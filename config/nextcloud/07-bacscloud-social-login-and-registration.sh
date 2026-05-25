#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/utils/logging.sh"; start_log "bacscloud-social-login-registration"
source "$ROOT_DIR/utils/env-loader.sh"; load_all_env
source "$ROOT_DIR/utils/remote.sh"

GOOGLE_ENV="$SECRETS_DIR/google.env"
USERS_ENV="$SECRETS_DIR/users.env"
[[ -f "$USERS_ENV" ]] || { echo "❌ users.env yok: $USERS_ENV"; exit 1; }
# shellcheck disable=SC1090
source "$USERS_ENV"
if [[ -f "$GOOGLE_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$GOOGLE_ENV"
fi

TMP_ENV="$(mktemp)"
TMP_SCRIPT="$(mktemp)"
trap 'rm -f "$TMP_ENV" "$TMP_SCRIPT"' EXIT
cat > "$TMP_ENV" <<ENV
GOOGLE_CLIENT_ID='${GOOGLE_CLIENT_ID:-}'
GOOGLE_CLIENT_SECRET='${GOOGLE_CLIENT_SECRET:-}'
PUBLIC_HOST='cloud.bacmastercloud.com'
REGISTRATION_ENABLED='${NEXTCLOUD_REGISTRATION_ENABLED:-1}'
REGISTRATION_APPROVAL_REQUIRED='${NEXTCLOUD_REGISTRATION_APPROVAL_REQUIRED:-1}'
REGISTRATION_ALLOWED_DOMAINS='${NEXTCLOUD_REGISTRATION_ALLOWED_DOMAINS:-}'
REGISTRATION_DEFAULT_GROUP='${NEXTCLOUD_REGISTRATION_DEFAULT_GROUP:-bacscloud-pending}'
SOCIAL_DEFAULT_GROUP='${NEXTCLOUD_SOCIAL_DEFAULT_GROUP:-bacscloud-users}'
DEFAULT_NEW_USER_QUOTA='${NEXTCLOUD_DEFAULT_NEW_USER_QUOTA:-5 GB}'
EXISTING_USER_QUOTA='${NEXTCLOUD_EXISTING_USER_QUOTA:-50 GB}'
ADMIN_QUOTA='${NEXTCLOUD_ADMIN_QUOTA:-none}'
ENV
chmod 600 "$TMP_ENV"

cat > "$TMP_SCRIPT" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
cd /opt/homelab/nextcloud || { echo "❌ /opt/homelab/nextcloud yok"; exit 1; }
occ(){ docker exec -u www-data hb-nextcloud php occ "$@"; }

echo "🔐 Bacscloud Social Login + Registration config"
occ status

echo "[1/6] Groups / quota policy"
occ group:add "${SOCIAL_DEFAULT_GROUP:-bacscloud-users}" >/dev/null 2>&1 || true
occ group:add "${REGISTRATION_DEFAULT_GROUP:-bacscloud-pending}" >/dev/null 2>&1 || true
occ config:app:set files default_quota --value="${DEFAULT_NEW_USER_QUOTA:-5 GB}" >/dev/null 2>&1 || true
for u in bacmaster atlon elifezel tulumba; do
  if occ user:info "$u" >/dev/null 2>&1; then
    case "$u" in
      bacmaster) occ user:setting "$u" files quota "${ADMIN_QUOTA:-none}" || true ;;
      *) occ user:setting "$u" files quota "${EXISTING_USER_QUOTA:-50 GB}" || true ;;
    esac
  fi
done

echo "[2/6] Social Login app install/enable"
occ app:install sociallogin || true
occ app:enable sociallogin || true
occ config:app:set sociallogin prevent_create_email_exists --value="0" || true
occ config:app:set sociallogin update_profile_on_login --value="1" || true
occ config:app:set sociallogin auto_create_groups --value="0" || true
occ config:app:set sociallogin hide_default_login --value="0" || true
occ config:app:set sociallogin disable_registration --value="0" || true

echo "[3/6] Google provider"
if [[ -n "${GOOGLE_CLIENT_ID:-}" && -n "${GOOGLE_CLIENT_SECRET:-}" ]]; then
  PROVIDERS="$(jq -n \
    --arg clientId "$GOOGLE_CLIENT_ID" \
    --arg clientSecret "$GOOGLE_CLIENT_SECRET" \
    --arg defaultGroup "${SOCIAL_DEFAULT_GROUP:-bacscloud-users}" \
    '{custom_oidc:[{name:"google",title:"Google ile giriş yap",authorizeUrl:"https://accounts.google.com/o/oauth2/v2/auth",tokenUrl:"https://oauth2.googleapis.com/token",userInfoUrl:"https://openidconnect.googleapis.com/v1/userinfo",logoutUrl:"",clientId:$clientId,clientSecret:$clientSecret,scope:"openid email profile",groupsClaim:"",style:"google",defaultGroup:$defaultGroup}]}' )"
  occ config:app:set sociallogin custom_providers --value="$PROVIDERS" >/dev/null >/dev/null || true
  echo "✅ Google Social Login provider yazıldı."
else
  echo "⚠️ GOOGLE_CLIENT_ID/SECRET boş; Social Login app aktif ama Google provider atlandı."
  echo "   Bootstrap secrets/env içinde google.env doldurup bu scripti tekrar çalıştır."
fi

echo "[4/6] Registration app controlled setup"
if [[ "${REGISTRATION_ENABLED:-1}" == "1" ]]; then
  occ app:install registration || true
  occ app:enable registration || true
  # Registration app keys have changed across versions. These are harmless app config values if unsupported.
  occ config:app:set registration registered_user_group --value="${REGISTRATION_DEFAULT_GROUP:-bacscloud-pending}" || true
  occ config:app:set registration admin_approval_required --value="${REGISTRATION_APPROVAL_REQUIRED:-1}" || true
  occ config:app:set registration allowed_domains --value="${REGISTRATION_ALLOWED_DOMAINS:-}" || true
  occ config:app:set registration show_fullname --value="1" || true
  occ config:app:set registration email_is_login --value="1" || true
  echo "✅ Registration app aktif: group=${REGISTRATION_DEFAULT_GROUP:-bacscloud-pending}, admin_approval=${REGISTRATION_APPROVAL_REQUIRED:-1}"
else
  occ app:disable registration || true
  echo "ℹ️ Registration disabled bırakıldı."
fi

echo "[5/6] Reverse proxy canonical URL"
occ config:system:set trusted_domains 0 --value="${PUBLIC_HOST:-cloud.bacmastercloud.com}" >/dev/null || true
occ config:system:set trusted_domains 1 --value="cloud-api.bacmastercloud.com" >/dev/null || true
occ config:system:set trusted_domains 2 --value="192.168.50.104" >/dev/null || true
occ config:system:set trusted_domains 3 --value="192.168.50.104:8080" >/dev/null || true
occ config:system:set overwrite.cli.url --value="https://${PUBLIC_HOST:-cloud.bacmastercloud.com}" >/dev/null || true
occ config:system:set overwritehost --value="${PUBLIC_HOST:-cloud.bacmastercloud.com}" >/dev/null || true
occ config:system:set overwriteprotocol --value="https" >/dev/null || true

echo "[6/6] Restart + final hints"
docker compose restart nextcloud >/dev/null || docker restart hb-nextcloud >/dev/null || true
sleep 10
curl -k -fsSI "https://${PUBLIC_HOST:-cloud.bacmastercloud.com}/login" | grep -iE 'HTTP/|location|strict-transport-security|server' || true

echo
cat <<DONE
✅ Bacscloud Social Login / Registration configuration tamamlandı.
Login kontrolü:
  https://${PUBLIC_HOST:-cloud.bacmastercloud.com}/login
Google Console redirect URI genelde şudur:
  https://${PUBLIC_HOST:-cloud.bacmastercloud.com}/apps/sociallogin/oauth/google
Registration kontrollü modda açıldıysa yeni kullanıcılar admin onayı/pending group ile gelir.
DONE
REMOTE
chmod +x "$TMP_SCRIPT"

rscp "$TMP_ENV" 104 /tmp/bacscloud-social.env
rscp "$TMP_SCRIPT" 104 /tmp/bacscloud-social-login-registration.sh
rssh 104 "sudo bash -c 'set -a; source /tmp/bacscloud-social.env; set +a; bash /tmp/bacscloud-social-login-registration.sh; rm -f /tmp/bacscloud-social.env /tmp/bacscloud-social-login-registration.sh'"
