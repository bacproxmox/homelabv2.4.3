#!/usr/bin/env bash
set -Eeuo pipefail
TS="$(date +%Y%m%d-%H%M%S)"
OUT_DIR="/root/homelab-logs/pbs-immich-debug-${TS}"
mkdir -p "$OUT_DIR"
PBS_HOST="${PBS_HOST:-192.168.50.110}"; PBS_USER="${PBS_USER:-root}"
IMMICH_HOST="${IMMICH_HOST:-192.168.50.106}"; IMMICH_USER="${IMMICH_USER:-bacmaster}"
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

echo "============================================================"
echo " Homelab PBS + Immich Debug Collector"
echo "============================================================"
echo "PBS:    ${PBS_USER}@${PBS_HOST}"
echo "Immich: ${IMMICH_USER}@${IMMICH_HOST}"
echo "Output: ${OUT_DIR}"

cat >/tmp/pbs-debug.remote.sh <<'PBS_REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
TS="${TS:?TS missing}"
BASE="/tmp/homelab-pbs-debug-${TS}"; mkdir -p "$BASE"
run(){ local n="$1"; shift; echo "### $*" > "$BASE/${n}.txt"; "$@" >> "$BASE/${n}.txt" 2>&1 || true; }
runsh(){ local n="$1"; shift; echo "### $*" > "$BASE/${n}.txt"; bash -lc "$*" >> "$BASE/${n}.txt" 2>&1 || true; }
{
  echo "date=$(date -Is)"; echo "host=$(hostname)"; cat /etc/os-release || true
} > "$BASE/00-info.txt" 2>&1
runsh ip_addr 'ip -br a; ip route'
runsh disk 'lsblk -f; df -hT; mount | sort'
runsh ports 'ss -lntup || true'
runsh packages "dpkg -l | grep -Ei 'proxmox-backup|pbs' || true; apt-cache policy proxmox-backup-server proxmox-backup-client 2>/dev/null || true"
runsh sources "find /etc/apt -maxdepth 3 -type f \( -name '*.list' -o -name '*.sources' \) -print -exec sed -n '1,220p' {} \;"
runsh status 'systemctl status proxmox-backup proxmox-backup-proxy ssh --no-pager || true; systemctl --failed || true'
runsh journal_proxy 'journalctl -u proxmox-backup-proxy -b --no-pager -n 500 || true'
runsh journal_server 'journalctl -u proxmox-backup -b --no-pager -n 500 || true'
runsh commands 'command -v proxmox-backup-manager || true; proxmox-backup-manager versions 2>&1 || true; proxmox-backup-manager datastore list 2>&1 || true'
runsh curl 'curl -k -I --connect-timeout 5 --max-time 10 https://127.0.0.1:8007 2>&1 || true; curl -k -I --connect-timeout 5 --max-time 10 https://192.168.50.110:8007 2>&1 || true'
tar -C /tmp -czf "/tmp/homelab-pbs-debug-${TS}.tar.gz" "homelab-pbs-debug-${TS}"
echo "/tmp/homelab-pbs-debug-${TS}.tar.gz"
PBS_REMOTE

cat >/tmp/immich-debug.remote.sh <<'IMMICH_REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
TS="${TS:?TS missing}"
BASE="/tmp/homelab-immich-debug-${TS}"; mkdir -p "$BASE"
redact(){ sed -i -E -e 's/(password|passwd|secret|token|api[_-]?key|clientSecret|client_secret|access_token|refresh_token)(["=: ]+)[^", ]+/\1\2***REDACTED***/Ig' -e 's/GOCSPX-[A-Za-z0-9_-]+/GOCSPX-***REDACTED***/g' "$1" 2>/dev/null || true; }
runsh(){ local n="$1"; shift; echo "### $*" > "$BASE/${n}.txt"; bash -lc "$*" >> "$BASE/${n}.txt" 2>&1 || true; redact "$BASE/${n}.txt"; }
{
  echo "date=$(date -Is)"; echo "host=$(hostname)"; cat /etc/os-release || true
} > "$BASE/00-info.txt" 2>&1
runsh ip_addr 'ip -br a; ip route'
runsh disk 'lsblk -f; df -hT; mount | sort'
runsh gpu "lspci -nn | grep -Ei 'vga|3d|display|intel|nvidia|amd' || true; ls -lah /dev/dri 2>&1 || true; lsmod | grep -Ei 'i915|xe|nvidia|amdgpu' || true; getent group render video || true"
runsh docker 'systemctl status docker --no-pager || true; docker version 2>&1 || true; docker compose version 2>&1 || true; docker ps -a --no-trunc || true'
runsh immich_files "find /opt /srv /home -maxdepth 5 -type f \( -name docker-compose.yml -o -name compose.yml -o -name .env \) 2>/dev/null | grep -Ei 'immich|homelab' || true; ls -lah /opt/homelab/immich 2>/dev/null || true"
for c in hb-immich-server hb-immich-machine-learning hb-immich-postgres hb-immich-redis; do
  if docker ps -a --format '{{.Names}}' | grep -qx "$c"; then
    runsh "inspect_${c}" "docker inspect '$c' || true"
    runsh "logs_${c}" "docker logs --tail=500 '$c' 2>&1 || true"
  fi
done
runsh port 'ss -lntup | grep -E "2283|5432|6379" || true; curl -fsS --connect-timeout 5 --max-time 10 http://127.0.0.1:2283/api/server/ping 2>&1 || true'
if [[ -f /opt/homelab/immich/docker-compose.yml ]]; then
  (cd /opt/homelab/immich && docker compose config) > "$BASE/compose_config.txt" 2>&1 || true
  redact "$BASE/compose_config.txt"
fi
tar -C /tmp -czf "/tmp/homelab-immich-debug-${TS}.tar.gz" "homelab-immich-debug-${TS}"
echo "/tmp/homelab-immich-debug-${TS}.tar.gz"
IMMICH_REMOTE

collect_one(){
  local label="$1" host="$2" user="$3" script="$4" remote="/tmp/${label}-debug-${TS}.sh" tar="/tmp/homelab-${label}-debug-${TS}.tar.gz"
  echo; echo "Collecting ${label}: ${user}@${host}"
  scp "${SSH_OPTS[@]}" "$script" "${user}@${host}:${remote}"
  if [[ "$user" == "root" ]]; then
    ssh -tt "${SSH_OPTS[@]}" "${user}@${host}" "chmod +x '$remote' && TS='$TS' bash '$remote'"
  else
    ssh -tt "${SSH_OPTS[@]}" "${user}@${host}" "chmod +x '$remote' && sudo TS='$TS' bash '$remote'"
  fi
  scp "${SSH_OPTS[@]}" "${user}@${host}:${tar}" "$OUT_DIR/"
  echo "✅ ${label} logları alındı."
}

collect_one pbs "$PBS_HOST" "$PBS_USER" /tmp/pbs-debug.remote.sh || true
collect_one immich "$IMMICH_HOST" "$IMMICH_USER" /tmp/immich-debug.remote.sh || true
{
  qm status 110 2>&1 || true; qm config 110 2>&1 || true
  qm status 106 2>&1 || true; qm config 106 2>&1 || true
  curl -k -I --connect-timeout 5 --max-time 10 "https://${PBS_HOST}:8007" 2>&1 || true
  curl -I --connect-timeout 5 --max-time 10 "http://${IMMICH_HOST}:2283" 2>&1 || true
} > "$OUT_DIR/proxmox-local-summary.txt"
tar -C /root/homelab-logs -czf "/root/homelab-pbs-immich-debug-${TS}.tar.gz" "pbs-immich-debug-${TS}"
echo "✅ Paket: /root/homelab-pbs-immich-debug-${TS}.tar.gz"
