package Genesis::Hook::Info::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail info/;

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

	my $exodus = $self->env->exodus_lookup('/') || {};

	my $s3_api_url   = $exodus->{s3_api_url}    || '';
	my $ips          = $exodus->{ips}            || '(not set)';
	my $cluster      = $exodus->{cluster}        || 0;
	my $cluster_size = $exodus->{cluster_size}   || '';

	if (!$s3_api_url) {
		info("Garage not yet deployed — run `genesis deploy` first.");
		return $self->done(1);
	}

	# Instance count: prefer exodus (post-deploy truth), then params, then default 1
	my $instance_count = $exodus->{instances}
		|| $self->env->lookup('params.instances', 1);

	my $cluster_mode = $cluster ? 'yes' : 'no';

	my $vault_path   = $self->env->vault_path;
	my $env_name     = $self->env->name;
	my $deployment   = $self->env->deployment_name;

	info("Garage Info:");
	info("  Deployment:   %s", $deployment);
	info("  S3 API URL:   %s", $s3_api_url);
	info("  IPs:          %s", $ips);
	info("  Cluster mode: %s", $cluster_mode);
	if ($cluster && $cluster_size) {
		info("  Cluster size: %s", $cluster_size);
	}
	info("  Admin token:  (stored in vault at %s/credentials/admin_token)", $vault_path);
	info("  RPC secret:   (stored in vault at %s/credentials/rpc_secret)", $vault_path);
	info("");
	info("Useful commands:");
	info("  Smoke test:          genesis %s do smoke", $env_name);
	info("  Rotate credentials:  genesis %s do reset-credentials", $env_name);
	info("  Garage CLI info:     genesis %s do mc", $env_name);

	return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
