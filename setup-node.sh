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
apt-get install idn sudo dnsutils wamerican wireguard-tools zip unzip python3 wget curl openssl gettext -y

export GIT_BRANCH="main"
export GIT_REPO="patronJS/mytests"
export XRAY_VERSION="v26.3.23"
# Pinned versions: yq=v4.52.5, marzban-node=v0.5.2, wg-easy=15, angie=minimal
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
read -ep "Enter VPS1 panel domain:"$'\n' PANEL_DOMAIN; export PANEL_DOMAIN
read -ep "Enter VPS1 IP address:"$'\n' VPS1_IP; export VPS1_IP
read -ep "Enter VPS1 public key (PBK):"$'\n' PANEL_PBK; export PANEL_PBK
read -ep "Enter VPS1 short ID:"$'\n' PANEL_SHORT_ID; export PANEL_SHORT_ID
read -ep "Enter inter-VPS UUID:"$'\n' UUID_LINK; export UUID_LINK
read -ep "Enter XHTTP path:"$'\n' XHTTP_PATH; export XHTTP_PATH
read -ep "Enter VPS1 WG tunnel public key:"$'\n' PANEL_WG_PBK; export PANEL_WG_PBK

# VPS2 public IP (for node registration and WG peer instructions)
DEFAULT_VPS2_IP=$(hostname -I | awk '{print $1}')
read -ep "Enter this server's public IP [$DEFAULT_VPS2_IP]:"$'\n' VPS2_IP
VPS2_IP=${VPS2_IP:-$DEFAULT_VPS2_IP}
export VPS2_IP

# Panel credentials
read -ep "Enter panel admin username:"$'\n' PANEL_USER; export PANEL_USER
read -s -ep "Enter panel admin password:"$'\n' PANEL_PASS; export PANEL_PASS; echo

# Input validation
[[ "$UUID_LINK" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "Invalid UUID_LINK format"; exit 1; }
[[ ${#PANEL_PBK} -ge 40 ]] || { echo "PANEL_PBK looks too short"; exit 1; }
[[ "$PANEL_SHORT_ID" =~ ^[0-9a-f]{2,16}$ ]] && (( ${#PANEL_SHORT_ID} % 2 == 0 )) || { echo "Invalid PANEL_SHORT_ID: must be 2-16 even-length hex chars"; exit 1; }
[[ "$VPS1_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VPS1_IP format"; exit 1; }
[[ "$XHTTP_PATH" =~ ^[0-9a-f]{24}$ ]] || { echo "Invalid XHTTP_PATH format"; exit 1; }
[[ ${#PANEL_WG_PBK} -ge 40 ]] || { echo "PANEL_WG_PBK looks too short"; exit 1; }

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

# Check congestion protocol and enable ip_forward
if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
  echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
  echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
fi
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
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
export WG_TUNNEL_PIK=$(wg genkey)
export WG_TUNNEL_PBK=$(echo $WG_TUNNEL_PIK | wg pubkey)
export WG_TUNNEL_PEER_PBK="$PANEL_WG_PBK"
export WG_ADMIN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export WG_ADMIN_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy:15 wgpw "$WG_ADMIN_PASS")
export WG_UI_PATH=$(openssl rand -hex 8)

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
fetch_template "node-xray" | envsubst > ./node/xray_config.json
fetch_template "node-angie" | envsubst '$VLESS_DOMAIN $WG_UI_PATH' > ./angie.conf
fetch_template "compose-cascade-node" | envsubst > ./docker-compose.yml
fetch_template "confluence" | envsubst > ./index.html
touch ./ssl_client_cert.pem

# File permissions
chmod 600 ./node/xray_config.json ./ssl_client_cert.pem
chmod 644 ./angie.conf ./index.html ./docker-compose.yml

# WireGuard tunnel config
mkdir -p /etc/wireguard
fetch_template "wg-tunnel-node" | envsubst '$WG_TUNNEL_PIK $WG_TUNNEL_PEER_PBK $VPS1_IP' > /etc/wireguard/wg-tunnel.conf
chmod 600 /etc/wireguard/wg-tunnel.conf
systemctl enable --now wg-quick@wg-tunnel

# DNS fallback — ensure panel domain resolves even without public DNS propagation
grep -q "$PANEL_DOMAIN" /etc/hosts || echo "$VPS1_IP $PANEL_DOMAIN" >> /etc/hosts

# Start angie + wg-easy only (marzban-node needs cert from panel first)
docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d angie wg-easy

# Panel API setup — authenticate, fetch cert, register node, update config
node_api_setup() {
  echo "Connecting to panel at https://$PANEL_DOMAIN..."
  TOKEN=$(curl -sf -X POST "https://$PANEL_DOMAIN/api/admin/token" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    --data-urlencode "username=$PANEL_USER" \
    --data-urlencode "password=$PANEL_PASS" \
    | yq '.access_token')

  if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
    echo "Failed to authenticate with panel. Check credentials and panel availability."
    exit 1
  fi

  echo "Fetching SSL client certificate from panel..."
  CERT_HTTP=$(curl -s -o /tmp/node_settings.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/node/settings" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$CERT_HTTP" != "200" ]]; then
    echo "Failed to fetch node settings (HTTP $CERT_HTTP):"
    cat /tmp/node_settings.json
    exit 1
  fi
  python3 -c "import json,sys; print(json.load(open('/tmp/node_settings.json'))['certificate'], end='')" \
    > /opt/xray-vps-setup/ssl_client_cert.pem

  [ -s /opt/xray-vps-setup/ssl_client_cert.pem ] || { echo "Failed to fetch cert — file is empty"; exit 1; }

  NODE_IP="$VPS2_IP"
  NODE_NAME=$(hostname)

  echo "Creating node '$NODE_NAME' ($NODE_IP) on panel..."
  NODE_HTTP=$(curl -s -o /tmp/node_response.json -w "%{http_code}" \
    -X POST "https://$PANEL_DOMAIN/api/node" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"$NODE_NAME\",\"address\":\"$NODE_IP\",\"port\":62050,\"api_port\":62051,\"add_as_new_host\":false}" || echo "000")
  if [[ "$NODE_HTTP" == "200" ]]; then
    NODE_ID=$(cat /tmp/node_response.json | yq '.id')
    echo "Node created with ID: $NODE_ID"
  elif [[ "$NODE_HTTP" == "409" ]]; then
    echo "Node already exists on panel, reusing..."
    NODES_HTTP=$(curl -s -o /tmp/nodes_list.json -w "%{http_code}" \
      "https://$PANEL_DOMAIN/api/nodes" \
      -H "Authorization: Bearer $TOKEN" || echo "000")
    if [[ "$NODES_HTTP" != "200" ]]; then
      echo "Failed to fetch nodes list (HTTP $NODES_HTTP):"
      cat /tmp/nodes_list.json
      exit 1
    fi
    NODE_ID=$(python3 -c "import json,sys; nodes=json.load(open('/tmp/nodes_list.json')); print(next(str(n['id']) for n in nodes if n['address']=='$NODE_IP'))")
    echo "Existing node ID: $NODE_ID"
  else
    echo "Failed to create node (HTTP $NODE_HTTP):"
    cat /tmp/node_response.json
    exit 1
  fi

  echo "Updating xray config serverNames with node domain..."
  CONFIG_HTTP=$(curl -s -o /tmp/xray_config.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/core/config" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$CONFIG_HTTP" != "200" ]]; then
    echo "Failed to fetch xray config (HTTP $CONFIG_HTTP):"
    cat /tmp/xray_config.json
    exit 1
  fi

  export NODE_DOMAIN="$VLESS_DOMAIN"
  cat > /tmp/update_servernames.py << 'PYEOF'
import json, os
with open('/tmp/xray_config.json') as f:
    config = json.load(f)
node_domain = os.environ['NODE_DOMAIN']
for inbound in config.get('inbounds', []):
    stream = inbound.get('streamSettings', {})
    reality = stream.get('realitySettings', {})
    if 'serverNames' in reality and node_domain not in reality['serverNames']:
        reality['serverNames'].append(node_domain)
print(json.dumps(config))
PYEOF
  python3 /tmp/update_servernames.py > /tmp/xray_config_updated.json \
    || { echo "Failed to process xray config JSON"; exit 1; }
  curl -s -o /dev/null \
    -X PUT "https://$PANEL_DOMAIN/api/core/config" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @/tmp/xray_config_updated.json || true
  echo "serverNames updated."

  echo "Fetching inbounds and current hosts..."
  INBOUNDS_HTTP=$(curl -s -o /tmp/marzban_inbounds.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/inbounds" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$INBOUNDS_HTTP" != "200" ]]; then
    echo "Failed to fetch inbounds (HTTP $INBOUNDS_HTTP):"
    cat /tmp/marzban_inbounds.json
    exit 1
  fi
  HOSTS_HTTP=$(curl -s -o /tmp/marzban_hosts.json -w "%{http_code}" \
    "https://$PANEL_DOMAIN/api/hosts" \
    -H "Authorization: Bearer $TOKEN" || echo "000")
  if [[ "$HOSTS_HTTP" != "200" ]]; then
    echo "Failed to fetch hosts (HTTP $HOSTS_HTTP):"
    cat /tmp/marzban_hosts.json
    exit 1
  fi

  export HOST_NODE_NAME="$NODE_NAME"
  export HOST_PANEL_USER="$PANEL_USER"
  cat > /tmp/update_hosts.py << 'PYEOF'
import json, os
with open('/tmp/marzban_hosts.json') as f:
    hosts = json.load(f)
with open('/tmp/marzban_inbounds.json') as f:
    inbounds = json.load(f)
node_domain = os.environ['NODE_DOMAIN']
node_name = os.environ['HOST_NODE_NAME']
panel_user = os.environ['HOST_PANEL_USER']
inbound_info = {}
for protocol, inbound_list in inbounds.items():
    for inbound in inbound_list:
        tag = inbound.get('tag', '')
        network = inbound.get('network', 'tcp')
        inbound_info[tag] = {'protocol': protocol, 'network': network}
for inbound_tag, host_list in hosts.items():
    info = inbound_info.get(inbound_tag, {})
    protocol = info.get('protocol', inbound_tag)
    transport = info.get('network', 'tcp')
    remark = f'{node_name} ({panel_user}) [{protocol} - {transport}]'
    host_list.append({
        'remark': remark,
        'address': node_domain,
        'port': None,
        'sni': node_domain,
        'host': None,
        'path': None,
        'security': 'inbound_default',
        'alpn': '',
        'fingerprint': 'chrome',
        'allowinsecure': None,
        'is_disabled': None,
        'mux_enable': None,
        'fragment_setting': None,
        'noise_setting': None,
        'random_user_agent': None,
        'use_sni_as_host': None,
    })
print(json.dumps(hosts))
PYEOF
  python3 /tmp/update_hosts.py > /tmp/marzban_hosts_updated.json \
    || { echo "Failed to process hosts JSON"; exit 1; }
  curl -s -o /dev/null \
    -X PUT "https://$PANEL_DOMAIN/api/hosts" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -d @/tmp/marzban_hosts_updated.json || true
  echo "Panel hosts updated."

  echo "Panel configuration complete!"
}

node_api_setup

# Start marzban-node (cert is now in place)
docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d marzban-node

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
iptables_add INPUT -p udp -m udp --dport 51820 -j ACCEPT
iptables_add INPUT -s $VPS1_IP -p udp -m udp --dport 51830 -j ACCEPT
iptables_add INPUT -p udp -m udp --dport 51830 -j DROP
iptables_add INPUT -s $VPS1_IP -p tcp -m tcp --dport 62050 -j ACCEPT
iptables_add INPUT -s $VPS1_IP -p tcp -m tcp --dport 62051 -j ACCEPT
iptables_add INPUT -p tcp -m tcp --dport 62050 -j REJECT --reject-with tcp-reset
iptables_add INPUT -p tcp -m tcp --dport 62051 -j REJECT --reject-with tcp-reset
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
rm -f /tmp/node_settings.json /tmp/node_response.json /tmp/nodes_list.json \
  /tmp/xray_config.json /tmp/xray_config_updated.json /tmp/update_servernames.py \
  /tmp/marzban_inbounds.json /tmp/marzban_hosts.json /tmp/marzban_hosts_updated.json \
  /tmp/update_hosts.py /tmp/xray.zip

# Output
clear
echo "========================================="
echo " VLESS+XHTTP+REALITY (primary):"
echo " vless://$CLIENT_UUID@$VLESS_DOMAIN:443?type=xhttp&security=reality&pbk=$XRAY_PBK&fp=chrome&sni=$VLESS_DOMAIN&sid=$SHORT_ID&path=%2F$CLIENT_XHTTP_PATH#XHTTP"
echo ""
echo " VLESS+REALITY TCP (fallback):"
echo " vless://$CLIENT_UUID@$VLESS_DOMAIN:443?type=tcp&security=reality&pbk=$XRAY_PBK&fp=chrome&sni=$VLESS_DOMAIN&sid=$SHORT_ID&flow=xtls-rprx-vision#TCP"
echo ""
echo " WireGuard UI: https://$VLESS_DOMAIN/$WG_UI_PATH/"
echo " WG admin password: $WG_ADMIN_PASS"
echo ""
echo " === Run on VPS1 ==="
echo " setup-panel.sh --add-wg-peer $WG_TUNNEL_PBK $VPS2_IP"
echo ""
echo " === Verify ==="
echo " On VPS1: ping 10.9.0.2"
echo " On VPS2: ping 10.9.0.1"
echo " From client: connect and check IP at ipinfo.io"
echo "========================================="
if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo " SSH user: $SSH_USER, SSH password: $SSH_USER_PASS, SSH port: $SSH_PORT"
fi
