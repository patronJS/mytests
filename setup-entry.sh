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
apt-get install idn sudo dnsutils wamerican zip unzip python3 wget curl openssl gettext -y

export GIT_BRANCH="main"
export GIT_REPO="patronJS/mytests"
export XRAY_VERSION="v26.3.27"
# Pinned versions: yq=v4.52.5, marzban=latest, angie=minimal
TEMPLATE_URL="https://raw.githubusercontent.com/$GIT_REPO/refs/heads/$GIT_BRANCH/templates_for_script"

fetch_template() {
  local content
  content=$(wget -4 -qO- "$TEMPLATE_URL/$1") || { echo "Failed to download template: $1"; exit 1; }
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
  if ! curl -4 -I https://api.cloudflareclient.com --connect-timeout 10 > /dev/null 2>&1; then
    echo "Warp can't be used"
    configure_warp_input="n"
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
  wget -4 -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-64.zip
elif [[ "$ARCH" == "arm64" ]]; then
  wget -4 -O /tmp/xray.zip https://github.com/XTLS/Xray-core/releases/download/$XRAY_VERSION/Xray-linux-arm64-v8a.zip
fi
unzip -qo /tmp/xray.zip -d /opt/xray-vps-setup/node/xray-core

# Download and envsubst templates
mkdir -p /opt/xray-vps-setup/node
cd /opt/xray-vps-setup
fetch_template "node-xray" | envsubst '$CLIENT_UUID $CLIENT_XHTTP_PATH $XRAY_PIK $XRAY_PBK $SHORT_IDS $VPS1_IP $VPS1_PBK $VPS1_SHORT_ID $UUID_LINK $XHTTP_PATH $VPS1_DOMAIN $VLESS_DOMAIN' > ./node/xray_config.json
fetch_template "node-angie" | envsubst '$VLESS_DOMAIN' > ./angie.conf
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
PANEL_TOKEN=$(curl -4 -sf -X POST "https://$VLESS_DOMAIN/api/admin/token" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  --data-urlencode "username=$MARZBAN_USER" \
  --data-urlencode "password=$MARZBAN_PASS" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])" || echo "")
if [[ -n "$PANEL_TOKEN" && "$PANEL_TOKEN" != "null" ]]; then
  PHOSTS_HTTP=$(curl -4 -s -o /tmp/panel_hosts.json -w "%{http_code}" \
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
    curl -4 -s -o /dev/null \
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
  curl -4 -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor --output /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
  echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(. /etc/os-release && echo $VERSION_CODENAME) main" | tee /etc/apt/sources.list.d/cloudflare-client.list
  apt update
  apt install cloudflare-warp -y

  if ! echo "y" | warp-cli registration new; then
    echo "Couldn't connect to WARP, continuing without it"
    return 0
  fi
  if ! warp-cli mode proxy || ! warp-cli proxy port 40000 || ! warp-cli connect; then
    echo "WARP setup failed, continuing without it"
    return 0
  fi
  XRAY_CONFIG_WARP="/opt/xray-vps-setup/node/xray_config.json"
  # Add WARP SOCKS outbound and switch default catch-all from direct → warp
  if yq eval \
    '.outbounds += {"tag": "warp","protocol": "socks","settings": {"servers": [{"address": "127.0.0.1","port": 40000}]}}' \
    -i "$XRAY_CONFIG_WARP" && \
     yq eval '(.routing.rules[] | select(.inboundTag != null)).outboundTag = "warp"' -i "$XRAY_CONFIG_WARP"; then
    docker compose -f /opt/xray-vps-setup/docker-compose.yml restart
    echo "WARP enabled as default outbound"
  else
    echo "Warning: failed to patch XRay config for WARP, continuing without it"
  fi
}

if [[ ${configure_warp_input,,} == "y" ]]; then
  warp_install
fi

# Create route files for whitelist-based routing
mkdir -p /opt/xray-vps-setup/routes
cat > /opt/xray-vps-setup/routes/domains.txt << 'ROUTES_EOF'
# Domains to route through VPS1 (Germany)
# One per line. Subdomains included automatically.
# Supported formats:
#   netflix.com          — matches netflix.com and *.netflix.com
#   full:exact.com       — exact match only
#   regexp:.*\.example$  — regex pattern
#   geosite:netflix      — from geosite.dat
#
# Example:
# netflix.com
# youtube.com
# spotify.com
# openai.com
ROUTES_EOF

cat > /opt/xray-vps-setup/routes/ips.txt << 'ROUTES_EOF'
# IPs/CIDRs to route through VPS1 (Germany)
# One per line.
# Supported formats:
#   1.2.3.4              — single IP
#   5.6.7.0/24           — CIDR range
#   geoip:us             — country from geoip.dat
#
# Example:
# 8.8.8.8
# 1.0.0.0/24
ROUTES_EOF

# Install apply-routes script
cat > /usr/local/bin/apply-routes.sh << 'APPLYSCRIPT_EOF'
#!/bin/bash
set -euo pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

ROUTES_DIR="/opt/xray-vps-setup/routes"
XRAY_CONFIG="/opt/xray-vps-setup/node/xray_config.json"

if [ ! -f "$XRAY_CONFIG" ]; then
  echo "Error: $XRAY_CONFIG not found"
  exit 1
fi

python3 << 'PYEOF'
import json, os, sys

routes_dir = "/opt/xray-vps-setup/routes"
config_path = "/opt/xray-vps-setup/node/xray_config.json"

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

# Detect current default outbound (direct or warp)
default_tag = "direct"
for rule in config.get('routing', {}).get('rules', []):
    if 'inboundTag' in rule:
        default_tag = rule.get('outboundTag', 'direct')
        break

rules = [{"protocol": "bittorrent", "outboundTag": "block"}]
if domains:
    rules.append({"domain": format_domains(domains), "outboundTag": "chain-vps1"})
if ips:
    rules.append({"ip": ips, "outboundTag": "chain-vps1"})
rules.append({"ip": ["geoip:private"], "outboundTag": "direct"})
rules.append({"inboundTag": ["reality-tcp", "xhttp-in"], "outboundTag": default_tag})

config['routing']['rules'] = rules

with open(config_path, 'w') as f:
    json.dump(config, f, indent=2)

print(f"Routes: {len(domains)} domains, {len(ips)} IPs -> chain-vps1")
print(f"Default outbound: {default_tag}")
PYEOF

docker compose -f /opt/xray-vps-setup/docker-compose.yml restart marzban
echo "XRay restarted with updated routes"
APPLYSCRIPT_EOF
chmod +x /usr/local/bin/apply-routes.sh

# Create update-geodata.sh helper
cat > /usr/local/bin/update-geodata.sh << 'GEODATA_EOF'
#!/bin/bash
set -euo pipefail
XRAY_DIR="/opt/xray-vps-setup/node/xray-core"

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
rm -f /tmp/panel_hosts.json /tmp/panel_hosts_updated.json /tmp/xray.zip

# Output
clear
echo "========================================="
echo " VPS2 Marzban Panel: http://localhost:8000/$MARZBAN_PATH"
echo " (access via SSH tunnel: ssh -L 8000:localhost:8000 root@<VPS2_IP>)"
echo " Panel user: $MARZBAN_USER"
echo " Panel pass: $MARZBAN_PASS"
echo ""
echo " === Routing ==="
echo " By default all traffic goes direct from VPS2."
echo " To route specific sites through VPS1 (Germany):"
echo "   1. Edit /opt/xray-vps-setup/routes/domains.txt"
echo "   2. Edit /opt/xray-vps-setup/routes/ips.txt"
echo "   3. Run: apply-routes.sh"
echo ""
echo " === Geodata ==="
echo " geosite.dat/geoip.dat auto-update: weekly (Mon 4:00 AM)"
echo " Manual update: update-geodata.sh"
echo ""
echo " === Next steps ==="
echo " 1. Connect via SSH tunnel and open Marzban panel"
echo " 2. Add domains/IPs to route files and run apply-routes.sh"
echo " 3. Create users and copy VLESS links to distribute"
echo "========================================="
if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo " SSH user: $SSH_USER, SSH password: $SSH_USER_PASS, SSH port: $SSH_PORT"
fi
