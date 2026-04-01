#!/bin/bash

set -euo pipefail

# --add-wg-peer mode: add WG tunnel peer and exit
if [[ "${1:-}" == "--add-wg-peer" ]]; then
  WG_PBK="${2:-}"
  VPS2_IP="${3:-}"
  if [[ -z "$WG_PBK" || -z "$VPS2_IP" ]]; then
    echo "Usage: setup-panel.sh --add-wg-peer <VPS2_WG_PUBLIC_KEY> <VPS2_IP>"
    exit 1
  fi
  # Remove commented placeholder AND any existing [Peer] section (idempotent)
  sed -i '/^# \[Peer\]/,/^# Endpoint/d' /etc/wireguard/wg-tunnel.conf
  sed -i '/^\[Peer\]/,/^$/d' /etc/wireguard/wg-tunnel.conf
  cat >> /etc/wireguard/wg-tunnel.conf << EOF

[Peer]
PublicKey = $WG_PBK
AllowedIPs = 10.8.0.0/24, 10.9.0.2/32
Endpoint = $VPS2_IP:51830
EOF
  systemctl restart wg-quick@wg-tunnel
  echo "WG tunnel peer added. Testing connectivity..."
  ping -c 3 10.9.0.2 || echo "Warning: ping failed — VPS2 tunnel may not be up yet"
  exit 0
fi

# Check if script started as root
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Disable IPv6 early — prevents wget/apt hangs on dual-stack hosts
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null

# Install dependencies
apt-get update
apt-get install idn sudo dnsutils wamerican wireguard-tools zip unzip python3 wget curl openssl gettext -y

export GIT_BRANCH="main"
export GIT_REPO="patronJS/mytests"
export XRAY_VERSION="v26.3.23"
TEMPLATE_URL="https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script"

fetch_template() {
  local content
  content=$(wget -qO- "$TEMPLATE_URL/$1") || { echo "Failed to download template: $1"; exit 1; }
  [ -n "$content" ] || { echo "Template is empty: $1"; exit 1; }
  echo "$content"
}

# Read domain input
read -ep "Enter your domain:"$'\n' input_domain

export VLESS_DOMAIN=$(echo "$input_domain" | idn)

SERVER_IPS=($(hostname -I))

RESOLVED_IP=$(dig +short $VLESS_DOMAIN | tail -n1)

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
    echo "✓ DNS record points to this server ($RESOLVED_IP)"
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

# Install Docker
docker_install() {
  curl -fsSL https://get.docker.com | sh
}

if ! command -v docker 2>&1 >/dev/null; then
    docker_install
fi

# Install yq
export ARCH=$(dpkg --print-architecture)

YQ_VERSION="v4.52.5"
yq_install() {
  wget -q "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH" -O /usr/bin/yq
  wget -qO /tmp/yq_checksums "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/checksums"
  YQ_SHA256=$(grep "yq_linux_$ARCH " /tmp/yq_checksums | awk '{print $19}')
  echo "$YQ_SHA256  /usr/bin/yq" | sha256sum -c - || { echo "yq checksum verification failed"; rm -f /usr/bin/yq; exit 1; }
  chmod +x /usr/bin/yq
  rm -f /tmp/yq_checksums
}

yq_install

# Check congestion protocol and enable ip_forward
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.default.disable_ipv6=1" >> /etc/sysctl.conf
sysctl -p > /dev/null

# Generate secrets
export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core x25519 | head -n1 | cut -d' ' -f 2)
export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core x25519 -i $XRAY_PIK | tail -2 | head -1 | cut -d' ' -f 2)
export UUID_LINK=$(docker run --rm ghcr.io/xtls/xray-core uuid)
export XHTTP_PATH=$(openssl rand -hex 12)
export SID1=$(openssl rand -hex 2)
export SID2=$(openssl rand -hex 4)
export SID3=$(openssl rand -hex 6)
export SID4=$(openssl rand -hex 8)
export SHORT_IDS="\"$SID1\",\"$SID2\",\"$SID3\",\"$SID4\""
export SHORT_ID=$SID4
export MARZBAN_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export MARZBAN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export MARZBAN_PATH=$(openssl rand -hex 8)
export MARZBAN_SUB_PATH=$(openssl rand -hex 8)
export WG_TUNNEL_PIK=$(wg genkey)
export WG_TUNNEL_PBK=$(echo $WG_TUNNEL_PIK | wg pubkey)

# Download XRay core
mkdir -p /opt/xray-vps-setup/marzban/xray-core
if [[ "$ARCH" == "amd64" ]]; then
  wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip
elif [[ "$ARCH" == "arm64" ]]; then
  wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-arm64-v8a.zip
fi
unzip -qo /tmp/xray.zip -d /opt/xray-vps-setup/marzban/xray-core

# Download and envsubst templates
mkdir -p /opt/xray-vps-setup/marzban
cd /opt/xray-vps-setup
fetch_template "panel-xray" | envsubst > ./marzban/xray_config.json
fetch_template "panel-angie" | envsubst '$VLESS_DOMAIN $MARZBAN_PATH $MARZBAN_SUB_PATH' > ./angie.conf
fetch_template "compose-panel" | envsubst > ./docker-compose.yml
fetch_template "marzban" | envsubst > ./marzban/.env
fetch_template "confluence" | envsubst > ./index.html

# File permissions
chmod 600 ./marzban/xray_config.json ./marzban/.env
chmod 644 ./angie.conf ./index.html ./docker-compose.yml

# Detect default network interface
export DEFAULT_IFACE=$(ip route show default | awk '{print $5}' | head -1)
if [[ -z "$DEFAULT_IFACE" ]]; then
  echo "Could not detect default network interface"
  exit 1
fi

# WireGuard tunnel config
mkdir -p /etc/wireguard
fetch_template "wg-tunnel-panel" | envsubst '$WG_TUNNEL_PIK $DEFAULT_IFACE' > /etc/wireguard/wg-tunnel.conf
chmod 600 /etc/wireguard/wg-tunnel.conf
systemctl enable wg-quick@wg-tunnel

# Start containers
docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d

# Marzban init — wait until API is ready (up to 60s)
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

# Update panel default host
echo "Updating panel default host with domain $VLESS_DOMAIN..."
PANEL_TOKEN=$(curl -sf -X POST "https://$VLESS_DOMAIN/api/admin/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "username=$MARZBAN_USER" \
  --data-urlencode "password=$MARZBAN_PASS" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" || echo "")
if [[ -n "$PANEL_TOKEN" && "$PANEL_TOKEN" != "null" ]]; then
  PHOSTS_HTTP=$(curl -s -o /tmp/panel_hosts.json -w "%{http_code}" \
    "https://$VLESS_DOMAIN/api/hosts" \
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
    curl -s -o /dev/null \
      -X PUT "https://$VLESS_DOMAIN/api/hosts" \
      -H "Authorization: Bearer $PANEL_TOKEN" \
      -H "Content-Type: application/json" \
      -d @/tmp/panel_hosts_updated.json || true
    echo "Panel host updated."
  else
    echo "Warning: could not fetch panel hosts (HTTP $PHOSTS_HTTP) - update address/SNI manually"
  fi
else
  echo "Warning: could not authenticate to panel API - update default host address/SNI to $VLESS_DOMAIN manually"
fi

# Configure iptables
export SSH_PORT=$(ss -tlnp | grep sshd | grep -Po '(?<=:)\d+(?= )' | head -n 1)
SSH_PORT=${SSH_PORT:-22}

debconf-set-selections <<EOF
iptables-persistent iptables-persistent/autosave_v4 boolean true
iptables-persistent iptables-persistent/autosave_v6 boolean true
EOF
apt-get install iptables-persistent netfilter-persistent -y

iptables_add() {
  iptables -C "$@" 2>/dev/null || iptables -A "$@"
}

iptables_add INPUT -p icmp -j ACCEPT
iptables_add INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables_add INPUT -p tcp -m state --state NEW -m tcp --dport $SSH_PORT -j ACCEPT
iptables_add INPUT -p tcp -m tcp --dport 80 -j ACCEPT
iptables_add INPUT -p tcp -m tcp --dport 443 -j ACCEPT
iptables_add INPUT -p udp -m udp --dport 51830 -j ACCEPT
iptables_add INPUT -i lo -j ACCEPT
iptables_add OUTPUT -o lo -j ACCEPT
iptables -P INPUT DROP
netfilter-persistent save

# Cleanup temp files
rm -f /tmp/panel_hosts.json /tmp/panel_hosts_updated.json /tmp/xray.zip

# Output
clear
echo "========================================="
echo " Panel URL: https://$VLESS_DOMAIN/$MARZBAN_PATH"
echo " Panel user: $MARZBAN_USER"
echo " Panel pass: $MARZBAN_PASS"
echo ""
echo " === Values for setup-node.sh ==="
echo " PANEL_PBK:      $XRAY_PBK"
echo " PANEL_SHORT_ID: $SHORT_ID (recommended for node outbound)"
echo " All shortIds:   $SID1, $SID2, $SID3, $SID4"
echo " UUID_LINK:      $UUID_LINK"
echo " XHTTP_PATH:     $XHTTP_PATH"
echo " WG_TUNNEL_PBK:  $WG_TUNNEL_PBK"
echo ""
echo " After setup-node.sh completes, run:"
echo " setup-panel.sh --add-wg-peer <VPS2_WG_PBK> <VPS2_IP>"
echo "========================================="
