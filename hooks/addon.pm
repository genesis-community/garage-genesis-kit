package Genesis::Hook::Addon::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {
  push @INC,
    $ENV{GENESIS_LIB}
      ? $ENV{GENESIS_LIB}
      : $ENV{HOME}.'/.genesis/lib'
}

use parent qw(Genesis::Hook::Addon);
use Genesis qw/bail/;

# valid_addons - List of supported addon names and their shortcut letters {{{
# Supported addons:
#   smoke             (s) - run smoke-tests BOSH errand
#   reset-credentials (r) - regenerate rpc_secret + admin_token in Vault
#   mc                (m) - print garage CLI and mc client commands for the cluster
my %SHORTCUTS = (
  s => 'smoke',
  r => 'reset-credentials',
  m => 'mc',
);
# }}}

# init - enforce a minimum Genesis version {{{
sub init {
  my ($class, %ops) = @_;
  my $self = $class->SUPER::init(%ops);
  $self->check_minimum_genesis_version('3.1.0');
  return $self;
}
# }}}

# valid_addons - return the list of supported addon command names {{{
sub valid_addons {
  return qw/smoke reset-credentials mc/;
}
# }}}

# addon_name_for - resolve a shortcut letter or full name to canonical addon name {{{
sub addon_name_for {
  my ($self, $cmd) = @_;
  return $SHORTCUTS{$cmd} if exists $SHORTCUTS{$cmd};
  return $cmd;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
