package Genesis::Hook::Blueprint::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Blueprint);

use Genesis qw/bail info warning error mkfile_or_fail count_nouns/;

# Include the shared cluster shape helpers
BEGIN {
	require File::Basename;
	require File::Spec;
	my $mixin_file = File::Basename::dirname(File::Spec->rel2abs(__FILE__)) . '/lib/_garage_shape.pm';
	do $mixin_file or die "Failed to include hook mixin $mixin_file: " . ($@ || $! || 'unknown error');
}

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
		# Determine instance count and IPs from ocfp config.  The dedicated
		# static IP for the smoke-tests errand comes from instance 0's subnet.
		# The "garage_ip_smoke" reserved-ip is pinned to the smoke-tests errand
		# IG via a (( replace )) network fragment so spruce does not append a
		# duplicate network entry.
		my $az_map = $self->env->director_exodus_lookup('/network')->{azs};
		my ($reserved_ips, $subnet_azs, $smoke_ip) = $self->_garage_ocfp_reserved;
		my @ips = @$reserved_ips;
		my @azs = map {
			if (!$_) {
				warning("No AZ found for a subnet that reserves a garage_ip");
				undef;
			} else {
				$az_map->{$_}{name} || undef;
			}
		} @$subnet_azs;

		my $instances = $self->_garage_instance_count;
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

		} elsif ($feature eq 'resolute') {
			# Handled after the loop so that it overrides every other fragment.

		} elsif (-f "$ENV{GENESIS_ROOT}/${feature}.yml") {
			$self->add_files("$ENV{GENESIS_ROOT}/${feature}.yml");

		} else {
			push @invalid, $feature;
		}
	}

	# The default replication factor depends on how many nodes the manifest
	# deploys, which spruce cannot work out, so it is set here.  Three nodes
	# or more get three copies, and smaller clusters get one copy per node.
	# An explicit params.garage_replication_factor still wins in the manifest.
	my $default_rf = _garage_default_rf($self->_garage_instance_count);
	$dynamic_static_fragment = <<"EOF" . $dynamic_static_fragment;
meta:
  default:
    replication_factor: $default_rf

EOF

	# The static IP fragment goes after every feature fragment. cluster.yml
	# sets its own static_ips, and when it came later it replaced params.ips
	# and, under ocfp, appended a second network to the instance group.
	my $statics_file = "manifests/network.dynamic.yml";
	mkfile_or_fail($self->env->kit->path($statics_file), 0644, $dynamic_static_fragment);
	$self->add_files($statics_file);

	$self->_process_resolute;

	bail(
		"Invalid %s encountered: %s",
		count_nouns(scalar(@invalid), 'feature', suppress_count => 1),
		join(', ', @invalid)
	) if @invalid;

	return $self->done(1);
}

# _process_resolute - Opt-in ubuntu-resolute stemcell support {{{
# Called after every other fragment is added so that it overrides the
# stemcell os default (ubuntu-noble) and the bpm release pin.
sub _process_resolute {
	my ($self) = @_;

	if ($self->want_feature('resolute')) {
		my $stemcell_os = $self->env->lookup('params.stemcell_os', 'ubuntu-resolute');
		bail(
			"The #c{resolute} feature sets the stemcell os to ubuntu-resolute, but " .
			"the environment sets #c{params.stemcell_os} to #R{%s}.  " .
			"Remove that parameter.", $stemcell_os
		) if $stemcell_os ne 'ubuntu-resolute';
		$self->add_files(
			'manifests/resolute.yml',
			# bpm releases older than 1.4.41 do not compile on resolute.
			'manifests/releases/bpm-resolute.yml',
		);
	} elsif ($self->env->lookup('params.stemcell_os', 'ubuntu-noble') eq 'ubuntu-resolute') {
		bail(
			"The environment sets #c{params.stemcell_os} to ubuntu-resolute " .
			"without the #c{resolute} feature.  Enable the feature and remove " .
			"that parameter."
		);
	}
	return;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
