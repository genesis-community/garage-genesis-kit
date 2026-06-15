package Genesis::Hook::Addon::Garage::Mc v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/info run bail/;

# init - Initialize the hook {{{
sub init {
  my $class = shift;
  my $obj = $class->SUPER::init(@_);
  $obj->check_minimum_genesis_version('3.1.0');
  return $obj;
}
# }}}

# cmd_details - Short description shown in genesis do --list {{{
sub cmd_details {
  return
    "Print garage CLI commands and mc (MinIO client) alias setup for the cluster.\n".
    "Requires BOSH access for garage CLI commands; requires mc locally for mc commands\n".
    "(https://min.io/docs/minio/linux/reference/minio-mc.html).";
}
# }}}

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;
  return 1 if $self->completed;

  my $env        = $self->env;
  my $env_name   = $env->name;
  my $vault_path = $env->vault_path_prefix;
  my $deployment = $env->deployment_name;

  # Read S3 API URL from exodus
  my $s3_api_url = $self->_exodus_value('s3_api_url');
  bail(
    "Could not read s3_api_url from exodus for environment %s.\n".
    "Ensure the environment has been deployed at least once.",
    $env_name
  ) unless $s3_api_url;

  # Read admin token from vault (sensitive — not written to exodus)
  my ($admin_token, $at_rc) = run(
    { stderr => 0 },
    'safe', '-T', $env_name,
    'get', "$vault_path/credentials:admin_token"
  );
  bail(
    "Could not read admin_token from Vault path %s/credentials:admin_token.\n".
    "Ensure you are authenticated: safe -T %s auth",
    $vault_path, $env_name
  ) unless $at_rc == 0 && $admin_token;
  chomp $admin_token;

  my $alias = "garage-$env_name";
  $alias =~ s/[^A-Za-z0-9_-]/-/g;

  info("");
  info("#M{Garage CLI commands for environment: %s}", $env_name);
  info("");
  info("Run garage CLI directly on the deployed VMs via BOSH:");
  info("");
  info("  Cluster status:");
  info("    #G{bosh -d %s ssh garage/0 -c 'source /var/vcap/jobs/garage/bin/env.sh && garage status'}",
    $deployment);
  info("");
  info("  Layout overview:");
  info("    #G{bosh -d %s ssh garage/0 -c 'source /var/vcap/jobs/garage/bin/env.sh && garage layout show'}",
    $deployment);
  info("");
  info("  List keys:");
  info("    #G{bosh -d %s ssh garage/0 -c 'source /var/vcap/jobs/garage/bin/env.sh && garage key list'}",
    $deployment);
  info("");
  info("  Node info:");
  info("    #G{bosh -d %s ssh garage/0 -c 'source /var/vcap/jobs/garage/bin/env.sh && garage node info'}",
    $deployment);
  info("");
  info("#M{mc client setup for environment: %s}", $env_name);
  info("");
  info("To use the MinIO mc client against this Garage cluster, first create an S3 key:");
  info("  #G{bosh -d %s ssh garage/0 -c 'source /var/vcap/jobs/garage/bin/env.sh && garage key create <key-name>'}",
    $deployment);
  info("");
  info("Then configure mc with the returned access_key and secret_key:");
  info("  #G{mc alias set %s %s <access_key> <secret_key>}",
    $alias, $s3_api_url);
  info("");
  info("Common mc commands (using alias #C{%s}):", $alias);
  info("");
  info("  List buckets:");
  info("    #G{mc ls %s}", $alias);
  info("");
  info("  Create a bucket:");
  info("    #G{mc mb %s/<bucket-name>}", $alias);
  info("");
  info("  Upload a file:");
  info("    #G{mc cp <local-file> %s/<bucket-name>/}", $alias);
  info("");
  info("  Download a file:");
  info("    #G{mc cp %s/<bucket-name>/<file> <local-dest>}", $alias);
  info("");
  info("  Remove a bucket (recursive):");
  info("    #G{mc rb --force %s/<bucket-name>}", $alias);
  info("");
  info("#Y{Note}: Garage does not use access_key/secret_key from this kit's admin_token.");
  info("         The admin_token is for the Garage admin API only.");
  info("         S3 access keys are managed via `garage key create` on the cluster.");
  info("");

  return $self->done(1);
}
# }}}

# _exodus_value - Read a single key from genesis exodus data {{{
sub _exodus_value {
  my ($self, $key) = @_;

  my ($out, $rc) = run(
    { stderr => 0 },
    'safe', '-T', $ENV{GENESIS_ENVIRONMENT},
    'get', "$ENV{GENESIS_EXODUS_MOUNT}:$key"
  );
  return undef unless $rc == 0 && defined $out;
  chomp $out;
  return $out;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
