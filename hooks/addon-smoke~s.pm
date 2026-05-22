package Genesis::Hook::Addon::Garage::Smoke v0.1.0;

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

  my $env        = $self->env;
  my $deployment = $env->deployment_name;

  system("bosh", "-e", $env->bosh->alias, "-d", $deployment, "run-errand", "smoke-tests") == 0
    or bail("smoke-tests errand failed (exit %d)", $? >> 8);

  info("#g{[ok]} smoke-tests passed");
  return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
