#!/bin/bash

set -euo pipefail

# Check if script started as root
if [ "$EUID" -ne 0 ]
  then echo "Please run as root"
  exit
fi

# Disable IPv6 early — prevents wget/apt hangs on dual-stack hosts
sysctl -w net.ipv6.conf.all.disable_ipv6=1 > /dev/null
sysctl -w net.ipv6.conf.default.disable_ipv6=1 > /dev/null

# Force apt to use IPv4 only
echo 'Acquire::ForceIPv4 "true";' > /etc/apt/apt.conf.d/99force-ipv4

# Install dependencies
apt-get update
apt-get install sudo idn dnsutils wamerican zip unzip python3 wget curl openssl gettext -y

export GIT_BRANCH="main"
export GIT_REPO="patronJS/mytests"
export XRAY_VERSION="v26.3.27"
# Pinned versions: yq=v4.52.5, marzban=latest
TEMPLATE_URL="https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script"

fetch_template() {
  local content
  content=$(wget -4 -qO- "$TEMPLATE_URL/$1") || { echo "Failed to download template: $1"; exit 1; }
  [ -n "$content" ] || { echo "Template is empty: $1"; exit 1; }
  echo "$content"
}

# Read domain input
read -ep "Enter VPS1 domain:"$'\n' input_domain

export VPS1_DOMAIN=$(echo "$input_domain" | idn)
export VLESS_DOMAIN="$VPS1_DOMAIN"

SERVER_IPS=($(hostname -I))

RESOLVED_IP=$(dig +short $VPS1_DOMAIN | tail -n1)

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
  curl -4 -fsSL https://get.docker.com | sh
}

if ! command -v docker 2>&1 >/dev/null; then
    docker_install
fi
# Restart Docker to pick up disabled IPv6
systemctl restart docker

# Install yq
export ARCH=$(dpkg --print-architecture)

YQ_VERSION="v4.52.5"
yq_install() {
  wget -4 -q "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH" -O /usr/bin/yq
  wget -4 -qO /tmp/yq_checksums "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/checksums"
  YQ_SHA256=$(grep "yq_linux_$ARCH " /tmp/yq_checksums | awk '{print $19}')
  echo "$YQ_SHA256  /usr/bin/yq" | sha256sum -c - || { echo "yq checksum verification failed"; rm -f /usr/bin/yq; exit 1; }
  chmod +x /usr/bin/yq
  rm -f /tmp/yq_checksums
}

yq_install

# Check congestion protocol
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.default.disable_ipv6=1" >> /etc/sysctl.conf
sysctl -p > /dev/null

# Generate secrets
export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} x25519 | grep 'PrivateKey' | awk '{print $NF}')
export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} x25519 -i "$XRAY_PIK" | grep 'PublicKey' | awk '{print $NF}')
export UUID_LINK=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} uuid)
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

# Download XRay core
mkdir -p /opt/xray-vps-setup/marzban/xray-core
if [[ "$ARCH" == "amd64" ]]; then
  wget -4 -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip
elif [[ "$ARCH" == "arm64" ]]; then
  wget -4 -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-arm64-v8a.zip
fi
unzip -qo /tmp/xray.zip -d /opt/xray-vps-setup/marzban/xray-core

# Download and envsubst templates
mkdir -p /opt/xray-vps-setup/marzban
cd /opt/xray-vps-setup
fetch_template "panel-xray" | envsubst '$UUID_LINK $XHTTP_PATH $SHORT_IDS $XRAY_PIK $XRAY_PBK $VPS1_DOMAIN' > ./marzban/xray_config.json
fetch_template "compose-panel" | envsubst > ./docker-compose.yml
fetch_template "marzban" | envsubst > ./marzban/.env
fetch_template "panel-angie" | envsubst '$VPS1_DOMAIN' > ./angie.conf
fetch_template "confluence" | envsubst > ./index.html

# File permissions
chmod 600 ./marzban/xray_config.json ./marzban/.env
chmod 644 ./docker-compose.yml
chmod 644 ./angie.conf ./index.html

# Start containers
# Open port 80 for ACME before starting Angie
iptables -C INPUT -p tcp -m tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
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
iptables_add INPUT -p tcp -m tcp --dport 49321 -j ACCEPT
iptables_add INPUT -p tcp -m tcp --dport 80 -j ACCEPT
iptables_add INPUT -i lo -j ACCEPT
iptables_add OUTPUT -o lo -j ACCEPT
iptables -P INPUT DROP
netfilter-persistent save

# Create update-geodata.sh helper
cat > /usr/local/bin/update-geodata.sh << 'GEODATA_EOF'
#!/bin/bash
set -euo pipefail
XRAY_DIR="/opt/xray-vps-setup/marzban/xray-core"

echo "Downloading latest geosite.dat..."
wget -4 -qO "$XRAY_DIR/geosite.dat" \
  https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat

echo "Downloading latest geoip.dat..."
wget -4 -qO "$XRAY_DIR/geoip.dat" \
  https://github.com/v2fly/geoip/releases/latest/download/geoip.dat

docker compose -f /opt/xray-vps-setup/docker-compose.yml restart marzban
echo "geodata updated, XRay restarted"
GEODATA_EOF
chmod +x /usr/local/bin/update-geodata.sh

# Schedule weekly geodata update (Monday 4:00 AM)
(crontab -l 2>/dev/null | grep -v 'update-geodata'; echo "0 4 * * 1 /usr/local/bin/update-geodata.sh >/dev/null 2>&1") | crontab -

# Cleanup temp files
rm -f /tmp/xray.zip

# Output
clear
echo "========================================="
echo " Marzban Panel: http://localhost:8000/$MARZBAN_PATH"
echo " (access via SSH tunnel: ssh -L 8000:localhost:8000 root@<VPS1_IP>)"
echo " Panel user: $MARZBAN_USER"
echo " Panel pass: $MARZBAN_PASS"
echo ""
echo " === Values for setup-entry.sh ==="
echo " VPS1_IP:         $(hostname -I | awk '{print $1}')"
echo " VPS1_PBK:        $XRAY_PBK"
echo " VPS1_SHORT_ID:   $SHORT_ID"
echo " UUID_LINK:       $UUID_LINK"
echo " XHTTP_PATH:      $XHTTP_PATH"
echo " VPS1_DOMAIN:      $VPS1_DOMAIN"
echo ""
echo " === Geodata ==="
echo " geosite.dat/geoip.dat auto-update: weekly (Mon 4:00 AM)"
echo " Manual update: update-geodata.sh"
echo "========================================="
