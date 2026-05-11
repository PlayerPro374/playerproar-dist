#!/bin/bash
# ============================================================
#   PLAYER PRO AR — CLIENT INSTALLER
#   Installa il pannello sul server del cliente
#   Richiede una License Key valida per completare
#   Uso: bash install_client.sh
# ============================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; WHITE='\033[1;37m'
BOLD='\033[1m'; RESET='\033[0m'
ok()   { echo -e "${GREEN}  [OK]${RESET} $*"; }
info() { echo -e "${CYAN}  [>>]${RESET} $*"; }
warn() { echo -e "${YELLOW}  [!!]${RESET} $*"; }
err()  { echo -e "${RED}  [ERR]${RESET} $*"; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n${BOLD}${BLUE}  $*${RESET}"; }
ask()  { echo -e "${WHITE}${BOLD}  ?  $*${RESET}"; }
skip() { echo -e "${YELLOW}  [--]${RESET} Saltato: $*"; }

[[ $EUID -ne 0 ]] && { err "Eseguire come root."; exit 1; }

INSTALL_DIR="/root/scripts/PlayerPROAR"
LICENSE_SERVER_URL="https://license.watchyour-back.com"

clear
echo -e "${BOLD}${CYAN}"
echo "  ██████╗ ██╗      █████╗ ██╗   ██╗███████╗██████╗  "
echo "  ██╔══██╗██║     ██╔══██╗╚██╗ ██╔╝██╔════╝██╔══██╗ "
echo "  ██████╔╝██║     ███████║ ╚████╔╝ █████╗  ██████╔╝ "
echo "  ██╔═══╝ ██║     ██╔══██║  ╚██╔╝  ██╔══╝  ██╔══██╗ "
echo "  ██║     ███████╗██║  ██║   ██║   ███████╗██║  ██║ "
echo "  ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚══════╝╚═╝  ╚═╝ "
echo -e "${RESET}${BOLD}${GREEN}"
echo "        C L I E N T  I N S T A L L E R"
echo "  ──────────────────────────────────────────────────"
echo -e "${RESET}"

LOG_FILE="/root/playerproar_client_install_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOG_FILE") 2>&1

# ════════════════════════════════════════════════════════════
#  1. LICENSE KEY — verifica PRIMA di procedere
# ════════════════════════════════════════════════════════════
step "1 / 11  —  VERIFICA LICENZA"

ask "Inserisci la tua License Key (formato: PPRO-XXXX-XXXX-XXXX):"
read -rp "  > " LICENSE_KEY

if ! [[ "$LICENSE_KEY" =~ ^PPRO-[A-Z0-9]{4}-[A-Z0-9]{4}-[A-Z0-9]{4}$ ]]; then
  err "Formato license key non valido. Atteso: PPRO-XXXX-XXXX-XXXX"
fi
info "License key: $LICENSE_KEY"

# Verifica connettività al license server
info "Connessione al server di licenze..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 \
  "${LICENSE_SERVER_URL}/license/public-key" 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" != "200" ]]; then
  err "Impossibile raggiungere il server di licenze (HTTP $HTTP_CODE). Verifica la connessione e riprova."
fi
ok "Server di licenze raggiungibile"

# Pre-verifica della key (senza hardware binding per ora — solo esistenza)
PRE_CHECK=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 \
  -X POST "${LICENSE_SERVER_URL}/license/verify" \
  -H "Content-Type: application/json" \
  -d "{\"license_key\":\"${LICENSE_KEY}\",\"hardware_hash\":\"precheck\"}" 2>/dev/null || echo "000")

if [[ "$PRE_CHECK" == "000" ]]; then
  err "Server di licenze non raggiungibile durante la verifica."
fi
# Pre-check: 200 con valid:false è OK (hw mismatch aspettato), 200 con error license_not_found è KO
PRE_RESP=$(curl -s --connect-timeout 10 \
  -X POST "${LICENSE_SERVER_URL}/license/verify" \
  -H "Content-Type: application/json" \
  -d "{\"license_key\":\"${LICENSE_KEY}\",\"hardware_hash\":\"precheck\"}" 2>/dev/null)
PRE_ERROR=$(echo "$PRE_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error',''))" 2>/dev/null || echo "")

if [[ "$PRE_ERROR" == "license_not_found" ]]; then
  err "License key non trovata. Contatta il supporto."
elif [[ "$PRE_ERROR" == "license_revoked" ]]; then
  err "Questa licenza è stata revocata. Contatta il supporto."
elif [[ "$PRE_ERROR" == "license_expired" ]]; then
  err "Questa licenza è scaduta. Contatta il supporto per rinnovarla."
fi

ok "License key valida — procedo con l'installazione"

# ════════════════════════════════════════════════════════════
#  2. PARAMETRI
# ════════════════════════════════════════════════════════════
step "2 / 11  —  CONFIGURAZIONE"

ask "Dominio o IP pubblico [auto-detect]:"
read -rp "  > " SERVER_DOMAIN
SERVER_DOMAIN="${SERVER_DOMAIN:-$(curl -s --connect-timeout 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')}"
info "Server: $SERVER_DOMAIN"

ask "Porta backend [8888]:"
read -rp "  > " BACKEND_PORT; BACKEND_PORT="${BACKEND_PORT:-8888}"

ask "Worker uvicorn [8]:"
read -rp "  > " UVICORN_WORKERS; UVICORN_WORKERS="${UVICORN_WORKERS:-8}"

ask "Creare swap? [0=no / 1 / 2 / 4 GB] [default: 2]:"
read -rp "  > " SWAP_SIZE; SWAP_SIZE="${SWAP_SIZE:-2}"

ask "Configurare SSL con Certbot? [s/N]:"
read -rp "  > " SETUP_SSL; SETUP_SSL="${SETUP_SSL:-N}"
CERTBOT_EMAIL=""
if [[ "$SETUP_SSL" =~ ^[Ss]$ ]]; then
  ask "Email per Certbot:"; read -rp "  > " CERTBOT_EMAIL
fi

echo ""
echo -e "${BOLD}${YELLOW}  ┌──────────────────────────────────────────────────┐"
echo   "  │  RIEPILOGO — INSTALLAZIONE CLIENT              │"
echo   "  ├──────────────────────────────────────────────────┤"
printf "  │  License Key:     %-32s│\n" "$LICENSE_KEY"
printf "  │  Server:          %-32s│\n" "$SERVER_DOMAIN"
printf "  │  Porta:           %-32s│\n" "$BACKEND_PORT"
printf "  │  Workers:         %-32s│\n" "$UVICORN_WORKERS"
printf "  │  Swap:            %-32s│\n" "${SWAP_SIZE}G"
printf "  │  SSL:             %-32s│\n" "$SETUP_SSL"
echo   "  └──────────────────────────────────────────────────┘${RESET}"
echo ""
ask "Confermi e avvii l'installazione? [s/N]:"; read -rp "  > " CONFIRM
[[ "$CONFIRM" =~ ^[Ss]$ ]] || { warn "Annullato."; exit 0; }

# ════════════════════════════════════════════════════════════
#  3. PRE-FLIGHT
# ════════════════════════════════════════════════════════════
step "3 / 11  —  PRE-FLIGHT CHECKS"
DISK_GB=$(( $(df / | awk 'NR==2{print $4}') / 1024 / 1024 ))
(( DISK_GB >= 5 )) && ok "Disco: ${DISK_GB}GB liberi" || err "Disco insufficiente"
RAM_MB=$(( $(grep MemTotal /proc/meminfo | awk '{print $2}') / 1024 ))
ok "RAM: ${RAM_MB}MB | CPU: $(nproc) core"
curl -s --connect-timeout 5 https://pypi.org > /dev/null && ok "Internet OK" || err "Nessun internet"

# ════════════════════════════════════════════════════════════
#  4. SWAP
# ════════════════════════════════════════════════════════════
step "4 / 11  —  SWAP FILE"
if [[ "$SWAP_SIZE" != "0" ]] && ! swapon --show 2>/dev/null | grep -q .; then
  fallocate -l "${SWAP_SIZE}G" /swapfile 2>/dev/null || dd if=/dev/zero of=/swapfile bs=1M count=$(( SWAP_SIZE * 1024 )) status=none
  chmod 600 /swapfile && mkswap /swapfile -q && swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 > /dev/null
  ok "Swap ${SWAP_SIZE}G attivato"
else
  skip "Swap già presente o non richiesto"
fi

# ════════════════════════════════════════════════════════════
#  5. PACCHETTI
# ════════════════════════════════════════════════════════════
step "5 / 11  —  PACCHETTI DI SISTEMA"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq python3 python3-pip python3-dev nginx openvpn \
  certbot python3-certbot-nginx curl wget rsync git \
  build-essential libssl-dev libffi-dev \
  iptables-persistent cron logrotate fail2ban ufw \
  net-tools unzip jq 2>&1 | grep -E "^(Get:|Inst|Err:|W:)" || true
ok "Pacchetti installati"

# ════════════════════════════════════════════════════════════
#  FFMPEG 7 STATICO  (richiesto da PlayerPROAR per -decryption_key)
# ════════════════════════════════════════════════════════════
_FFMPEG_BIN=/usr/local/bin/ffmpeg
_ff_need=1
if [[ -x "$_FFMPEG_BIN" ]]; then
  _ff_major="$("$_FFMPEG_BIN" -version 2>&1 | grep -oP 'version \K[0-9]+' | head -1)"
  [[ "${_ff_major:-0}" -ge 7 ]] && _ff_need=0
fi
if [[ $_ff_need -eq 0 ]]; then
  skip "ffmpeg $("$_FFMPEG_BIN" -version 2>&1 | grep -oP 'version \K[^ ]+' | head -1) gia presente in $_FFMPEG_BIN"
else
  step "FFMPEG 7  —  download static build"
  _ff_arch=$(uname -m)
  case "$_ff_arch" in
    x86_64)  _ff_url="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" ;;
    aarch64) _ff_url="https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-arm64-static.tar.xz" ;;
    *)       warn "Architettura $_ff_arch non supportata per ffmpeg statico"; _ff_url="" ;;
  esac
  if [[ -n "$_ff_url" ]]; then
    wget -q "$_ff_url" -O /tmp/ffmpeg-release.tar.xz
    tar -xf /tmp/ffmpeg-release.tar.xz -C /tmp/
    _ff_dir=$(ls -d /tmp/ffmpeg-*-static 2>/dev/null | head -1)
    cp "$_ff_dir/ffmpeg"  /usr/local/bin/ffmpeg
    cp "$_ff_dir/ffprobe" /usr/local/bin/ffprobe
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe
    rm -rf /tmp/ffmpeg-release.tar.xz "$_ff_dir"
    ok "ffmpeg $(/usr/local/bin/ffmpeg -version 2>&1 | grep -oP 'version \K[^ ]+' | head -1) installato"
  fi
fi


# ════════════════════════════════════════════════════════════
#  6. DOWNLOAD + DECIFRA + INSTALLA PACCHETTO
# ════════════════════════════════════════════════════════════
step "6 / 11  —  DOWNLOAD PACCHETTO"

mkdir -p "$INSTALL_DIR"/{data,logs,scripts,cdm,config}
mkdir -p "$INSTALL_DIR"/crons/{tivify/logs,teditv/logs,pluto_tv/logs}
mkdir -p /root/backups

# Genera hardware fingerprint inline (stesso algoritmo di license_client.py)
info "Generazione hardware fingerprint..."
HW_HASH=$(python3 - << 'HWEOF'
import hashlib, subprocess, socket
from pathlib import Path

def mac():
    for iface in ["eth0","ens3","ens18","enp0s3","eth1"]:
        p = Path(f"/sys/class/net/{iface}/address")
        if p.exists(): return p.read_text().strip()
    import uuid; return str(uuid.getnode())

def cpu():
    try:
        txt = Path("/proc/cpuinfo").read_text()
        for l in txt.splitlines():
            if "model name" in l:
                import hashlib; return hashlib.md5(l.encode()).hexdigest()[:16]
    except: pass
    return "unknown_cpu"

def disk():
    try:
        r = subprocess.check_output(["blkid","-s","UUID","-o","value","/dev/sda1"],
            stderr=subprocess.DEVNULL, timeout=3).decode().strip()
        if r: return r
    except: pass
    try: return Path("/etc/machine-id").read_text().strip()
    except: return "unknown_disk"

raw = f"{mac()}|{cpu()}|{disk()}|{socket.gethostname()}"
print(hashlib.sha256(raw.encode()).hexdigest())
HWEOF
)
info "HW hash: ${HW_HASH:0:16}..."

# Richiedi build_key + URL download al license server
info "Autorizzazione download dal server di licenze..."
PKG_RESP=$(curl -s --connect-timeout 15 \
  -X POST "${LICENSE_SERVER_URL}/license/package" \
  -H "Content-Type: application/json" \
  -d "{\"license_key\":\"${LICENSE_KEY}\",\"hardware_hash\":\"${HW_HASH}\"}" 2>/dev/null)

PKG_ERROR=$(echo "$PKG_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(d.get('error', d.get('detail',{}).get('error','') if isinstance(d.get('detail'),dict) else ''))
" 2>/dev/null || echo "parse_error")

if [[ "$PKG_ERROR" == "build_key_not_configured" ]]; then
  err "Build key non configurata. Contatta il supporto."
elif [[ "$PKG_ERROR" == "license_expired" ]]; then
  err "Licenza scaduta. Rinnova la licenza prima di installare."
elif [[ "$PKG_ERROR" == "license_revoked" ]]; then
  err "Licenza revocata. Contatta il supporto."
elif [[ "$PKG_ERROR" == "license_not_found" ]]; then
  err "License key non trovata. Contatta il supporto."
fi

BUILD_KEY=$(echo "$PKG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('build_key',''))" 2>/dev/null)
DOWNLOAD_URL=$(echo "$PKG_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('download_url',''))" 2>/dev/null)

[[ -z "$BUILD_KEY" ]]    && err "Build key non ricevuta. Risposta: $PKG_RESP"
[[ -z "$DOWNLOAD_URL" ]] && err "URL download non ricevuto dal server."

ok "Autorizzato — scarico pacchetto da GitHub..."

# Scarica il pacchetto .ppro da GitHub
info "Download da $DOWNLOAD_URL..."
curl -L --connect-timeout 30 --max-time 600 --progress-bar \
  "$DOWNLOAD_URL" \
  -o /tmp/playerproar.ppro

[[ -f /tmp/playerproar.ppro && -s /tmp/playerproar.ppro ]] || \
  err "Download fallito o file vuoto."
ok "Pacchetto scaricato"

# Decifra con AES-256-CBC
info "Decifratura pacchetto..."
echo "$BUILD_KEY" | openssl enc -d -aes-256-cbc -pbkdf2 -iter 100000 \
  -in /tmp/playerproar.ppro \
  -out /tmp/playerproar_stage.tar.gz \
  -pass stdin 2>/dev/null || err "Decifratura fallita — build key non valida."
rm -f /tmp/playerproar.ppro
ok "Pacchetto decifrato"

# Estrai
info "Estrazione..."
tar xzf /tmp/playerproar_stage.tar.gz -C /tmp/ || err "Estrazione fallita."
rm -f /tmp/playerproar_stage.tar.gz

[[ -d /tmp/stage ]] || err "Struttura pacchetto non trovata dopo estrazione."
cp -r /tmp/stage/. "$INSTALL_DIR/"
rm -rf /tmp/stage
ok "File installati in $INSTALL_DIR"

# ════════════════════════════════════════════════════════════
#  7. DIPENDENZE PYTHON
# ════════════════════════════════════════════════════════════
step "7 / 11  —  DIPENDENZE PYTHON"
[[ -f "$INSTALL_DIR/requirements.txt" ]] && pip3 install -q -r "$INSTALL_DIR/requirements.txt"
pip3 install -q aiofiles bcrypt httpx geoip2 streamlink curl_cffi \
  python-jose[cryptography] cryptography 2>/dev/null || true
ok "Dipendenze Python pronte"

# ════════════════════════════════════════════════════════════
#  8. NGINX + SYSTEMD + FIREWALL
# ════════════════════════════════════════════════════════════
step "8 / 11  —  NGINX + SYSTEMD + FIREWALL"

rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true
cat > /etc/nginx/sites-available/playerproar.conf << NGINXEOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    location / {
        proxy_pass http://127.0.0.1:${BACKEND_PORT};
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_read_timeout 300s;
        proxy_send_timeout 300s;
        client_max_body_size 100M;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/playerproar.conf /etc/nginx/sites-enabled/playerproar.conf
nginx -t && systemctl enable nginx && systemctl reload nginx && ok "Nginx configurato"

[[ "$SETUP_SSL" =~ ^[Ss]$ ]] && certbot --nginx -d "$SERVER_DOMAIN" \
  --email "$CERTBOT_EMAIL" --agree-tos --non-interactive --redirect && ok "SSL attivato" || true

cat > /etc/systemd/system/playerproar.service << SVCEOF
[Unit]
Description=PLAYER PRO AR Backend Service
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=root
WorkingDirectory=${INSTALL_DIR}
Environment=PATH=/root/.deno/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONHASHSEED=random
ExecStart=/usr/bin/python3 -m uvicorn backend.main:app \\
  --host 0.0.0.0 --port ${BACKEND_PORT} \\
  --workers ${UVICORN_WORKERS} \\
  --timeout-keep-alive 5 \\
  --limit-concurrency 200 --backlog 1024
Restart=always
RestartSec=5
MemoryHigh=8G
MemoryMax=12G
CPUQuota=800%
LimitNOFILE=65536
LimitNPROC=8192
KillSignal=SIGTERM
TimeoutStopSec=20
KillMode=mixed
SendSIGKILL=yes

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload && systemctl enable playerproar

ufw --force reset > /dev/null
ufw default deny incoming > /dev/null; ufw default allow outgoing > /dev/null
ufw allow 22/tcp > /dev/null; ufw allow 80/tcp > /dev/null
ufw allow 443/tcp > /dev/null; ufw allow "${BACKEND_PORT}/tcp" > /dev/null
ufw --force enable > /dev/null && ok "UFW attivato"

iptables -C INPUT -p tcp --dport 1234 -s 127.0.0.1 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp --dport 1234 -s 127.0.0.1 -j ACCEPT
iptables -C INPUT -p tcp --dport 1234 -j DROP 2>/dev/null || iptables -A INPUT -p tcp --dport 1234 -j DROP
iptables-save > /etc/iptables.conf

ok "Servizi configurati"

# ════════════════════════════════════════════════════════════
#  9. CRONTAB + LOGROTATE
# ════════════════════════════════════════════════════════════
step "9 / 11  —  CRONTAB + LOGROTATE"
add_cron() { crontab -l 2>/dev/null | grep -qF "$1" || { crontab -l 2>/dev/null; echo "$1"; } | crontab -; }
add_cron "@reboot sleep 30 && iptables-restore < /etc/iptables.conf"
add_cron "*/3 * * * * /usr/bin/python3 ${INSTALL_DIR}/backend/services/watchdog.py >> ${INSTALL_DIR}/logs/watchdog_cron.log 2>&1"
add_cron "5 */4 * * * /usr/bin/python3 ${INSTALL_DIR}/crons/tivify/refresh_keys.py >> ${INSTALL_DIR}/crons/tivify/logs/crontab.log 2>&1"
add_cron "0 3 * * * certbot renew --quiet --post-hook 'systemctl reload nginx' 2>/dev/null || true"
add_cron "0 4 * * * cp ${INSTALL_DIR}/data/player.db /root/backups/player.db.\$(date +\%Y\%m\%d) && find /root/backups -name 'player.db.*' -mtime +7 -delete 2>/dev/null"

cat > /etc/logrotate.d/playerproar << LREOF
${INSTALL_DIR}/logs/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
    dateext
    dateformat -%Y%m%d
}
LREOF
ok "Crontab e logrotate configurati"

# ════════════════════════════════════════════════════════════
#  10. ATTIVAZIONE LICENZA
# ════════════════════════════════════════════════════════════
step "10 / 11  —  ATTIVAZIONE LICENZA"

info "Attivazione licenza $LICENSE_KEY su questo server..."
python3 << PYEOF
import sys
sys.path.insert(0, '$INSTALL_DIR')
try:
    from backend.core.license_client import activate_license
    ok = activate_license('$LICENSE_KEY')
    if ok:
        print('ACTIVATION_OK')
    else:
        print('ACTIVATION_FAILED')
        sys.exit(1)
except Exception as e:
    print(f'ACTIVATION_ERROR: {e}')
    sys.exit(1)
PYEOF

[[ $? -eq 0 ]] && ok "Licenza attivata con successo" || err "Attivazione licenza fallita — contatta il supporto con la tua License Key: $LICENSE_KEY"

# ════════════════════════════════════════════════════════════
#  11. AVVIO E VERIFICA FINALE
# ════════════════════════════════════════════════════════════
step "11 / 11  —  AVVIO E VERIFICA"

systemctl stop playerproar 2>/dev/null || true; sleep 2
systemctl start playerproar && ok "playerproar avviato" || err "playerproar NON avviato — journalctl -u playerproar -n 50"
systemctl restart nginx && ok "nginx riavviato"
info "Attendo avvio (15s)..."
sleep 15

LIC_STATUS=$(curl -s --connect-timeout 5 "http://localhost:${BACKEND_PORT}/api/license/status" 2>/dev/null || echo '{}')
LIC_VALID=$(echo "$LIC_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('valid','?'))" 2>/dev/null || echo "?")
LIC_EXP=$(echo "$LIC_STATUS" | python3 -c "import sys,json; d=json.load(sys.stdin); print(str(d.get('expires_at','?'))[:10])" 2>/dev/null || echo "?")

echo ""
echo -e "${BOLD}${GREEN}"
echo "  ╔══════════════════════════════════════════════════════╗"
echo "  ║   INSTALLAZIONE COMPLETATA  ✓                        ║"
echo "  ╠══════════════════════════════════════════════════════╣"
printf "  ║  Pannello:     http://%-32s║\n" "${SERVER_DOMAIN}/"
[[ "$SETUP_SSL" =~ ^[Ss]$ ]] && printf "  ║  Sicuro:       https://%-31s║\n" "${SERVER_DOMAIN}/"
printf "  ║  License:      %-38s║\n" "$LICENSE_KEY"
printf "  ║  Stato:        %-38s║\n" "Valida: $LIC_VALID — Scade: $LIC_EXP"
echo   "  ╠══════════════════════════════════════════════════════╣"
echo   "  ║  Supporto: contatta il tuo rivenditore               ║"
echo   "  ╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"
echo -e "  Log installazione: ${CYAN}${LOG_FILE}${RESET}"
