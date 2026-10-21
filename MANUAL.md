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

When `garage_replication_factor` is unset, the kit picks it from the number of nodes it deploys. Three or more nodes get three copies of each object, and a smaller deployment gets one copy per node. This holds under `ocfp` too, with or without the `cluster` feature. Garage cannot change the replication factor of a cluster once it has a layout, so we settle it before the first deploy.

The check hook refuses a cluster shape that would lose data. It refuses a factor of 1 on more than one node, because every object would then live on a single disk, unless we set `params.garage_allow_rf1: true` to accept that risk. It also refuses a factor larger than the number of nodes, since Garage needs one node per copy.

Every deploy records the replication factor and the instance count in exodus, and the check hook compares the next deploy against them. It refuses any change to the factor, because Garage will not start a node whose factor differs from the one in its stored layout. A first deploy has nothing to compare against, so it passes. An environment deployed by an older kit has no factor in exodus, and the hook assumes that kit's default of 1. For such an environment we set `params.garage_replication_factor` to the factor the cluster runs today, and we add `params.garage_allow_rf1: true` if that factor is 1.

## Scaling Down

The check hook refuses a deploy that lowers the instance count. BOSH deletes a departing node together with its persistent disk, and Garage loses every copy that disk holds unless the data has moved first. We scale down in this order:

1. Run `garage layout remove <node-id>` for each departing node. BOSH deletes the highest indexes first, so those are the nodes to remove.
2. Apply the new layout with `garage layout apply --version <next-version>`.
3. Wait for the resync to finish. `garage status` should show the remaining nodes holding every partition, and the resync queue in `garage stats` should be empty.
4. Lower `params.instances`, set `params.garage_allow_scale_down: true`, and deploy.
5. Remove `params.garage_allow_scale_down` again, so that the next accidental drop is caught.

The remaining nodes must still number at least `garage_replication_factor`, or the check hook refuses the deploy for that reason instead.

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

The addon asks for confirmation and then runs `safe gen` against the environment's own vault, which `genesis.vault` names, so it does not matter what our local safe target is called. It passes the arguments to safe as a list, with no shell in between, and it reads each key back to confirm that Vault now holds a new value of the right length. It never prints a value.

The `access_key` and `secret_key` are not rotated. Garage imports the root key once, when the cluster first forms, so the kit marks those two keys as fixed, along with `rpc_secret`. That keeps `genesis rotate-secrets` from changing them. This addon is the only way to rotate `rpc_secret`.

Nodes that hold different RPC secrets cannot talk to each other, so a rolling deploy would stall on its first node, and `upgrade-serial` makes that worse. We apply a rotation with a full stop instead, then a deploy that updates every node at once, and then a start of every node together:

```bash
genesis my-env bosh stop
genesis deploy my-env --canaries=0 --max-in-flight=<instances>
genesis my-env bosh start --canaries=0 --max-in-flight=100%
```

The addon prints these commands with the instance count filled in. The final start is needed because a deploy leaves stopped instances stopped. The cluster is unavailable from the stop until the start, so we plan the rotation for a maintenance window.

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

If the metadata is corrupted beyond recovery, we can remove the metadata directory and let the node rebuild from its peers, which needs a replication factor of 2 or more. A wiped node comes back with a new node identity, so the cluster sees it as a new node, and the old identity still holds its role in the layout. The release's post-deploy swaps the new identity into the old one's place with `garage layout assign --replace`, and Garage then copies the node's partitions back from its peers. A node in a cluster with a replication factor of 1 has no peers to copy from, so its objects are lost.

## Upgrading Garage

To upgrade the Garage binary version:

1. Update the `garage` release pin in `manifests/releases/garage.yml` with the new version, URL, and SHA256.
2. Update `config/blobs.yml` in the `garage-boshrelease` repo and rebuild the final release.
3. Redeploy:

```bash
genesis deploy my-env
```

The default update block already rolls one node at a time with one canary, so the other nodes keep serving while each one restarts. The `upgrade-serial` feature sets the same thing explicitly. We avoid `upgrade-all-at-once` on a production cluster, because it restarts every node together.

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
| `garage_replication_factor` | `3` for three or more nodes, otherwise the node count | Copies of each object, which we settle before the first deploy and never change afterwards |
| `garage_allow_rf1` | `false` | Accepts a replication factor of 1 on more than one node, where losing one disk loses data |
| `garage_allow_scale_down` | `false` | Accepts a lower instance count, after the departing nodes have left the layout and the resync has finished |
| `ips` | (from the network's static range) | Static IPs for the Garage nodes. Under `ocfp` they come from the subnet's `garage_ip` reserved IPs |
| `stemcell_os` | `ubuntu-noble` | Stemcell OS, which the `resolute` feature sets to `ubuntu-resolute` |
| `stemcell_version` | `latest` | Stemcell version |
| `azure_availability_set` | `garage_as` | Azure VM availability set name (Azure only) |
