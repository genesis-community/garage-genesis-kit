package Genesis::Hook::PostDeploy::Garage v0.2.1;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::PostDeploy);

use Genesis qw/info/;
use JSON::PP ();

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

  # A missing return code is not a success.  Genesis passes it to the hook
  # and also exports it, so read either one, and treat anything other than
  # a plain 0 as a failed deploy.
  my $rc = defined($self->{rc}) ? $self->{rc} : $ENV{GENESIS_DEPLOY_RC};
  unless (defined($rc) && $rc =~ /^\s*0\s*$/) {
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
  my $rf         = scalar($env->exodus_lookup('replication_factor', undef));
  my $ips        = scalar($env->exodus_lookup('ips', undef));
  # Genesis may store the list as one comma-separated string.
  $ips = [split /\s*,\s*/, $ips] if defined($ips) && !ref($ips);
  $ips = [] unless ref($ips) eq 'ARRAY';

  # The probe targets come from BOSH, which knows which address belongs to
  # which instance.  Without it, fall back to the exodus addresses in index
  # order, which BOSH does not promise to match.
  my @nodes = $self->_garage_nodes;
  my $from_bosh = scalar(@nodes);
  unless (@nodes) {
    my $count = scalar($env->exodus_lookup('instances', undef));
    $count = scalar(@$ips) unless defined($count) && $count =~ /^[1-9][0-9]*$/;
    $count ||= 1;
    @nodes = map {{target => "garage/$_", ip => $ips->[$_]}} (0 .. $count - 1);
  }
  my $instances = scalar(@nodes);

  info("  S3 API URL:          #G{%s}", $s3_api_url);
  info("  Instances:           #C{%d}", $instances);
  info("  Replication factor:  #C{%s}", $rf // '(unknown)');
  info("");

  # Health probe on each instance via bosh ssh + curl admin endpoint
  # The garage job's own post-deploy script handles the cluster layout
  # bootstrap.  This hook provides operator-visible status only; failures are
  # non-fatal.  The release binds the admin API to loopback when its link has
  # one instance and to each instance's own IP when it has more, so the
  # probe follows the real instance count rather than the cluster feature.
  info("  #Y{[note]} BOSH did not list the instances, so each probe assumes garage/N owns the Nth exodus address")
    unless $from_bosh;
  my $admin_port = scalar($env->lookup('params.garage_admin_port', 3903));
  for my $node (@nodes) {
    my $host = $instances == 1 ? '127.0.0.1' : $node->{ip};
    $self->_probe_node($node->{target}, $host, $admin_port);
  }

  info("");
  info(
    "For deployment details, run:\n".
    "  #G{genesis info $ENV{GENESIS_ENVIRONMENT}}\n"
  );

  return $self->done(1);
}
# }}}

# _garage_nodes - every garage instance with its own address, from BOSH {{{
# Returns an empty list when BOSH cannot be asked, so the caller can fall
# back to the exodus data.  Errand VMs are skipped.
sub _garage_nodes {
  my ($self) = @_;
  my ($out, $rc) = eval {
    $self->env->bosh->execute(
      { stderr => 0, deployment => $self->env->deployment_name },
      'instances', '--json',
    );
  };
  return () if $@ || !defined($rc) || $rc != 0 || !defined($out);

  my $json = eval { JSON::PP->new->decode($out) };
  return () unless ref($json) eq 'HASH' && ref($json->{Tables}) eq 'ARRAY';

  my @nodes;
  for my $row (map {@{$_->{Rows} // []}} grep {ref($_) eq 'HASH'} @{$json->{Tables}}) {
    my $instance = $row->{instance} // '';
    next unless $instance =~ m{^garage/};
    $instance =~ s/\s*\(.*\)\s*$//;  # drop a "(bootstrap)" style suffix
    my @addresses = grep {$_ ne ''} split /[\s,]+/, ($row->{ips} // '');
    my ($ipv4) = grep {/^\d{1,3}(?:\.\d{1,3}){3}$/} @addresses;
    push @nodes, {target => $instance, ip => $ipv4 // $addresses[0]};
  }
  return @nodes;
}
# }}}

# _probe_node - Curl the admin health endpoint on a specific Garage instance {{{
sub _probe_node {
  my ($self, $target, $host, $admin_port) = @_;

  my $deployment = $self->env->deployment_name;

  info("  Probing health of #C{$target}...");
  unless (defined($host)) {
    info("    #Y{[warn]} $target has no known address - skipping its probe");
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
  my $url_host = $host =~ /:/ ? "[$host]" : $host;
  my ($out, $rc) = $self->env->bosh->execute(
    { stderr => 0, deployment => $deployment },
    'ssh', $target,
    '--command', "curl -sf --max-time 5 -o /dev/null http://$url_host:$admin_port/health",
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
