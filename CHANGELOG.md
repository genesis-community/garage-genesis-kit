# Changelog

## [0.1.0] - Unreleased

### Added

- Add a `resolute` feature that deploys on Ubuntu Resolute stemcells. It sets `params.stemcell_os` to `ubuntu-resolute` and pins bpm 1.4.41. The blueprint refuses a conflicting `stemcell_os` under the feature, and it refuses `stemcell_os: ubuntu-resolute` without the feature.
- Add a testkit spec suite that covers base, cluster, cluster with explicit IPs, ocfp, resolute, ocfp with cluster and resolute, and both resolute refusals. The refusal specs assert a non-zero exit from every genesis command.
- Add MANUAL sections on resolute stemcells and on how a cluster bootstraps, along with parameter rows for `garage_replication_factor`, `ips`, `stemcell_os`, and `stemcell_version`.
- Add Proxmox VE (`pve`) support. The kit lists `pve` in `kit.yml` `supports`, and `cloud-config.pm` carries `pve` branches on the network, every vm_type, and every disk_type (bridge, cpu/ram/disk, and persistent disk storage/format, all overridable via `bosh-configs.cpi.*`).
- Add the service-named cloud-config entries `vm_type_definition('garage')` and `disk_type_definition('garage')`, which the ocfp manifest references and which resolve as `<cloud>vm-garage` / `<cloud>disk-garage`.
- Make `cloud-config.pm` emit one BOSH CPI per AZ so the deploy-time stemcell check resolves against the named per-AZ CPI.

### Changed

- Pin bpm to 1.4.22 on noble instead of `latest`, because bpm 1.4.31 cannot start jobs on noble.
- Pin the garage release to the dev release 0.2.0+dev.1, which carries Garage v2.3.0 and fixes cluster bootstrap. The final release's URL and SHA1 replace this pin.
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
