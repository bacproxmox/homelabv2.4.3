#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "pbs-backup-automation"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env

require_root
load_env_file "$SECRETS_DIR/users.env"
: "${BACKUP_USER:=backup}"
: "${BACKUP_PASS:?BACKUP_PASS eksik. Önce Bootstrap secrets/env çalıştır.}"

PBS_IP="${PBS_IP:-192.168.50.110}"
PBS_STORAGE_ID="${PBS_STORAGE_ID:-pbs-homelab}"
PBS_DATASTORE="${PBS_DATASTORE:-homelab}"
PBS_NFS_EXPORT="${PBS_NFS_EXPORT:-192.168.50.99:/srv/pbs-a/datastore}"
PBS_NFS_MOUNT="${PBS_NFS_MOUNT:-/mnt/pi-pbs-a}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-03:30}"
PRUNE_KEEP_DAILY="${PRUNE_KEEP_DAILY:-7}"
PRUNE_KEEP_WEEKLY="${PRUNE_KEEP_WEEKLY:-4}"
PRUNE_KEEP_MONTHLY="${PRUNE_KEEP_MONTHLY:-3}"
VERIFY_SCHEDULE="${VERIFY_SCHEDULE:-Sun 04:30}"

apt-get update -y >/dev/null
apt-get install -y sshpass curl jq openssl nfs-common >/dev/null
SSH_OPTS=(-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/root/.ssh/known_hosts -o ConnectTimeout=10 -o PreferredAuthentications=password -o PubkeyAuthentication=no)
sq(){ printf '%q' "$1"; }

remote_pbs(){
  sshpass -p "$BACKUP_PASS" ssh "${SSH_OPTS[@]}" "root@${PBS_IP}" "$@"
}

copy_pbs(){
  sshpass -p "$BACKUP_PASS" scp "${SSH_OPTS[@]}" "$1" "root@${PBS_IP}:$2" >/dev/null
}

ensure_pbs_ssh(){
  echo "🧪 PBS SSH/root erişimi kontrol ediliyor..."
  if remote_pbs 'echo PBS_SSH_OK' | grep -q PBS_SSH_OK; then
    echo "✅ PBS root SSH erişimi OK."
    return 0
  fi
  echo "❌ PBS root SSH erişimi yok. VM110 root password BACKUP_PASS ile set edilmeli."
  return 1
}

ensure_pbs_packages_and_service(){
  echo "🧰 PBS paket/servis doğrulanıyor..."
  cat >/tmp/homelab-pbs-ensure-server.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${BACKUP_USER:=backup}"
: "${BACKUP_PASS:?BACKUP_PASS eksik}"

log(){ echo "[$(date -Is)] $*"; }
wait_8007(){
  for i in $(seq 1 60); do
    if ss -ltn 2>/dev/null | grep -q ':8007 '; then return 0; fi
    sleep 3
  done
  systemctl --no-pager --full status proxmox-backup-proxy proxmox-backup || true
  journalctl -u proxmox-backup-proxy -b --no-pager -n 120 || true
  return 1
}

mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-homelab-root-login.conf <<'SSHCONF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
SSHCONF
echo "root:${BACKUP_PASS}" | chpasswd
if ! id "$BACKUP_USER" >/dev/null 2>&1; then useradd -m -s /bin/bash "$BACKUP_USER"; fi
echo "${BACKUP_USER}:${BACKUP_PASS}" | chpasswd
usermod -aG sudo "$BACKUP_USER" || true
systemctl enable --now ssh >/dev/null 2>&1 || true
systemctl restart ssh >/dev/null 2>&1 || true

if ! command -v proxmox-backup-manager >/dev/null 2>&1 || ! dpkg-query -W proxmox-backup-server >/dev/null 2>&1; then
  log "PBS paketi eksik; no-subscription repo + proxmox-backup-server kuruluyor..."
  apt-get update
  apt-get install -y wget curl ca-certificates gnupg jq openssh-server sudo
  wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
  grep -RIl "enterprise.proxmox.com/debian/pbs" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | while read -r f; do
    case "$f" in
      *.sources) if grep -qi '^Enabled:' "$f"; then sed -i 's/^Enabled:.*/Enabled: false/i' "$f"; else printf '\nEnabled: false\n' >> "$f"; fi ;;
      *) sed -i 's/^deb /# deb /' "$f" || true ;;
    esac
  done
  cat >/etc/apt/sources.list.d/proxmox-pbs.sources <<PBSREPO
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: trixie
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: true
PBSREPO
  apt-get update
  apt-get install -y proxmox-backup-server proxmox-backup-client
fi

dpkg-query -W proxmox-backup-server proxmox-backup-client
command -v proxmox-backup-manager >/dev/null
systemctl enable --now proxmox-backup-proxy proxmox-backup
wait_8007
curl -kfsS --connect-timeout 5 --max-time 10 https://127.0.0.1:8007 >/dev/null
proxmox-backup-manager versions || proxmox-backup-manager version || true
REMOTE
  chmod +x /tmp/homelab-pbs-ensure-server.sh
  cat >/tmp/homelab-pbs-ensure.env <<ENV
BACKUP_USER=$(sq "$BACKUP_USER")
BACKUP_PASS=$(sq "$BACKUP_PASS")
ENV
  chmod 600 /tmp/homelab-pbs-ensure.env
  copy_pbs /tmp/homelab-pbs-ensure-server.sh /tmp/homelab-pbs-ensure-server.sh
  copy_pbs /tmp/homelab-pbs-ensure.env /tmp/homelab-pbs-ensure.env
  remote_pbs "chmod +x /tmp/homelab-pbs-ensure-server.sh && bash -c 'set -a; source /tmp/homelab-pbs-ensure.env; set +a; bash /tmp/homelab-pbs-ensure-server.sh; rm -f /tmp/homelab-pbs-ensure.env'"
  rm -f /tmp/homelab-pbs-ensure-server.sh /tmp/homelab-pbs-ensure.env
}

wait_pbs(){
  echo "⏳ PBS VM bekleniyor: ${PBS_IP}:8007"
  for i in $(seq 1 60); do
    if curl -kfsS --connect-timeout 3 --max-time 8 "https://${PBS_IP}:8007" >/dev/null 2>&1; then
      echo "✅ PBS API/Web reachable."
      return 0
    fi
    sleep 5
  done
  echo "❌ PBS reachable değil: https://${PBS_IP}:8007"
  return 1
}

pbs_fingerprint(){
  local fp=""
  fp="$(remote_pbs "proxmox-backup-manager cert info 2>/dev/null | awk -F': ' '/Fingerprint/ {print \\$2; exit}'" 2>/dev/null || true)"
  if [[ -z "$fp" ]]; then
    fp="$(echo | openssl s_client -connect "${PBS_IP}:8007" -servername "$PBS_IP" 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null | sed 's/^sha256 Fingerprint=//I; s/^SHA256 Fingerprint=//I; s/://g' || true)"
  fi
  echo "$fp"
}

configure_pbs_server(){
  echo "🧰 PBS datastore/NFS/ACL doğrulanıyor..."
  cat >/tmp/homelab-pbs-configure-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
: "${BACKUP_USER:=backup}"
: "${BACKUP_PASS:?BACKUP_PASS eksik}"
: "${PBS_DATASTORE:=homelab}"
: "${PBS_NFS_EXPORT:=192.168.50.99:/srv/pbs-a/datastore}"
: "${PBS_NFS_MOUNT:=/mnt/pi-pbs-a}"
: "${PRUNE_KEEP_DAILY:=7}"
: "${PRUNE_KEEP_WEEKLY:=4}"
: "${PRUNE_KEEP_MONTHLY:=3}"
: "${VERIFY_SCHEDULE:=Sun 04:30}"

export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null
apt-get install -y nfs-common jq openssh-server sudo >/dev/null

mkdir -p "$PBS_NFS_MOUNT"
if ! grep -Fq "$PBS_NFS_EXPORT $PBS_NFS_MOUNT" /etc/fstab; then
  echo "$PBS_NFS_EXPORT $PBS_NFS_MOUNT nfs4 vers=4.2,proto=tcp,hard,noatime,_netdev,x-systemd.automount,x-systemd.device-timeout=30 0 0" >> /etc/fstab
fi
systemctl daemon-reload
mount "$PBS_NFS_MOUNT" || mount -a || true
if ! findmnt "$PBS_NFS_MOUNT" >/dev/null 2>&1; then
  echo "⚠️ Raspberry Pi NFS datastore mount olmadı: $PBS_NFS_EXPORT -> $PBS_NFS_MOUNT"
  DATASTORE_PATH="/backup/datastore/${PBS_DATASTORE}"
else
  DATASTORE_PATH="${PBS_NFS_MOUNT}/${PBS_DATASTORE}"
fi
mkdir -p "$DATASTORE_PATH"
chown -R backup:backup "$(dirname "$DATASTORE_PATH")" "$DATASTORE_PATH" 2>/dev/null || true

proxmox-backup-manager user create "${BACKUP_USER}@pam" 2>/dev/null || proxmox-backup-manager user update "${BACKUP_USER}@pam" --enable true 2>/dev/null || true
if ! proxmox-backup-manager datastore list --output-format json 2>/dev/null | jq -e --arg n "$PBS_DATASTORE" '.[]? | select(.name==$n)' >/dev/null 2>&1; then
  proxmox-backup-manager datastore create "$PBS_DATASTORE" "$DATASTORE_PATH"
fi
proxmox-backup-manager acl update / Admin --auth-id "${BACKUP_USER}@pam" || true
proxmox-backup-manager acl update "/datastore/${PBS_DATASTORE}" DatastoreAdmin --auth-id "${BACKUP_USER}@pam" || true

proxmox-backup-manager prune-job create "homelab-daily-prune" --store "$PBS_DATASTORE" --schedule daily --keep-daily "$PRUNE_KEEP_DAILY" --keep-weekly "$PRUNE_KEEP_WEEKLY" --keep-monthly "$PRUNE_KEEP_MONTHLY" 2>/dev/null \
  || proxmox-backup-manager prune-job update "homelab-daily-prune" --store "$PBS_DATASTORE" --schedule daily --keep-daily "$PRUNE_KEEP_DAILY" --keep-weekly "$PRUNE_KEEP_WEEKLY" --keep-monthly "$PRUNE_KEEP_MONTHLY" 2>/dev/null || true
proxmox-backup-manager verify-job create "homelab-weekly-verify" --store "$PBS_DATASTORE" --schedule "$VERIFY_SCHEDULE" 2>/dev/null \
  || proxmox-backup-manager verify-job update "homelab-weekly-verify" --store "$PBS_DATASTORE" --schedule "$VERIFY_SCHEDULE" 2>/dev/null || true

systemctl enable --now proxmox-backup-proxy proxmox-backup >/dev/null
ss -ltnp | grep ':8007'
proxmox-backup-manager datastore list
REMOTE
  chmod +x /tmp/homelab-pbs-configure-remote.sh
  cat >/tmp/homelab-pbs-automation.env <<ENV
BACKUP_USER=$(sq "$BACKUP_USER")
BACKUP_PASS=$(sq "$BACKUP_PASS")
PBS_DATASTORE=$(sq "$PBS_DATASTORE")
PBS_NFS_EXPORT=$(sq "$PBS_NFS_EXPORT")
PBS_NFS_MOUNT=$(sq "$PBS_NFS_MOUNT")
PRUNE_KEEP_DAILY=$(sq "$PRUNE_KEEP_DAILY")
PRUNE_KEEP_WEEKLY=$(sq "$PRUNE_KEEP_WEEKLY")
PRUNE_KEEP_MONTHLY=$(sq "$PRUNE_KEEP_MONTHLY")
VERIFY_SCHEDULE=$(sq "$VERIFY_SCHEDULE")
ENV
  chmod 600 /tmp/homelab-pbs-automation.env
  copy_pbs /tmp/homelab-pbs-configure-remote.sh /tmp/homelab-pbs-configure-remote.sh
  copy_pbs /tmp/homelab-pbs-automation.env /tmp/homelab-pbs-automation.env
  remote_pbs "chmod +x /tmp/homelab-pbs-configure-remote.sh && bash -c 'set -a; source /tmp/homelab-pbs-automation.env; set +a; bash /tmp/homelab-pbs-configure-remote.sh; rm -f /tmp/homelab-pbs-automation.env'"
  rm -f /tmp/homelab-pbs-configure-remote.sh /tmp/homelab-pbs-automation.env
}

configure_pve_storage(){
  local fp prune
  fp="$(pbs_fingerprint)"
  [[ -n "$fp" ]] || { echo "❌ PBS fingerprint alınamadı."; return 1; }
  echo "🔑 PBS fingerprint: $fp"
  if pvesm status | awk '{print $1}' | grep -qx "$PBS_STORAGE_ID"; then
    echo "✅ PVE PBS storage zaten var: $PBS_STORAGE_ID"
    pvesm set "$PBS_STORAGE_ID" --server "$PBS_IP" --datastore "$PBS_DATASTORE" --username "${BACKUP_USER}@pam" --password "$BACKUP_PASS" --fingerprint "$fp" >/dev/null
  else
    pvesm add pbs "$PBS_STORAGE_ID" --server "$PBS_IP" --datastore "$PBS_DATASTORE" --username "${BACKUP_USER}@pam" --password "$BACKUP_PASS" --fingerprint "$fp" --content backup
  fi
  pvesm status | grep -E "^${PBS_STORAGE_ID}[[:space:]]" || { echo "❌ PVE PBS storage görünmüyor."; return 1; }

  prune="keep-daily=${PRUNE_KEEP_DAILY},keep-weekly=${PRUNE_KEEP_WEEKLY},keep-monthly=${PRUNE_KEEP_MONTHLY}"
  mkdir -p /etc/pve
  if [[ -f /etc/pve/jobs.cfg ]]; then cp /etc/pve/jobs.cfg "/etc/pve/jobs.cfg.bak-v243-$(date +%Y%m%d-%H%M%S)" || true; fi
  python3 - "$PBS_STORAGE_ID" "$BACKUP_SCHEDULE" "$prune" <<'PY'
from pathlib import Path
import sys,re
storage, schedule, prune = sys.argv[1:4]
p=Path('/etc/pve/jobs.cfg')
text=p.read_text() if p.exists() else ''
block=f'''vzdump: homelab-daily-vm-backup
	schedule {schedule}
	storage {storage}
	mode snapshot
	enabled 1
	all 1
	compress zstd
	prune-backups {prune}
	mailto root
'''
pat=re.compile(r'(?ms)^vzdump:\s+homelab-daily-vm-backup\n(?:\t.*\n?)*')
if pat.search(text): text=pat.sub(block, text)
else:
    if text and not text.endswith('\n'): text+='\n'
    text += block
p.write_text(text)
PY
  echo "✅ PVE daily backup job yazıldı: /etc/pve/jobs.cfg"
  grep -A10 '^vzdump: homelab-daily-vm-backup' /etc/pve/jobs.cfg || true
}

validate(){
  echo "🧪 PBS/PVE backup validation"
  curl -kfsS --connect-timeout 5 --max-time 10 "https://${PBS_IP}:8007" >/dev/null || return 1
  pvesm status | grep -E "^${PBS_STORAGE_ID}[[:space:]]" || return 1
  grep -A10 '^vzdump: homelab-daily-vm-backup' /etc/pve/jobs.cfg || return 1
  remote_pbs "proxmox-backup-manager datastore list"
  echo "✅ PBS backup automation tamamlandı. İlk backup zamanlaması: daily ${BACKUP_SCHEDULE}"
}

ensure_pbs_ssh
ensure_pbs_packages_and_service
wait_pbs
configure_pbs_server
configure_pve_storage
validate
