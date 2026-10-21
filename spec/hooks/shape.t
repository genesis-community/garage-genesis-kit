#!/usr/bin/env perl
# Proves the cluster shape rules that the blueprint and check hooks share.
#
# The helpers in hooks/lib/_garage_shape.pm are loaded into a stub hook whose
# environment answers lookup and exodus_lookup from plain hashes, so that each
# case can say what the environment file sets and what the last deploy wrote
# to exodus.  Run it with `prove spec/hooks` or `perl spec/hooks/shape.t`.

use v5.20;
use warnings;

use Cwd qw/abs_path/;
use File::Basename qw/dirname/;
use Test::More;

my $hooks = abs_path(dirname(__FILE__).'/../../hooks');

# The stub environment {{{
# lookup and exodus_lookup return a value and key pair in list context, as
# Genesis does, so a helper that forgets scalar() gets the wrong answer here.
package StubEnv {
	sub new { my ($class, %data) = @_; bless {params => {}, exodus => undef, subnets => {}, %data}, $class }
	sub _pair { wantarray ? ($_[0], $_[1]) : $_[0] }
	sub lookup {
		my ($self, $key, $default) = @_;
		(my $name = $key) =~ s/^params\.//;
		return _pair(exists($self->{params}{$name}) ? $self->{params}{$name} : $default, $key);
	}
	sub exodus_lookup {
		my ($self, $key, $default) = @_;
		return _pair(defined($self->{exodus}) ? $self->{exodus} : $default, $key);
	}
	sub ocfp_config_lookup { $_[0]{subnets} }
	sub ocfp_subnet_prefix { 'ocfp' }
}

package StubHook {
	sub new { my ($class, %opts) = @_; bless {features => [], %opts}, $class }
	sub env { $_[0]{env} }
	sub want_feature { my ($self, $f) = @_; scalar(grep {$_ eq $f} @{$self->{features}}) }
}

{
	package StubHook;
	do "$hooks/lib/_garage_shape.pm" or die "include _garage_shape.pm: ".($@ || $!);
}

sub hook {
	my (%opts) = @_;
	my $features = delete($opts{features}) // [];
	return StubHook->new(features => $features, env => StubEnv->new(%opts));
}

# shape runs what the check hook runs and returns the error messages.
sub shape {
	my $hook = hook(@_);
	my $instances = $hook->_garage_instance_count;
	my ($rf, $explicit) = $hook->_garage_replication_factor($instances);
	return StubHook::_garage_shape_errors(
		instances        => $instances,
		rf               => $rf,
		previous         => $hook->_garage_previous_shape($explicit ? $rf : undef),
		allow_rf1        => scalar($hook->env->lookup('params.garage_allow_rf1', 0)),
		allow_scale_down => scalar($hook->env->lookup('params.garage_allow_scale_down', 0)),
	);
}

# }}}
# default replication factor {{{
is(StubHook::_garage_default_rf($_->[0]), $_->[1], "$_->[0] nodes default to a factor of $_->[1]")
	for [1, 1], [2, 2], [3, 3], [5, 3], [16, 3];

# }}}
# instance count {{{
is(hook()->_garage_instance_count, 1, 'a single node without the cluster feature');
is(hook(features => ['cluster'])->_garage_instance_count, 3, 'the cluster feature defaults to three nodes');
is(hook(features => ['cluster'], params => {instances => 5})->_garage_instance_count, 5, 'params.instances sets the count');
is(hook(params => {ips => [qw/10.0.0.1 10.0.0.2/], instances => 7})->_garage_instance_count, 2, 'params.ips sets the count');
my %subnets = map {("ocfp-$_" => {az => "z$_", 'reserved-ips' => {garage_ip => "10.0.$_.190"}})} 1 .. 3;
is(hook(features => ['ocfp'], subnets => \%subnets)->_garage_instance_count, 3, 'ocfp deploys one node per reserved garage_ip');
is(hook(features => ['ocfp'], subnets => \%subnets, params => {ocfp_instances => 2})->_garage_instance_count, 2, 'params.ocfp_instances sets the ocfp count');

# }}}
# first deploy {{{
is_deeply([shape()], [], 'a single node with the default factor passes');
is_deeply([shape(features => ['cluster'])], [], 'a three-node cluster with the default factor passes');
is_deeply([shape(features => ['ocfp'], subnets => \%subnets)], [], 'ocfp without the cluster feature gets three copies');
like(join(' ', shape(features => ['cluster'], params => {garage_replication_factor => 1})),
	qr/is 1 on a cluster of 3 nodes/, 'a factor of 1 on three nodes is refused');
is_deeply([shape(features => ['cluster'], params => {garage_replication_factor => 1, garage_allow_rf1 => 1})], [],
	'garage_allow_rf1 accepts a factor of 1');
like(join(' ', shape(features => ['cluster'], params => {garage_replication_factor => 1, garage_allow_rf1 => 'false'})),
	qr/is 1 on a cluster/, 'garage_allow_rf1 given as the string false does not accept it');
like(join(' ', shape(params => {garage_replication_factor => 3})),
	qr/deploys only 1 garage instance/, 'a factor above the instance count is refused');
like(join(' ', shape(params => {garage_replication_factor => 0})),
	qr/whole number of copies/, 'a factor of 0 is refused');

# }}}
# compared with the last deploy {{{
my %three_rf3 = (replication_factor => '3', instances => '3');
is_deeply([shape(features => ['cluster'], exodus => {%three_rf3})], [], 'an unchanged cluster passes');
like(join(' ', shape(features => ['cluster'], params => {garage_replication_factor => 2}, exodus => {%three_rf3})),
	qr/would change from 3 to 2/, 'a change of factor is refused');
like(join(' ', shape(features => ['cluster'], exodus => {replication_factor => '1', instances => '3'})),
	qr/would change from 1 to 3/, 'a new default factor on an rf=1 cluster is refused');
is_deeply([shape(features => ['cluster'], params => {instances => 5}, exodus => {%three_rf3})], [], 'scaling up passes');
my @down = shape(features => ['cluster'], params => {instances => 2}, exodus => {replication_factor => '2', instances => '3'});
like(join(' ', @down), qr/would drop from 3 to 2/, 'scaling down is refused');
like(join(' ', @down), qr/garage layout remove.*garage\s+layout apply.*resync.*lower instances/s,
	'the refusal explains the scale-down procedure in order');
is_deeply([shape(features => ['cluster'], params => {instances => 2, garage_allow_scale_down => 1},
	exodus => {replication_factor => '2', instances => '3'})], [], 'garage_allow_scale_down accepts a scale down');
like(join(' ', shape(features => ['cluster'], params => {instances => 2, garage_allow_scale_down => 1},
	exodus => {%three_rf3})), qr/would change from 3 to 2/, 'garage_allow_scale_down does not excuse a change of factor');
like(join(' ', shape(features => ['cluster'], params => {instances => 1, garage_replication_factor => 1, garage_allow_scale_down => 1},
	exodus => {replication_factor => '1', instances => '3'})), qr/would drop from 3 to 1\..*does not excuse this/, 'a cluster cannot scale down to a single node, even with garage_allow_scale_down');
is(scalar(shape(features => ['cluster'], params => {instances => 1, garage_replication_factor => 1},
	exodus => {replication_factor => '1', instances => '3'})), 1, 'scaling a cluster to one node reports only the single-node refusal');

# }}}
# exodus data from an older kit {{{
my %legacy = (s3_api_url => 'http://10.0.0.1:3900', ips => '10.0.0.1,10.0.0.2,10.0.0.3');
is_deeply(hook(exodus => {%legacy})->_garage_previous_shape(undef), {rf => 1, rf_legacy => 1, instances => 3},
	'older exodus data counts the addresses and assumes the old default factor');
like(join(' ', shape(features => ['cluster'], exodus => {%legacy})),
	qr/did not record the replication factor/, 'older exodus data with the new default factor is refused');
is_deeply([shape(features => ['cluster'], params => {garage_replication_factor => 3}, exodus => {%legacy})], [],
	'an explicit factor is taken as the one the older kit deployed');
is_deeply([shape(features => ['cluster'], params => {garage_replication_factor => 1, garage_allow_rf1 => 1},
	exodus => {%legacy})], [], 'an older rf=1 cluster passes once the environment says so');
like(join(' ', shape(features => ['cluster'], params => {instances => 2, garage_replication_factor => 2},
	exodus => {%legacy})), qr/would drop from 3 to 2/, 'older exodus data still catches a scale down');

# }}}

done_testing();
