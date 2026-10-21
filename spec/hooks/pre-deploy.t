#!/usr/bin/env perl
# Proves that the pre-deploy hook checks the merged manifest of a resolute
# deploy, which is the last place an override of the stemcells or of the bpm
# release can show up.
#
# Each case writes a small manifest, points GENESIS_MANIFEST_FILE at it, and
# runs the hook's resolute check.  spruce converts the manifest, as it does
# in a real deploy.  Run it with `prove spec/hooks` or
# `perl spec/hooks/pre-deploy.t`.

use v5.20;
use warnings;

use Cwd qw/abs_path/;
use File::Basename qw/dirname/;
use File::Temp qw/tempdir/;
use Test::More;

BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

chomp(my $spruce = `command -v spruce`);
plan skip_all => 'spruce is not installed' unless $spruce;

my $hooks = abs_path(dirname(__FILE__).'/../../hooks');
my $work  = tempdir('garage-predeploy-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);
require "$hooks/pre-deploy.pm";

# check runs the resolute check on a manifest and returns whether it passed
# and what it printed.
sub check {
	my ($manifest) = @_;
	open(my $fh, '>', "$work/manifest.yml") or die;
	print {$fh} $manifest;
	close($fh);
	local $ENV{GENESIS_MANIFEST_FILE} = "$work/manifest.yml";
	my $hook = bless {label => 'pre-deploy'}, 'Genesis::Hook::PreDeploy::Garage';
	my $ok = eval { $hook->_check_resolute; 1 };
	return ($ok, $@ // '');
}

my $resolute = "stemcells:\n- alias: default\n  os: ubuntu-resolute\n  version: \"0.184\"\n";
my $noble    = "stemcells:\n- alias: default\n  os: ubuntu-noble\n  version: latest\n";
sub bpm { "releases:\n- name: garage\n  version: 0.2.0\n- name: bpm\n  version: $_[0]\n" }

my ($ok, $error);

($ok, $error) = check($resolute . bpm('1.4.41'));
ok($ok, 'resolute stemcells with bpm 1.4.41 pass') or diag($error);

($ok, $error) = check($resolute . bpm('1.5.0'));
ok($ok, 'a newer bpm passes') or diag($error);

($ok, $error) = check($noble . bpm('1.4.41'));
ok(!$ok, 'a noble stemcell is refused');
like($error, qr/ubuntu-noble/, 'the refusal names the stemcell os');

($ok, $error) = check($resolute . "- alias: extra\n  os: ubuntu-jammy\n  version: latest\n" . bpm('1.4.41'));
ok(!$ok, 'a second stemcell on another os is refused');
like($error, qr/extra/, 'the refusal names the stemcell alias');

($ok, $error) = check($resolute . bpm('1.4.22'));
ok(!$ok, 'bpm 1.4.22 is refused');
like($error, qr/1\.4\.22/, 'the refusal names the bpm version');

($ok, $error) = check($resolute . bpm('latest'));
ok(!$ok, 'bpm latest is refused');

($ok, $error) = check($resolute . "releases:\n- name: garage\n  version: 0.2.0\n");
ok(!$ok, 'a manifest without bpm is refused');

($ok, $error) = check(bpm('1.4.41'));
ok(!$ok, 'a manifest without stemcells is refused');

{
	local $ENV{GENESIS_MANIFEST_FILE} = "$work/missing.yml";
	my $hook = bless {label => 'pre-deploy'}, 'Genesis::Hook::PreDeploy::Garage';
	ok(!eval { $hook->_check_resolute; 1 }, 'a missing manifest is refused');
}

done_testing();
