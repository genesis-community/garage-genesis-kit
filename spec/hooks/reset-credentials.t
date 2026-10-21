#!/usr/bin/env perl
# Proves that the reset-credentials addon really rotates the rpc_secret and
# admin_token, through the environment's own vault, without a shell and
# without printing a value.
#
# The addon runs against a stub environment whose vault keeps the secrets in
# a hash.  The stub's query() records every safe command and carries out
# `safe gen` the way safe does, unless a case tells it to fail or to leave
# the value alone.  Run it with `prove spec/hooks` or
# `perl spec/hooks/reset-credentials.t`.

use v5.20;
use warnings;

use Cwd qw/abs_path/;
use File::Basename qw/dirname/;
use File::Temp qw/tempdir/;
use Test::More;

BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

my $hooks = abs_path(dirname(__FILE__).'/../../hooks');
my $work  = tempdir('garage-reset-test-XXXXXX', TMPDIR => 1, CLEANUP => 1);
my $path  = 'secret/rotate/test/garage/credentials';

# The stub vault and environment {{{
package StubVault {
	sub new { my ($class, %opts) = @_; bless {calls => [], mode => 'ok', %opts}, $class }
	sub get {
		my ($self, $path, $key) = @_;
		return $self->{store}{"$path:$key"};
	}
	sub query {
		my $self = shift;
		my $opts = ref($_[0]) eq 'HASH' ? shift : {};
		push @{$self->{calls}}, {opts => $opts, argv => [@_]};
		return ('', 1, 'safe: permission denied') if $self->{mode} eq 'fail';
		my ($cmd, @args) = @_;
		return ('', 2, "unexpected safe $cmd") unless $cmd eq 'gen';
		my %flag;
		while (@args && $args[0] =~ /^-/) {
			my $name = shift @args;
			$flag{$name} = shift @args;
		}
		my ($path, $key) = @args;
		return ('', 0, '') if $self->{mode} eq 'noop';
		my $value = join '', map {(0 .. 9, 'a' .. 'f')[int rand 16]} 1 .. $flag{'-l'};
		$value = substr($value, 1) if $self->{mode} eq 'short';
		$self->{store}{"$path:$key"} = $value;
		return ('', 0, '');
	}
}

package StubEnv {
	sub new { my ($class, %opts) = @_; bless {%opts}, $class }
	sub name { 'rotate-test' }
	sub vault { $_[0]{vault} }
	sub secrets_base { '/secret/rotate/test/garage/' }
	sub exodus_lookup { wantarray ? ('3', $_[1]) : '3' }
}

# }}}

my %old = (rpc_secret => 'a' x 64, admin_token => 'b' x 32);

# run_addon runs the addon with the given answer on STDIN and returns
# whether it finished, what it printed, and the vault it used.
sub run_addon {
	my (%opts) = @_;
	require "$hooks/addon-reset-credentials~r.pm";
	my $vault = StubVault->new(
		store => {map {("$path:$_" => $old{$_})} keys %old},
		mode  => $opts{mode} // 'ok',
	);
	my $hook = bless {env => StubEnv->new(vault => $vault), label => 'reset-credentials'},
		'Genesis::Hook::Addon::Garage::ResetCredentials';

	open(my $in, '>', "$work/answer") or die;
	print {$in} $opts{answer} // "y\n";
	close($in);
	open(my $saved_in,  '<&', \*STDIN)  or die;
	open(my $saved_out, '>&', \*STDOUT) or die;
	open(my $saved_err, '>&', \*STDERR) or die;
	open(STDIN,  '<', "$work/answer") or die;
	open(STDOUT, '>', "$work/output") or die;
	open(STDERR, '>&', \*STDOUT) or die;
	my $ok = eval { $hook->perform; 1 };
	my $error = $@;
	open(STDIN,  '<&', $saved_in)  or die;
	open(STDOUT, '>&', $saved_out) or die;
	open(STDERR, '>&', $saved_err) or die;
	my $output = do { local (@ARGV, $/) = ("$work/output"); <> } // '';
	return ($ok, $output.$error, $vault);
}

# a confirmed rotation {{{
{
	my ($ok, $output, $vault) = run_addon();
	ok($ok, 'a confirmed rotation succeeds') or diag($output);
	is(scalar(@{$vault->{calls}}), 2, 'it runs safe twice');
	is_deeply($vault->{calls}[0]{argv}, ['gen', '-l', 64, '--policy', '0-9a-f', $path, 'rpc_secret'],
		'it generates the rpc_secret with safe gen and list arguments');
	is_deeply($vault->{calls}[1]{argv}, ['gen', '-l', 32, '--policy', '0-9a-f', $path, 'admin_token'],
		'it generates the admin_token with safe gen and list arguments');
	ok($vault->{calls}[0]{opts}{redact_output}, 'it redacts what safe prints');
	like($vault->{store}{"$path:rpc_secret"},  qr/^[0-9a-f]{64}$/, 'the rpc_secret holds 64 new hex characters');
	like($vault->{store}{"$path:admin_token"}, qr/^[0-9a-f]{32}$/, 'the admin_token holds 32 new hex characters');
	isnt($vault->{store}{"$path:rpc_secret"},  $old{rpc_secret},  'the rpc_secret changed');
	isnt($vault->{store}{"$path:admin_token"}, $old{admin_token}, 'the admin_token changed');
	for my $value (values(%old), map {$vault->{store}{"$path:$_"}} keys %old) {
		ok(index($output, $value) < 0, 'the output holds no old or new value');
	}
	like($output, qr/bosh stop/, 'it prints the full stop');
	like($output, qr/--canaries=0 --max-in-flight=3/, 'it prints a deploy with every node in flight');
}

# }}}
# refusals {{{
{
	my ($ok, $output, $vault) = run_addon(answer => "n\n");
	ok(!$ok, 'an unconfirmed rotation stops');
	is(scalar(@{$vault->{calls}}), 0, 'it never runs safe');
}
{
	my ($ok, $output) = run_addon(mode => 'fail');
	ok(!$ok, 'a failed safe gen stops the addon');
	like($output, qr/Failed\s+to\s+rotate/, 'it says the rotation failed');
}
{
	my ($ok, $output) = run_addon(mode => 'noop');
	ok(!$ok, 'a safe gen that leaves the value alone stops the addon');
	like($output, qr/still\s+holds\s+its\s+old\s+value/, 'it says the value did not change');
	ok(index($output, $old{rpc_secret}) < 0, 'it does not print the value');
}
{
	my ($ok, $output) = run_addon(mode => 'short');
	ok(!$ok, 'a value of the wrong length stops the addon');
	like($output, qr/does\s+not\s+hold\s+64\s+hex\s+characters/, 'it says the value is the wrong length');
}

# }}}

done_testing();
