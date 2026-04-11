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

# Optional config prompts
read -ep "Do you want to harden SSH? [y/N] "$'\n' configure_ssh_input
if [[ ${configure_ssh_input,,} == "y" ]]; then
  read -ep "Enter SSH port. Default 22, can't use ports: 80, 443, 4123, 49321:"$'\n' input_ssh_port

  while ! [[ "$input_ssh_port" =~ ^[0-9]+$ ]] || (( input_ssh_port < 1 || input_ssh_port > 65535 )) || [[ "$input_ssh_port" -eq 80 || "$input_ssh_port" -eq 443 || "$input_ssh_port" -eq 4123 || "$input_ssh_port" -eq 49321 ]]; do
    read -ep "Invalid or reserved port ($input_ssh_port). Use 1-65535, not 80/443/4123/49321:"$'\n' input_ssh_port
  done

  read -ep "Enter SSH public key:"$'\n' input_ssh_pbk
  ssh_key_tmp=$(mktemp)
  echo "$input_ssh_pbk" > "$ssh_key_tmp"
  if ! ssh-keygen -l -f "$ssh_key_tmp"; then
    rm -f "$ssh_key_tmp"
    echo "Can't verify the public key. Try again and make sure to include 'ssh-rsa' or 'ssh-ed25519' followed by 'user@pcname' at the end of the file."
    exit 1
  fi
  rm -f "$ssh_key_tmp"
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

# Download latest geodata (geosite.dat from XRay release may be outdated)
echo "Downloading latest geosite.dat and geoip.dat..."
wget -4 -qO /opt/xray-vps-setup/marzban/xray-core/geosite.dat \
  https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat
wget -4 -qO /opt/xray-vps-setup/marzban/xray-core/geoip.dat \
  https://github.com/v2fly/geoip/releases/latest/download/geoip.dat

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
iptables_add INPUT -p tcp -m tcp --dport 49321 -j ACCEPT
iptables_add INPUT -p tcp -m tcp --dport 80 -j ACCEPT
iptables_add INPUT -i lo -j ACCEPT
iptables_add OUTPUT -o lo -j ACCEPT
iptables -P INPUT DROP
netfilter-persistent save

# fail2ban — SSH brute-force protection (installed regardless of hardening choice)
apt-get install fail2ban -y
fetch_template "fail2ban-jail" | envsubst '$SSH_PORT' > /etc/fail2ban/jail.local
systemctl enable fail2ban
systemctl restart fail2ban

# SSH hardening
export SSH_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export SSH_USER_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)

sshd_edit() {
  fetch_template "00-disable-password" | envsubst > /etc/ssh/sshd_config.d/00-disable-password.conf
  sshd -t || { echo "ERROR: sshd config test failed — reverting"; rm -f /etc/ssh/sshd_config.d/00-disable-password.conf; exit 1; }
  systemctl daemon-reload
  systemctl restart ssh
}

add_user() {
  id "$SSH_USER" &>/dev/null || useradd "$SSH_USER" -s /bin/bash
  usermod -aG sudo "$SSH_USER"
  echo "$SSH_USER:$SSH_USER_PASS" | chpasswd
  mkdir -p "/home/$SSH_USER/.ssh"
  touch "/home/$SSH_USER/.ssh/authorized_keys"
  grep -qF "$input_ssh_pbk" "/home/$SSH_USER/.ssh/authorized_keys" 2>/dev/null || echo "$input_ssh_pbk" >> "/home/$SSH_USER/.ssh/authorized_keys"
  chmod 700 "/home/$SSH_USER/.ssh/"
  chmod 600 "/home/$SSH_USER/.ssh/authorized_keys"
  chown "$SSH_USER:$SSH_USER" -R "/home/$SSH_USER"
  usermod -aG docker "$SSH_USER"
}

if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo "New user for ssh: $SSH_USER, password for user: $SSH_USER_PASS. New port for SSH: $SSH_PORT."
  add_user
  sshd_edit
fi

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
if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo " Marzban Panel: http://localhost:8000/$MARZBAN_PATH"
  echo " (access via SSH tunnel: ssh -p $SSH_PORT -L 8000:localhost:8000 $SSH_USER@<VPS1_IP>)"
else
  echo " Marzban Panel: http://localhost:8000/$MARZBAN_PATH"
  echo " (access via SSH tunnel: ssh -L 8000:localhost:8000 root@<VPS1_IP>)"
fi
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
echo " === Security ==="
echo " fail2ban is installed and active (sshd jail, backend=systemd)."
echo "   bantime=1h, findtime=10m, maxretry=5"
echo " Useful commands:"
echo "   fail2ban-client status sshd       # jail status + banned IPs"
echo "   fail2ban-client unban <ip>        # lift a ban"
echo ""
echo " === Geodata ==="
echo " geosite.dat/geoip.dat auto-update: weekly (Mon 4:00 AM)"
echo " Manual update: update-geodata.sh"
echo "========================================="
if [[ ${configure_ssh_input,,} == "y" ]]; then
  echo " SSH user: $SSH_USER, SSH password: $SSH_USER_PASS, SSH port: $SSH_PORT"
fi
