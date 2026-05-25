#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "pbs-service-install"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env
source "$ROOT_DIR/utils/remote.sh"

: "${BACKUP_USER:=backup}"
: "${BACKUP_PASS:?BACKUP_PASS eksik. Önce Install Menu -> 1 Bootstrap secrets/env çalıştır.}"

PBS_VM="110"
PBS_IP="192.168.50.110"
TMP_REMOTE="/tmp/homelab-pbs-install-remote.sh"
ENV_REMOTE="/tmp/homelab-pbs.env"

sq() { printf "%s" "$1" | sed "s/'/'\\''/g; s/^/'/; s/$/'/"; }

cat > /tmp/homelab-pbs.env <<ENV
BACKUP_USER=$(sq "$BACKUP_USER")
BACKUP_PASS=$(sq "$BACKUP_PASS")
PBS_DATASTORE_NAME=homelab
PBS_DATASTORE_PATH=/backup/datastore/homelab
ENV
chmod 600 /tmp/homelab-pbs.env

cat > /tmp/homelab-pbs-install-remote.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive

log(){ echo "[$(date -Is)] $*"; }
need_env(){ local v="$1"; [[ -n "${!v:-}" ]] || { echo "❌ $v eksik"; exit 1; }; }
need_env BACKUP_USER
need_env BACKUP_PASS
PBS_DATASTORE_NAME="${PBS_DATASTORE_NAME:-homelab}"
PBS_DATASTORE_PATH="${PBS_DATASTORE_PATH:-/backup/datastore/homelab}"

wait_port_8007(){
  log "PBS 8007 portu bekleniyor..."
  for i in $(seq 1 60); do
    if ss -ltn 2>/dev/null | grep -q ':8007 '; then
      curl -kfsS --connect-timeout 3 --max-time 8 https://127.0.0.1:8007 >/dev/null 2>&1 || true
      echo "✅ PBS proxy 8007 dinliyor."
      return 0
    fi
    sleep 3
  done
  echo "❌ PBS proxy 8007 açılmadı."
  systemctl --no-pager --full status proxmox-backup-proxy proxmox-backup || true
  journalctl -u proxmox-backup-proxy -b --no-pager -n 200 || true
  return 1
}

log "PBS base paketleri hazırlanıyor..."
apt-get update
apt-get install -y wget curl ca-certificates gnupg lsb-release jq openssh-server sudo apt-transport-https

CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
if [[ "$CODENAME" != "trixie" ]]; then
  echo "⚠️ PBS 4.x için Debian 13/Trixie bekleniyor. Algılanan: ${CODENAME:-unknown}. Repo trixie olarak ayarlanacak."
  CODENAME="trixie"
fi

log "PBS enterprise repo devre dışı bırakılıyor..."
grep -RIl "enterprise.proxmox.com/debian/pbs" /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null | while read -r f; do
  case "$f" in
    *.sources)
      if grep -qi '^Enabled:' "$f"; then sed -i 's/^Enabled:.*/Enabled: false/i' "$f" || true; else printf '\nEnabled: false\n' >> "$f"; fi
      ;;
    *) sed -i 's/^deb /# deb /' "$f" || true ;;
  esac
done

log "PBS no-subscription repo ekleniyor..."
wget -qO /usr/share/keyrings/proxmox-archive-keyring.gpg https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg
cat >/etc/apt/sources.list.d/proxmox-pbs.sources <<PBSREPO
Types: deb
URIs: http://download.proxmox.com/debian/pbs
Suites: ${CODENAME}
Components: pbs-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
Enabled: true
PBSREPO

log "apt update + proxmox-backup-server kurulumu..."
apt-get update
apt-get install -y proxmox-backup-server proxmox-backup-client

dpkg-query -W proxmox-backup-server proxmox-backup-client
command -v proxmox-backup-manager >/dev/null || { echo "❌ proxmox-backup-manager yok; PBS paketi kurulmamış."; exit 1; }

log "root/BACKUP_USER şifreleri ve SSH root erişimi ayarlanıyor..."
if ! id "$BACKUP_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "$BACKUP_USER"
fi
echo "${BACKUP_USER}:${BACKUP_PASS}" | chpasswd
echo "root:${BACKUP_PASS}" | chpasswd
usermod -aG sudo "$BACKUP_USER" || true
mkdir -p /etc/ssh/sshd_config.d
cat >/etc/ssh/sshd_config.d/99-homelab-root-login.conf <<'SSHCONF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
SSHCONF
systemctl enable --now ssh >/dev/null 2>&1 || true
systemctl restart ssh >/dev/null 2>&1 || true

log "PBS servisleri enable/start..."
systemctl enable --now proxmox-backup-proxy proxmox-backup
wait_port_8007

log "PBS kullanıcı/ACL ayarlanıyor: ${BACKUP_USER}@pam"
proxmox-backup-manager user create "${BACKUP_USER}@pam" 2>/dev/null || proxmox-backup-manager user update "${BACKUP_USER}@pam" --enable true 2>/dev/null || true
proxmox-backup-manager acl update / Admin --auth-id "${BACKUP_USER}@pam" || true

log "Varsayılan local datastore hazırlanıyor: ${PBS_DATASTORE_NAME} -> ${PBS_DATASTORE_PATH}"
mkdir -p "$PBS_DATASTORE_PATH"
chown backup:backup "$PBS_DATASTORE_PATH" 2>/dev/null || true
if ! proxmox-backup-manager datastore list --output-format json 2>/dev/null | jq -e --arg n "$PBS_DATASTORE_NAME" '.[]? | select(.name==$n)' >/dev/null 2>&1; then
  proxmox-backup-manager datastore create "$PBS_DATASTORE_NAME" "$PBS_DATASTORE_PATH"
else
  echo "✅ Datastore zaten mevcut: $PBS_DATASTORE_NAME"
fi
proxmox-backup-manager acl update "/datastore/${PBS_DATASTORE_NAME}" DatastoreAdmin --auth-id "${BACKUP_USER}@pam" || true

log "Final PBS validation"
proxmox-backup-manager versions || proxmox-backup-manager version || true
proxmox-backup-manager datastore list
curl -kfsS --connect-timeout 5 --max-time 10 https://127.0.0.1:8007 >/dev/null
ss -ltnp | grep ':8007'

if [[ -f /var/run/reboot-required ]]; then
  echo "⚠️ PBS VM reboot-required işaretli. Kurulum tamamlandıktan sonra maintenance penceresinde reboot edebilirsin."
fi

cat <<DONE
✅ Proxmox Backup Server kuruldu ve doğrulandı.
Web UI:
  https://192.168.50.110:8007
Login:
  ${BACKUP_USER}@pam veya root@pam
  şifre: BACKUP_PASS
Datastore:
  ${PBS_DATASTORE_NAME} -> ${PBS_DATASTORE_PATH}
DONE
REMOTE
chmod +x /tmp/homelab-pbs-install-remote.sh

wait_ssh "$PBS_VM"
scp "${SSH_OPTS[@]}" /tmp/homelab-pbs.env "$SSH_USER@$PBS_IP:$ENV_REMOTE" >/dev/null
scp "${SSH_OPTS[@]}" /tmp/homelab-pbs-install-remote.sh "$SSH_USER@$PBS_IP:$TMP_REMOTE" >/dev/null
ssh "${SSH_OPTS[@]}" "$SSH_USER@$PBS_IP" "chmod +x '$TMP_REMOTE' && sudo bash -c 'set -a; source $ENV_REMOTE; set +a; $TMP_REMOTE; rm -f $ENV_REMOTE'"

rm -f /tmp/homelab-pbs.env /tmp/homelab-pbs-install-remote.sh

echo "🧪 Proxmox host üzerinden PBS reachability doğrulanıyor..."
for i in $(seq 1 30); do
  if curl -kfsS --connect-timeout 3 --max-time 8 "https://${PBS_IP}:8007" >/dev/null 2>&1; then
    echo "✅ PBS service install tamamlandı ve reachable: https://${PBS_IP}:8007"
    exit 0
  fi
  sleep 3
done

echo "❌ PBS kurulum scripti bitti ama https://${PBS_IP}:8007 reachable değil."
exit 1
