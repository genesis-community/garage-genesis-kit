package Genesis::Hook::PostDeploy::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info/;

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

  # Read the exodus data this deploy just exported.  exodus_lookup returns
  # a value and key pair in list context, so each call is made scalar.
  my $s3_api_url = scalar($env->exodus_lookup('s3_api_url', undef)) // '(unknown)';
  my $cluster    = scalar($env->exodus_lookup('cluster', undef)) ? 1 : 0;
  my $ips        = scalar($env->exodus_lookup('ips', undef));
  # Genesis may store the list as one comma-separated string.
  $ips = [split /\s*,\s*/, $ips] if defined($ips) && !ref($ips);
  $ips = [] unless ref($ips) eq 'ARRAY';
  my $instances  = $cluster
    ? scalar($env->exodus_lookup('cluster_size', undef)) // scalar(@$ips) || 1
    : 1;

  info("  S3 API URL:   #G{%s}", $s3_api_url);
  info("  Instances:    #C{%d}", $instances);
  info("  Cluster mode: #C{%s}", $cluster ? 'yes' : 'no');
  info("");

  # Health probe on each instance via bosh ssh + curl admin endpoint
  # The garage job's own post-deploy script handles the cluster layout
  # bootstrap.  This hook provides operator-visible status only; failures are
  # non-fatal.  A single node binds the admin API to loopback, and a cluster
  # binds it to each instance's IP so that new nodes can reach it.
  my $admin_port = scalar($env->lookup('params.garage_admin_port', 3903));
  for my $idx (0 .. $instances - 1) {
    my $host = $cluster ? $ips->[$idx] : '127.0.0.1';
    $self->_probe_node($idx, $host, $admin_port);
  }

  info("");
  info(
    "For deployment details, run:\n".
    "  #G{genesis info $ENV{GENESIS_ENVIRONMENT}}\n"
  );

  return $self->done(1);
}
# }}}

# _probe_node - Curl the admin health endpoint on a specific Garage instance {{{
sub _probe_node {
  my ($self, $idx, $host, $admin_port) = @_;

  my $deployment = $self->env->deployment_name;
  my $target     = "garage/$idx";

  info("  Probing health of #C{$target}...");
  unless (defined($host)) {
    info("    #Y{[warn]} $target has no address in the exodus data - skipping its probe");
    return;
  }

  # bosh ssh + curl admin health endpoint; /health answers 503 until the node
  # can serve reads and writes, so curl fails on it.  Non-zero is non-fatal,
  # because the cluster may still be converging.
  #
  # Route through $self->env->bosh->execute rather than a bare `bosh -e <alias>`:
  # execute() sets BOSH_ENVIRONMENT to the director URL (plus CA/client creds),
  # so it connects straight to the director IP. A bare alias is resolved as a
  # hostname, and when a public DNS record shadows the alias the probe hangs
  # indefinitely on an i/o timeout instead of reaching the director.
  my ($out, $rc) = $self->env->bosh->execute(
    { stderr => 0, deployment => $deployment },
    'ssh', $target,
    '--command', "curl -sf --max-time 5 -o /dev/null http://$host:$admin_port/health",
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
