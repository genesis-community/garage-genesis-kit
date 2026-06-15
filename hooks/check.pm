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

	# Cloud Config checks
	if ($ENV{GENESIS_CLOUD_CONFIG}) {
		$self->start_check("Checking cloud config");

		my @errors;

		push @errors, $self->env->missing_cloud_config_keys(
			vm_type   => [$self->env->lookup('params.garage_vm_type',   'default')],
			network   => [$self->env->lookup('params.garage_network',   'garage')],
			disk_type => [$self->env->lookup('params.garage_disk_type', 'default')],
		);

		if (@errors) {
			$self->check_result(0, join("\n", @errors));
			$ok = 0;
		} else {
			$self->check_result(1);
		}
	}

	# route-registrar: verify CF exodus has required fields
	# uses NATS mTLS (cert+key), not the older password-based auth
	if ($self->want_feature('route-registrar')) {
		$self->start_check("Checking CF exodus data for route-registrar");

		my @errors;
		my $cf_exodus = eval { $self->env->cf_exodus_lookup('/') };
		if ($@) {
			push @errors, "Could not read CF exodus data: $@";
		} else {
			push @errors, "CF exodus missing system_domain"
				unless $cf_exodus->{system_domain};
			push @errors, "CF exodus missing nats_client_cert"
				unless $cf_exodus->{nats_client_cert};
			push @errors, "CF exodus missing nats_client_key"
				unless $cf_exodus->{nats_client_key};
		}

		if (@errors) {
			$self->check_result(0, join("\n", @errors));
			$ok = 0;
		} else {
			$self->check_result(1);
		}
	}

	# Stemcell availability check (warn only — bosh deploy enforces hard error)
	{
		$self->start_check("Checking stemcell ubuntu-noble availability");
		my $stemcell_os = $self->env->lookup('params.stemcell_os', 'ubuntu-noble');
		my @stemcells   = eval { $self->env->bosh->stemcells() };
		if ($@) {
			# Non-fatal: bosh connectivity failure during check is best-effort
			warning("Could not query BOSH director for stemcells: %s", $@);
			$self->check_result(1, "skipped (could not contact director)");
		} else {
			# bosh->stemcells() may return hashrefs (with an 'os' key) or
			# plain "os@version" strings depending on Genesis version; match
			# either form.
			my ($found) = grep {
				ref($_) eq 'HASH'
					? (($_->{os} // '') eq $stemcell_os)
					: (defined($_) && $_ =~ /\Q$stemcell_os\E/);
			} @stemcells;
			if ($found) {
				$self->check_result(1);
			} else {
				warning(
					"Stemcell '%s' not found in director — upload before deploying",
					$stemcell_os
				);
				# check_result(1) because bosh deploy will produce the hard error;
				# we only warn here to give early feedback.
				$self->check_result(1, "warning: stemcell '$stemcell_os' not uploaded");
			}
		}
	}

	return $self->done($ok);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
