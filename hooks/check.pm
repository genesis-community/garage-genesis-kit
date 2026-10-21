package Genesis::Hook::Check::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Check);

use Genesis qw/info warning/;

# Include the shared cluster shape helpers
BEGIN {
	require File::Basename;
	require File::Spec;
	my $mixin_file = File::Basename::dirname(File::Spec->rel2abs(__FILE__)) . '/lib/_garage_shape.pm';
	do $mixin_file or die "Failed to include hook mixin $mixin_file: " . ($@ || $! || 'unknown error');
}

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
	$ok = 0 unless $self->check_cluster_shape;

	# Stemcells are left to Genesis core, which checks every stemcell the
	# manifest names on deploy and on `genesis check --stemcells`, and skips
	# them under --no-stemcells.  The kit used to repeat that check here and
	# contacted the director even when the operator had turned it off.

	return $self->done($ok);
}
# }}}

# check_cloud_config - The vm type, network, and disk type the manifest uses {{{
sub check_cloud_config {
	my ($self) = @_;
	return 1 unless $ENV{GENESIS_CLOUD_CONFIG};

	$self->start_check('cloud-config');

	# An explicit param always wins, as it does in the manifest.  Without one,
	# the ocfp feature names every entry after the environment and type
	# (manifests/ocfp.yml), and otherwise the manifest defaults apply.
	my %default = (vm_type => 'default', network => 'garage', disk_type => 'default');
	if ($self->want_feature('ocfp')) {
		my $cloud = "$ENV{GENESIS_ENVIRONMENT}.$ENV{GENESIS_TYPE}.";
		%default = (
			vm_type   => "${cloud}vm-garage",
			network   => "${cloud}net-garage",
			disk_type => "${cloud}disk-garage",
		);
	}
	my $vm_type   = scalar($self->env->lookup('params.garage_vm_type',   $default{vm_type}));
	my $network   = scalar($self->env->lookup('params.garage_network',   $default{network}));
	my $disk_type = scalar($self->env->lookup('params.garage_disk_type', $default{disk_type}));

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

	# The manifest reads the CF exodus data of the environment with the same
	# name (manifests/route-registrar.yml), so the check reads it from there.
	my @errors;
	my $cf_slug   = $self->env->name . '/cf';
	my $cf_exodus = eval { scalar($self->env->exodus_lookup('.', undef, $cf_slug)) };
	if ($@) {
		push @errors, "could not read CF exodus data: $@";
	} elsif (ref($cf_exodus) ne 'HASH') {
		push @errors, "no CF exodus data under $cf_slug, so deploy CF first";
	} else {
		push @errors, "CF exodus missing system_domain"    unless $cf_exodus->{system_domain};
		push @errors, "CF exodus missing nats_client_cert" unless $cf_exodus->{nats_client_cert};
		push @errors, "CF exodus missing nats_client_key"  unless $cf_exodus->{nats_client_key};
	}

	return $self->check_result('route-registrar', 'failed', join('; ', @errors)) if @errors;
	return $self->check_result('route-registrar', 'passed');
}
# }}}

# check_cluster_shape - Refuse unsafe replication factors and shrinking {{{
# Garage keeps replication_factor copies of each object, refuses to start a
# node whose factor differs from the one in its stored layout, and loses the
# copies on any node BOSH deletes before the layout has moved them.  The
# last deploy's exodus data holds the factor and the instance count it
# used, so the next deploy is compared against them.  A first deploy has no
# exodus data and only gets the checks that need none.
sub check_cluster_shape {
	my ($self) = @_;
	$self->start_check('garage cluster shape');

	my $instances = $self->_garage_instance_count;
	my ($rf, $explicit) = $self->_garage_replication_factor($instances);
	my $previous = $self->_garage_previous_shape($explicit ? $rf : undef);

	my @errors = _garage_shape_errors(
		instances        => $instances,
		rf               => $rf,
		previous         => $previous,
		allow_rf1        => scalar($self->env->lookup('params.garage_allow_rf1', 0)),
		allow_scale_down => scalar($self->env->lookup('params.garage_allow_scale_down', 0)),
	);
	if (@errors) {
		info("[[    - >>#R{%s}", $_) for @errors;
		return $self->check_result('garage cluster shape', 'failed');
	}

	return $self->check_result(
		'garage cluster shape', 'passed',
		sprintf(
			"%d %s with a replication factor of %d%s",
			$instances, $instances == 1 ? 'node' : 'nodes', $rf,
			$previous ? '' : ' (first deploy)'
		)
	);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
