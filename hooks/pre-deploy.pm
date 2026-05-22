package Genesis::Hook::PreDeploy::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

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

  my $env  = $self->env;
  my $name = $env->name;

  info("");
  info("#M{$name} - Garage pre-deploy");
  info("  target:     #C{%s}", $name);
  info("  deployment: #C{%s}", $env->deployment_name);
  info("");
  info("Genesis manages credentials - no pre-deploy credential checks needed.");
  info("Cluster layout bootstrap runs automatically on index 0 after the first deploy.");
  info("");

  return $self->done(1);
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
