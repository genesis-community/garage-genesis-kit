package Genesis::Hook::CloudConfig::Garage v0.1.0;

use v5.20;
use warnings;

# Only needed for development
BEGIN {push @INC, $ENV{GENESIS_LIB} ? $ENV{GENESIS_LIB} : $ENV{HOME}.'/.genesis/lib'}

use parent qw(Genesis::Hook::CloudConfig);

use Genesis::Hook::CloudConfig::Helpers qw/gigabytes megabytes/;

use Genesis qw//;
use JSON::PP;

sub init {
	my $class = shift;
	my $obj = $class->SUPER::init(@_);
	$obj->check_minimum_genesis_version('3.1.0');
	return $obj;
}

sub perform {
	my ($self) = @_;
	return 1 if $self->completed;

	my $network_name = $self->env->lookup('params.garage_network', 'garage');

	my $config = $self->build_cloud_config({
		'networks' => [
			$self->network_definition($network_name, strategy => 'ocfp',
				dynamic_subnets => {
					allocation => {
						# Static IPs come from the ocfp blueprint reserved-ips
						# (garage_ip per subnet/instance plus garage_ip_smoke for
						# the errand), not a pre-sized pool, so the network claims
						# exactly what it uses.
						size    => 0,
						statics => 0,
					},
					cloud_properties_for_iaas => {
						aws => {
							'subnet' => $self->subnet_reference('id'),
						},
						openstack => {
							'net_id'          => $self->network_reference('id'),
							'security_groups' => ['default'],
						},
						stackit => {
							'net_id'          => $self->network_reference('id'),
							'security_groups' => $self->network_reference('sgs', 'get_sgs_by_names', 'ocfp', 'default'),
						},
						pve => {
							'bridge' => scalar($self->env->lookup('bosh-configs.cpi.pve_network_bridge', 'lvnet001')),
						},
					},
				}
			)
		],
		'vm_types' => [
			$self->vm_type_definition('small',
				cloud_properties_for_iaas => {
					aws => {
						'instance_type'  => 't3.small',
						'ephemeral_disk' => {
							'encrypted' => $self->TRUE,
							'size'      => megabytes(8192),
							'type'      => 'gp3',
						},
						'metadata_options' => {
							'http_tokens' => 'required',
						},
					},
					openstack => {
						'instance_type'    => 'm1.1',
						'boot_from_volume' => $self->TRUE,
						'root_disk'        => { 'size' => 16 },
					},
					stackit => {
						'instance_type'    => 'm1a.1d',
						'boot_from_volume' => $self->TRUE,
						'root_disk'        => { 'size' => 16 },
					},
					vsphere => {
						'cpu'  => 2,
						'ram'  => 2048,
						'disk' => 16384,
					},
					azure => {
						'instance_type' => 'Standard_B2s',
					},
					gcp => {
						'machine_type' => 'n2-standard-2',
					},
					pve => {
						'cpu'            => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_cpu',  2)),
						'ram'            => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_ram',  4096)),
						'disk'           => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_disk', 32768)),
						'network_bridge' => scalar($self->env->lookup('bosh-configs.cpi.pve_network_bridge', 'lvnet001')),
					},
				},
			),
			$self->vm_type_definition('medium',
				cloud_properties_for_iaas => {
					aws => {
						'instance_type'  => 't3.medium',
						'ephemeral_disk' => {
							'encrypted' => $self->TRUE,
							'size'      => megabytes(16384),
							'type'      => 'gp3',
						},
						'metadata_options' => {
							'http_tokens' => 'required',
						},
					},
					openstack => {
						'instance_type'    => 'm1.2',
						'boot_from_volume' => $self->TRUE,
						'root_disk'        => { 'size' => 32 },
					},
					stackit => {
						'instance_type'    => 'm1a.2d',
						'boot_from_volume' => $self->TRUE,
						'root_disk'        => { 'size' => 32 },
					},
					vsphere => {
						'cpu'  => 4,
						'ram'  => 8192,
						'disk' => 32768,
					},
					azure => {
						'instance_type' => 'Standard_D4s_v5',
					},
					gcp => {
						'machine_type' => 'n2-standard-4',
					},
					pve => {
						'cpu'            => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_cpu',  4)),
						'ram'            => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_ram',  8192)),
						'disk'           => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_disk', 65536)),
						'network_bridge' => scalar($self->env->lookup('bosh-configs.cpi.pve_network_bridge', 'lvnet001')),
					},
				},
			),
			$self->vm_type_definition('large',
				cloud_properties_for_iaas => {
					aws => {
						'instance_type'  => 'm6i.large',
						'ephemeral_disk' => {
							'encrypted' => $self->TRUE,
							'size'      => megabytes(32768),
							'type'      => 'gp3',
						},
						'metadata_options' => {
							'http_tokens' => 'required',
						},
					},
					openstack => {
						'instance_type'    => 'm1.3',
						'boot_from_volume' => $self->TRUE,
						'root_disk'        => { 'size' => 64 },
					},
					stackit => {
						'instance_type'    => 'm1a.4d',
						'boot_from_volume' => $self->TRUE,
						'root_disk'        => { 'size' => 64 },
					},
					vsphere => {
						'cpu'  => 8,
						'ram'  => 16384,
						'disk' => 65536,
					},
					azure => {
						'instance_type' => 'Standard_D8s_v5',
					},
					gcp => {
						'machine_type' => 'n2-standard-8',
					},
					pve => {
						'cpu'            => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_cpu',  8)),
						'ram'            => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_ram',  16384)),
						'disk'           => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_disk', 131072)),
						'network_bridge' => scalar($self->env->lookup('bosh-configs.cpi.pve_network_bridge', 'lvnet001')),
					},
				},
			),
			# Service-named vm_type — referenced by the ocfp manifest
			# (garage_vm_type: <cloud>vm-garage). Medium-class sizing; Garage
			# runs metadata + S3 data serving on this single instance.
			$self->vm_type_definition('garage',
				cloud_properties_for_iaas => {
					aws => {
						'instance_type'  => 't3.medium',
						'ephemeral_disk' => {
							'encrypted' => $self->TRUE,
							'size'      => megabytes(16384),
							'type'      => 'gp3',
						},
						'metadata_options' => {
							'http_tokens' => 'required',
						},
					},
					openstack => {
						'instance_type'    => 'm1.2',
						'boot_from_volume' => $self->TRUE,
						'root_disk'        => { 'size' => 32 },
					},
					stackit => {
						'instance_type'    => 'm1a.2d',
						'boot_from_volume' => $self->TRUE,
						'root_disk'        => { 'size' => 32 },
					},
					vsphere => {
						'cpu'  => 4,
						'ram'  => 8192,
						'disk' => 32768,
					},
					azure => {
						'instance_type' => 'Standard_D4s_v5',
					},
					gcp => {
						'machine_type' => 'n2-standard-4',
					},
					pve => {
						'cpu'            => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_cpu',  4)),
						'ram'            => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_ram',  8192)),
						'disk'           => scalar($self->env->lookup('bosh-configs.cpi.pve_garage_disk', 65536)),
						'network_bridge' => scalar($self->env->lookup('bosh-configs.cpi.pve_network_bridge', 'lvnet001')),
					},
				},
			),
		],
		'disk_types' => [
			$self->disk_type_definition('small',
				common => {
					disk_size => gigabytes(5),
				},
				cloud_properties_for_iaas => {
					aws => {
						'encrypted' => $self->TRUE,
						'type'      => 'gp3',
					},
					openstack => {
						'type' => 'storage_premium_perf2',
					},
					stackit => {
						'type' => 'storage_premium_perf2',
					},
					pve => {
						'storage'     => scalar($self->env->lookup('bosh-configs.cpi.pve_disk_storage', 'zfs-1')),
						'disk_format' => scalar($self->env->lookup('bosh-configs.cpi.pve_disk_format', 'raw')),
					},
				},
			),
			$self->disk_type_definition('medium',
				common => {
					disk_size => gigabytes(50),
				},
				cloud_properties_for_iaas => {
					aws => {
						'encrypted' => $self->TRUE,
						'type'      => 'gp3',
					},
					openstack => {
						'type' => 'storage_premium_perf6',
					},
					stackit => {
						'type' => 'storage_premium_perf6',
					},
					pve => {
						'storage'     => scalar($self->env->lookup('bosh-configs.cpi.pve_disk_storage', 'zfs-1')),
						'disk_format' => scalar($self->env->lookup('bosh-configs.cpi.pve_disk_format', 'raw')),
					},
				},
			),
			$self->disk_type_definition('large',
				common => {
					disk_size => gigabytes(500),
				},
				cloud_properties_for_iaas => {
					aws => {
						'encrypted' => $self->TRUE,
						'type'      => 'gp3',
					},
					openstack => {
						'type' => 'storage_premium_perf6',
					},
					stackit => {
						'type' => 'storage_premium_perf6',
					},
					pve => {
						'storage'     => scalar($self->env->lookup('bosh-configs.cpi.pve_disk_storage', 'zfs-1')),
						'disk_format' => scalar($self->env->lookup('bosh-configs.cpi.pve_disk_format', 'raw')),
					},
				},
			),
		# Service-named disk_type — required by the ocfp manifest
		# (garage_disk_type: <cloud>garage). Based on medium sizing (50 GB);
		# per-IaaS properties match the medium disk_type above. Garage stores
		# metadata + data blocks here, mounted XFS via env.persistent_disk_fs.
		$self->disk_type_definition('garage',
				common => {
					disk_size => gigabytes(50),
				},
				cloud_properties_for_iaas => {
					aws => {
						'encrypted' => $self->TRUE,
						'type'      => 'gp3',
					},
					openstack => {
						'type' => 'storage_premium_perf6',
					},
					stackit => {
						'type' => 'storage_premium_perf6',
					},
					pve => {
						'storage'     => scalar($self->env->lookup('bosh-configs.cpi.pve_disk_storage', 'zfs-1')),
						'disk_format' => scalar($self->env->lookup('bosh-configs.cpi.pve_disk_format', 'raw')),
					},
				},
			),
		],
	});

	$self->done($config);

	return 1;
}

sub get_sgs_by_names {
	my ($self, $subnet_data, $ref, @names) = @_;
	my @ids = map { $subnet_data->{$ref}{$_}{id} } @names;
	return \@ids;
}

1;
# vim: set ts=2 sw=2 sts=2 noet fdm=marker foldlevel=1:
