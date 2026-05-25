#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/utils/env-loader.sh"
source "$REPO_ROOT/utils/logging.sh"
source "$REPO_ROOT/utils/remote.sh"
source "$REPO_ROOT/utils/state.sh"
source "$REPO_ROOT/utils/env-write.sh"
start_log "chia-farmer-install"
load_all_env

CHIA_MNEMONIC_ENV="$SECRETS_DIR/chia-mnemonic.env"
CHIA_BOOTSTRAP_ENV="$SECRETS_DIR/chia-bootstrap.env"
ask_text_default(){ local var="$1" prompt="$2" def="$3" value=""; read -r -p "$prompt [$def]: " value; printf -v "$var" "%s" "${value:-$def}"; }
ask_mnemonic_hidden(){
  local a="" wc=""
  while true; do
    read -r -s -p "Chia 24-word mnemonic (gizli input, ekranda/logda görünmez): " a; echo
    a="$(echo "$a" | xargs)"
    wc="$(awk '{print NF}' <<<"$a")"
    [[ -n "$a" ]] || { echo "❌ Mnemonic boş olamaz."; continue; }
    [[ "$wc" -eq 24 ]] || { echo "❌ Mnemonic $wc kelime görünüyor; 24 kelime olmalı."; continue; }
    echo "✅ Mnemonic alındı, 24 kelime doğrulandı. İçerik loga basılmadı."
    CHIA_MNEMONIC="$a"
    break
  done
}

if [[ ! -f "$CHIA_MNEMONIC_ENV" ]]; then
  echo "⚠️ $CHIA_MNEMONIC_ENV yok. v2.4.3 hedefi bunu Bootstrap secrets/env aşamasında toplamaktır."
  echo "   Bu sefer güvenli fallback olarak burada sorulacak ve kurulum sonunda silinecek."
  ask_mnemonic_hidden
  { write_env_header; write_env_line CHIA_MNEMONIC "$CHIA_MNEMONIC"; } > "$CHIA_MNEMONIC_ENV"
  chmod 600 "$CHIA_MNEMONIC_ENV"
fi

if [[ ! -f "$CHIA_BOOTSTRAP_ENV" ]]; then
  echo "⚠️ $CHIA_BOOTSTRAP_ENV yok. Official latest torrent varsayılanı yazılıyor."
  {
    write_env_header
    write_env_line CHIA_KEY_LABEL "bacmaster"
    write_env_line CHIA_DB_BOOTSTRAP_MODE "official_torrent"
    write_env_line CHIA_DB_MODE "official_torrent"
    write_env_line CHIA_DB_TORRENT_URL "https://torrents.chia.net/databases/mainnet/mainnet.latest.tar.gz.torrent"
    write_env_line CHIA_DB_DOWNLOAD_URL "https://torrents.chia.net/databases/mainnet/mainnet.latest.tar.gz.torrent"
    write_env_line CHIA_DB_MANUAL_PATH ""
    write_env_line CHIA_DB_CACHE_NFS "192.168.50.101:/mnt/tank/chia-db"
    write_env_line CHIA_DB_CACHE_MOUNT "/mnt/chia-db-cache"
    write_env_line CHIA_DB_DOWNLOAD_DIR "/mnt/chia-db-cache"
    write_env_line EXPECTED_CHIA_PLOT_DISKS "5"
  } > "$CHIA_BOOTSTRAP_ENV"
  chmod 600 "$CHIA_BOOTSTRAP_ENV"
fi

# shellcheck disable=SC1090
source "$CHIA_MNEMONIC_ENV"
# shellcheck disable=SC1090
source "$CHIA_BOOTSTRAP_ENV"
CHIA_DB_MODE="${CHIA_DB_BOOTSTRAP_MODE:-${CHIA_DB_MODE:-fresh}}"
CHIA_DB_DOWNLOAD_URL="${CHIA_DB_DOWNLOAD_URL:-${CHIA_DB_TORRENT_URL:-}}"
CHIA_DB_MANUAL_PATH="${CHIA_DB_MANUAL_PATH:-}"
CHIA_DB_CACHE_NFS="${CHIA_DB_CACHE_NFS:-192.168.50.101:/mnt/tank/chia-db}"
CHIA_DB_CACHE_MOUNT="${CHIA_DB_CACHE_MOUNT:-/mnt/chia-db-cache}"
CHIA_DB_DOWNLOAD_DIR="${CHIA_DB_DOWNLOAD_DIR:-/mnt/chia-db-cache}"
# If this env was created by an older v2.4.3 draft, move the default download path
# to the new TrueNAS-backed cache automatically. Explicit custom paths are respected.
if [[ "$CHIA_DB_DOWNLOAD_DIR" == "/home/bacmaster/chia-db-download" ]]; then
  CHIA_DB_DOWNLOAD_DIR="$CHIA_DB_CACHE_MOUNT"
fi
CHIA_KEY_LABEL="${CHIA_KEY_LABEL:-}"


wait_ssh 107
TMP_REMOTE="/tmp/homelab-chia-install.sh"
MNEMONIC_REMOTE="/tmp/chia-mnemonic.txt"

printf '%s\n' "$CHIA_MNEMONIC" > /tmp/chia-mnemonic.txt
chmod 600 /tmp/chia-mnemonic.txt
scp "${SSH_OPTS[@]}" /tmp/chia-mnemonic.txt "$SSH_USER@192.168.50.107:$MNEMONIC_REMOTE" >/dev/null
shred -u /tmp/chia-mnemonic.txt || rm -f /tmp/chia-mnemonic.txt

cat > /tmp/homelab-chia-install.sh <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail
export DEBIAN_FRONTEND=noninteractive
CHIA_HOME="/home/bacmaster/.chia/mainnet"
CHIA_SRC="/opt/chia-blockchain"
MNEMONIC_FILE="/tmp/chia-mnemonic.txt"
DB_MODE="${CHIA_DB_MODE:-fresh}"
DB_URL="${CHIA_DB_DOWNLOAD_URL:-}"
DB_MANUAL_PATH="${CHIA_DB_MANUAL_PATH:-}"
CACHE_NFS="${CHIA_DB_CACHE_NFS:-192.168.50.101:/mnt/tank/chia-db}"
CACHE_MOUNT="${CHIA_DB_CACHE_MOUNT:-/mnt/chia-db-cache}"
DOWNLOAD_DIR="${CHIA_DB_DOWNLOAD_DIR:-$CACHE_MOUNT}"
if [[ "$DOWNLOAD_DIR" == "/home/bacmaster/chia-db-download" ]]; then
  DOWNLOAD_DIR="$CACHE_MOUNT"
fi
CHIA_KEY_LABEL="${CHIA_KEY_LABEL:-}"
DB_TARGET="$CHIA_HOME/db/blockchain_v2_mainnet.sqlite"
CHIA_BIN="/opt/chia-blockchain/venv/bin/chia"
CACHE_READY=0
DB_BOOTSTRAPPED=0

sudo apt update
sudo apt install -y git curl ca-certificates build-essential python3 python3-venv python3-pip python3-dev lsb-release jq tmux unzip rsync aria2 gzip tar pv file nfs-common

if [[ ! -d "$CHIA_SRC/.git" ]]; then
  sudo git clone https://github.com/Chia-Network/chia-blockchain.git -b latest --recurse-submodules "$CHIA_SRC"
else
  cd "$CHIA_SRC"
  sudo git fetch --all --tags
  sudo git checkout latest || true
  sudo git pull --recurse-submodules || true
  sudo git submodule update --init --recursive
fi

sudo chown -R bacmaster:bacmaster "$CHIA_SRC"
cd "$CHIA_SRC"
sudo -u bacmaster bash -lc 'sh install.sh'
sudo -u bacmaster bash -lc 'cd /opt/chia-blockchain && . ./activate && chia init'

if [[ -s "$MNEMONIC_FILE" ]]; then
  echo "🔐 Chia mnemonic import ediliyor (içerik loga basılmaz)..."
  sudo -u bacmaster bash -lc "cd /opt/chia-blockchain && . ./activate && printf '%s\n' \"${CHIA_KEY_LABEL:-}\" | chia keys add -f '$MNEMONIC_FILE' || true"
  shred -u "$MNEMONIC_FILE" || sudo rm -f "$MNEMONIC_FILE"
fi

find_db_candidate(){
  local root="$1"
  find "$root" -type f \
    \( -name 'blockchain_v2_mainnet.sqlite' -o -name 'blockchain_v2_mainnet.sqlite.gz' -o -name 'blockchain_v2_mainnet.sqlite.zip' -o -name '*.sqlite' -o -name '*.sqlite.gz' -o -name '*.zip' -o -name '*.tar.gz' -o -name '*.tgz' \) \
    -printf '%s %p\n' 2>/dev/null | sort -nr | awk '{$1=""; sub(/^ /,""); print; exit}'
}

bytes_free_at(){
  local path="$1"
  mkdir -p "$path" 2>/dev/null || true
  df -PB1 "$path" | awk 'NR==2 {print $4}'
}

need_free_bytes(){
  local path="$1" need="$2" label="$3" free
  free="$(bytes_free_at "$path")"
  if [[ -z "$free" || "$free" -lt "$need" ]]; then
    echo "❌ Yetersiz boş alan: $label path=$path free=${free:-unknown} need=$need bytes"
    return 1
  fi
  return 0
}

ensure_chia_db_cache_mount(){
  echo "🗄️ TrueNAS Chia DB cache mount hazırlanıyor..."
  echo "   NFS  : $CACHE_NFS"
  echo "   Mount: $CACHE_MOUNT"

  sudo mkdir -p "$CACHE_MOUNT"

  if ! mountpoint -q "$CACHE_MOUNT"; then
    if ! grep -Fqs " $CACHE_MOUNT " /etc/fstab; then
      echo "$CACHE_NFS $CACHE_MOUNT nfs4 rw,hard,noatime,_netdev,x-systemd.automount,x-systemd.device-timeout=30 0 0" | sudo tee -a /etc/fstab >/dev/null
    fi
    sudo systemctl daemon-reload || true
    sudo mount "$CACHE_MOUNT" || sudo mount -a || true
  fi

  if mountpoint -q "$CACHE_MOUNT"; then
    sudo mkdir -p "$CACHE_MOUNT"
    sudo chown bacmaster:bacmaster "$CACHE_MOUNT" 2>/dev/null || true
    if sudo -u bacmaster test -w "$CACHE_MOUNT"; then
      CACHE_READY=1
      DOWNLOAD_DIR="$CACHE_MOUNT"
      echo "✅ Chia DB cache hazır: $DOWNLOAD_DIR"
      return 0
    fi
    echo "⚠️ Chia DB cache mount var ama bacmaster yazamıyor: $CACHE_MOUNT"
    return 1
  fi

  echo "⚠️ Chia DB cache mount edilemedi. Torrent/URL download local diske yapılmayacak; gerekirse fresh sync'e düşülecek."
  return 1
}

validate_db_target(){
  if [[ ! -s "$DB_TARGET" ]]; then
    echo "❌ DB import sonucu boş/eksik: $DB_TARGET"
    return 1
  fi
  local sz
  sz="$(stat -c '%s' "$DB_TARGET" 2>/dev/null || echo 0)"
  if [[ "$sz" -lt 1073741824 ]]; then
    echo "❌ DB import sonucu şüpheli küçük: $DB_TARGET size=$sz bytes"
    return 1
  fi
  if ! file "$DB_TARGET" | grep -qi 'SQLite'; then
    echo "❌ DB import sonucu SQLite gibi görünmüyor: $DB_TARGET"
    file "$DB_TARGET" || true
    return 1
  fi
  return 0
}

extract_tar_member_to_tmp(){
  local archive="$1" member="$2"
  mkdir -p "$(dirname "$DB_TARGET")"
  rm -f "$DB_TARGET.tmp"
  case "$member" in
    *.sqlite.gz)
      echo "🗜️ tar.gz içindeki gzip DB stream ediliyor: $member"
      tar -xOzf "$archive" "$member" | gzip -dc > "$DB_TARGET.tmp"
      ;;
    *.sqlite)
      echo "🗜️ tar.gz içindeki sqlite DB stream ediliyor: $member"
      tar -xOzf "$archive" "$member" > "$DB_TARGET.tmp"
      ;;
    *)
      echo "❌ tar.gz içinde desteklenmeyen DB üyesi: $member"
      return 1
      ;;
  esac
}

bootstrap_db(){
  sudo -u bacmaster mkdir -p "$CHIA_HOME/db"
  local src="$1"
  echo "📦 DB import kaynağı: $src"
  sudo systemctl stop chia-farmer.service >/dev/null 2>&1 || true
  sudo -u bacmaster "$CHIA_BIN" stop all -d >/dev/null 2>&1 || true
  rm -f "$DB_TARGET.tmp"
  case "$src" in
    *.tar.gz|*.tgz)
      local member member_size need
      echo "🗜️ tar.gz arşivi /tmp'ye açılmadan stream import edilecek."
      member="$(tar -tzf "$src" | grep -E '(^|/)blockchain_v2_mainnet\.sqlite(\.gz)?$|\.sqlite(\.gz)?$' | head -n1 || true)"
      [[ -n "$member" ]] || { echo "❌ tar.gz içinde DB bulunamadı"; return 1; }
      # GNU tar verbose size column is the 3rd field for normal listings.
      member_size="$(tar -tvzf "$src" "$member" 2>/dev/null | awk 'NR==1 {print $3}' || true)"
      if [[ "$member_size" =~ ^[0-9]+$ && "$member_size" -gt 0 ]]; then
        # Need a little headroom for the tmp file. For .sqlite.gz this is compressed size only, so still validate after import.
        need=$(( member_size + 1073741824 ))
        need_free_bytes "$(dirname "$DB_TARGET")" "$need" "Chia DB target" || return 1
      else
        # Conservative minimum when tar cannot expose a sane size.
        need_free_bytes "$(dirname "$DB_TARGET")" 107374182400 "Chia DB target minimum" || return 1
      fi
      extract_tar_member_to_tmp "$src" "$member"
      ;;
    *.sqlite.gz)
      echo "🗜️ gzip DB açılıyor..."
      need_free_bytes "$(dirname "$DB_TARGET")" 107374182400 "Chia DB target minimum" || return 1
      gzip -dc "$src" > "$DB_TARGET.tmp"
      ;;
    *.zip)
      tmpd="/home/bacmaster/chia-db-download/unzip-tmp-$$"; rm -rf "$tmpd"; mkdir -p "$tmpd"
      echo "🗜️ zip arşivi persistent path içine açılıyor..."
      unzip -o "$src" -d "$tmpd" >/dev/null
      found="$(find_db_candidate "$tmpd")"
      [[ -n "$found" ]] || { echo "❌ zip içinde DB bulunamadı"; rm -rf "$tmpd"; return 1; }
      bootstrap_db "$found"
      rm -rf "$tmpd"
      return 0
      ;;
    *.sqlite)
      local sz need
      sz="$(stat -c '%s' "$src" 2>/dev/null || echo 0)"
      need=$(( sz + 1073741824 ))
      need_free_bytes "$(dirname "$DB_TARGET")" "$need" "Chia DB target" || return 1
      cp "$src" "$DB_TARGET.tmp"
      ;;
    *)
      if file "$src" | grep -qi 'SQLite'; then
        local sz need
        sz="$(stat -c '%s' "$src" 2>/dev/null || echo 0)"
        need=$(( sz + 1073741824 ))
        need_free_bytes "$(dirname "$DB_TARGET")" "$need" "Chia DB target" || return 1
        cp "$src" "$DB_TARGET.tmp"
      else
        echo "❌ Desteklenmeyen DB dosyası: $src"
        return 1
      fi
      ;;
  esac
  [[ -s "$DB_TARGET.tmp" ]] || { echo "❌ Import tmp dosyası boş oluştu: $DB_TARGET.tmp"; rm -f "$DB_TARGET.tmp"; return 1; }
  mv "$DB_TARGET.tmp" "$DB_TARGET"
  sudo chown -R bacmaster:bacmaster "$CHIA_HOME"
  validate_db_target || return 1
  echo "✅ Chia DB hazır: $DB_TARGET ($(du -h "$DB_TARGET" | awk '{print $1}'))"
}

show_download_hint(){
  cat <<HINT

📥 Chia DB download takip bilgisi
  VM107 path : $DOWNLOAD_DIR
  Log        : $DOWNLOAD_DIR/aria2.log
  Canlı takip: tail -f $DOWNLOAD_DIR/aria2.log
  Boyut takip: watch -n 10 'du -sh $DOWNLOAD_DIR; ls -lh $DOWNLOAD_DIR | tail'

HINT
}

# Always prefer an existing DB/archive in the TrueNAS-backed cache before asking
# the network to download anything.  This keeps the 117+ GiB torrent archive
# reusable across fresh installs while the active SQLite DB stays local on VM107.
ensure_chia_db_cache_mount || true

if [[ "$CACHE_READY" == "1" ]]; then
  echo "🔍 Chia DB cache içinde hazır DB/arşiv aranıyor: $DOWNLOAD_DIR"
  found="$(find_db_candidate "$DOWNLOAD_DIR")"
  if [[ -n "$found" ]]; then
    echo "✅ Cache adayı bulundu: $found"
    if bootstrap_db "$found"; then
      DB_BOOTSTRAPPED=1
    else
      echo "⚠️ Cache adayı import edilemedi; seçili bootstrap yöntemiyle devam edilecek."
    fi
  else
    echo "ℹ️ Cache içinde hazır DB/arşiv yok. Seçili bootstrap yöntemi uygulanacak: $DB_MODE"
  fi
fi

if [[ "$DB_BOOTSTRAPPED" != "1" ]]; then
case "$DB_MODE" in
  official_torrent)
    DB_URL="${DB_URL:-https://torrents.chia.net/databases/mainnet/mainnet.latest.tar.gz.torrent}"
    ;&
  torrent)
    if [[ -z "$DB_URL" || "$DB_URL" == "1" ]]; then
      echo "⚠️ Torrent URL geçersiz/boş: ${DB_URL:-empty}"
      DB_URL="https://torrents.chia.net/databases/mainnet/mainnet.latest.tar.gz.torrent"
      echo "ℹ️ Official latest torrent kullanılacak: $DB_URL"
    fi
    if [[ -n "$DB_URL" ]]; then
      if [[ "$CACHE_READY" != "1" ]]; then
        echo "⚠️ TrueNAS Chia DB cache hazır değil; büyük torrent local VM diskine indirilmeyecek. Fresh sync ile devam."
        DB_URL=""
      fi
    fi
    if [[ -n "$DB_URL" ]]; then
      mkdir -p "$DOWNLOAD_DIR"; chown -R bacmaster:bacmaster "$DOWNLOAD_DIR"
      # Official mainnet torrent archive is huge. Avoid downloading into a filesystem that cannot hold it.
      if ! need_free_bytes "$DOWNLOAD_DIR" 125000000000 "Chia DB download archive"; then
        echo "⚠️ Torrent download için yeterli alan yok; fresh sync ile devam edilecek."
        DB_URL=""
      fi
      if [[ -z "$DB_URL" ]]; then
        echo "⚠️ DB_URL boş/yetersiz alan; fresh sync ile devam."
      else
      echo "📦 Chia DB torrent/magnet ile indiriliyor..."
      echo "ℹ️ aria2 progress 30 sn'de bir ekrana ve aria2.log dosyasına yazılır; script donmuş değildir."
      show_download_hint
      sudo -u bacmaster aria2c \
        -c \
        --seed-time=0 \
        --summary-interval=30 \
        --download-result=full \
        --console-log-level=notice \
        --log="$DOWNLOAD_DIR/aria2.log" \
        --log-level=notice \
        --dir="$DOWNLOAD_DIR" \
        "$DB_URL" || echo "⚠️ aria2c hata/interrupt döndürdü; mevcut dosyalar kontrol edilecek."
      found="$(find_db_candidate "$DOWNLOAD_DIR")"
      if [[ -n "$found" ]]; then
        bootstrap_db "$found" || echo "⚠️ Torrent indirildi ama DB import başarısız; fresh sync ile devam."
      else
        echo "⚠️ Torrent klasöründe DB dosyası bulunamadı; fresh sync ile devam."
      fi
      fi
    else
      echo "⚠️ Torrent URL boş; fresh sync ile devam."
    fi
    ;;
  url)
    if [[ -n "$DB_URL" ]]; then
      if [[ "$CACHE_READY" != "1" ]]; then
        echo "⚠️ TrueNAS Chia DB cache hazır değil; büyük URL download local VM diskine indirilmeyecek. Fresh sync ile devam."
        DB_URL=""
      fi
    fi
    if [[ -n "$DB_URL" ]]; then
      mkdir -p "$DOWNLOAD_DIR"; chown -R bacmaster:bacmaster "$DOWNLOAD_DIR"
      echo "📦 Chia DB HTTP/HTTPS URL'den indiriliyor..."
      show_download_hint
      out="$DOWNLOAD_DIR/$(basename "${DB_URL%%\?*}")"
      sudo -u bacmaster curl -fL --progress-bar -C - "$DB_URL" -o "$out"
      bootstrap_db "$out" || echo "⚠️ DB import başarısız; fresh sync ile devam edilecek."
    else
      echo "⚠️ DB URL boş; fresh sync ile devam."
    fi
    ;;
  manual)
    if [[ -n "$DB_MANUAL_PATH" && -f "$DB_MANUAL_PATH" ]]; then
      echo "📦 Manuel DB dosyası kullanılıyor: $DB_MANUAL_PATH"
      bootstrap_db "$DB_MANUAL_PATH" || echo "⚠️ Manuel DB import başarısız; fresh sync ile devam."
    else
      echo "⚠️ Manuel DB path bulunamadı: ${DB_MANUAL_PATH:-empty}; fresh sync ile devam."
    fi
    ;;
  *)
    echo "ℹ️ Fresh sync seçildi; DB bootstrap atlandı."
    ;;
esac
else
  echo "✅ Chia DB cache import başarılı; network bootstrap/download atlandı."
fi

sudo tee /etc/systemd/system/chia-farmer.service >/dev/null <<'UNIT'
[Unit]
Description=Chia Farmer
After=network-online.target
Wants=network-online.target

[Service]
Type=forking
User=bacmaster
WorkingDirectory=/opt/chia-blockchain
Environment=CHIA_ROOT=/home/bacmaster/.chia/mainnet
ExecStart=/bin/bash -lc 'cd /opt/chia-blockchain && . ./activate && chia start farmer -r'
ExecStop=/bin/bash -lc 'cd /opt/chia-blockchain && . ./activate && chia stop all -d'
Restart=on-failure
RestartSec=20
TimeoutStartSec=300

[Install]
WantedBy=multi-user.target
UNIT

sudo ln -sf "$CHIA_BIN" /usr/local/bin/chia || true
sudo systemctl daemon-reload
sudo systemctl enable chia-farmer.service
sudo systemctl restart chia-farmer.service || true

# Make compressed C7 plots farmable by default.
CONFIG="/home/bacmaster/.chia/mainnet/config/config.yaml"
if [[ -f "$CONFIG" ]]; then
  sudo -u bacmaster python3 - <<'PY'
from pathlib import Path
p=Path('/home/bacmaster/.chia/mainnet/config/config.yaml')
text=p.read_text()
lines=text.splitlines()
out=[]; in_h=False; inserted=False
for line in lines:
    if line.startswith('harvester:'):
        in_h=True; out.append(line); continue
    if in_h and line and not line.startswith(' '):
        if not inserted:
            out.append('  parallel_decompressor_count: 1'); inserted=True
        in_h=False
    if line.strip().startswith('parallel_decompressor_count:'):
        indent=line[:len(line)-len(line.lstrip())]
        out.append(f'{indent}parallel_decompressor_count: 1'); inserted=True
    else:
        out.append(line)
if not inserted:
    if not any(l.startswith('harvester:') for l in out): out += ['harvester:', '  parallel_decompressor_count: 1']
    else:
        new=[]; done=False
        for l in out:
            new.append(l)
            if l.startswith('harvester:') and not done:
                new.append('  parallel_decompressor_count: 1'); done=True
        out=new
p.write_text('\n'.join(out)+'\n')
PY
fi

sudo systemctl restart chia-farmer.service || true
sleep 8
sudo -u bacmaster bash -lc 'cd /opt/chia-blockchain && . ./activate && chia show -s || true'
REMOTE

scp "${SSH_OPTS[@]}" /tmp/homelab-chia-install.sh "$SSH_USER@192.168.50.107:$TMP_REMOTE" >/dev/null
{
  printf 'CHIA_DB_MODE=%q\n' "${CHIA_DB_MODE:-fresh}"
  printf 'CHIA_DB_DOWNLOAD_URL=%q\n' "${CHIA_DB_DOWNLOAD_URL:-}"
  printf 'CHIA_DB_MANUAL_PATH=%q\n' "${CHIA_DB_MANUAL_PATH:-}"
  printf 'CHIA_DB_DOWNLOAD_DIR=%q\n' "${CHIA_DB_DOWNLOAD_DIR:-/home/bacmaster/chia-db-download}"
  printf 'CHIA_KEY_LABEL=%q\n' "${CHIA_KEY_LABEL:-}"
} > /tmp/chia-remote.env
scp "${SSH_OPTS[@]}" /tmp/chia-remote.env "$SSH_USER@192.168.50.107:/tmp/chia-remote.env" >/dev/null
rm -f /tmp/chia-remote.env
ssh "${SSH_OPTS[@]}" "$SSH_USER@192.168.50.107" "chmod +x $TMP_REMOTE && sudo bash -c 'set -a; source /tmp/chia-remote.env; set +a; $TMP_REMOTE; rm -f /tmp/chia-remote.env'"
rm -f /tmp/homelab-chia-install.sh

if [[ -f "$CHIA_MNEMONIC_ENV" ]]; then
  echo "🧹 Chia mnemonic secret dosyası siliniyor: $CHIA_MNEMONIC_ENV"
  shred -u "$CHIA_MNEMONIC_ENV" || rm -f "$CHIA_MNEMONIC_ENV"
fi

echo "🔧 Chia plot disk / compressed plot repair uygulanıyor..."
bash "$REPO_ROOT/maintenance/repair/repair-chia-plot-disks.sh" || echo "⚠️ Chia plot disk repair tamamlanamadı; maintenance menüsünden tekrar çalıştırabilirsin."

state_set chia_farmer_installed true
state_set chia_farmer_installed_at "$(date -Is)"
echo "✅ Chia farmer kurulumu tamamlandı."
