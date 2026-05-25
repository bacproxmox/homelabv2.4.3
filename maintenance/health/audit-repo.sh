#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

echo "========================================="
echo " Homelab v2.4.3 - Repo Audit"
echo "========================================="

fail=0
check() {
  local name="$1" cmd="$2"
  echo
  echo "▶️ $name"
  if bash -c "$cmd"; then
    echo "✅ OK: $name"
  else
    echo "❌ FAIL: $name"
    fail=1
  fi
}

check "Bash syntax" 'find . -name "*.sh" -print0 | xargs -0 -n1 bash -n'
check "Executable scripts" 'missing=$(find . -name "*.sh" ! -perm -111); [[ -z "$missing" ]] || { echo "$missing"; exit 1; }'
check "Required directories" 'for d in bootstrap vm services config menu utils maintenance lib docs gpu additionals; do [[ -d "$d" ]] || exit 1; done'
check "Guided full pipeline present" 'grep -q "0) Guided full install pipeline" menu/install-menu.sh && grep -q "run_full_install_pipeline" menu/install-menu.sh'
check "TrueNAS fixed MAC present" 'grep -q "02:23:14:00:01:01" vm/101-truenas-vm-install.sh && grep -q "TRUENAS_FIXED_MAC" vm/101-truenas-vm-install.sh'
check "Ubuntu/PBS fixed MAC helper present" 'grep -q "mac_for_vmid" lib/vm-cloudinit-common.sh && grep -q "VM110_MAC" bootstrap/00-bootstrap-secrets.sh'
check "TrueNAS helper skip boot fix support" 'grep -q "TRUENAS_SKIP_BOOT_FIX" services/truenas/00-truenas-postinstall-import-api-network.sh'
check "Guided Cloudflared auto final" 'grep -q "GUIDED_AUTO_CLOUDFLARED=1" menu/install-menu.sh'
check "Bacscloud Admin Overview cleanup script" '[[ -f config/nextcloud/06-bacscloud-admin-overview-cleanup.sh ]] && grep -q "Strict-Transport-Security" config/nextcloud/06-bacscloud-admin-overview-cleanup.sh'
check "Bacscloud Social Login + Registration script" '[[ -f config/nextcloud/07-bacscloud-social-login-and-registration.sh ]] && grep -q "sociallogin" config/nextcloud/07-bacscloud-social-login-and-registration.sh && grep -q "registration" config/nextcloud/07-bacscloud-social-login-and-registration.sh'
check "PBS backup automation script" '[[ -f config/pbs/01-pbs-backup-automation.sh ]] && grep -q "homelab-daily-vm-backup" config/pbs/01-pbs-backup-automation.sh'
check "Uptime Kuma TLS ignore fallback" 'grep -q "TLS ignore validate" config/uptime-kuma/02-uptime-kuma-auto-config.sh'
check "Chia tar.gz streaming import fix" 'grep -q "tar.gz arşivi /tmp.ye açılmadan stream" services/chia/01-chia-farmer-service-install.sh || grep -q "stream import" services/chia/01-chia-farmer-service-install.sh'
check "Chia TrueNAS DB cache integration" 'grep -q "/mnt/tank/chia-db" services/truenas/01-truenas-api-bootstrap-storage.sh && grep -q "/mnt/chia-db-cache" bootstrap/00-bootstrap-secrets.sh && grep -q "ensure_chia_db_cache_mount" services/chia/01-chia-farmer-service-install.sh'
check "VM107 Chia local disk default is not tiny" 'grep -q "CHIA_VM_DISK_SIZE" vm/107-chia-farmer-vm-install.sh && ! grep -q " 320G " vm/107-chia-farmer-vm-install.sh'
check "Support bundle excludes raw Chia mnemonic" 'grep -q "chia-mnemonic.env" maintenance/logs/collect-support-bundle.sh'
check "Core service installers exist" 'for f in services/arr/01-arr-service-install.sh services/seerr/01-seerr-service-install.sh services/uptime-kuma/01-uptime-kuma-service-install.sh services/nextcloud/01-nextcloud-service-install.sh services/jellyfin/01-jellyfin-service-install.sh services/immich/01-immich-service-install.sh services/ollama/01-ollama-openwebui-service-install.sh services/lidarr/01-lidarr-service-install.sh services/homeassistant/01-homeassistant-service-install.sh services/pbs/01-pbs-service-install.sh services/cloudflared/01-cloudflared-service-install.sh; do [[ -f "$f" ]] || { echo "missing $f"; exit 1; }; done'


check "VM107 Chia disk default is 512G" 'grep -q "CHIA_VM_DISK_SIZE=\"\${CHIA_VM_DISK_SIZE:-512G}\"" vm/107-chia-farmer-vm-install.sh'
check "VM110 PBS OS disk is 64G" 'grep -q "8192 4 64G" vm/110-pbs-backup-vm-install.sh'
check "Cloud-init disk resize validation" 'grep -q "assert_vm_disk_at_least" lib/vm-cloudinit-common.sh && grep -q "preflight_storage_for_disk" lib/vm-cloudinit-common.sh'
check "PBS server package hard validation" 'grep -q "apt-get install -y proxmox-backup-server proxmox-backup-client" services/pbs/01-pbs-service-install.sh && grep -q "PBS service install tamamlandı ve reachable" services/pbs/01-pbs-service-install.sh'
check "PBS automation can repair missing PBS server" 'grep -q "ensure_pbs_packages_and_service" config/pbs/01-pbs-backup-automation.sh'
check "Immich CPU fallback when /dev/dri missing" 'grep -q "Immich CPU mode" services/immich/01-immich-service-install.sh && grep -q "docker-compose.gpu.yml" services/immich/01-immich-service-install.sh'
check "Debug collector preserves timestamp under sudo" 'grep -q "sudo TS=.*bash" maintenance/logs/collect-pbs-immich-debug.sh'
check "Bacscloud cron.d directory creation" 'grep -q "mkdir -p /etc/cron.d" config/nextcloud/06-bacscloud-admin-overview-cleanup.sh'
check "OAuth secrets are not printed" 'grep -q "custom_providers --value=\"\$PROVIDERS\" >/dev/null" config/nextcloud/07-bacscloud-social-login-and-registration.sh && grep -q "GOCSPX-<REDACTED>" maintenance/logs/collect-support-bundle.sh'

if [[ "$fail" -eq 0 ]]; then
  echo
  echo "✅ Repo audit temiz."
else
  echo
  echo "❌ Repo audit hata buldu."
fi
exit "$fail"
