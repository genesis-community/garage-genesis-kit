package Genesis::Hook::Blueprint::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Blueprint);

use Genesis qw/bail info warning error mkfile_or_fail count_nouns/;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	$self->add_files(
		'manifests/garage.yml',
		'manifests/releases/garage.yml',
		'manifests/releases/bpm.yml',
	);

	my $iaas = $self->iaas;
	my $ips  = $self->env->lookup('params.ips', []);

	# Track which optional releases have been added to avoid duplicates
	my %added_releases;

	my $dynamic_static_fragment = '';
	if ($self->want_feature('ocfp')) {
		# Determine instance count and IPs from ocfp config
		my $subnets = $self->env->ocfp_config_lookup('net.subnets');
		my $prefix   = $self->env->ocfp_subnet_prefix;
		my $az_map   = $self->env->director_exodus_lookup('/network')->{azs};

		my (@ips, @azs) = ();
		# Dedicated static IP for the smoke-tests errand taken from instance 0's
		# subnet. The "garage_ip_smoke" reserved-ip is collected here and pinned
		# to the smoke-tests errand IG via a (( replace )) network fragment so
		# spruce does not append a duplicate network entry.
		my $smoke_ip;
		for my $subnet (sort grep {/^$prefix/} keys %$subnets) {
			my $ip = $subnets->{$subnet}{'reserved-ips'}{'garage_ip'};
			next unless $ip;
			push @ips, $ip;
			$smoke_ip //= $subnets->{$subnet}{'reserved-ips'}{'garage_ip_smoke'};

			my $az = $subnets->{$subnet}{az};
			if (!$az) {
				warning("No AZ found for subnet %s", $subnet);
				push @azs, undef;
			} else {
				push @azs, $az_map->{$az}{name} || undef;
			}
		}

		my $instances = $self->env->lookup('params.ocfp_instances') || scalar(@ips);
		bail(
			"Only %s instances available under OCFP; environment requested %s",
			scalar(@ips), $instances
		) if $instances > scalar(@ips);

		@ips = @ips[0..$instances-1];
		@azs = @azs[0..$instances-1];
		my $network_name = "$ENV{GENESIS_ENVIRONMENT}.$ENV{GENESIS_TYPE}.net-garage";

		my @valid_azs = grep { defined $_ } @azs;
		bail("No valid availability zones found for Garage instances") unless @valid_azs;

		# Deduped AZ names for the top-level azs: block (below).
		my %seen_az;
		my @uniq_azs = grep { !$seen_az{$_}++ } @valid_azs;

		# Each AZ carries the environment's CPI so the deploy-time stemcell
		# check matches the right (named) CPI's stemcells; fall back to a bare
		# name when the env has no distinct CPI.
		my $cpi_name = $self->env->cpi_name;
		my $az_block = join '', map {
			"\n- name: $_" . (defined $cpi_name ? "\n  cpi: $cpi_name" : '')
		} @uniq_azs;

		# Top-level azs: lets the deploy-time AZ check resolve the instance
		# group's AZs (genesis reads the unmerged manifest, which otherwise has
		# no azs); genesis prunes this block before bosh deploy.
		#
		# azs (instance group): the base manifest value is a (( grab )) scalar
		# operator, so a literal array overwrites it cleanly — no replace
		# directive (a leading (( replace )) would survive as a literal AZ,
		# since there is no base array to replace).
		#
		# networks: the base manifest value is a literal array, so a leading
		# (( replace )) correctly discards it and pins the ocfp network + static
		# IPs.
		$dynamic_static_fragment = <<"EOF";
exodus:
  ips: ${\(join ',', @ips)}

azs:$az_block

instance_groups:
- name: garage
  azs:${\(join "\n  - ", '', @valid_azs)}
  instances: $instances
  networks:
  - (( replace ))
  - name: $network_name
    static_ips:${\(join "\n    - ", '', @ips)}
EOF

		# Pin the errand to its dedicated static IP on net-garage when one is
		# reserved; otherwise the errand falls back to the manifest default
		# (a dynamic address, if the network has spare capacity).
		if ($smoke_ip) {
			# Replace the errand's grab-derived network (the base entry's name is
			# an unresolved (( grab )) at merge time, so spruce would otherwise
			# append rather than merge) and pin it to net-garage + the smoke IP.
			$dynamic_static_fragment .= <<"EOF";
- name: smoke-tests
  networks:
  - (( replace ))
  - name: $network_name
    static_ips:
    - $smoke_ip
EOF
		}

	} elsif (my $instances = scalar(@$ips)) {
		$dynamic_static_fragment = <<"EOF";
exodus:
  ips: ${\(join ',', @$ips)}

instance_groups:
- name: garage
  instances: $instances
  networks:
  - name: (( grab params.garage_network || "garage" ))
    static_ips:${\(join "\n    - ", '', @$ips)}
EOF
	}

	if ($dynamic_static_fragment) {
		my $statics_file = "manifests/network.dynamic.yml";
		mkfile_or_fail($self->env->kit->path($statics_file), 0644, $dynamic_static_fragment);
		$self->add_files($statics_file);
	}

	$self->add_files('manifests/azure.yml')   if $iaas eq 'azure';
	$self->add_files('manifests/stackit.yml') if $iaas eq 'stackit';

	my @invalid = ();
	for my $feature ($self->features) {
		if ($feature eq 'ocfp') {
			$self->add_files('manifests/ocfp.yml');

		} elsif ($feature eq 'route-registrar') {
			$self->add_files('manifests/route-registrar.yml');
			unless ($added_releases{'routing'}++) {
				$self->add_files('manifests/releases/routing.yml');
			}
			unless ($added_releases{'bosh-dns-aliases'}++) {
				$self->add_files('manifests/releases/bosh-dns-aliases.yml');
			}

		} elsif ($feature eq 'cluster') {
			$self->add_files('manifests/cluster.yml');
			unless ($added_releases{'bosh-dns-aliases'}++) {
				$self->add_files('manifests/releases/bosh-dns-aliases.yml');
			}

		} elsif ($feature =~ /^scale-(small|medium|large)$/) {
			$self->add_files("manifests/scale-${1}.yml");

		} elsif ($feature =~ /^upgrade-(serial|all-at-once)$/) {
			$self->add_files("manifests/upgrade-${1}.yml");

		} elsif (-f "$ENV{GENESIS_ROOT}/${feature}.yml") {
			$self->add_files("$ENV{GENESIS_ROOT}/${feature}.yml");

		} else {
			push @invalid, $feature;
		}
	}

	bail(
		"Invalid %s encountered: %s",
		count_nouns(scalar(@invalid), 'feature', suppress_count => 1),
		join(', ', @invalid)
	) if @invalid;

	return $self->done(1);
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
