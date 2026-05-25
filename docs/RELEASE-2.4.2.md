# Homelab v2.4.3 Release Notes

v2.4.3 is built directly on the v2.4.1 source tree and keeps the v2.4.1 guided pipeline, fixed VM MAC mapping, TrueNAS manual checkpoint flow, PBS VM110, and current architecture intact.

## Critical retained v2.4.1 foundation

- Install Menu option `0` guided full install pipeline remains present.
- VM101 TrueNAS fixed MAC remains `02:23:14:00:01:01`.
- VM102-107/110 fixed MAC mapping remains generated via `lib/vm-cloudinit-common.sh` and bootstrap `global.env`.
- TrueNAS manual checkpoint still asks `TrueNAS kurulumu bitti mi?`, switches VM101 from ISO to disk boot, checks WebUI, then checks SSH.

## v2.4.3 fixes

### TrueNAS guided flow

- The guided pipeline no longer asks the old redundant post-install helper confirmation after SSH has already been validated.
- `services/truenas/00-truenas-postinstall-import-api-network.sh` now supports `--skip-boot-fix` / `TRUENAS_SKIP_BOOT_FIX=1`, so guided mode does not stop/reboot VM101 a second time.

### Cloudflared

- Guided mode now runs final Cloudflared setup automatically instead of pausing for another yes/no prompt.
- VM103 skips DNS route creation when only early-prepared tunnel JSON is present and `cert.pem` is absent. DNS route creation is expected to happen during the Proxmox early credential prepare step, where `cert.pem` is available.

### Bacscloud / Nextcloud

- Added `config/nextcloud/06-bacscloud-admin-overview-cleanup.sh`.
- Added `config/nextcloud/07-bacscloud-social-login-and-registration.sh`.
- Admin Overview cleanup fixes HSTS/security headers, trusted domain order, Cloudflare overwrite settings, theming/appdata folders, optional AppAPI warning, cron/background jobs, and stale logs.
- Social Login / Registration script installs/enables Social Login and Registration, applies Google provider settings from `google.env`, creates controlled groups, and applies safe default quotas.

### PBS backup automation

- Added `config/pbs/01-pbs-backup-automation.sh`.
- Added `maintenance/pbs/show-backup-status.sh`.
- PBS service install now syncs the VM110 `root` password to `BACKUP_PASS` and enables password SSH for admin recovery.
- PBS enterprise repository disabling is more aggressive across `.sources` and `.list` files.
- PVE gets a `pbs-homelab` storage and a daily `homelab-daily-vm-backup` job with retention defaults.

### Uptime Kuma

- TLS-ignore handling for Proxmox/PBS monitors now sets all plausible TLS-ignore DB columns found in the active Uptime Kuma schema.
- The script prints a validation summary for Proxmox/PBS TLS-ignore fields after DB update.

### Chia

- Official Chia DB torrent import no longer extracts `.tar.gz` into `/tmp`.
- `.tar.gz` DB import streams the SQLite member directly to the target DB path.
- Import validates target free space, non-empty DB, minimum DB size, and SQLite file type before reporting success.
- If download/import cannot be done safely, it reports the reason and leaves Chia to fresh sync instead of printing false success.

### ARR/Prowlarr

- ARR/Prowlarr language and sync helper scripts now treat HTTP 202 as accepted/success where appropriate.

### Audits and maintenance

- Repo audit now explicitly checks the v2.4.3 “kemik kadro”: guided menu, fixed MAC, TrueNAS skip boot-fix, Cloudflared auto final, Bacscloud cleanup/social scripts, PBS automation, Uptime Kuma TLS fallback, Chia tar.gz streaming import, and Chia mnemonic support-bundle exclusion.
