package Genesis::Hook::Addon::Garage::Smoke v0.2.1;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/info bail/;

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
  return "Run the smoke-tests BOSH errand against the deployed Garage cluster.";
}
# }}}

# perform - Main hook execution {{{
sub perform {
  my ($self) = @_;
  return 1 if $self->completed;

  info("");
  info("Running #C{smoke-tests} errand...");

  # Run through the env's BOSH director object so the correct director URL,
  # credentials, and deployment context are used (a bare `bosh -e <alias>`
  # relies on a local alias that is not configured on every host).  On Linux,
  # Genesis runs interactive bosh commands under `script`, which loses the
  # errand's exit code, so we run it non-interactively and check that code.
  my ($out, $rc) = $self->env->bosh->execute(
    { interactive => 0, stderr => 0 },
    'run-errand', 'smoke-tests'
  );
  info("%s", $out) if defined($out) && $out ne '';
  bail("#R{[failed]} the smoke-tests errand exited %d", $rc) unless $rc == 0;

  info("#g{[ok]} smoke-tests passed");
  return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
