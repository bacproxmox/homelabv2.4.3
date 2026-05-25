#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "bacscloud-admin-overview-cleanup"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env
source "$ROOT_DIR/utils/remote.sh"

TMP="$(mktemp)"; trap 'rm -f "$TMP"' EXIT
cat > "$TMP" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/homelab/nextcloud || { echo "❌ /opt/homelab/nextcloud yok"; exit 1; }

NC_CONTAINER="${NC_CONTAINER:-hb-nextcloud}"
PUBLIC_HOST="${PUBLIC_HOST:-cloud.bacmastercloud.com}"
PUBLIC_API_HOST="${PUBLIC_API_HOST:-cloud-api.bacmastercloud.com}"
LAN_HOST="${LAN_HOST:-192.168.50.104:8080}"
CLOUDFLARED_PROXY_IP="${CLOUDFLARED_PROXY_IP:-192.168.50.103}"
DISABLE_APPAPI="${DISABLE_APPAPI:-1}"

if ! docker ps --format '{{.Names}}' | grep -qx "$NC_CONTAINER"; then
  echo "❌ $NC_CONTAINER çalışmıyor."
  docker ps -a --filter "name=$NC_CONTAINER" || true
  exit 1
fi

occ(){ docker exec -u www-data "$NC_CONTAINER" php occ "$@"; }
rootsh(){ docker exec -u root "$NC_CONTAINER" sh -lc "$*"; }

wait_occ(){
  for i in $(seq 1 60); do
    if occ status >/tmp/nc-status.txt 2>&1; then
      cat /tmp/nc-status.txt
      grep -q 'installed:[[:space:]]*true' /tmp/nc-status.txt && return 0
    fi
    sleep 2
  done
  echo "❌ occ status installed:true olmadı."
  cat /tmp/nc-status.txt 2>/dev/null || true
  return 1
}

backup_log(){
  local data_dir logfile stamp
  data_dir="$(occ config:system:get datadirectory 2>/dev/null || echo /var/www/html/data)"
  logfile="$(occ config:system:get logfile 2>/dev/null || true)"
  [[ -n "$logfile" ]] || logfile="$data_dir/nextcloud.log"
  stamp="$(date +%Y%m%d-%H%M%S)"
  rootsh "if [ -f '$logfile' ]; then cp '$logfile' '$logfile.pre-overview-cleanup-$stamp' || true; : > '$logfile' || true; chown www-data:www-data '$logfile' || true; fi"
}

echo "🧹 Bacscloud Admin Overview cleanup başlıyor..."
wait_occ

echo "[1/8] trusted domains / reverse proxy"
occ config:system:set trusted_domains 0 --value="$PUBLIC_HOST" >/dev/null
occ config:system:set trusted_domains 1 --value="$PUBLIC_API_HOST" >/dev/null
occ config:system:set trusted_domains 2 --value="${LAN_HOST%:8080}" >/dev/null
occ config:system:set trusted_domains 3 --value="$LAN_HOST" >/dev/null
occ config:system:set trusted_domains 4 --value="localhost" >/dev/null
occ config:system:set trusted_domains 5 --value="127.0.0.1" >/dev/null
occ config:system:set overwrite.cli.url --value="https://${PUBLIC_HOST}" >/dev/null
occ config:system:set overwritehost --value="$PUBLIC_HOST" >/dev/null
occ config:system:set overwriteprotocol --value="https" >/dev/null
occ config:system:set overwritecondaddr --value="^${CLOUDFLARED_PROXY_IP//./\\.}$|^172\\.|^10\\." >/dev/null || true
occ config:system:set trusted_proxies 0 --value="$CLOUDFLARED_PROXY_IP" >/dev/null || true
occ config:system:set trusted_proxies 1 --value="172.16.0.0/12" >/dev/null || true
occ config:system:set trusted_proxies 2 --value="10.0.0.0/8" >/dev/null || true
occ config:system:set forwarded_for_headers 0 --value="HTTP_CF_CONNECTING_IP" >/dev/null || true
occ config:system:set forwarded_for_headers 1 --value="HTTP_X_FORWARDED_FOR" >/dev/null || true

echo "[2/8] HSTS/security headers"
rootsh "a2enmod headers rewrite remoteip >/dev/null 2>&1 || true
cat > /etc/apache2/conf-available/homelab-bacscloud-headers.conf <<'APACHE'
SetEnvIf X-Forwarded-Proto \"https\" HTTPS=on
RemoteIPHeader X-Forwarded-For
<IfModule mod_headers.c>
    Header always set Strict-Transport-Security \"max-age=15552000; includeSubDomains\"
    Header always set Referrer-Policy \"no-referrer\"
    Header always set X-Content-Type-Options \"nosniff\"
    Header always set X-Frame-Options \"SAMEORIGIN\"
</IfModule>
APACHE
a2enconf homelab-bacscloud-headers >/dev/null 2>&1 || true
apache2ctl -t"

echo "[3/8] appdata/theming repair"
DATA_DIR="$(occ config:system:get datadirectory)"
INSTANCE_ID="$(occ config:system:get instanceid)"
APPDATA_DIR="${DATA_DIR}/appdata_${INSTANCE_ID}"
rootsh "mkdir -p '$APPDATA_DIR/theming/global' '$APPDATA_DIR/theming/images' '$APPDATA_DIR/css' '$APPDATA_DIR/js' '$APPDATA_DIR/preview' && touch '$DATA_DIR/.ocdata' && chown -R www-data:www-data '$APPDATA_DIR' '$DATA_DIR/.ocdata'"
occ files:scan-app-data || true

echo "[4/8] Bacscloud branding / serverid"
occ app:enable theming >/dev/null 2>&1 || true
occ config:app:set theming name --value="Bacscloud" >/dev/null 2>&1 || true
occ config:app:set theming slogan --value="Bacmaster Cloud" >/dev/null 2>&1 || true
occ config:app:set theming url --value="https://${PUBLIC_HOST}" >/dev/null 2>&1 || true
occ config:app:set theming color --value="#0f172a" >/dev/null 2>&1 || true
occ config:system:set serverid --type=integer --value=1 >/dev/null 2>&1 || true

echo "[5/8] AppAPI cleanup"
if [[ "$DISABLE_APPAPI" == "1" ]]; then
  if occ app:list | grep -qE '^\s*- app_api:'; then
    occ app:disable app_api || true
  fi
fi

echo "[6/8] cron/background jobs"
occ background:cron || true
rootsh "mkdir -p /etc/cron.d
cat > /etc/cron.d/homelab-nextcloud <<'CRON'
*/5 * * * * root docker exec -u www-data hb-nextcloud php -f /var/www/html/cron.php >/dev/null 2>&1
CRON
chmod 644 /etc/cron.d/homelab-nextcloud"

echo "[7/8] maintenance repair + log reset"
occ maintenance:repair || true
backup_log

echo "[8/8] restart + validation"
docker compose restart nextcloud >/dev/null || docker restart "$NC_CONTAINER" >/dev/null
sleep 15
wait_occ

echo "---- Headers: public HTTPS status.php ----"
curl -k -sSI "https://${PUBLIC_HOST}/status.php" | grep -iE 'HTTP/|strict-transport-security|referrer-policy|x-content-type-options|x-frame-options|server' || true

echo "---- trusted_domains ----"
occ config:system:get trusted_domains || true

echo "✅ Bacscloud Admin Overview cleanup tamamlandı."
echo "Kontrol: https://${PUBLIC_HOST}/settings/admin/overview"
REMOTE
chmod +x "$TMP"
rscp "$TMP" 104 /tmp/bacscloud-admin-overview-cleanup.sh
rssh 104 "sudo bash /tmp/bacscloud-admin-overview-cleanup.sh"
