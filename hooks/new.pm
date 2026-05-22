package Genesis::Hook::New::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook);

use Genesis qw/bail/;
use Genesis::UI qw/prompt_for_line prompt_for_list/;

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

	my $instances = prompt_for_line(
		'How many Garage nodes? (1 = single-node, 3+ = cluster)',
		'instances', '1',
		qr/^[1-9]\d*$/, 'must be a positive integer'
	);

	my $garage_network = prompt_for_line(
		'Network name for Garage instances:',
		'network', 'garage',
	);

	my $garage_vm_type = prompt_for_line(
		'VM type for Garage instances:',
		'vm_type', 'default',
	);

	my $garage_disk_type = prompt_for_line(
		'Persistent disk type for Garage instances:',
		'disk_type', 'default',
	);

	my @azs = prompt_for_list(
		'line',
		'Availability zones',
		'az',
		1, undef,
	);
	@azs = qw/z1 z2 z3/ unless @azs;

	my $file_content = "---\n";
	$file_content .= "kit:\n";
	$file_content .= "  name:    $ENV{GENESIS_KIT_NAME}\n";
	$file_content .= "  version: $ENV{GENESIS_KIT_VERSION}\n";
	$file_content .= "\n";
	$file_content .= $self->env->genesis_config_block;
	$file_content .= "\n";
	$file_content .= "params:\n";
	$file_content .= "  instances:         $instances\n";
	$file_content .= "  garage_network:    $garage_network\n";
	$file_content .= "  garage_vm_type:    $garage_vm_type\n";
	$file_content .= "  garage_disk_type:  $garage_disk_type\n";
	$file_content .= "  availability_zones:\n";
	$file_content .= "  - $_\n" for @azs;

	# route-registrar-specific prompts
	if ($self->want_feature('route-registrar')) {
		my $garage_route_prefix = prompt_for_line(
			'Route prefix for S3 API endpoint:',
			'garage_route_prefix', 's3-api',
		);
		$file_content .= "  garage_route_prefix: $garage_route_prefix\n";
		# Route suffix is always CF system_domain from exodus — no separate prompt needed
	}

	$self->env->write_manifest($file_content);

	return $self->done();
}
# }}}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
