# garage-genesis-kit

A Genesis kit for deploying [Garage](https://garagehq.deuxfleurs.fr/), a lightweight, S3-compatible distributed object storage system, using BOSH.

## Overview

This kit deploys Garage v2.3.0 under BPM on Ubuntu Noble stemcells, or on Ubuntu Resolute stemcells with the `resolute` feature, and it can register CF routes through `route_registrar`. Each BOSH VM runs a single Garage node backed by a persistent disk. Cluster formation is automatic on first deploy and idempotent on subsequent deploys.

```mermaid
graph LR
    A[Genesis Kit] -->|assembles| B[BOSH Deployment]
    B -->|runs| C[garage VMs]
    C -->|BPM manages| D[garage process]
    D -->|S3 API :3900| E[gorouter]
    D -->|RPC :3901| D
    D -->|LMDB + data| F[(Persistent Disk)]
    G[route_registrar] -->|NATS mTLS| E
    C -->|colocates| G
```

## Features

| Feature | Description |
|---------|-------------|
| `cluster` | Scale to 3+ nodes with BOSH link-based peer discovery and auto layout bootstrap, and scale back down with each departing node's data moved first (see the MANUAL) |
| `route-registrar` | Register `s3-api.<system-domain>` into CF gorouter via NATS mTLS |
| `ocfp` | Derive network, VM type, and disk type names from OCFP naming conventions |
| `scale-small` | Use small VM type and disk type |
| `scale-medium` | Use medium VM type and disk type |
| `scale-large` | Use large VM type and disk type |
| `upgrade-serial` | Rolling upgrade: one instance at a time, canary first |
| `upgrade-all-at-once` | Upgrade all instances simultaneously, which the check hook refuses for a deploy that removes nodes |
| `resolute` | Deploy on an Ubuntu Resolute stemcell with bpm 1.4.41 |

## Quick Start

```bash
# Create a new environment
genesis new my-garage-env

# Edit the generated environment file
$EDITOR envs/my-garage-env.yml

# Deploy
genesis deploy my-garage-env
```

## Properties

The following parameters can be set in your environment file under `params:`.

| Parameter | Default | Description |
|-----------|---------|-------------|
| `instances` | `1` | Number of Garage nodes (use `cluster` feature for 3+) |
| `garage_network` | `garage` | BOSH network name |
| `garage_vm_type` | `default` | BOSH VM type |
| `garage_disk_type` | `default` | BOSH persistent disk type |
| `garage_route_prefix` | `s3-api` | Route prefix (produces `<prefix>.<system-domain>`) |
| `availability_zones` | `[z1, z2, z3]` | BOSH AZs to spread instances across |

## Addons

Run addons with `genesis <env> do <addon>`.

| Addon | Shortcut | Description |
|-------|----------|-------------|
| `smoke` | `s` | Run the smoke-tests BOSH errand against the deployment |
| `reset-credentials` | `r` | Rotate `rpc_secret` and `admin_token` in Vault |
| `mc` | `m` | Print `mc alias set` command for CLI access |

## Cluster Bootstrap

On first deploy, the garage job's post-deploy script on the instance with the highest index calls `garage layout assign` for each unassigned node, then `garage layout apply`. The bootstrap is idempotent, so subsequent deploys skip it because no nodes are in the `NO ROLE ASSIGNED` state.

To opt out of the automatic bootstrap, we set `params.garage_layout_manual: true` and manage the cluster layout manually via the `mc` addon.

## Cloud-Provider Notes

**Azure**: The `azure` feature is applied automatically when the IaaS is Azure. It restricts deployment to a single AZ (`z1`) and adds `vm_extensions: [garage_as]` for VM availability set placement. Override the availability set name with `params.azure_availability_set`.

**STACKIT**: The `stackit` feature is applied automatically for STACKIT environments. It clears `vm_extensions` because STACKIT has no native availability set concept.

## Contributing

Pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for the development workflow.

## License

Apache 2.0. Copyright 2026 Cloud Foundry Community. See [LICENSE](LICENSE).
