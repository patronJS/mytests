#!/bin/bash

# -E (errtrace) is required so trap ERR fires on failures inside shell
# functions and command substitutions, which is where most of the logic lives.
set -Eeuo pipefail

# Check if script started as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# ---------------------------------------------------------------------------
# Logging — tee stdout/stderr to a timestamped log file for post-mortem.
# ---------------------------------------------------------------------------
LOG_FILE="/var/log/setup-vps2-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /var/log
: > "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== setup-vps2.sh started at $(date -Iseconds) ==="
echo "=== full log: $LOG_FILE ==="

# ---------------------------------------------------------------------------
# trap ERR — report the failing line, keep partial state for debugging.
# ---------------------------------------------------------------------------
on_error() {
  local exit_code=$?
  local line_no=${1:-?}
  echo ""
  echo "=========================================="
  echo " ERROR: setup-vps2.sh failed at line $line_no (exit $exit_code)"
  echo " Log: $LOG_FILE"
  echo "=========================================="
  exit "$exit_code"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# retry_cmd <tries> <sleep_seconds> -- <command...>
retry_cmd() {
  local tries=$1 delay=$2
  shift 2
  [[ "${1:-}" == "--" ]] && shift
  local attempt=1
  while (( attempt <= tries )); do
    if "$@"; then
      return 0
    fi
    echo "  retry $attempt/$tries failed for: $*"
    if (( attempt < tries )); then
      sleep "$delay"
    fi
    attempt=$(( attempt + 1 ))
  done
  return 1
}

# wget wrapper with built-in retries/timeouts. Use instead of raw wget for
# all network downloads so transient upstream failures don't brick installs.
net_wget() {
  wget -4 --tries=3 --timeout=20 --waitretry=5 --retry-connrefused "$@"
}

# atomic_write <dest> — consume stdin into a temp file next to dest,
# then rename into place. Keeps boot-critical configs consistent on rerun
# even if the upstream stream is truncated mid-flight.
atomic_write() {
  local dest=$1
  local tmp
  tmp=$(mktemp "${dest}.XXXXXX")
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    echo "ERROR: failed to stage $dest"
    exit 1
  fi
  if [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    echo "ERROR: empty content for $dest"
    exit 1
  fi
  mv -f "$tmp" "$dest"
}

# Disable IPv6 early — prevents wget/apt hangs on dual-stack hosts
sysctl -w net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
sysctl -w net.ipv6.conf.default.disable_ipv6=1 >/dev/null 2>&1 || true

# Force apt to use IPv4 only + enable retries on flaky mirrors
cat > /etc/apt/apt.conf.d/99force-ipv4 << 'APT_CONF_EOF'
Acquire::ForceIPv4 "true";
Acquire::Retries "3";
APT_CONF_EOF

# Ubuntu 24.04: disable interactive prompts (needrestart menu, debconf dialogs)
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# Install dependencies (with retry — apt mirrors are sometimes flaky)
retry_cmd 3 5 -- apt-get -o DPkg::Lock::Timeout=60 update
retry_cmd 3 5 -- apt-get -o DPkg::Lock::Timeout=60 install -y \
  idn sudo dnsutils wamerican zip unzip python3 wget curl openssl gettext

export GIT_BRANCH="main"
export GIT_REPO="patronJS/mytests"
export XRAY_VERSION="v26.3.27"
# Pinned versions: yq=v4.52.5, marzban=latest, angie=minimal
TEMPLATE_URL="https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script"

fetch_template() {
  local content
  content=$(retry_cmd 3 3 -- net_wget -qO- "$TEMPLATE_URL/$1") || {
    echo "Failed to download template: $1"
    exit 1
  }
  [ -n "$content" ] || { echo "Template is empty: $1"; exit 1; }
  printf '%s\n' "$content"
}

# ---------------------------------------------------------------------------
# Architecture check — do this early, before we spend time on downloads.
# ---------------------------------------------------------------------------
ARCH=$(dpkg --print-architecture)
[[ -n "$ARCH" ]] || { echo "ERROR: cannot detect architecture"; exit 1; }
case "$ARCH" in
  amd64|arm64) ;;
  *) echo "ERROR: Unsupported architecture: $ARCH. Supported: amd64, arm64."; exit 1 ;;
esac
export ARCH

# ---------------------------------------------------------------------------
# Read domain input
# ---------------------------------------------------------------------------
read -ep "Enter your domain:"$'\n' input_domain
while [[ -z "${input_domain// }" ]]; do
  read -ep "Domain cannot be empty. Enter your domain:"$'\n' input_domain
done

VLESS_DOMAIN=$(echo "$input_domain" | idn)
[[ -n "$VLESS_DOMAIN" ]] || { echo "ERROR: idn returned empty domain"; exit 1; }
export VLESS_DOMAIN

read -ra SERVER_IPS <<< "$(hostname -I)"

RESOLVED_IP=$(dig +short "$VLESS_DOMAIN" | tail -n1)

if [ -z "$RESOLVED_IP" ]; then
  echo "Warning: Domain has no DNS record"
  read -ep "Are you sure? That domain has no DNS record. If you didn't add that you will have to restart xray and angie by yourself [y/N]"$'\n' prompt_response
  if [[ "$prompt_response" =~ ^([yY])$ ]]; then
    echo "Ok, proceeding without DNS verification"
  else
    echo "Come back later"
    exit 1
  fi
else
  MATCH_FOUND=false
  for server_ip in "${SERVER_IPS[@]}"; do
    if [ "$RESOLVED_IP" == "$server_ip" ]; then
      MATCH_FOUND=true
      break
    fi
  done

  if [ "$MATCH_FOUND" = true ]; then
    echo "DNS record points to this server ($RESOLVED_IP)"
  else
    echo "Warning: DNS record exists but points to different IP"
    echo "  Domain resolves to: $RESOLVED_IP"
    echo "  This server's IPs: ${SERVER_IPS[*]}"
    read -ep "Continue anyway? [y/N]"$'\n' prompt_response
    if [[ "$prompt_response" =~ ^([yY])$ ]]; then
      echo "Ok, proceeding"
    else
      echo "Come back later"
      exit 1
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Ask VPS1 connection info (with validation)
# ---------------------------------------------------------------------------
read -ep "Enter VPS1 IP address:"$'\n' VPS1_IP
read -ep "Enter VPS1 public key (PBK):"$'\n' VPS1_PBK
read -ep "Enter VPS1 short ID:"$'\n' VPS1_SHORT_ID
read -ep "Enter inter-VPS UUID:"$'\n' UUID_LINK
read -ep "Enter XHTTP path:"$'\n' XHTTP_PATH
read -ep "Enter VPS1 domain:"$'\n' VPS1_DOMAIN

[[ "$UUID_LINK" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "Invalid UUID_LINK format"; exit 1; }
[[ ${#VPS1_PBK} -ge 40 ]] || { echo "VPS1_PBK looks too short"; exit 1; }
[[ "$VPS1_SHORT_ID" =~ ^[0-9a-f]{2,16}$ ]] && (( ${#VPS1_SHORT_ID} % 2 == 0 )) || { echo "Invalid VPS1_SHORT_ID: must be 2-16 even-length hex chars"; exit 1; }
[[ "$VPS1_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VPS1_IP format"; exit 1; }
[[ "$XHTTP_PATH" =~ ^[0-9a-f]{24}$ ]] || { echo "Invalid XHTTP_PATH format"; exit 1; }
[[ "$VPS1_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "VPS1_DOMAIN must be a domain name, not an IP address"; exit 1; }
[[ "$VPS1_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] || { echo "Invalid VPS1_DOMAIN format"; exit 1; }

export VPS1_IP VPS1_PBK VPS1_SHORT_ID UUID_LINK XHTTP_PATH VPS1_DOMAIN

# ---------------------------------------------------------------------------
# Optional SSH hardening prompts
# ---------------------------------------------------------------------------
read -ep "Do you want to harden SSH? [y/N] "$'\n' configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  read -ep "Enter SSH port. Default 22, can't use ports: 80, 443 and 4123:"$'\n' input_ssh_port

  while ! [[ "$input_ssh_port" =~ ^[0-9]+$ ]] || (( input_ssh_port < 1 || input_ssh_port > 65535 )) || [[ "$input_ssh_port" -eq 80 || "$input_ssh_port" -eq 443 || "$input_ssh_port" -eq 4123 ]]; do
    read -ep "Invalid or reserved port ($input_ssh_port). Use 1-65535, not 80/443/4123:"$'\n' input_ssh_port
  done

  read -ep "Enter SSH public key:"$'\n' input_ssh_pbk
  # Normalize: strip CR and trailing whitespace so dedupe works across reruns
  input_ssh_pbk=$(printf '%s' "$input_ssh_pbk" | tr -d '\r' | sed 's/[[:space:]]*$//')
  ssh_key_tmp=$(mktemp)
  trap 'rm -f "$ssh_key_tmp"' EXIT
  echo "$input_ssh_pbk" > "$ssh_key_tmp"
  if ! ssh-keygen -l -f "$ssh_key_tmp"; then
    echo "Can't verify the public key. Try again and make sure to include 'ssh-rsa' or 'ssh-ed25519' followed by 'user@pcname' at the end of the file."
    exit 1
  fi
  rm -f "$ssh_key_tmp"
  trap - EXIT
fi

# ---------------------------------------------------------------------------
# Install Docker (only if missing — avoid restarting a running production
# daemon on rerun, which would bounce every container on the host).
# ---------------------------------------------------------------------------
docker_installed_now=0
docker_install() {
  curl -4 -fsSL --retry 3 --retry-connrefused --connect-timeout 15 --max-time 300 \
    https://get.docker.com -o /tmp/get-docker.sh
  [[ -s /tmp/get-docker.sh ]] || { echo "ERROR: docker installer download failed"; exit 1; }
  sh /tmp/get-docker.sh
  rm -f /tmp/get-docker.sh
  docker_installed_now=1
}

if ! command -v docker >/dev/null 2>&1; then
  docker_install
fi
# Restart Docker only if we just installed it — picks up our IPv6 disable.
if (( docker_installed_now == 1 )); then
  systemctl restart docker
fi

# ---------------------------------------------------------------------------
# Install yq — pinned version + SHA256 verification, installed to
# /usr/local/bin per FHS (dpkg owns /usr/bin).
# ---------------------------------------------------------------------------
YQ_VERSION="v4.52.5"
yq_install() {
  retry_cmd 3 5 -- net_wget -q \
    "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH" \
    -O /usr/local/bin/yq
  [[ -s /usr/local/bin/yq ]] || { echo "ERROR: yq download failed or empty"; rm -f /usr/local/bin/yq; exit 1; }

  retry_cmd 3 5 -- net_wget -qO /tmp/yq_checksums \
    "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/checksums"
  [[ -s /tmp/yq_checksums ]] || { echo "ERROR: yq checksums download failed or empty"; rm -f /usr/local/bin/yq; exit 1; }

  # The yq checksums file has a fixed-column layout where SHA-256 is the 19th
  # column. Pinned to YQ_VERSION — stable unless we bump the version.
  YQ_SHA256=$(grep "yq_linux_$ARCH " /tmp/yq_checksums | awk '{print $19}')
  [[ -n "$YQ_SHA256" ]] || { echo "ERROR: yq checksum not found for yq_linux_$ARCH"; rm -f /usr/local/bin/yq; exit 1; }
  echo "$YQ_SHA256  /usr/local/bin/yq" | sha256sum -c - || {
    echo "yq checksum verification failed"
    rm -f /usr/local/bin/yq
    exit 1
  }
  chmod +x /usr/local/bin/yq
  rm -f /tmp/yq_checksums
}

if ! command -v yq >/dev/null 2>&1 || ! /usr/local/bin/yq --version 2>/dev/null | grep -q "$YQ_VERSION"; then
  yq_install
fi

# ---------------------------------------------------------------------------
# sysctl persistence — BBR + IPv6 disable
# ---------------------------------------------------------------------------
grep -q "^net.core.default_qdisc=fq" /etc/sysctl.conf || echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
grep -q "^net.ipv4.tcp_congestion_control=bbr" /etc/sysctl.conf || echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
grep -q "^net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf
grep -q "^net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.default.disable_ipv6=1" >> /etc/sysctl.conf
sysctl -p > /dev/null

# ---------------------------------------------------------------------------
# Secrets persistence — reuse on rerun so existing clients don't break.
# flock serializes concurrent invocations; atomic mktemp+mv prevents
# partial writes on crash/Ctrl-C.
# ---------------------------------------------------------------------------
mkdir -p /opt/xray-vps-setup/node
SECRETS_FILE="/opt/xray-vps-setup/.secrets.env"
SECRETS_LOCK="/opt/xray-vps-setup/.secrets.lock"
: > "$SECRETS_LOCK"
chmod 600 "$SECRETS_LOCK"
exec 9>"$SECRETS_LOCK"
flock -x 9

if [[ -f "$SECRETS_FILE" ]]; then
  echo "Existing install detected — reusing secrets from $SECRETS_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
else
  XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} x25519 | grep 'PrivateKey' | awk '{print $NF}')
  [[ -n "$XRAY_PIK" ]] || { echo "ERROR: xray x25519 private key generation failed"; exit 1; }
  XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} x25519 -i "$XRAY_PIK" | grep 'PublicKey' | awk '{print $NF}')
  [[ -n "$XRAY_PBK" ]] || { echo "ERROR: xray x25519 public key derivation failed"; exit 1; }
  CLIENT_UUID=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} uuid)
  [[ -n "$CLIENT_UUID" ]] || { echo "ERROR: xray uuid generation failed"; exit 1; }

  SID1=$(openssl rand -hex 2)
  SID2=$(openssl rand -hex 4)
  SID3=$(openssl rand -hex 6)
  SID4=$(openssl rand -hex 8)
  # shellcheck disable=SC2089
  SHORT_IDS="\"$SID1\",\"$SID2\",\"$SID3\",\"$SID4\""
  SHORT_ID=$SID4
  CLIENT_XHTTP_PATH=$(openssl rand -hex 12)

  MARZBAN_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words 2>/dev/null | shuf -n 1 || true)
  [[ -n "$MARZBAN_USER" ]] || MARZBAN_USER="adm$(openssl rand -hex 3)"
  # Note: we intentionally avoid `tr </dev/urandom | head -c N` because with
  # `set -o pipefail` the early close by head causes SIGPIPE in tr → exit 141.
  MARZBAN_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 512 /dev/urandom))
  MARZBAN_PASS=${MARZBAN_PASS:0:13}
  [[ ${#MARZBAN_PASS} -eq 13 ]] || { echo "ERROR: MARZBAN_PASS generation failed"; exit 1; }
  MARZBAN_PATH=$(openssl rand -hex 8)
  MARZBAN_SUB_PATH=$(openssl rand -hex 8)

  # Atomic write: stage into temp file, chmod, then rename
  secrets_tmp=$(mktemp "${SECRETS_FILE}.XXXXXX")
  chmod 600 "$secrets_tmp"
  cat > "$secrets_tmp" << SECRETS_EOF
export XRAY_PIK="$XRAY_PIK"
export XRAY_PBK="$XRAY_PBK"
export SID1="$SID1"
export SID2="$SID2"
export SID3="$SID3"
export SID4="$SID4"
export SHORT_IDS='$SHORT_IDS'
export SHORT_ID="$SHORT_ID"
export CLIENT_UUID="$CLIENT_UUID"
export CLIENT_XHTTP_PATH="$CLIENT_XHTTP_PATH"
export MARZBAN_USER="$MARZBAN_USER"
export MARZBAN_PASS="$MARZBAN_PASS"
export MARZBAN_PATH="$MARZBAN_PATH"
export MARZBAN_SUB_PATH="$MARZBAN_SUB_PATH"
SECRETS_EOF
  mv -f "$secrets_tmp" "$SECRETS_FILE"
fi
exec 9>&-

# Post-source validation — fail loud if state is corrupted
for _v in XRAY_PIK XRAY_PBK SID1 SID2 SID3 SID4 SHORT_IDS SHORT_ID \
          CLIENT_UUID CLIENT_XHTTP_PATH MARZBAN_USER MARZBAN_PASS \
          MARZBAN_PATH MARZBAN_SUB_PATH; do
  if [[ -z "${!_v:-}" ]]; then
    echo "ERROR: secret $_v is empty — $SECRETS_FILE is corrupted."
    echo "       Back it up and rerun: mv $SECRETS_FILE ${SECRETS_FILE}.bad"
    exit 1
  fi
done
unset _v
# shellcheck disable=SC2090
export XRAY_PIK XRAY_PBK SID1 SID2 SID3 SID4 SHORT_IDS SHORT_ID
export CLIENT_UUID CLIENT_XHTTP_PATH MARZBAN_USER MARZBAN_PASS MARZBAN_PATH MARZBAN_SUB_PATH

# ---------------------------------------------------------------------------
# Download XRay core (with retry and staged write)
# ---------------------------------------------------------------------------
mkdir -p /opt/xray-vps-setup/node/xray-core
rm -f /tmp/xray.zip
if [[ "$ARCH" == "amd64" ]]; then
  XRAY_ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip"
else
  XRAY_ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-arm64-v8a.zip"
fi
retry_cmd 3 5 -- net_wget -O /tmp/xray.zip "$XRAY_ZIP_URL"
[[ -s /tmp/xray.zip ]] || { echo "ERROR: xray zip download failed or empty"; exit 1; }
unzip -qo /tmp/xray.zip -d /opt/xray-vps-setup/node/xray-core

# Download latest geodata (geosite.dat from XRay release may be outdated)
# Stage into tmp first so a partial download never clobbers a working file.
echo "Downloading latest geosite.dat and geoip.dat..."
retry_cmd 3 5 -- net_wget -qO /tmp/geosite.dat \
  https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
[[ -s /tmp/geosite.dat ]] || { echo "ERROR: geosite.dat download failed"; exit 1; }
retry_cmd 3 5 -- net_wget -qO /tmp/geoip.dat \
  https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
[[ -s /tmp/geoip.dat ]] || { echo "ERROR: geoip.dat download failed"; exit 1; }
mv -f /tmp/geosite.dat /opt/xray-vps-setup/node/xray-core/geosite.dat
mv -f /tmp/geoip.dat /opt/xray-vps-setup/node/xray-core/geoip.dat

# ---------------------------------------------------------------------------
# Download and envsubst templates — whitelisted variables + atomic writes.
# ---------------------------------------------------------------------------
cd /opt/xray-vps-setup

fetch_template "node-xray" \
  | envsubst '$CLIENT_UUID $CLIENT_XHTTP_PATH $XRAY_PIK $XRAY_PBK $SHORT_IDS $VPS1_IP $VPS1_PBK $VPS1_SHORT_ID $UUID_LINK $XHTTP_PATH $VPS1_DOMAIN $VLESS_DOMAIN' \
  | atomic_write ./node/xray_config.json

fetch_template "node-angie" \
  | envsubst '$VLESS_DOMAIN' \
  | atomic_write ./angie.conf

fetch_template "compose-cascade-node" \
  | envsubst '$VLESS_DOMAIN $XRAY_VERSION' \
  | atomic_write ./docker-compose.yml

fetch_template "confluence" \
  | envsubst '$VLESS_DOMAIN' \
  | atomic_write ./index.html

fetch_template "marzban" \
  | envsubst '$MARZBAN_USER $MARZBAN_PASS $MARZBAN_PATH $MARZBAN_SUB_PATH' \
  | atomic_write ./node/.env

# Validate JSON — break early if template substitution produced junk
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json; json.load(open('/opt/xray-vps-setup/node/xray_config.json'))" || {
    echo "ERROR: node/xray_config.json is not valid JSON after envsubst"
    exit 1
  }
fi

# File permissions
chmod 600 ./node/xray_config.json ./node/.env
chmod 644 ./angie.conf ./index.html ./docker-compose.yml

# ---------------------------------------------------------------------------
# Port preflight — fail early if something else holds any of the ports we
# need. Allowlist our own container process names so reruns don't self-trip.
# ---------------------------------------------------------------------------
port_in_use_by_other() {
  local spec=$1
  local ss_out
  ss_out=$(ss -Htlnp "$spec" 2>/dev/null || true)
  [[ -z "$ss_out" ]] && return 1
  if echo "$ss_out" | grep -Eq 'docker-proxy|"(angie|nginx|xray|marzban|uvicorn|python3?)"'; then
    return 1
  fi
  echo "  $spec is held by: $ss_out"
  return 0
}

# Wildcard-bound ports (angie on network_mode: host — 80 for ACME, 443 for VLESS)
for p in 80 443; do
  if port_in_use_by_other "sport = :$p"; then
    echo "ERROR: port $p is already bound by another service — free it and rerun."
    exit 1
  fi
done
# Loopback-bound ports (Marzban API + XRay local API)
for p in 8000 4123; do
  if port_in_use_by_other "src 127.0.0.1:$p"; then
    echo "ERROR: 127.0.0.1:$p is already bound by another service — free it and rerun."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Open ports 80 + 443 for ACME / clients before starting Angie
# (iptables default policy is still ACCEPT at this point)
# ---------------------------------------------------------------------------
iptables -C INPUT -p tcp -m tcp --dport 80 -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
iptables -C INPUT -p tcp -m tcp --dport 443 -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -p tcp -m tcp --dport 443 -j ACCEPT

docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

# ---------------------------------------------------------------------------
# Marzban init — wait until API is ready (up to 60s)
# ---------------------------------------------------------------------------
echo "Waiting for Marzban to start..."
MARZBAN_IMPORTED=false
for i in $(seq 1 12); do
  sleep 5
  if docker exec marzban marzban-cli admin import-from-env 2>/dev/null; then
    echo "Marzban admin imported successfully"
    MARZBAN_IMPORTED=true
    break
  fi
  echo "  attempt $i/12..."
done
if [[ "$MARZBAN_IMPORTED" != "true" ]]; then
  echo "ERROR: Marzban admin import failed after 12 attempts. Check logs:"
  docker logs marzban --tail 30
  exit 1
fi

# ---------------------------------------------------------------------------
# Update panel default host. The token flow uses curl with explicit timeouts
# and a Python parser that normalizes JSON null -> empty string (otherwise
# we'd send "Bearer None" and silently 401).
# ---------------------------------------------------------------------------
echo "Updating panel host with domain $VLESS_DOMAIN..."
PANEL_TOKEN=""
for attempt in 1 2 3; do
  PANEL_TOKEN=$(curl -4 -sf --connect-timeout 5 --max-time 15 \
    -X POST "http://127.0.0.1:8000/${MARZBAN_PATH}/api/admin/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=$MARZBAN_USER" \
    --data-urlencode "password=$MARZBAN_PASS" \
    | python3 -c "
import json, sys
try:
    data = json.load(sys.stdin)
    tok = data.get('access_token')
    print(tok if isinstance(tok, str) and tok else '')
except Exception:
    print('')
" 2>/dev/null || true)
  [[ -n "$PANEL_TOKEN" ]] && break
  sleep 2
done

if [[ -n "$PANEL_TOKEN" ]]; then
  PHOSTS_HTTP=$(curl -4 -s --connect-timeout 5 --max-time 15 \
    -o /tmp/panel_hosts.json -w "%{http_code}" \
    "http://127.0.0.1:8000/${MARZBAN_PATH}/api/hosts" \
    -H "Authorization: Bearer $PANEL_TOKEN" || echo "000")
  if [[ "$PHOSTS_HTTP" == "200" ]]; then
    export PANEL_HOST_DOMAIN="$VLESS_DOMAIN"
    python3 << 'PYEOF' > /tmp/panel_hosts_updated.json
import json, os
with open('/tmp/panel_hosts.json') as f:
    hosts = json.load(f)
domain = os.environ['PANEL_HOST_DOMAIN']
for host_list in hosts.values():
    for host in host_list:
        host['address'] = domain
        host['sni'] = domain
print(json.dumps(hosts))
PYEOF
    PUT_HTTP=$(curl -4 -s --connect-timeout 5 --max-time 15 -o /dev/null \
      -w "%{http_code}" \
      -X PUT "http://127.0.0.1:8000/${MARZBAN_PATH}/api/hosts" \
      -H "Authorization: Bearer $PANEL_TOKEN" \
      -H "Content-Type: application/json" \
      -d @/tmp/panel_hosts_updated.json || echo "000")
    if [[ "$PUT_HTTP" == "200" || "$PUT_HTTP" == "204" ]]; then
      echo "Panel host updated."
    else
      echo "Warning: panel host PUT returned HTTP $PUT_HTTP — update address/SNI to $VLESS_DOMAIN manually"
    fi
  else
    echo "Warning: could not fetch panel hosts (HTTP $PHOSTS_HTTP) - update address/SNI manually"
  fi
else
  echo "Warning: could not authenticate to panel API - update default host address/SNI to $VLESS_DOMAIN manually"
fi

# ---------------------------------------------------------------------------
# Detect current SSH port (Ubuntu 24.04 socket-activated ssh aware)
# ---------------------------------------------------------------------------
detect_ssh_port() {
  local port=""
  if systemctl is-enabled ssh.socket &>/dev/null; then
    local listen_val
    listen_val=$(systemctl show ssh.socket -p Listen --value 2>/dev/null || true)
    [[ "$listen_val" =~ :([0-9]+) ]] && port="${BASH_REMATCH[1]}"
  fi
  if [[ -z "$port" ]]; then
    port=$(ss -tlnp 2>/dev/null | grep sshd | grep -Po '(?<=:)\d+(?= )' | head -n 1 || true)
  fi
  echo "${port:-22}"
}

CURRENT_SSH_PORT=$(detect_ssh_port)
if [[ ${configure_ssh_input,,} == "y" && -n "${input_ssh_port:-}" ]]; then
  SSH_PORT="${input_ssh_port}"
else
  SSH_PORT="$CURRENT_SSH_PORT"
fi
export SSH_PORT

# ---------------------------------------------------------------------------
# Install iptables-persistent + configure firewall
# ---------------------------------------------------------------------------
debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
retry_cmd 3 5 -- apt-get -o DPkg::Lock::Timeout=60 install -y iptables-persistent netfilter-persistent

iptables_add() {
  iptables -C "$@" 2>/dev/null || iptables -A "$@"
}

iptables_add INPUT -p icmp -j ACCEPT
iptables_add INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
# Always keep BOTH the new SSH_PORT and the currently-detected port open.
# This prevents lockout if the sshd_config change fails to take effect.
iptables_add INPUT -p tcp -m state --state NEW -m tcp --dport "$SSH_PORT" -j ACCEPT
if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
  iptables_add INPUT -p tcp -m state --state NEW -m tcp --dport "$CURRENT_SSH_PORT" -j ACCEPT
fi
iptables_add INPUT -p tcp -m tcp --dport 80 -j ACCEPT
iptables_add INPUT -p tcp -m tcp --dport 443 -j ACCEPT
iptables_add INPUT -i lo -j ACCEPT
iptables_add OUTPUT -o lo -j ACCEPT
iptables -P INPUT DROP
netfilter-persistent save

# fail2ban — SSH brute-force protection (installed regardless of hardening choice)
retry_cmd 3 5 -- apt-get -o DPkg::Lock::Timeout=60 install -y fail2ban
fetch_template "fail2ban-jail" \
  | envsubst '$SSH_PORT' \
  | atomic_write /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# SSH hardening
# Persist SSH state across reruns (flock + atomic write + validation).
# ---------------------------------------------------------------------------
SSH_STATE_FILE="/opt/xray-vps-setup/.ssh-state.env"
SSH_STATE_LOCK="/opt/xray-vps-setup/.ssh-state.lock"
: > "$SSH_STATE_LOCK"
chmod 600 "$SSH_STATE_LOCK"
exec 8>"$SSH_STATE_LOCK"
flock -x 8

ssh_state_existed=0
if [[ -f "$SSH_STATE_FILE" ]]; then
  ssh_state_existed=1
  # shellcheck disable=SC1090
  source "$SSH_STATE_FILE"
else
  # Pick a dictionary word that does NOT collide with an existing system account
  SSH_USER=""
  for _ in $(seq 1 50); do
    candidate=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words 2>/dev/null | shuf -n 1 || true)
    if [[ -n "$candidate" ]] && ! id "$candidate" &>/dev/null; then
      SSH_USER="$candidate"
      break
    fi
  done
  if [[ -z "$SSH_USER" ]]; then
    _rand_suffix=$(LC_ALL=C tr -dc 'a-z0-9' < <(head -c 256 /dev/urandom))
    SSH_USER="op${_rand_suffix:0:6}"
    unset _rand_suffix
  fi
  SSH_USER_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9' < <(head -c 512 /dev/urandom))
  SSH_USER_PASS=${SSH_USER_PASS:0:13}
  [[ ${#SSH_USER_PASS} -eq 13 ]] || { echo "ERROR: SSH_USER_PASS generation failed"; exit 1; }

  ssh_state_tmp=$(mktemp "${SSH_STATE_FILE}.XXXXXX")
  chmod 600 "$ssh_state_tmp"
  cat > "$ssh_state_tmp" << SSH_STATE_EOF
export SSH_USER="$SSH_USER"
export SSH_USER_PASS="$SSH_USER_PASS"
SSH_STATE_EOF
  mv -f "$ssh_state_tmp" "$SSH_STATE_FILE"
fi
exec 8>&-

if [[ -z "${SSH_USER:-}" || -z "${SSH_USER_PASS:-}" ]]; then
  echo "ERROR: $SSH_STATE_FILE is missing SSH_USER or SSH_USER_PASS — corrupted state."
  echo "       Back it up and rerun: mv $SSH_STATE_FILE ${SSH_STATE_FILE}.bad"
  exit 1
fi
export SSH_USER SSH_USER_PASS

sshd_smoke_test() {
  # Wait up to 10s for sshd to actually bind the requested port.
  local tries=10
  while (( tries > 0 )); do
    if ss -Htln "sport = :$SSH_PORT" 2>/dev/null | grep -q LISTEN; then
      return 0
    fi
    sleep 1
    tries=$(( tries - 1 ))
  done
  return 1
}

sshd_edit() {
  # Preflight: refuse if the chosen port is bound by anything other than sshd.
  # On Ubuntu 24.04, ssh.socket holds the port as "systemd" — tolerated if
  # it's our own ssh.socket on the same port (we transition it below).
  if ss -tlnp 2>/dev/null | grep -E ":${SSH_PORT}[[:space:]]" | grep -qv '"sshd"'; then
    local is_own_ssh_socket=0
    if systemctl is-enabled ssh.socket &>/dev/null; then
      local listen_val socket_port=""
      listen_val=$(systemctl show ssh.socket -p Listen --value 2>/dev/null || true)
      [[ "$listen_val" =~ :([0-9]+) ]] && socket_port="${BASH_REMATCH[1]}"
      [[ "$socket_port" == "$SSH_PORT" ]] && is_own_ssh_socket=1
    fi
    if (( is_own_ssh_socket == 0 )); then
      echo "ERROR: port $SSH_PORT is already bound by another service:"
      ss -tlnp | grep -E ":${SSH_PORT}[[:space:]]" || true
      echo "Choose a different port or stop that service, then rerun."
      exit 1
    fi
  fi

  local sshd_drop_in="/etc/ssh/sshd_config.d/00-disable-password.conf"
  local sshd_backup=""
  if [[ -f "$sshd_drop_in" ]]; then
    sshd_backup=$(mktemp)
    cp -a "$sshd_drop_in" "$sshd_backup"
  fi

  # Snapshot original socket/service state so we can restore it on ANY
  # failure in the transition block below.
  local had_socket=0
  systemctl is-enabled ssh.socket &>/dev/null && had_socket=1

  # Unified rollback — safe to call multiple times.
  rollback_ssh() {
    echo "--- rolling back SSH state ---"
    if [[ -n "$sshd_backup" && -f "$sshd_backup" ]]; then
      mv -f "$sshd_backup" "$sshd_drop_in" || true
      sshd_backup=""
    else
      rm -f "$sshd_drop_in" || true
    fi
    if (( had_socket == 1 )); then
      systemctl enable --now ssh.socket &>/dev/null || true
      systemctl disable ssh.service &>/dev/null || true
    fi
    systemctl daemon-reload || true
    systemctl restart ssh.service &>/dev/null || \
      systemctl restart ssh.socket &>/dev/null || true
  }

  if ! fetch_template "00-disable-password" \
       | envsubst '$SSH_PORT' \
       | atomic_write "$sshd_drop_in"; then
    echo "ERROR: failed to write sshd drop-in"
    rollback_ssh
    exit 1
  fi

  if ! sshd -t; then
    echo "ERROR: sshd config test failed"
    rollback_ssh
    exit 1
  fi

  # Ubuntu 24.04: ssh is socket-activated via ssh.socket by default; the socket
  # unit's ListenStream= overrides Port= from sshd_config.d. Switch to plain
  # ssh.service so our new port actually takes effect.
  if (( had_socket == 1 )); then
    echo "Transitioning ssh.socket -> ssh.service (Ubuntu 24.04 default)..."
    if ! systemctl disable --now ssh.socket; then
      echo "ERROR: disable ssh.socket failed"
      rollback_ssh
      exit 1
    fi
    if ! systemctl enable ssh.service; then
      echo "ERROR: enable ssh.service failed"
      rollback_ssh
      exit 1
    fi
  fi

  if ! systemctl daemon-reload; then
    echo "ERROR: daemon-reload failed"
    rollback_ssh
    exit 1
  fi

  if ! systemctl restart ssh.service; then
    echo "ERROR: ssh.service restart failed"
    rollback_ssh
    exit 1
  fi

  if ! sshd_smoke_test; then
    echo "ERROR: sshd is not listening on port $SSH_PORT after restart"
    rollback_ssh
    exit 1
  fi

  # Success — drop the backup copy, keep only the live file
  [[ -n "$sshd_backup" ]] && rm -f "$sshd_backup"
  echo "sshd is listening on port $SSH_PORT (verified)"
}

add_user() {
  local ssh_home
  if id "$SSH_USER" &>/dev/null; then
    ssh_home=$(getent passwd "$SSH_USER" | cut -d: -f6)
  else
    useradd "$SSH_USER" -m -s /bin/bash
    ssh_home=$(getent passwd "$SSH_USER" | cut -d: -f6)
  fi
  [[ -n "$ssh_home" && -d "$ssh_home" ]] || { echo "ERROR: cannot resolve home dir for $SSH_USER"; exit 1; }
  usermod -aG sudo "$SSH_USER"
  if (( ssh_state_existed == 0 )); then
    echo "$SSH_USER:$SSH_USER_PASS" | chpasswd
  fi
  mkdir -p "$ssh_home/.ssh"
  touch "$ssh_home/.ssh/authorized_keys"
  grep -qF "$input_ssh_pbk" "$ssh_home/.ssh/authorized_keys" 2>/dev/null || echo "$input_ssh_pbk" >> "$ssh_home/.ssh/authorized_keys"
  chmod 700 "$ssh_home/.ssh/"
  chmod 600 "$ssh_home/.ssh/authorized_keys"
  chown "$SSH_USER:$SSH_USER" -R "$ssh_home/.ssh"
  usermod -aG docker "$SSH_USER"
}

if [[ ${configure_ssh_input,,} == "y" ]]; then
  if (( ssh_state_existed == 1 )); then
    echo "Reusing persisted SSH user: $SSH_USER (state file $SSH_STATE_FILE)"
  else
    echo "New SSH user: $SSH_USER (password + port stored in credentials.txt)"
  fi
  add_user
  sshd_edit
fi

# ---------------------------------------------------------------------------
# Install enable-warp.sh helper (manual WARP toggle, run by user after setup)
# ---------------------------------------------------------------------------
cat > /usr/local/bin/enable-warp.sh << 'ENABLEWARP_EOF'
#!/bin/bash
set -Eeuo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

XRAY_CONFIG="/opt/xray-vps-setup/node/xray_config.json"
COMPOSE_FILE="/opt/xray-vps-setup/docker-compose.yml"
WARP_PROXY_PORT=40000

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root"
  exit 1
fi

# Preflight: xray_config.json assumes host networking because warp outbound
# points at 127.0.0.1:40000 on the host loopback.
if ! grep -qE '^\s*network_mode:\s*host' "$COMPOSE_FILE"; then
  echo "ERROR: $COMPOSE_FILE does not use network_mode: host"
  echo "The warp outbound targets 127.0.0.1:$WARP_PROXY_PORT and only works with host networking."
  exit 1
fi

if ! curl -4 -I https://api.cloudflareclient.com --connect-timeout 10 > /dev/null 2>&1; then
  echo "Error: can't reach Cloudflare WARP API. WARP is unavailable in this region."
  exit 1
fi

if ! command -v warp-cli >/dev/null 2>&1; then
  echo "Installing Cloudflare WARP..."
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export NEEDRESTART_SUSPEND=1
  APT_OPTS=(-o DPkg::Lock::Timeout=60 -o Acquire::Retries=3)
  apt_retry() {
    local tries=3
    local i=1
    while (( i <= tries )); do
      if apt-get "${APT_OPTS[@]}" "$@"; then return 0; fi
      echo "  apt-get $* failed, retry $i/$tries"
      sleep 5
      i=$(( i + 1 ))
    done
    return 1
  }
  apt_retry install -y gpg
  curl -4 -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
    https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  mkdir -p /etc/apt/sources.list.d
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
    > /etc/apt/sources.list.d/cloudflare-client.list
  apt_retry update
  if ! apt_retry install -y cloudflare-warp; then
    echo "Failed to install cloudflare-warp package"
    exit 1
  fi
fi

if warp-cli status 2>/dev/null | grep -q "Registration Missing"; then
  if ! echo "y" | warp-cli registration new; then
    echo "Couldn't register WARP"
    exit 1
  fi
fi
if ! warp-cli mode proxy || ! warp-cli proxy port "$WARP_PROXY_PORT"; then
  echo "WARP client configuration failed"
  exit 1
fi
if ! warp-cli status 2>/dev/null | grep -q "Connected"; then
  if ! timeout 30 warp-cli connect; then
    echo "WARP connect timed out"
    exit 1
  fi
fi

# Wait for the SOCKS listener to actually accept connections before
# switching XRay traffic to it.
socks_ready=0
for _ in $(seq 1 20); do
  if ss -tln 2>/dev/null | grep -qE ":${WARP_PROXY_PORT}[[:space:]]"; then
    socks_ready=1
    break
  fi
  sleep 0.5
done
if (( socks_ready == 0 )); then
  echo "ERROR: warp-cli is connected but 127.0.0.1:$WARP_PROXY_PORT is not listening"
  warp-cli disconnect 2>/dev/null || true
  exit 1
fi

backup=$(mktemp "${XRAY_CONFIG}.bak.XXXXXX")
cp "$XRAY_CONFIG" "$backup"

# Cleanup trap: if anything below bails out, restore config and disconnect warp.
cleanup_failed() {
  if [[ -f "$backup" ]]; then
    cp "$backup" "$XRAY_CONFIG" 2>/dev/null || true
    rm -f "$backup"
  fi
  warp-cli disconnect 2>/dev/null || true
}
trap 'cleanup_failed' ERR INT TERM

yq eval 'del(.outbounds[] | select(.tag == "warp"))' -i "$XRAY_CONFIG"
yq eval \
  '.outbounds += {"tag": "warp","protocol": "socks","settings": {"servers": [{"address": "127.0.0.1","port": 40000}]}}' \
  -i "$XRAY_CONFIG"

# Catch-all (chain-vps1 or direct) → warp
yq eval \
  '(.routing.rules[] | select(.inboundTag != null)).outboundTag = "warp"' \
  -i "$XRAY_CONFIG"

# Readback uses -r so scalars come back unquoted (yq v4 on .json input
# otherwise emits "warp" with literal quotes and the compare below fails).
patched=$(yq -r eval '.routing.rules[] | select(.inboundTag != null) | .outboundTag' "$XRAY_CONFIG")
if [[ "$patched" != "warp" ]]; then
  echo "XRay config patch did not apply correctly, rolling back"
  cp "$backup" "$XRAY_CONFIG"
  warp-cli disconnect 2>/dev/null || true
  rm -f "$backup"
  trap - ERR INT TERM
  exit 1
fi

if ! docker compose -f "$COMPOSE_FILE" restart; then
  echo "Docker restart failed, rolling back XRay config"
  cp "$backup" "$XRAY_CONFIG"
  docker compose -f "$COMPOSE_FILE" restart 2>/dev/null || true
  warp-cli disconnect 2>/dev/null || true
  rm -f "$backup"
  trap - ERR INT TERM
  exit 1
fi

trap - ERR INT TERM
rm -f "$backup"
echo "WARP enabled as catch-all outbound (replaces chain-vps1)"
ENABLEWARP_EOF
chmod +x /usr/local/bin/enable-warp.sh

# ---------------------------------------------------------------------------
# Install disable-warp.sh helper (revert to chain-vps1 catch-all)
# ---------------------------------------------------------------------------
cat > /usr/local/bin/disable-warp.sh << 'DISABLEWARP_EOF'
#!/bin/bash
set -Eeuo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

XRAY_CONFIG="/opt/xray-vps-setup/node/xray_config.json"
COMPOSE_FILE="/opt/xray-vps-setup/docker-compose.yml"

if [[ $EUID -ne 0 ]]; then
  echo "Must be run as root"
  exit 1
fi

backup=$(mktemp "${XRAY_CONFIG}.bak.XXXXXX")
cp "$XRAY_CONFIG" "$backup"

# Cleanup trap: restore config on any failure (including Ctrl-C).
cleanup_failed() {
  if [[ -f "$backup" ]]; then
    cp "$backup" "$XRAY_CONFIG" 2>/dev/null || true
    rm -f "$backup"
  fi
}
trap 'cleanup_failed' ERR INT TERM

# Revert catch-all: warp → chain-vps1
yq eval \
  '(.routing.rules[] | select(.inboundTag != null) | select(.outboundTag == "warp")).outboundTag = "chain-vps1"' \
  -i "$XRAY_CONFIG"

# Remove warp outbound
yq eval 'del(.outbounds[] | select(.tag == "warp"))' -i "$XRAY_CONFIG"

if ! docker compose -f "$COMPOSE_FILE" restart; then
  echo "Docker restart failed, rolling back XRay config"
  cp "$backup" "$XRAY_CONFIG"
  docker compose -f "$COMPOSE_FILE" restart 2>/dev/null || true
  rm -f "$backup"
  trap - ERR INT TERM
  exit 1
fi

trap - ERR INT TERM
rm -f "$backup"

# Disconnect only — keep registration so re-enable is fast.
# Use `warp-cli registration delete` manually if you want a full teardown.
if command -v warp-cli >/dev/null 2>&1; then
  warp-cli disconnect 2>/dev/null || true
fi

echo "WARP disabled, catch-all reverted to chain-vps1"
DISABLEWARP_EOF
chmod +x /usr/local/bin/disable-warp.sh

# ---------------------------------------------------------------------------
# Create route files for exclude-list routing (preserve existing on rerun)
# ---------------------------------------------------------------------------
mkdir -p /opt/xray-vps-setup/routes
if [[ ! -f /opt/xray-vps-setup/routes/domains.txt ]]; then
  cat > /opt/xray-vps-setup/routes/domains.txt << 'ROUTES_EOF'
# Domains that MUST exit directly from VPS2 (Russian IP)
# Everything NOT listed here is forwarded through VPS1 (Germany).
# One per line. Subdomains included automatically.
# Supported formats:
#   yandex.ru            — matches yandex.ru and *.yandex.ru
#   full:exact.ru        — exact match only
#   regexp:.*\.example$  — regex pattern
#   geosite:category-ru  — from geosite.dat
#
# Example:
# yandex.ru
# vk.com
# gosuslugi.ru
# sberbank.ru
ROUTES_EOF
fi

if [[ ! -f /opt/xray-vps-setup/routes/ips.txt ]]; then
  cat > /opt/xray-vps-setup/routes/ips.txt << 'ROUTES_EOF'
# IPs/CIDRs that MUST exit directly from VPS2 (Russian IP)
# Everything NOT listed here is forwarded through VPS1 (Germany).
# One per line.
# Supported formats:
#   1.2.3.4              — single IP
#   5.6.7.0/24           — CIDR range
#   geoip:ru             — country from geoip.dat
#
# Example:
# geoip:ru
# 77.88.8.0/24
ROUTES_EOF
fi

# ---------------------------------------------------------------------------
# Install apply-routes script (atomic write of xray_config.json)
# ---------------------------------------------------------------------------
cat > /usr/local/bin/apply-routes.sh << 'APPLYSCRIPT_EOF'
#!/bin/bash
set -Eeuo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ROUTES_DIR="/opt/xray-vps-setup/routes"
XRAY_CONFIG="/opt/xray-vps-setup/node/xray_config.json"

if [ ! -f "$XRAY_CONFIG" ]; then
  echo "Error: $XRAY_CONFIG not found"
  exit 1
fi

# Python writes to a sibling temp file, we rename on success.
CONFIG_TMP=$(mktemp "${XRAY_CONFIG}.XXXXXX")
trap 'rm -f "$CONFIG_TMP"' EXIT

python3 - "$XRAY_CONFIG" "$CONFIG_TMP" "$ROUTES_DIR" << 'PYEOF'
import json, os, sys

config_path, tmp_path, routes_dir = sys.argv[1], sys.argv[2], sys.argv[3]

def read_list(filepath):
    if not os.path.exists(filepath):
        return []
    with open(filepath) as f:
        return [l.strip() for l in f if l.strip() and not l.startswith('#')]

def format_domains(raw):
    prefixes = ('geosite:', 'regexp:', 'full:', 'domain:', 'ext:')
    return [d if any(d.startswith(p) for p in prefixes) else 'domain:' + d for d in raw]

domains = read_list(os.path.join(routes_dir, "domains.txt"))
ips = read_list(os.path.join(routes_dir, "ips.txt"))

with open(config_path) as f:
    config = json.load(f)

# Detect current catch-all outbound (chain-vps1 or warp).
# Preserves WARP choice across reruns: if WARP is enabled, the catch-all
# was patched to "warp" and we keep it.
catchall_tag = "chain-vps1"
for rule in config.get('routing', {}).get('rules', []):
    if 'inboundTag' in rule:
        catchall_tag = rule.get('outboundTag', 'chain-vps1')
        break

# Inverted routing:
#   listed domains/IPs -> direct (exit from VPS2 with Russian IP)
#   everything else    -> chain-vps1 (forwarded through VPS1 Germany)
rules = [{"protocol": "bittorrent", "outboundTag": "block"}]
if domains:
    rules.append({"domain": format_domains(domains), "outboundTag": "direct"})
if ips:
    rules.append({"ip": ips, "outboundTag": "direct"})
rules.append({"ip": ["geoip:private"], "outboundTag": "direct"})
rules.append({"inboundTag": ["reality-tcp", "xhttp-in"], "outboundTag": catchall_tag})

config['routing']['rules'] = rules

with open(tmp_path, 'w') as f:
    json.dump(config, f, indent=2)

print(f"Routes: {len(domains)} domains, {len(ips)} IPs -> direct (Russia)")
print(f"Catch-all outbound: {catchall_tag}")
PYEOF

# Validate JSON before swap
python3 -c "import json; json.load(open('$CONFIG_TMP'))"
chmod 600 "$CONFIG_TMP"

# Keep a backup of the live config so we can roll back if marzban fails
# to restart with the new routes. Sibling file — same filesystem, so
# mv is truly atomic.
backup=$(mktemp "${XRAY_CONFIG}.bak.XXXXXX")
cp -a "$XRAY_CONFIG" "$backup"

mv -f "$CONFIG_TMP" "$XRAY_CONFIG"
trap - EXIT

if ! docker compose -f /opt/xray-vps-setup/docker-compose.yml restart marzban; then
  echo "ERROR: marzban restart failed — rolling back xray_config.json"
  mv -f "$backup" "$XRAY_CONFIG"
  docker compose -f /opt/xray-vps-setup/docker-compose.yml restart marzban || true
  exit 1
fi

rm -f "$backup"
echo "XRay restarted with updated routes"
APPLYSCRIPT_EOF
chmod +x /usr/local/bin/apply-routes.sh

# ---------------------------------------------------------------------------
# Create update-geodata.sh helper
# ---------------------------------------------------------------------------
cat > /usr/local/bin/update-geodata.sh << 'GEODATA_EOF'
#!/bin/bash
set -Eeuo pipefail
XRAY_DIR="/opt/xray-vps-setup/node/xray-core"
mkdir -p "$XRAY_DIR"

# Stage into sibling temp files inside $XRAY_DIR so mv is a true atomic
# rename — /tmp can be on a different filesystem on Ubuntu 24.04.
geosite_tmp=$(mktemp "$XRAY_DIR/geosite.dat.XXXXXX")
geoip_tmp=$(mktemp "$XRAY_DIR/geoip.dat.XXXXXX")
trap 'rm -f "$geosite_tmp" "$geoip_tmp"' EXIT

echo "Downloading latest geosite.dat..."
wget -4 --tries=3 --timeout=20 --retry-connrefused -qO "$geosite_tmp" \
  https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
[[ -s "$geosite_tmp" ]] || { echo "ERROR: geosite.dat download failed"; exit 1; }

echo "Downloading latest geoip.dat..."
wget -4 --tries=3 --timeout=20 --retry-connrefused -qO "$geoip_tmp" \
  https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
[[ -s "$geoip_tmp" ]] || { echo "ERROR: geoip.dat download failed"; exit 1; }

mv -f "$geosite_tmp" "$XRAY_DIR/geosite.dat"
mv -f "$geoip_tmp" "$XRAY_DIR/geoip.dat"
trap - EXIT

docker compose -f /opt/xray-vps-setup/docker-compose.yml restart marzban
echo "geodata updated, XRay restarted"
GEODATA_EOF
chmod +x /usr/local/bin/update-geodata.sh

# Schedule weekly geodata update (Monday 4:00 AM) — safe on nodes without crontab
({ crontab -l 2>/dev/null || true; } | grep -v 'update-geodata' || true; echo "0 4 * * 1 /usr/local/bin/update-geodata.sh >/dev/null 2>&1") | crontab -

# Cleanup temp files
rm -f /tmp/panel_hosts.json /tmp/panel_hosts_updated.json /tmp/xray.zip

# ---------------------------------------------------------------------------
# Credentials — write sensitive values to a root-only file, echo only a
# short summary to the console (works for cloud-init / ansible runs).
# ---------------------------------------------------------------------------
CRED_FILE="/opt/xray-vps-setup/credentials.txt"
VPS2_IP=$(hostname -I | awk '{print $1}')

{
  echo "# setup-vps2.sh credentials — generated at $(date -Iseconds)"
  echo "# Keep this file 0600."
  echo ""
  echo "VPS2_IP=$VPS2_IP"
  echo "VLESS_DOMAIN=$VLESS_DOMAIN"
  echo ""
  echo "MARZBAN_PANEL_URL=http://localhost:8000/$MARZBAN_PATH"
  echo "MARZBAN_USER=$MARZBAN_USER"
  echo "MARZBAN_PASS=$MARZBAN_PASS"
  echo ""
  echo "VPS1_IP=$VPS1_IP"
  echo "VPS1_DOMAIN=$VPS1_DOMAIN"
  echo ""
  if [[ ${configure_ssh_input,,} == "y" ]]; then
    echo "SSH_USER=$SSH_USER"
    echo "SSH_USER_PASS=$SSH_USER_PASS"
    echo "SSH_PORT=$SSH_PORT"
  fi
} > "$CRED_FILE"
chmod 600 "$CRED_FILE"

echo ""
echo "========================================="
echo " setup-vps2.sh completed successfully"
echo "========================================="
echo " Credentials saved to: $CRED_FILE (chmod 600)"
echo " Log file:             $LOG_FILE"
echo ""
echo " VPS2 Marzban Panel: http://localhost:8000/$MARZBAN_PATH"
if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo "   ssh -p $SSH_PORT -L 8000:localhost:8000 $SSH_USER@$VPS2_IP"
else
  echo "   ssh -L 8000:localhost:8000 root@$VPS2_IP"
fi
echo ""
echo " === Routing ==="
echo " By default all traffic is forwarded through VPS1 (Germany)."
echo " To pin specific sites to VPS2 direct exit (Russian IP):"
echo "   1. Edit /opt/xray-vps-setup/routes/domains.txt"
echo "   2. Edit /opt/xray-vps-setup/routes/ips.txt"
echo "   3. Run: apply-routes.sh"
echo ""
echo " === Security ==="
echo " fail2ban: active (sshd jail, backend=systemd)"
echo "   bantime=1h, findtime=10m, maxretry=5"
echo "   fail2ban-client status sshd"
echo "   fail2ban-client unban <ip>"
if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
  echo ""
  echo " NOTE: both port $SSH_PORT (new) and $CURRENT_SSH_PORT (old) are open."
  echo "       After verifying the new port works, remove the old rule:"
  echo "         iptables -D INPUT -p tcp -m state --state NEW -m tcp --dport $CURRENT_SSH_PORT -j ACCEPT"
  echo "         netfilter-persistent save"
fi
echo ""
echo " === WARP (optional) ==="
echo " To forward catch-all traffic via Cloudflare WARP (instead of VPS1):"
echo "   enable-warp.sh    # install + enable"
echo "   disable-warp.sh   # revert to VPS1 catch-all"
echo ""
echo " === Geodata ==="
echo " Auto-update: weekly (Mon 4:00 AM)"
echo " Manual: update-geodata.sh"
echo ""
echo " === Next steps ==="
echo " 1. Connect via SSH tunnel and open Marzban panel"
echo " 2. Add domains/IPs to route files and run apply-routes.sh"
echo " 3. Create users and copy VLESS links to distribute"
echo "========================================="
