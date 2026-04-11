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
LOG_FILE="/var/log/setup-vps1-$(date +%Y%m%d-%H%M%S).log"
mkdir -p /var/log
: > "$LOG_FILE"
chmod 600 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1
echo "=== setup-vps1.sh started at $(date -Iseconds) ==="
echo "=== full log: $LOG_FILE ==="

# ---------------------------------------------------------------------------
# trap ERR — report the failing line, keep partial state for debugging.
# ---------------------------------------------------------------------------
on_error() {
  local exit_code=$?
  local line_no=${1:-?}
  echo ""
  echo "=========================================="
  echo " ERROR: setup-vps1.sh failed at line $line_no (exit $exit_code)"
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
  sudo idn dnsutils wamerican zip unzip python3 wget curl openssl gettext

export GIT_BRANCH="main"
export GIT_REPO="patronJS/mytests"
export XRAY_VERSION="v26.3.27"
# Pinned versions: yq=v4.52.5, marzban=latest
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
read -ep "Enter VPS1 domain:"$'\n' input_domain
while [[ -z "${input_domain// }" ]]; do
  read -ep "Domain cannot be empty. Enter VPS1 domain:"$'\n' input_domain
done

VPS1_DOMAIN=$(echo "$input_domain" | idn)
[[ -n "$VPS1_DOMAIN" ]] || { echo "ERROR: idn returned empty domain"; exit 1; }
export VPS1_DOMAIN
export VLESS_DOMAIN="$VPS1_DOMAIN"

read -ra SERVER_IPS <<< "$(hostname -I)"

RESOLVED_IP=$(dig +short "$VPS1_DOMAIN" | tail -n1)

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
# Optional SSH hardening prompts
# ---------------------------------------------------------------------------
read -ep "Do you want to harden SSH? [y/N] "$'\n' configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  read -ep "Enter SSH port. Default 22, can't use ports: 80, 443, 4123, 49321:"$'\n' input_ssh_port

  while ! [[ "$input_ssh_port" =~ ^[0-9]+$ ]] || (( input_ssh_port < 1 || input_ssh_port > 65535 )) || [[ "$input_ssh_port" -eq 80 || "$input_ssh_port" -eq 443 || "$input_ssh_port" -eq 4123 || "$input_ssh_port" -eq 49321 ]]; do
    read -ep "Invalid or reserved port ($input_ssh_port). Use 1-65535, not 80/443/4123/49321:"$'\n' input_ssh_port
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
# Install yq — pinned version + SHA256 verification
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
  # column. This is pinned to YQ_VERSION, so it's stable across reruns as long
  # as we don't bump YQ_VERSION without re-verifying.
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
# Secrets persistence — reuse on rerun so existing clients/cascade don't break.
# flock on a separate lock file serializes concurrent invocations so two
# parallel runs can't race on the secrets file.
# ---------------------------------------------------------------------------
mkdir -p /opt/xray-vps-setup/marzban
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
  UUID_LINK=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} uuid)
  [[ -n "$UUID_LINK" ]] || { echo "ERROR: xray uuid generation failed"; exit 1; }

  XHTTP_PATH=$(openssl rand -hex 12)
  SID1=$(openssl rand -hex 2)
  SID2=$(openssl rand -hex 4)
  SID3=$(openssl rand -hex 6)
  SID4=$(openssl rand -hex 8)
  # shellcheck disable=SC2089
  SHORT_IDS="\"$SID1\",\"$SID2\",\"$SID3\",\"$SID4\""
  SHORT_ID=$SID4

  MARZBAN_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words 2>/dev/null | shuf -n 1 || true)
  [[ -n "$MARZBAN_USER" ]] || MARZBAN_USER="adm$(openssl rand -hex 3)"
  MARZBAN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13)
  MARZBAN_PATH=$(openssl rand -hex 8)
  MARZBAN_SUB_PATH=$(openssl rand -hex 8)

  # Atomic write: stage into a temp file next to the target, chmod 600,
  # then rename into place. Prevents half-written state on ^C / crash.
  secrets_tmp=$(mktemp "${SECRETS_FILE}.XXXXXX")
  chmod 600 "$secrets_tmp"
  cat > "$secrets_tmp" << SECRETS_EOF
export XRAY_PIK="$XRAY_PIK"
export XRAY_PBK="$XRAY_PBK"
export UUID_LINK="$UUID_LINK"
export XHTTP_PATH="$XHTTP_PATH"
export SID1="$SID1"
export SID2="$SID2"
export SID3="$SID3"
export SID4="$SID4"
export SHORT_IDS='$SHORT_IDS'
export SHORT_ID="$SHORT_ID"
export MARZBAN_USER="$MARZBAN_USER"
export MARZBAN_PASS="$MARZBAN_PASS"
export MARZBAN_PATH="$MARZBAN_PATH"
export MARZBAN_SUB_PATH="$MARZBAN_SUB_PATH"
SECRETS_EOF
  mv -f "$secrets_tmp" "$SECRETS_FILE"
fi
# Release the lock now that we've either sourced or written a valid state.
exec 9>&-

# Post-source validation: fail loud if .secrets.env is incomplete/corrupted.
for _v in XRAY_PIK XRAY_PBK UUID_LINK XHTTP_PATH SID1 SID2 SID3 SID4 SHORT_IDS \
          SHORT_ID MARZBAN_USER MARZBAN_PASS MARZBAN_PATH MARZBAN_SUB_PATH; do
  if [[ -z "${!_v:-}" ]]; then
    echo "ERROR: secret $_v is empty — $SECRETS_FILE is corrupted."
    echo "       Back it up and rerun: mv $SECRETS_FILE ${SECRETS_FILE}.bad"
    exit 1
  fi
done
unset _v
# shellcheck disable=SC2090
export XRAY_PIK XRAY_PBK UUID_LINK XHTTP_PATH SID1 SID2 SID3 SID4 SHORT_IDS SHORT_ID
export MARZBAN_USER MARZBAN_PASS MARZBAN_PATH MARZBAN_SUB_PATH

# ---------------------------------------------------------------------------
# Download XRay core (with retry and staged write)
# ---------------------------------------------------------------------------
mkdir -p /opt/xray-vps-setup/marzban/xray-core
rm -f /tmp/xray.zip
if [[ "$ARCH" == "amd64" ]]; then
  XRAY_ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip"
else
  XRAY_ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-arm64-v8a.zip"
fi
retry_cmd 3 5 -- net_wget -O /tmp/xray.zip "$XRAY_ZIP_URL"
[[ -s /tmp/xray.zip ]] || { echo "ERROR: xray zip download failed or empty"; exit 1; }
unzip -qo /tmp/xray.zip -d /opt/xray-vps-setup/marzban/xray-core

# Download latest geodata (geosite.dat from XRay release may be outdated)
# Stage into tmp first so a partial download never clobbers a working file.
echo "Downloading latest geosite.dat and geoip.dat..."
retry_cmd 3 5 -- net_wget -qO /tmp/geosite.dat \
  https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
[[ -s /tmp/geosite.dat ]] || { echo "ERROR: geosite.dat download failed"; exit 1; }
retry_cmd 3 5 -- net_wget -qO /tmp/geoip.dat \
  https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
[[ -s /tmp/geoip.dat ]] || { echo "ERROR: geoip.dat download failed"; exit 1; }
mv -f /tmp/geosite.dat /opt/xray-vps-setup/marzban/xray-core/geosite.dat
mv -f /tmp/geoip.dat /opt/xray-vps-setup/marzban/xray-core/geoip.dat

# ---------------------------------------------------------------------------
# Download and envsubst templates — with explicit variable whitelists and
# atomic writes (stage via mktemp, then rename).
# ---------------------------------------------------------------------------
cd /opt/xray-vps-setup

fetch_template "panel-xray" \
  | envsubst '$UUID_LINK $XHTTP_PATH $SHORT_IDS $XRAY_PIK $XRAY_PBK $VPS1_DOMAIN' \
  | atomic_write ./marzban/xray_config.json

fetch_template "compose-panel" \
  | envsubst '$XRAY_VERSION' \
  | atomic_write ./docker-compose.yml

fetch_template "marzban" \
  | envsubst '$MARZBAN_USER $MARZBAN_PASS $MARZBAN_PATH $MARZBAN_SUB_PATH' \
  | atomic_write ./marzban/.env

fetch_template "panel-angie" \
  | envsubst '$VPS1_DOMAIN' \
  | atomic_write ./angie.conf

fetch_template "confluence" \
  | envsubst '$VPS1_DOMAIN $VLESS_DOMAIN' \
  | atomic_write ./index.html

# Validate JSON — break early if template substitution produced junk
if command -v python3 >/dev/null 2>&1; then
  python3 -c "import json,sys; json.load(open('/opt/xray-vps-setup/marzban/xray_config.json'))" || {
    echo "ERROR: xray_config.json is not valid JSON after envsubst"
    exit 1
  }
fi

# File permissions
chmod 600 ./marzban/xray_config.json ./marzban/.env
chmod 644 ./docker-compose.yml
chmod 644 ./angie.conf ./index.html

# ---------------------------------------------------------------------------
# Port preflight — fail early if something else holds any of the ports we
# need. Excludes our own stack (angie / marzban / xray / uvicorn) so reruns
# don't self-trip. Checks both wildcard and loopback binds.
# ---------------------------------------------------------------------------
port_in_use_by_other() {
  local spec=$1
  local ss_out
  ss_out=$(ss -Htlnp "$spec" 2>/dev/null || true)
  [[ -z "$ss_out" ]] && return 1
  # network_mode: host — our containers show up as their real process names
  if echo "$ss_out" | grep -Eq 'docker-proxy|"(angie|nginx|xray|marzban|uvicorn|python3?)"'; then
    return 1
  fi
  echo "  $spec is held by: $ss_out"
  return 0
}

# Wildcard-bound ports (xray/angie on network_mode: host)
for p in 80 49321; do
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
# Open port 80 for ACME before starting Angie
# (iptables default policy is still ACCEPT at this point)
# ---------------------------------------------------------------------------
iptables -C INPUT -p tcp -m tcp --dport 80 -j ACCEPT 2>/dev/null || \
  iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT

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
# Install iptables-persistent + fail2ban
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
# This prevents lockout if the sshd_config change fails to take effect — the
# operator can still reach the box over the old port and fix things.
iptables_add INPUT -p tcp -m state --state NEW -m tcp --dport "$SSH_PORT" -j ACCEPT
if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
  iptables_add INPUT -p tcp -m state --state NEW -m tcp --dport "$CURRENT_SSH_PORT" -j ACCEPT
fi
iptables_add INPUT -p tcp -m tcp --dport 49321 -j ACCEPT
iptables_add INPUT -p tcp -m tcp --dport 80 -j ACCEPT
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
# Persist SSH state across reruns to avoid creating a new privileged user
# on every invocation.
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
    SSH_USER="op$(tr -dc 'a-z0-9' </dev/urandom | head -c 6)"
  fi
  SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13)

  # Atomic write — same pattern as .secrets.env
  ssh_state_tmp=$(mktemp "${SSH_STATE_FILE}.XXXXXX")
  chmod 600 "$ssh_state_tmp"
  cat > "$ssh_state_tmp" << SSH_STATE_EOF
export SSH_USER="$SSH_USER"
export SSH_USER_PASS="$SSH_USER_PASS"
SSH_STATE_EOF
  mv -f "$ssh_state_tmp" "$SSH_STATE_FILE"
fi
exec 8>&-

# Post-source validation — abort if state file is corrupted / truncated
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

  # Unified rollback — safe to call multiple times. Restores drop-in file and
  # reverses any ssh.socket -> ssh.service transition that may have started.
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

  # Write new drop-in
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
  # ssh.service so our new port actually takes effect. Any failure from here
  # until smoke-test triggers full rollback.
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
# Create update-geodata.sh helper
# ---------------------------------------------------------------------------
cat > /usr/local/bin/update-geodata.sh << 'GEODATA_EOF'
#!/bin/bash
set -euo pipefail
XRAY_DIR="/opt/xray-vps-setup/marzban/xray-core"

echo "Downloading latest geosite.dat..."
wget -4 --tries=3 --timeout=20 -qO /tmp/geosite.dat \
  https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
[[ -s /tmp/geosite.dat ]] || { echo "ERROR: geosite.dat download failed"; exit 1; }

echo "Downloading latest geoip.dat..."
wget -4 --tries=3 --timeout=20 -qO /tmp/geoip.dat \
  https://github.com/v2fly/geoip/releases/latest/download/geoip.dat
[[ -s /tmp/geoip.dat ]] || { echo "ERROR: geoip.dat download failed"; exit 1; }

mv -f /tmp/geosite.dat "$XRAY_DIR/geosite.dat"
mv -f /tmp/geoip.dat "$XRAY_DIR/geoip.dat"

docker compose -f /opt/xray-vps-setup/docker-compose.yml restart marzban
echo "geodata updated, XRay restarted"
GEODATA_EOF
chmod +x /usr/local/bin/update-geodata.sh

# Schedule weekly geodata update (Monday 4:00 AM) — safe on nodes without crontab
({ crontab -l 2>/dev/null || true; } | grep -v 'update-geodata' || true; echo "0 4 * * 1 /usr/local/bin/update-geodata.sh >/dev/null 2>&1") | crontab -

# Cleanup temp files
rm -f /tmp/xray.zip

# ---------------------------------------------------------------------------
# Credentials — write sensitive values to a root-only file, echo only a
# short summary to the console (works for cloud-init / ansible runs).
# ---------------------------------------------------------------------------
CRED_FILE="/opt/xray-vps-setup/credentials.txt"
VPS1_IP=$(hostname -I | awk '{print $1}')

{
  echo "# setup-vps1.sh credentials — generated at $(date -Iseconds)"
  echo "# Keep this file 0600. Use values for setup-vps2.sh on the entry node."
  echo ""
  echo "VPS1_IP=$VPS1_IP"
  echo "VPS1_DOMAIN=$VPS1_DOMAIN"
  echo "VPS1_PBK=$XRAY_PBK"
  echo "VPS1_SHORT_ID=$SHORT_ID"
  echo "UUID_LINK=$UUID_LINK"
  echo "XHTTP_PATH=$XHTTP_PATH"
  echo ""
  echo "MARZBAN_PANEL_URL=http://localhost:8000/$MARZBAN_PATH"
  echo "MARZBAN_USER=$MARZBAN_USER"
  echo "MARZBAN_PASS=$MARZBAN_PASS"
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
echo " setup-vps1.sh completed successfully"
echo "========================================="
echo " Credentials saved to: $CRED_FILE (chmod 600)"
echo " Log file:             $LOG_FILE"
echo ""
echo " Marzban Panel: http://localhost:8000/$MARZBAN_PATH"
if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo "   ssh -p $SSH_PORT -L 8000:localhost:8000 $SSH_USER@$VPS1_IP"
else
  echo "   ssh -L 8000:localhost:8000 root@$VPS1_IP"
fi
echo ""
echo " === Values for setup-vps2.sh ==="
echo " VPS1_IP:         $VPS1_IP"
echo " VPS1_PBK:        $XRAY_PBK"
echo " VPS1_SHORT_ID:   $SHORT_ID"
echo " UUID_LINK:       $UUID_LINK"
echo " XHTTP_PATH:      $XHTTP_PATH"
echo " VPS1_DOMAIN:     $VPS1_DOMAIN"
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
echo " === Geodata ==="
echo " Auto-update: weekly (Mon 4:00 AM)"
echo " Manual: update-geodata.sh"
echo "========================================="
