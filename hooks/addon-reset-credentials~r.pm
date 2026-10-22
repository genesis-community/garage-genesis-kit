package Genesis::Hook::Addon::Garage::ResetCredentials v0.2.1;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/info bail run/;

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
    "Regenerate the Garage rpc_secret and admin_token in Vault.\n".
    "Prompts for confirmation before rotating. Does not redeploy automatically.\n".
    "Apply the new values with a full stop, then a deploy with every node in\n".
    "flight, because nodes holding different RPC secrets cannot talk.";
}
# }}}

# The secrets this addon rotates, with the number of hex characters each has.
# They match the definitions in kit.yml.
my @ROTATED = (
  [rpc_secret  => 64],
  [admin_token => 32],
);

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;
  return 1 if $self->completed;

  my $env      = $self->env;
  my $env_name = $env->name;

  # The environment's own vault, which genesis.vault names.  Its query()
  # runs safe with SAFE_TARGET set to that vault, so this works whatever the
  # operator's safe targets are called, and whichever one is current.
  my $vault = $env->vault;
  bail("No vault is configured for #M{%s}, so its credentials cannot be rotated.", $env_name)
    unless $vault;
  (my $path = $env->secrets_base . 'credentials') =~ s{^/+}{};

  info("");
  info("#Y{WARNING}: This will rotate the Garage rpc_secret and admin_token.");
  info("Every node must restart with the new rpc_secret at the same time.  A node");
  info("holding the new secret cannot talk to nodes holding the old one, so a");
  info("rolling deploy stalls on its first node.  Apply the rotation with:");
  info("");
  $self->_print_procedure;
  info("");
  info("Vault keys that will be regenerated:");
  info("  #C{%s:%s}", $path, $_->[0]) for @ROTATED;
  info("");

  # Prompt operator — abort unless confirmed
  print "This will rotate rpc_secret + admin_token. Continue? [y/N]: ";
  my $answer = <STDIN>;
  $answer //= '';
  chomp $answer;

  bail("Credential rotation aborted by operator.") unless lc($answer) eq 'y';

  info("");
  for my $secret (@ROTATED) {
    my ($key, $length) = @$secret;
    info("Rotating #C{%s} (%d hex characters)...", $key, $length);
    $self->_rotate($vault, $path, $key, $length);
    info("  #g{[ok]} %s rotated", $key);
  }

  info("");
  info("Credentials rotated.  Stop the deployment, then deploy and start every node at once:");
  $self->_print_procedure;
  info("");
  info("#Y{Note}: The running nodes keep the old secrets until that deploy, and a");
  info("         node that restarts before it cannot rejoin the cluster.");

  return $self->done(1);
}
# }}}

# _print_procedure - the commands that apply a rotation {{{
# A full stop first, so that no node is left running with the old secret.
# The deploy then updates every node at once with no canary, and a start
# with every node in flight brings them up together, because bosh deploy
# leaves stopped instances stopped.
sub _print_procedure {
  my ($self) = @_;
  my $env_name = $self->env->name;
  my $count = scalar($self->env->exodus_lookup('instances', undef));
  $count = '<instances>' unless defined($count) && $count =~ /^[1-9][0-9]*$/;
  info("  #G{genesis %s bosh stop}", $env_name);
  info("  #G{genesis deploy %s --canaries=0 --max-in-flight=%s}", $env_name, $count);
  info("  #G{genesis %s bosh start --canaries=0 --max-in-flight=100%%}", $env_name);
  return;
}
# }}}

# _rotate - generate a new value for one key and confirm Vault holds it {{{
# safe gen takes its arguments as a list, so no value or path passes through
# a shell.  Reads go through Service::Vault::get, which redacts the output,
# and no value is ever printed.
sub _rotate {
  my ($self, $vault, $path, $key, $length) = @_;

  my $before = $vault->get($path, $key);

  my (undef, $rc, $err) = $vault->query(
    { stderr => 0, redact_output => 1 },
    'gen', '-l', $length, '--policy', '0-9a-f', $path, $key
  );
  bail(
    "Failed to rotate #C{%s:%s} (safe exited %d): %s",
    $path, $key, $rc, ($err // '') =~ s/\s+$//r || 'no error output'
  ) unless $rc == 0;

  my $after = $vault->get($path, $key);
  bail(
    "safe reported success, but #C{%s:%s} could not be read back afterwards.",
    $path, $key
  ) unless defined($after) && $after ne '';
  bail(
    "safe reported success, but #C{%s:%s} does not hold %d hex characters.",
    $path, $key, $length
  ) unless $after =~ /^[0-9a-f]{$length}$/;
  bail(
    "safe reported success, but #C{%s:%s} still holds its old value.",
    $path, $key
  ) if defined($before) && $before eq $after;
  return 1;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
