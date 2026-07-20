# Garage Genesis Kit — Operator Manual

## Prerequisites

Before deploying, ensure the following are available:

- **Genesis 3.1.0 or later** — required for the hook API this kit uses.
- **Vault** — all credentials and certificates are stored in Vault. Genesis manages provisioning automatically via the `certificates:` block in `kit.yml`.
- **BOSH director** — the director must have the following releases uploaded:
  - `bpm` (any recent version; the kit pins `version: latest`)
  - `routing` 0.343.0 (required when using the `route-registrar` feature)
  - `bosh-dns-aliases` 0.0.4 (required when using `route-registrar` or `cluster`)
- **Ubuntu Noble stemcell** — upload with `bosh upload-stemcell`.

## New Environment Walkthrough

The `genesis new` wizard prompts for all required values:

```
$ genesis new my-env

Environment name: my-env

How many Garage instances do you need? [1]
  > 3

Which BOSH network should Garage use? [garage]
  > garage

Which VM type should Garage use? [default]
  > medium

Which persistent disk type should Garage use? [default]
  > medium

Which availability zones? (comma-separated) [z1,z2,z3]
  > z1,z2,z3

Enable CF route-registrar? (y/n) [n]
  > y

Route prefix for the S3 API endpoint? [s3-api]
  > s3-api
```

The wizard writes `envs/my-env.yml` with these values under `params:`.

## Deployment

```bash
genesis deploy my-env
```

Genesis renders the manifest, provisions certificates and credentials in Vault, and submits the deployment to BOSH. The `update` block defaults to serial rolling with one canary. Use the `upgrade-all-at-once` feature for parallel upgrades.

## Smoke Tests

Run the smoke-tests errand to verify a full S3 round-trip:

```bash
genesis my-env do smoke
# or
bosh -d my-env run-errand smoke-tests
```

The errand probes the admin health endpoint on every node, then performs CreateBucket, PutObject, GetObject (with content verification), DeleteObject, HeadObject (expects 404), and DeleteBucket against the primary node.

## Smoke Tests Prerequisites

Garage does not auto-create S3 keys. Before running the smoke-tests errand for the first time, create a dedicated test key:

```bash
genesis bosh ssh garage/0 -c 'sudo /var/vcap/packages/garage/bin/garage key create smoke-tests'
# Capture the access key id + secret key from the output
safe set secret/<env>/garage/credentials/smoke_access_key value=<ACCESS_KEY_ID>
safe set secret/<env>/garage/credentials/smoke_secret_key value=<SECRET_KEY>
```

After that, `genesis my-env do smoke` runs the errand.

## Scaling Up

To increase the number of nodes, update `params.instances` in your environment file and redeploy:

```yaml
params:
  instances: 5
```

```bash
genesis deploy my-env
```

The post-deploy auto-bootstrap on instance 0 is idempotent. It assigns layout roles only to nodes in the `NO ROLE ASSIGNED` state and increments the layout version. Existing nodes are not disturbed.

## Manual Layout Management

If you need full control over cluster layout — for example, to assign specific zones or capacities — set the following parameter before deploying:

```yaml
params:
  garage_layout_manual: true
```

With this flag set, the post-deploy hook prints a reminder and exits without calling `garage layout assign` or `garage layout apply`. Use the `mc` addon to get credentials, then manage layout directly with the `garage` CLI:

```bash
# Via bosh ssh
bosh -d my-env ssh garage/0

# Inside the VM
export GARAGE_CONFIG_FILE=/var/vcap/jobs/garage/config/garage.toml
/var/vcap/packages/garage/bin/garage status
/var/vcap/packages/garage/bin/garage layout assign <node-id> --zone z1 --capacity 1T
/var/vcap/packages/garage/bin/garage layout apply --version <next-version>
```

## Credential Rotation

To rotate the `rpc_secret` and `admin_token`:

```bash
genesis my-env do reset-credentials
```

The addon prompts for confirmation (`Type 'y' to continue`), then generates new values using `openssl rand -hex` and stores them in Vault via `safe set`. After rotation, redeploy so all nodes receive the updated secrets:

```bash
genesis deploy my-env
```

Use the `upgrade-serial` feature to roll the redeploy safely — one node at a time — so the cluster remains available throughout.

## Troubleshooting

### NATS mTLS errors (route-registrar)

If `route_registrar` fails to connect to NATS, verify that the CF deployment exports `nats_client_cert` and `nats_client_key` in its exodus data:

```bash
safe get secret/exodus/<env>/cf:nats_client_cert
safe get secret/exodus/<env>/cf:nats_client_key
```

If these keys are missing, re-run the CF genesis deployment to refresh exodus, then redeploy Garage.

### Cluster split-brain

If `garage status` shows inconsistent node states across instances, check that all nodes can reach each other on RPC port 3901.

Inter-node RPC uses an HMAC-shared secret (`rpc_secret`) for peer authentication. Garage v1.x does not support TLS on the RPC channel; the shared secret ensures only authorized peers can join the gossip ring. Rotate via the `reset-credentials` addon.

If nodes still cannot communicate after verifying network connectivity, confirm the `rpc_secret` is identical on all nodes by rotating credentials and redeploying.

### LMDB corruption

Garage uses LMDB for cluster metadata by default. If a node crashes without a clean shutdown, LMDB may require recovery. Signs include log messages containing `MDB_PAGE_NOTFOUND` or the garage process failing to start.

To recover:

1. Stop the affected instance: `bosh -d my-env stop garage/<index>`.
2. SSH in and inspect: `bosh -d my-env ssh garage/<index>`.
3. Remove the LMDB lock file only (not the data): `rm /var/vcap/store/garage/meta/lock.mdb`.
4. Restart: `bosh -d my-env start garage/<index>`.

If data is corrupted beyond recovery, remove the metadata directory entirely and allow Garage to rebuild it from peers (requires at least `replication_factor` healthy peers).

## Upgrading Garage

To upgrade the Garage binary version:

1. Update the `garage` release pin in `manifests/releases/garage.yml` with the new version, URL, and SHA256.
2. Update `config/blobs.yml` in the `garage-boshrelease` repo and rebuild the final release.
3. Redeploy:

```bash
genesis deploy my-env
```

Use the `upgrade-serial` feature during upgrades of production clusters to minimize blast radius.

## Vault Path Reference

All secrets are stored under `<vault_mount>/<env>/garage/` by Genesis.

| Path | Key | Content |
|------|-----|---------|
| `/certs/ca` | `certificate` | CA certificate (PEM) — reserved for future external client verification |
| `/credentials/rpc_secret` | (value) | 64-character hex RPC secret shared across all nodes |
| `/credentials/admin_token` | (value) | Garage admin API bearer token |
| `/credentials/smoke_access_key` | `value` | S3 access key ID for the smoke-tests errand |
| `/credentials/smoke_secret_key` | `value` | S3 secret key for the smoke-tests errand |

## Feature Reference

| Feature | Manifests Applied |
|---------|-------------------|
| `cluster` | `manifests/cluster.yml` |
| `route-registrar` | `manifests/route-registrar.yml`, `manifests/releases/routing.yml`, `manifests/releases/bosh-dns-aliases.yml` |
| `ocfp` | `manifests/ocfp.yml` |
| `scale-small` | `manifests/scale-small.yml` |
| `scale-medium` | `manifests/scale-medium.yml` |
| `scale-large` | `manifests/scale-large.yml` |
| `upgrade-serial` | `manifests/upgrade-serial.yml` |
| `upgrade-all-at-once` | `manifests/upgrade-all-at-once.yml` |

IaaS overlays (`azure`, `stackit`) are applied automatically by the blueprint hook based on the detected IaaS type; they do not need to be listed in `features:`.

## Parameter Reference

| Parameter | Default | Description |
|-----------|---------|-------------|
| `instances` | `1` | Number of Garage nodes |
| `garage_network` | `garage` | BOSH network name |
| `garage_vm_type` | `default` | BOSH VM type name |
| `garage_disk_type` | `default` | BOSH persistent disk type name |
| `garage_route_prefix` | `s3-api` | Route hostname prefix (suffix is always the CF system domain from exodus) |
| `availability_zones` | `[z1, z2, z3]` | BOSH AZs |
| `garage_layout_manual` | `false` | Skip auto cluster layout bootstrap |
| `azure_availability_set` | `garage_as` | Azure VM availability set name (Azure only) |
