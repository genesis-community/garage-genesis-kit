# Garage Genesis Kit — Operator Manual

## Prerequisites

Before deploying, ensure the following are available:

- **Genesis 3.1.0 or later** — required for the hook API this kit uses.
- **Vault** — all credentials and certificates are stored in Vault. Genesis manages provisioning automatically via the `certificates:` block in `kit.yml`.
- **BOSH director**, which needs the following releases. The kit pins every release it uses, and BOSH fetches each release that has a URL during the deploy:
  - `bpm` 1.4.22 on noble stemcells, or 1.4.41 when the `resolute` feature is on. The kit pins an exact version instead of `latest`, because bpm 1.4.31 cannot start jobs on noble.
  - `routing` 0.343.0 (required when using the `route-registrar` feature)
  - `bosh-dns-aliases` 0.0.4 (required when using `route-registrar` or `cluster`)
  - `garage` 0.2.0+dev.1, which carries Garage v2.3.0. This is a dev release with no URL, so we upload its tarball before the first deploy with `genesis my-env bosh upload-release <tarball>`. The final release's version, URL, and SHA1 replace this pin once it ships.
- **Stemcell**, either an Ubuntu Noble stemcell or, when the `resolute` feature is on, an Ubuntu Resolute stemcell. We upload it with `bosh upload-stemcell`.

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

The errand first checks that the S3 endpoint answers on every node. It then runs PutObject, GetObject (and checks the content), DeleteObject, and HeadObject (which must return 404) against the first node, inside the default bucket.

The errand signs its requests with the root key that `genesis add-secrets` generates, so we don't create a key by hand. Its access key id is `GK` followed by `credentials:access_key`, and its secret is `credentials:secret_key`. A single node creates that key and the `default_bucket` when Garage starts. A cluster can't do that at startup, so the garage job's post-deploy script imports the key and creates the bucket once the cluster layout is applied.

## Scaling Up

To increase the number of nodes, update `params.instances` in your environment file and redeploy:

```yaml
params:
  instances: 5
```

```bash
genesis deploy my-env
```

The post-deploy auto-bootstrap runs on the last instance, which is the one BOSH updates last, so every node has started by the time it runs. It is idempotent. It assigns layout roles only to nodes in the `NO ROLE ASSIGNED` state, puts each node in the zone of its own AZ, and increments the layout version. Existing nodes are not disturbed.

Each new node joins the cluster in its post-start script. It reads the first instance's node id from the admin API and connects to it over RPC. For that reason a cluster binds the admin API to each instance's own IP rather than to loopback, and it requires the admin token on `/metrics` as well. A single node keeps the admin API on `127.0.0.1`. The `garage.admin_bind_address` release property overrides either choice.

The kit defaults `garage_replication_factor` to 1, even for a cluster, which means each object lives on only one node. Set it to 3 for a three-zone cluster before the first deploy, because Garage cannot change the replication factor of a cluster that already holds data.

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

Inter-node RPC uses an HMAC-shared secret (`rpc_secret`) for peer authentication. Garage v2.x does not support TLS on the RPC channel; the shared secret ensures only authorized peers can join the gossip ring. Rotate via the `reset-credentials` addon.

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
| `/credentials` | `access_key` | 32-character hex suffix of the root S3 access key id (`GK<access_key>`), used by the smoke-tests errand |
| `/credentials` | `secret_key` | 64-character hex root S3 secret key |
| `/credentials` | `rpc_secret` | 64-character hex RPC secret shared across all nodes |
| `/credentials` | `admin_token` | Garage admin API bearer token |

## Resolute Stemcells

The `resolute` feature deploys Garage on an Ubuntu Resolute (26.04) stemcell instead of Noble. It sets `params.stemcell_os` to `ubuntu-resolute` and pins bpm 1.4.41, because earlier bpm releases cannot start jobs on Resolute. Noble deployments stay on bpm 1.4.22.

```yaml
kit:
  features:
  - resolute
```

The blueprint refuses two settings that would leave the stemcell and bpm out of step. It refuses the `resolute` feature together with a `stemcell_os` other than `ubuntu-resolute`, and it refuses `stemcell_os: ubuntu-resolute` without the feature. In both cases we remove the `stemcell_os` parameter and let the feature choose.

The director needs a Resolute stemcell before the deploy. Set `params.stemcell_version` to pin one, or leave it unset to take the latest that the director has.

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
| `resolute` | `manifests/resolute.yml`, `manifests/releases/bpm-resolute.yml` |

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
| `garage_replication_factor` | `1` | Copies of each object, which we set before the first deploy |
| `ips` | (from the network's static range) | Static IPs for the Garage nodes. Under `ocfp` they come from the subnet's `garage_ip` reserved IPs |
| `stemcell_os` | `ubuntu-noble` | Stemcell OS, which the `resolute` feature sets to `ubuntu-resolute` |
| `stemcell_version` | `latest` | Stemcell version |
| `azure_availability_set` | `garage_as` | Azure VM availability set name (Azure only) |
