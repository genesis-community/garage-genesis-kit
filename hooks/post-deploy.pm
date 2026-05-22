package Genesis::Hook::PostDeploy::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info run/;

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

  unless ($ENV{GENESIS_DEPLOY_RC} == 0) {
    info("#R{Deployment failed} - skipping post-deploy actions");
    return $self->done(1);
  }

  info("");
  info("#M{$ENV{GENESIS_ENVIRONMENT}} Garage deployed successfully!");
  info("");

  my $env = $self->env;

  # Read exodus values written by spruce during the deploy
  my $s3_api_url = $self->_exodus_value('s3_api_url') // '(unknown)';
  my $instances  = $self->_exodus_value('instances')  // 1;
  my $cluster    = $self->_exodus_value('cluster')    // 0;

  info("  S3 API URL:   #G{%s}", $s3_api_url);
  info("  Instances:    #C{%d}", $instances);
  info("  Cluster mode: #C{%s}", $cluster ? 'yes' : 'no');
  info("");

  # Health probe on each instance via bosh ssh + curl admin endpoint
  # The BOSH post-deploy.erb hook on index 0 handles cluster layout bootstrap.
  # This hook provides operator-visible status only; failures are non-fatal.
  for my $idx (0 .. $instances - 1) {
    $self->_probe_node($idx);
  }

  info("");
  info(
    "For deployment details, run:\n".
    "  #G{genesis info $ENV{GENESIS_ENVIRONMENT}}\n"
  );

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

# _probe_node - Curl the admin health endpoint on a specific Garage instance {{{
sub _probe_node {
  my ($self, $idx) = @_;

  my $deployment = $self->env->deployment_name;
  my $target     = "garage/$idx";

  info("  Probing health of #C{$target}...");

  # bosh ssh + curl admin health endpoint on loopback port 3903; non-zero is
  # non-fatal — cluster may still be converging or layout may not yet be applied
  my ($out, $rc) = run(
    { stderr => 0 },
    'bosh', '-e', $self->env->bosh->alias,
    '-d', $deployment,
    'ssh', $target,
    '--command', 'curl -sk --max-time 5 http://127.0.0.1:3903/health',
    '--results', '--json'
  );

  if ($rc == 0) {
    info("    #g{[ok]} $target health endpoint responded");
  } else {
    info(
      "    #Y{[warn]} $target health probe failed (exit $rc) - ".
      "cluster may still be converging"
    );
  }
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
