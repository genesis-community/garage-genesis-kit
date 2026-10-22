package Genesis::Hook::PreDeploy::Garage v0.2.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail info run load_json new_enough semver/;

# bpm releases older than this do not compile on the resolute stemcell,
# because their tini package needs an older CMake than resolute ships.
my $RESOLUTE_MIN_BPM = '1.4.41';

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

  $self->_check_resolute if $self->want_feature('resolute');

  info("");
  info("#M{$name} - Garage pre-deploy");
  info("  target:     #C{%s}", $name);
  info("  deployment: #C{%s}", $env->deployment_name);
  info("");
  info("Genesis manages credentials - no pre-deploy credential checks needed.");
  info("Cluster layout bootstrap runs automatically on the last instance after the first deploy.");
  info("");

  return $self->done(1);
}
# }}}

# _check_resolute - the merged manifest really deploys resolute {{{
# The blueprint gate reads params.stemcell_os only, so an environment file
# or a custom feature fragment can still set its own stemcells or override
# the bpm release.  The merged manifest is the last word, so we check it.
# Every stemcell must be ubuntu-resolute, and bpm must be 1.4.41 or newer.
sub _check_resolute {
  my ($self) = @_;

  my $file = $ENV{GENESIS_MANIFEST_FILE};
  bail(
    "The #c{resolute} feature is enabled, but Genesis did not pass the " .
    "manifest to the pre-deploy hook, so its stemcells cannot be checked."
  ) unless defined($file) && -f $file && -r $file;

  # The manifest holds secrets, so its conversion is redacted from the
  # trace log.
  my ($out, $rc, $err) = run({stderr => 0, redact_output => 1}, 'spruce json < "$1"', $file);
  my $manifest = $rc == 0 ? eval {load_json($out)} : undef;
  bail(
    "The #c{resolute} feature is enabled, but the manifest at #C{%s} could " .
    "not be read to check its stemcells: %s",
    $file, ($err // '') =~ s/\s+$//r || "spruce exited $rc"
  ) unless ref($manifest) eq 'HASH';

  my $stemcells = $manifest->{stemcells};
  bail(
    "The #c{resolute} feature is enabled, but the manifest lists no stemcells."
  ) unless ref($stemcells) eq 'ARRAY' && @$stemcells;

  my @wrong = map {
    ref($_) eq 'HASH'
      ? sprintf("%s (#R{%s})", $_->{alias} // '?', $_->{os} // 'no os')
      : '#R{an entry that is not a stemcell}'
  } grep {
    ref($_) ne 'HASH' || ($_->{os} // '') ne 'ubuntu-resolute'
  } @$stemcells;
  bail(
    "The #c{resolute} feature is enabled, but the manifest deploys these " .
    "stemcells on another OS: %s.  Remove the override that sets them.",
    join(', ', @wrong)
  ) if @wrong;

  my @bpm = grep {ref($_) eq 'HASH' && ($_->{name} // '') eq 'bpm'}
    @{ref($manifest->{releases}) eq 'ARRAY' ? $manifest->{releases} : []};
  bail(
    "The #c{resolute} feature is enabled, but the manifest deploys no bpm " .
    "release, and the garage job needs bpm %s or newer on resolute.",
    $RESOLUTE_MIN_BPM
  ) unless @bpm;
  for my $release (@bpm) {
    my $version = $release->{version} // '';
    bail(
      "The manifest deploys bpm #R{%s} on a resolute stemcell, which needs " .
      "bpm %s or newer.  Remove the override that pins bpm, so that the " .
      "#c{resolute} feature can choose it.",
      $version eq '' ? 'without a version' : $version, $RESOLUTE_MIN_BPM
    ) unless $version ne 'latest' && semver($version) && new_enough($version, $RESOLUTE_MIN_BPM);
  }
  return 1;
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
