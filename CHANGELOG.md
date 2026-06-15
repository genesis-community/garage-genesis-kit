# Changelog

## [Unreleased]

### Changed

- Wire smoke-tests errand network and static IP for ocfp deployments: blueprint
  collects `garage_ip_smoke` reserved-ip and appends a `(( replace ))` network
  fragment to `network.dynamic.yml`, pinning the errand to the correct subnet.
- Add credentials auto-generation in `kit.yml`: `access_key` (32-hex),
  `secret_key` (64-hex), `rpc_secret` (64-hex), and `admin_token` (32-hex) are
  all generated under a single `credentials` secret at `genesis add-secrets`.
- Construct `GK<access_key>` in `meta` so both the garage job and smoke errand
  use the identical S3 access key id without duplicating vault lookups.
- Set `persistent_disk_fs: xfs` on the garage instance group.
- Run smoke-tests via `$self->env->bosh->run_errand("smoke-tests")` instead of
  a bare `system("bosh", "-e", ...)` call.
- Pin garage release to version 0.1.6; drop `url` and `sha1` (local build).
- Switch all vault credential paths from slash to colon form
  (`credentials:rpc_secret`, `credentials:admin_token`, etc.) to match the
  single-secret credential block layout.

### Added

- Proxmox VE (`pve`) support: added to `kit.yml` `supports`, and
  `cloud-config.pm` carries `pve` branches on the network, every vm_type, and
  every disk_type (bridge, cpu/ram/disk, and persistent disk storage/format,
  all overridable via `bosh-configs.cpi.*`).
- Service-named cloud-config entries referenced by the ocfp manifest:
  `vm_type_definition('garage')` and `disk_type_definition('garage')`, resolved
  as `<cloud>vm-garage` / `<cloud>disk-garage`.
- `cloud-config.pm` emits one BOSH CPI per AZ so the deploy-time stemcell check
  resolves against the named per-AZ CPI.

### Fixed

- `check.pm` stemcell probe handles both hashref and `os@version` string forms
  returned by `bosh stemcells` across Genesis versions (was crashing on the
  string form).
- `manifests/ocfp.yml`: `garage_vm_type` / `garage_disk_type` reference the
  `vm-` / `disk-` prefixed names the cloud-config helpers actually emit.
- `post-deploy.pm` health probe runs through `$self->env->bosh->execute`
  (director URL) instead of `bosh -e <alias>`, which hangs when a public DNS
  record shadows the BOSH alias.

## [0.0.1] - 2026-05-21

### Added

- Initial release.
- Single-instance and clustered Garage v1.3.1 deployment.
- Optional CF route-registrar for `s3-api.<system-domain>` with configurable prefix and suffix.
- Auto cluster layout bootstrap with opt-out via `garage.layout.manual`.
- Smoke tests, credential rotation, and mc (garage CLI) addons.
- Cloud-provider overlays for Azure and STACKIT.
