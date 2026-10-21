# Changelog

## [0.1.0] - Unreleased

### Added

- Add a `resolute` feature that deploys on Ubuntu Resolute stemcells. It sets `params.stemcell_os` to `ubuntu-resolute` and pins bpm 1.4.41. The blueprint refuses a conflicting `stemcell_os` under the feature, and it refuses `stemcell_os: ubuntu-resolute` without the feature.
- Add a testkit spec suite that covers base, cluster, cluster with explicit IPs, ocfp, resolute, ocfp with cluster and resolute, and both resolute refusals. The refusal specs assert a non-zero exit from every genesis command.
- Add MANUAL sections on resolute stemcells and on how a cluster bootstraps, along with parameter rows for `garage_replication_factor`, `ips`, `stemcell_os`, and `stemcell_version`.
- Add Proxmox VE (`pve`) support. The kit lists `pve` in `kit.yml` `supports`, and `cloud-config.pm` carries `pve` branches on the network, every vm_type, and every disk_type (bridge, cpu/ram/disk, and persistent disk storage/format, all overridable via `bosh-configs.cpi.*`).
- Add the service-named cloud-config entries `vm_type_definition('garage')` and `disk_type_definition('garage')`, which the ocfp manifest references and which resolve as `<cloud>vm-garage` / `<cloud>disk-garage`.
- Make `cloud-config.pm` emit one BOSH CPI per AZ so the deploy-time stemcell check resolves against the named per-AZ CPI.
- Add a check that refuses unsafe cluster shapes. It refuses a replication factor of 1 on more than one node unless `params.garage_allow_rf1` is true, and it refuses a factor larger than the instance count.
- Export `replication_factor` and `instances` in exodus for every deployment shape. The check hook compares each deploy against them, refuses any change to the replication factor, and refuses a lower instance count unless `params.garage_allow_scale_down` is true. The refusal explains how to drain the departing nodes first. A first deploy passes.
- When the `resolute` feature is on, the pre-deploy hook reads the merged manifest and refuses any stemcell whose os is not `ubuntu-resolute`, along with a bpm release older than 1.4.41.
- Add a MANUAL section on scaling down, and parameter rows for `garage_allow_rf1` and `garage_allow_scale_down`.
- Add Perl tests under `spec/hooks/` for the cluster shape rules, the credential rotation addon, and the resolute pre-deploy check, along with refusal specs for each shape the check hook rejects.

### Changed

- Default `garage_replication_factor` to 3 for three or more nodes and to the node count for a smaller deployment, including under `ocfp` without the `cluster` feature. It used to default to 1 everywhere, which left a cluster one disk away from data loss.
- Mark `access_key`, `secret_key`, and `rpc_secret` as fixed in `kit.yml`, so `genesis rotate-secrets` leaves them alone. Garage imports the root key only once, and a changed `rpc_secret` must reach every node at the same moment.
- Rewrite the MANUAL's credential rotation section. A rotation is applied with a full stop, then a deploy and a start with every node in flight, instead of a serial redeploy. The MANUAL also says that a wiped node returns with a new identity, which the release's post-deploy swaps in with `garage layout assign --replace`.
- The post-deploy hook probes each node at the address the release binds, which is loopback on a single node and the instance IP on a cluster. It maps each address to its instance from the BOSH instance list.
- The check hook looks up each cloud config param first, and it falls back to the name derived from ocfp only when the param is unset.
- Leave the stemcell check to Genesis, so that `--no-stemcells` is honoured and the check no longer runs twice.
- Pin bpm to 1.4.22 on noble instead of `latest`, because bpm 1.4.31 cannot start jobs on noble.
- Pin the garage release to 0.2.0, which carries Garage v2.3.0. It fixes cluster bootstrap, tags each layout role with its BOSH instance, and replaces a recreated node's role only when that role provably belongs to the instance.
- Refuse to scale a cluster down to a single instance, even with `params.garage_allow_scale_down`, because Garage's single-node mode won't start on a layout that has moved past its first version.
- Require the cloud config for the blueprint, manifest, and check hooks, since the manifest takes static IPs from the cloud config network.
- Read the default instance count from `meta.default.instances`, because graft fails `static_ips` when `instances` falls through to a literal default.
- Rewrite the MANUAL's smoke-test section to describe the errand as it runs. The errand uses the generated root key and the default bucket, so we create no key by hand, and the vault table now lists the four keys of the `credentials` secret.
- Wire the smoke-tests errand network and static IP for ocfp deployments. The blueprint collects `garage_ip_smoke` reserved-ip and appends a `(( replace ))` network fragment to `network.dynamic.yml`, pinning the errand to the correct subnet.
- Add credentials auto-generation in `kit.yml`. The `access_key` (32-hex), `secret_key` (64-hex), `rpc_secret` (64-hex), and `admin_token` (32-hex) are all generated under a single `credentials` secret at `genesis add-secrets`.
- Construct `GK<access_key>` in `meta` so both the garage job and smoke errand use the identical S3 access key id without duplicating vault lookups.
- Set `persistent_disk_fs: xfs` on the garage instance group.
- Run smoke-tests via `$self->env->bosh->run_errand("smoke-tests")` instead of a bare `system("bosh", "-e", ...)` call.
- Switch all vault credential paths from slash to colon form (`credentials:rpc_secret`, `credentials:admin_token`, etc.) to match the single-secret credential block layout.

### Fixed

- The static IP fragment merges after every feature fragment. Before this, `cluster` replaced `params.ips` with the cloud config's static range, and under `ocfp` it appended a second network to the garage instance group.
- `check.pm` checks the cloud config through the Genesis `has_entry` API. It used to call a method that does not exist and exited 255.
- `check.pm` stemcell probe handles both hashref and `os@version` string forms returned by `bosh stemcells` across Genesis versions (was crashing on the string form).
- The `reset-credentials` addon rotates for real. It runs `safe gen` with list arguments against the environment's own vault, reads each key back to confirm the new value, and never prints a value. Before this, it called a Genesis method that does not exist and died before it reached safe.
- The `info` hook no longer dies on the same missing method, and it now shows the instance count and the replication factor.
- The route-registrar check reads the CF exodus data through `exodus_lookup`. It used to call a function that Genesis does not have, so the check always failed.
- The post-deploy hook treats a missing deploy exit code as a failure, instead of reporting success.
- In `manifests/ocfp.yml`, `garage_vm_type` / `garage_disk_type` now reference the `vm-` / `disk-` prefixed names the cloud-config helpers actually emit.
- `post-deploy.pm` health probe runs through `$self->env->bosh->execute` (director URL) instead of `bosh -e <alias>`, which hangs when a public DNS record shadows the BOSH alias.

## [0.0.1] - 2026-05-21

### Added

- Initial release.
- Single-instance and clustered Garage v1.3.1 deployment.
- Optional CF route-registrar for `s3-api.<system-domain>` with configurable prefix and suffix.
- Auto cluster layout bootstrap with opt-out via `garage.layout.manual`.
- Smoke tests, credential rotation, and mc (garage CLI) addons.
- Cloud-provider overlays for Azure and STACKIT.
