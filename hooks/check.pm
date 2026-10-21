package Genesis::Hook::Check::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Check);

use Genesis qw/info warning/;

# init - Initialize the hook {{{
sub init {
	my ($class, %ops) = @_;
	my $obj = $class->SUPER::init(%ops);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}
# }}}

# perform - Main hook execution {{{
sub perform {
	my ($self) = @_;
	my $ok = 1;

	$ok = 0 unless $self->check_cloud_config;
	$ok = 0 unless $self->check_route_registrar;
	$self->check_stemcell;

	return $self->done($ok);
}
# }}}

# check_cloud_config - The vm type, network, and disk type the manifest uses {{{
sub check_cloud_config {
	my ($self) = @_;
	return 1 unless $ENV{GENESIS_CLOUD_CONFIG};

	$self->start_check('cloud-config');

	# The ocfp feature names every entry after the environment and type
	# (manifests/ocfp.yml); otherwise the params, or their defaults, apply.
	my ($vm_type, $network, $disk_type);
	if ($self->want_feature('ocfp')) {
		my $cloud = "$ENV{GENESIS_ENVIRONMENT}.$ENV{GENESIS_TYPE}.";
		($vm_type, $network, $disk_type) = map {"${cloud}$_"} qw/vm-garage net-garage disk-garage/;
	} else {
		$vm_type   = $self->env->lookup('params.garage_vm_type',   'default');
		$network   = $self->env->lookup('params.garage_network',   'garage');
		$disk_type = $self->env->lookup('params.garage_disk_type', 'default');
	}

	$self->has_entry('cloud-config', 'vm_type',   $vm_type);
	$self->has_entry('cloud-config', 'network',   $network);
	$self->has_entry('cloud-config', 'disk_type', $disk_type);

	return $self->check_result('cloud-config');
}
# }}}

# check_route_registrar - CF exodus data the route-registrar feature needs {{{
# route-registrar uses NATS mTLS (cert+key), not the older password-based auth.
sub check_route_registrar {
	my ($self) = @_;
	return 1 unless $self->want_feature('route-registrar');

	$self->start_check('route-registrar');

	my @errors;
	my $cf_exodus = eval { $self->env->cf_exodus_lookup('/') };
	if ($@) {
		push @errors, "could not read CF exodus data: $@";
	} else {
		push @errors, "CF exodus missing system_domain"    unless $cf_exodus->{system_domain};
		push @errors, "CF exodus missing nats_client_cert" unless $cf_exodus->{nats_client_cert};
		push @errors, "CF exodus missing nats_client_key"  unless $cf_exodus->{nats_client_key};
	}

	return $self->check_result('route-registrar', 'failed', join('; ', @errors)) if @errors;
	return $self->check_result('route-registrar', 'passed');
}
# }}}

# check_stemcell - Warn when the director lacks the stemcell os {{{
# Warn only: bosh deploy produces the hard error.
sub check_stemcell {
	my ($self) = @_;

	my $stemcell_os = $self->env->lookup(
		'params.stemcell_os',
		$self->want_feature('resolute') ? 'ubuntu-resolute' : 'ubuntu-noble'
	);
	$self->start_check("stemcell $stemcell_os");

	my @stemcells = eval { $self->env->bosh->stemcells() };
	if ($@) {
		return $self->check_result('stemcell', 'skipped', 'could not contact the director');
	}

	# bosh->stemcells() may return hashrefs (with an 'os' key) or plain
	# "os@version" strings depending on Genesis version; match either form.
	my ($found) = grep {
		ref($_) eq 'HASH'
			? (($_->{os} // '') eq $stemcell_os)
			: (defined($_) && $_ =~ /\Q$stemcell_os\E/);
	} @stemcells;

	return $self->check_result('stemcell', 'passed') if $found;
	warning("Stemcell '%s' not found in director — upload before deploying", $stemcell_os);
	return $self->check_result('stemcell', 'warning', "$stemcell_os not uploaded");
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
