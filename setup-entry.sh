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

# Install dependencies
apt-get update
apt-get install idn sudo dnsutils wamerican zip unzip python3 wget curl openssl gettext -y

export GIT_BRANCH="main"
export GIT_REPO="patronJS/mytests"
export XRAY_VERSION="v26.3.27"
# Pinned versions: yq=v4.52.5, marzban=latest, angie=minimal
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

# Ask VPS1 connection info
read -ep "Enter VPS1 IP address:"$'\n' VPS1_IP; export VPS1_IP
read -ep "Enter VPS1 public key (PBK):"$'\n' VPS1_PBK; export VPS1_PBK
read -ep "Enter VPS1 short ID:"$'\n' VPS1_SHORT_ID; export VPS1_SHORT_ID
read -ep "Enter inter-VPS UUID:"$'\n' UUID_LINK; export UUID_LINK
read -ep "Enter XHTTP path:"$'\n' XHTTP_PATH; export XHTTP_PATH
read -ep "Enter VPS1 domain:"$'\n' VPS1_DOMAIN; export VPS1_DOMAIN

# Input validation
[[ "$UUID_LINK" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "Invalid UUID_LINK format"; exit 1; }
[[ ${#VPS1_PBK} -ge 40 ]] || { echo "VPS1_PBK looks too short"; exit 1; }
[[ "$VPS1_SHORT_ID" =~ ^[0-9a-f]{2,16}$ ]] && (( ${#VPS1_SHORT_ID} % 2 == 0 )) || { echo "Invalid VPS1_SHORT_ID: must be 2-16 even-length hex chars"; exit 1; }
[[ "$VPS1_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VPS1_IP format"; exit 1; }
[[ "$XHTTP_PATH" =~ ^[0-9a-f]{24}$ ]] || { echo "Invalid XHTTP_PATH format"; exit 1; }
[[ "$VPS1_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "VPS1_DOMAIN must be a domain name, not an IP address"; exit 1; }
[[ "$VPS1_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] || { echo "Invalid VPS1_DOMAIN format"; exit 1; }

# Optional config prompts
read -ep "Do you want to harden SSH? [y/N] "$'\n' configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  read -ep "Enter SSH port. Default 22, can't use ports: 80, 443 and 4123:"$'\n' input_ssh_port

  while ! [[ "$input_ssh_port" =~ ^[0-9]+$ ]] || [[ "$input_ssh_port" -eq 80 || "$input_ssh_port" -eq 443 || "$input_ssh_port" -eq 4123 ]]; do
    read -ep "Invalid or reserved port ($input_ssh_port), write again:"$'\n' input_ssh_port
  done

  read -ep "Enter SSH public key:"$'\n' input_ssh_pbk
  echo "$input_ssh_pbk" > ./test_pbk
  if ! ssh-keygen -l -f ./test_pbk; then
    echo "Can't verify the public key. Try again and make sure to include 'ssh-rsa' or 'ssh-ed25519' followed by 'user@pcname' at the end of the file."
    exit 1
  fi
  rm ./test_pbk
fi

configure_warp_input="n"
read -ep "Do you want WARP for Russian sites? [y/N] "$'\n' configure_warp_input
if [[ ${configure_warp_input,,} == "y" ]]; then
  if ! curl -I https://api.cloudflareclient.com --connect-timeout 10 > /dev/null 2>&1; then
    echo "Warp can't be used"
    configure_warp_input="n"
  fi
fi

# Install Docker
docker_install() {
  curl -fsSL https://get.docker.com | sh
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
  wget -q "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH" -O /usr/bin/yq
  wget -qO /tmp/yq_checksums "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/checksums"
  YQ_SHA256=$(grep "yq_linux_$ARCH " /tmp/yq_checksums | awk '{print $19}')
  echo "$YQ_SHA256  /usr/bin/yq" | sha256sum -c - || { echo "yq checksum verification failed"; rm -f /usr/bin/yq; exit 1; }
  chmod +x /usr/bin/yq
  rm -f /tmp/yq_checksums
}

yq_install

# Check congestion protocol and persist sysctl settings
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
grep -q "net.ipv6.conf.all.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf
grep -q "net.ipv6.conf.default.disable_ipv6" /etc/sysctl.conf || echo "net.ipv6.conf.default.disable_ipv6=1" >> /etc/sysctl.conf
sysctl -p > /dev/null

# Generate local secrets
export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} x25519 | grep 'PrivateKey' | awk '{print $NF}')
export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} x25519 -i "$XRAY_PIK" | grep 'PublicKey' | awk '{print $NF}')
export SID1=$(openssl rand -hex 2)
export SID2=$(openssl rand -hex 4)
export SID3=$(openssl rand -hex 6)
export SID4=$(openssl rand -hex 8)
export SHORT_IDS="\"$SID1\",\"$SID2\",\"$SID3\",\"$SID4\""
export SHORT_ID=$SID4
export CLIENT_UUID=$(docker run --rm ghcr.io/xtls/xray-core:${XRAY_VERSION#v} uuid)
export CLIENT_XHTTP_PATH=$(openssl rand -hex 12)
export MARZBAN_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export MARZBAN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export MARZBAN_PATH=$(openssl rand -hex 8)
export MARZBAN_SUB_PATH=$(openssl rand -hex 8)

# Download XRay core
mkdir -p /opt/xray-vps-setup/node/xray-core
if [[ "$ARCH" == "amd64" ]]; then
  wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip
elif [[ "$ARCH" == "arm64" ]]; then
  wget -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-arm64-v8a.zip
fi
unzip -qo /tmp/xray.zip -d /opt/xray-vps-setup/node/xray-core

# Download and envsubst templates
mkdir -p /opt/xray-vps-setup/node
cd /opt/xray-vps-setup
fetch_template "node-xray" | envsubst '$CLIENT_UUID $CLIENT_XHTTP_PATH $XRAY_PIK $XRAY_PBK $SHORT_IDS $VPS1_IP $VPS1_PBK $VPS1_SHORT_ID $UUID_LINK $XHTTP_PATH $VPS1_DOMAIN $VLESS_DOMAIN' > ./node/xray_config.json
fetch_template "node-angie" | envsubst '$VLESS_DOMAIN $MARZBAN_PATH $MARZBAN_SUB_PATH' > ./angie.conf
fetch_template "compose-cascade-node" | envsubst '$VLESS_DOMAIN' > ./docker-compose.yml
fetch_template "confluence" | envsubst > ./index.html
fetch_template "marzban" | envsubst > ./node/.env
chmod 600 ./node/.env

# File permissions
chmod 600 ./node/xray_config.json ./node/.env
chmod 644 ./angie.conf ./index.html ./docker-compose.yml

# Start all containers
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
echo "Updating panel host with domain $VLESS_DOMAIN..."
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
# Use the user-supplied SSH port if hardening was requested, otherwise detect current
if [[ ${configure_ssh_input,,} == "y" && -n "${input_ssh_port:-}" ]]; then
  export SSH_PORT="${input_ssh_port}"
else
  export SSH_PORT=$(ss -tlnp | grep sshd | grep -Po '(?<=:)\d+(?= )' | head -n 1)
  SSH_PORT=${SSH_PORT:-22}
fi

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
iptables_add INPUT -i lo -j ACCEPT
iptables_add OUTPUT -o lo -j ACCEPT
iptables -P INPUT DROP
netfilter-persistent save

# SSH hardening
export SSH_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export SSH_PORT=${input_ssh_port:-22}

sshd_edit() {
  fetch_template "00-disable-password" | envsubst > /etc/ssh/sshd_config.d/00-disable-password.conf
  sshd -t || { echo "ERROR: sshd config test failed — reverting"; rm -f /etc/ssh/sshd_config.d/00-disable-password.conf; exit 1; }
  systemctl daemon-reload
  systemctl restart ssh
}

add_user() {
  useradd $SSH_USER -s /bin/bash
  usermod -aG sudo $SSH_USER
  echo $SSH_USER:$SSH_USER_PASS | chpasswd
  mkdir -p /home/$SSH_USER/.ssh
  touch /home/$SSH_USER/.ssh/authorized_keys
  echo $input_ssh_pbk >> /home/$SSH_USER/.ssh/authorized_keys
  chmod 700 /home/$SSH_USER/.ssh/
  chmod 600 /home/$SSH_USER/.ssh/authorized_keys
  chown $SSH_USER:$SSH_USER -R /home/$SSH_USER
  usermod -aG docker $SSH_USER
}

if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo "New user for ssh: $SSH_USER, password for user: $SSH_USER_PASS. New port for SSH: $SSH_PORT."
  add_user
  sshd_edit
fi

# WARP install
warp_install() {
  apt install gpg -y
  echo "If this fails then warp won't be added to routing and everything will work without it"
  curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(. /etc/os-release && echo $VERSION_CODENAME) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
  apt update
  apt install cloudflare-warp -y

  echo "y" | warp-cli registration new
  TRY_WARP=$?
  if [[ $TRY_WARP != 0 ]]; then
    echo "Couldn't connect to WARP"
    exit 0
  else
    warp-cli mode proxy
    warp-cli proxy port 40000
    warp-cli connect
    export XRAY_CONFIG_WARP="/opt/xray-vps-setup/node/xray_config.json"
    yq eval \
    '.outbounds += {"tag": "warp","protocol": "socks","settings": {"servers": [{"address": "127.0.0.1","port": 40000}]}}' \
    -i $XRAY_CONFIG_WARP
    yq eval \
    '.routing.rules += {"outboundTag": "warp", "domain": ["geosite:category-ru", "regexp:.*\\.xn--$", "regexp:.*\\.ru$", "regexp:.*\\.su$"]}' \
    -i $XRAY_CONFIG_WARP
    docker compose -f /opt/xray-vps-setup/docker-compose.yml down && docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d
  fi
}

if [[ ${configure_warp_input,,} == "y" ]]; then
  warp_install
fi

# Cleanup temp files
rm -f /tmp/panel_hosts.json /tmp/panel_hosts_updated.json /tmp/xray.zip

# Output
clear
echo "========================================="
echo " VPS2 Marzban Panel: https://$VLESS_DOMAIN/$MARZBAN_PATH"
echo " Panel user: $MARZBAN_USER"
echo " Panel pass: $MARZBAN_PASS"
echo ""
echo " === Next steps ==="
echo " 1. Open Marzban panel and create users"
echo " 2. Use VLESS links from panel to connect clients"
echo " 3. Use WireGuard UI to create WG configs"
echo " 4. Check IP at ipinfo.io — should show VPS1 (Germany)"
echo "========================================="
if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo " SSH user: $SSH_USER, SSH password: $SSH_USER_PASS, SSH port: $SSH_PORT"
fi
