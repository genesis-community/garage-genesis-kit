package Genesis::Hook::Addon::Garage::ResetCredentials v0.1.0;

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
    "Run `genesis deploy` after rotation to apply the new credentials.";
}
# }}}

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;
  return 1 if $self->completed;

  my $env        = $self->env;
  my $env_name   = $env->name;
  my $vault_path = $env->vault_path_prefix;

  my $rpc_secret_path  = "$vault_path/credentials/rpc_secret";
  my $admin_token_path = "$vault_path/credentials/admin_token";

  info("");
  info("#Y{WARNING}: This will rotate Garage rpc_secret and admin_token.");
  info("All cluster nodes must be redeployed after rotation or they will");
  info("lose RPC connectivity (rpc_secret is a shared cluster secret).");
  info("");
  info("Vault paths that will be regenerated:");
  info("  #C{%s}", $rpc_secret_path);
  info("  #C{%s}", $admin_token_path);
  info("");

  # Prompt operator — abort unless confirmed
  print "This will rotate rpc_secret + admin_token. Continue? [y/N]: ";
  my $answer = <STDIN>;
  $answer //= '';
  chomp $answer;

  bail("Credential rotation aborted by operator.") unless lc($answer) eq 'y';

  info("");
  info("Rotating #C{rpc_secret} (64-char hex)...");
  my ($rpc_new, $rpc_rc) = run(
    { stderr => 1 },
    'bash', '-c',
    "openssl rand -hex 32 | safe -T $env_name set $rpc_secret_path"
  );
  bail("Failed to rotate rpc_secret (exit %d): %s", $rpc_rc, $rpc_new) unless $rpc_rc == 0;
  info("  #g{[ok]} rpc_secret rotated");

  info("Rotating #C{admin_token} (32-char hex)...");
  my ($tok_new, $tok_rc) = run(
    { stderr => 1 },
    'bash', '-c',
    "openssl rand -hex 16 | safe -T $env_name set $admin_token_path"
  );
  bail("Failed to rotate admin_token (exit %d): %s", $tok_rc, $tok_new) unless $tok_rc == 0;
  info("  #g{[ok]} admin_token rotated");

  info("");
  info("Credentials rotated. Run `genesis deploy` to apply new credentials:");
  info("  #G{genesis deploy %s}", $env_name);
  info("");
  info("#Y{Note}: All Garage nodes share rpc_secret. They will lose cluster");
  info("         connectivity until the redeploy completes.");

  return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
