package Genesis::Hook::Addon::Garage::Smoke v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/info/;

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
  # relies on a local alias that is not configured on every host).
  $self->env->bosh->run_errand("smoke-tests");

  info("#g{[ok]} smoke-tests passed");
  return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
