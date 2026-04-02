# steal_oneself на обоих VPS + удаление WireGuard — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Перевести VPS1 на steal_oneself с собственным доменом (устранить ASN mismatch) и полностью удалить WireGuard из архитектуры.

**Architecture:** VPS1 получает Angie (TLS-терминация + ACME + заглушка) и переходит на steal_oneself на порту 49321. VPS2 обновляет chain outbound serverName на домен VPS1. Весь WG-стек (wg-easy, TPROXY, dokodemo-door, sockopt.mark) удаляется с VPS2.

**Tech Stack:** Bash, Docker Compose, XRay v26.3.27, Angie (nginx-fork), Let's Encrypt ACME, envsubst

**Spec:** `docs/superpowers/specs/2026-04-02-steal-oneself-both-vps-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|---------------|
| `templates_for_script/panel-angie` | **Create** | Angie config for VPS1 (steal_oneself target + ACME + camouflage) |
| `templates_for_script/panel-xray` | Modify | Switch REALITY from dl.google.com to steal_oneself |
| `templates_for_script/compose-panel` | Modify | Add Angie container + volume |
| `setup-panel.sh` | Modify | Domain prompt, DNS validation, new templates, iptables port 80 |
| `templates_for_script/node-xray` | Modify | Remove TPROXY inbound, sockopt.mark; change chain outbound serverName |
| `templates_for_script/node-angie` | Modify | Fix proxy_protocol bug, remove WG UI location + unused maps |
| `templates_for_script/compose-cascade-node` | Modify | Remove wg-easy service, wg-data volume, NET_ADMIN from marzban |
| `setup-entry.sh` | Modify | Add VPS1_DOMAIN prompt; remove WG code (bcrypt, iptables-legacy, etc.) |
| `CLAUDE.md` | Modify | Update architecture, ports, remove WG references |
| `README.md` | Modify | Update install instructions, remove WG |

---

### Task 1: Create `panel-angie` template (VPS1 Angie config)

**Files:**
- Create: `templates_for_script/panel-angie`

- [ ] **Step 1: Create the panel-angie template file**

```nginx
user angie;
worker_processes auto;
error_log /var/log/angie/error.log notice;

events {
    worker_connections 1024;
}

http {
    server_tokens off;
    access_log off;

    resolver 1.1.1.1;
    acme_client vless https://acme-v02.api.letsencrypt.org/directory;

    # Default: reject unknown SNI
    # proxy_protocol on BOTH servers — xver:1 sends PROXY header to all connections
    server {
        listen 127.0.0.1:4123 ssl proxy_protocol default_server;
        ssl_reject_handshake on;
        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_session_timeout 1h;
        ssl_session_cache shared:SSL:10m;
    }

    # Main: steal_oneself target
    server {
        listen 127.0.0.1:4123 ssl proxy_protocol;
        http2 on;

        set_real_ip_from 127.0.0.1;
        real_ip_header proxy_protocol;

        server_name $VPS1_DOMAIN;

        acme vless;
        ssl_certificate $acme_cert_vless;
        ssl_certificate_key $acme_cert_key_vless;

        ssl_protocols TLSv1.2 TLSv1.3;
        ssl_ciphers TLS13_AES_128_GCM_SHA256:TLS13_AES_256_GCM_SHA384:TLS13_CHACHA20_POLY1305_SHA256:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305;
        ssl_prefer_server_ciphers on;

        ssl_stapling on;
        ssl_stapling_verify on;
        resolver 1.1.1.1 valid=60s;
        resolver_timeout 2s;

        location / {
            root /tmp;
            index index.html;
        }
    }

    # Port 80: ACME HTTP-01 challenge + camouflage stub
    # No redirect to https — port 443 is not open on VPS1 (service on 49321)
    server {
        listen 80;
        listen [::]:80;

        location / {
            root /tmp;
            index index.html;
        }
    }
}
```

- [ ] **Step 2: Verify the template has no syntax issues**

Run: `grep -c 'server {' templates_for_script/panel-angie`
Expected: `3` (default reject + main + port 80)

Run: `grep 'proxy_protocol' templates_for_script/panel-angie`
Expected: Both `listen` lines on port 4123 include `proxy_protocol`

- [ ] **Step 3: Commit**

```bash
git add templates_for_script/panel-angie
git commit -m "feat: add panel-angie template for VPS1 steal_oneself"
```

---

### Task 2: Modify `panel-xray` — switch REALITY to steal_oneself

**Files:**
- Modify: `templates_for_script/panel-xray`

- [ ] **Step 1: Update realitySettings**

Change the `realitySettings` block in the inbound from:
```json
"realitySettings": {
  "dest": "dl.google.com:443",
  "xver": 0,
  "serverNames": ["dl.google.com"],
```
To:
```json
"realitySettings": {
  "dest": "127.0.0.1:4123",
  "xver": 1,
  "serverNames": ["$VPS1_DOMAIN"],
```

- [ ] **Step 2: Verify the change**

Run: `grep -E '(dest|xver|serverNames)' templates_for_script/panel-xray`
Expected:
```
"dest": "127.0.0.1:4123",
"xver": 1,
"serverNames": ["$VPS1_DOMAIN"],
```
No references to `dl.google.com` should remain.

- [ ] **Step 3: Commit**

```bash
git add templates_for_script/panel-xray
git commit -m "feat: switch VPS1 REALITY to steal_oneself (dest=127.0.0.1:4123)"
```

---

### Task 3: Modify `compose-panel` — add Angie container

**Files:**
- Modify: `templates_for_script/compose-panel`

- [ ] **Step 1: Add angie service and volume**

Replace the entire file content with:
```yaml
services:
  angie:
    image: docker.angie.software/angie:minimal
    container_name: angie
    restart: always
    network_mode: host
    volumes:
      - angie-data:/var/lib/angie
      - ./angie.conf:/etc/angie/angie.conf:ro
      - ./index.html:/tmp/index.html:ro

  marzban:
    image: gozargah/marzban:latest
    container_name: marzban
    restart: always
    env_file: ./marzban/.env
    network_mode: host
    volumes:
      - ./marzban/xray_config.json:/code/xray_config.json
      - ./marzban/xray-core:/code/xray-core:ro
      - marzban_lib:/var/lib/marzban

volumes:
  angie-data:
    driver: local
    external: false
    name: angie-data
  marzban_lib:
    driver: local
```

- [ ] **Step 2: Verify**

Run: `grep -c 'container_name' templates_for_script/compose-panel`
Expected: `2` (angie + marzban)

Run: `grep 'angie-data' templates_for_script/compose-panel`
Expected: Volume reference in angie service + volume definition

- [ ] **Step 3: Commit**

```bash
git add templates_for_script/compose-panel
git commit -m "feat: add Angie container to VPS1 compose stack"
```

---

### Task 4: Modify `setup-panel.sh` — domain prompt, templates, iptables

**Files:**
- Modify: `setup-panel.sh`

- [ ] **Step 1: Add `idn` and `dnsutils` to dependencies**

Change the apt-get line from:
```bash
apt-get install sudo wamerican zip unzip python3 wget curl openssl gettext -y
```
To:
```bash
apt-get install sudo idn dnsutils wamerican zip unzip python3 wget curl openssl gettext -y
```

- [ ] **Step 2: Add domain prompt and DNS validation after dependencies, before Docker install**

Insert after the `fetch_template` function definition (after line 30), before the Docker install section:

```bash
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
```

- [ ] **Step 3: Replace the hardcoded `VLESS_DOMAIN="localhost"` line**

Find and remove:
```bash
export VLESS_DOMAIN="localhost"
```
This is no longer needed — `VLESS_DOMAIN` is set from `VPS1_DOMAIN` in step 2.

- [ ] **Step 4: Add template downloads for Angie and Confluence**

After the existing `fetch_template` calls (after `fetch_template "marzban"`), add:
```bash
fetch_template "panel-angie" | envsubst '$VPS1_DOMAIN' > ./angie.conf
fetch_template "confluence" | envsubst > ./index.html
```

Also update the panel-xray envsubst to include `$VPS1_DOMAIN`:
Change:
```bash
fetch_template "panel-xray" | envsubst > ./marzban/xray_config.json
```
To:
```bash
fetch_template "panel-xray" | envsubst '$UUID_LINK $XHTTP_PATH $SHORT_IDS $XRAY_PIK $XRAY_PBK $VPS1_DOMAIN' > ./marzban/xray_config.json
```

- [ ] **Step 5: Add file permissions for new files**

After the existing `chmod` lines, add:
```bash
chmod 644 ./angie.conf ./index.html
```

- [ ] **Step 6: Add iptables rule for port 80 BEFORE docker compose up**

IMPORTANT: Port 80 must be open before Angie starts, otherwise ACME HTTP-01 can fail on first run. Move the iptables block (or at least the port 80 rule) above `docker compose up`. 

The simplest approach: add a temporary port 80 open right before `docker compose up`:
```bash
# Open port 80 for ACME before starting Angie
iptables -C INPUT -p tcp -m tcp --dport 80 -j ACCEPT 2>/dev/null || iptables -A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
```

Insert this line immediately before `docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d`.

Also keep the rule in the main iptables block (after `--dport 49321`):
```bash
iptables_add INPUT -p tcp -m tcp --dport 80 -j ACCEPT
```

- [ ] **Step 7: Update output section**

Add `VPS1_DOMAIN` to the "Values for setup-entry.sh" output block. After the existing `XHTTP_PATH` line:
```bash
echo " VPS1_DOMAIN:      $VPS1_DOMAIN"
```

- [ ] **Step 8: Verify no references to dl.google.com remain**

Run: `grep -n 'dl.google' setup-panel.sh`
Expected: No output (no references)

Run: `grep -n 'VPS1_DOMAIN\|VLESS_DOMAIN' setup-panel.sh`
Expected: Multiple lines showing both variables are set and used

- [ ] **Step 9: Commit**

```bash
git add setup-panel.sh
git commit -m "feat: add domain prompt and Angie/Confluence to VPS1 setup"
```

---

### Task 5: Modify `node-xray` — remove WG/TPROXY, update chain outbound

**Files:**
- Modify: `templates_for_script/node-xray`

- [ ] **Step 1: Remove the `tproxy-in` inbound entirely**

Delete the entire third inbound object (tag `tproxy-in`, protocol `dokodemo-door`, port 12345). This is lines 51-68 in the current file.

- [ ] **Step 2: Remove `sockopt.mark` from chain outbound**

In the `chain-vps1` outbound `streamSettings`, delete:
```json
"sockopt": {
  "mark": 255
}
```

- [ ] **Step 3: Change `serverName` in chain outbound**

In the `chain-vps1` outbound `realitySettings`, change:
```json
"serverName": "dl.google.com",
```
To:
```json
"serverName": "$VPS1_DOMAIN",
```

- [ ] **Step 4: Update routing rule — remove tproxy-in from inboundTag**

Change:
```json
{"inboundTag": ["reality-tcp", "xhttp-in", "tproxy-in"], "outboundTag": "chain-vps1"}
```
To:
```json
{"inboundTag": ["reality-tcp", "xhttp-in"], "outboundTag": "chain-vps1"}
```

- [ ] **Step 5: Verify the final file**

Run: `grep -c 'tproxy' templates_for_script/node-xray`
Expected: `0`

Run: `grep -c 'mark' templates_for_script/node-xray`
Expected: `0`

Run: `grep 'serverName' templates_for_script/node-xray`
Expected: `"serverName": "$VPS1_DOMAIN",`

Run: `python3 -c "import json; json.load(open('templates_for_script/node-xray'))"`
Expected: Error (contains `$VPS1_DOMAIN` etc.), but this verifies it's at least structurally parseable after envsubst. Instead validate structure:

Run: `grep '"tag"' templates_for_script/node-xray | grep -c -E 'reality-tcp|xhttp-in|tproxy'`
Expected: `2` (reality-tcp + xhttp-in, no tproxy-in)

- [ ] **Step 6: Commit**

```bash
git add templates_for_script/node-xray
git commit -m "feat: remove TPROXY/WG from node-xray, switch chain outbound to VPS1_DOMAIN"
```

---

### Task 6: Modify `node-angie` — fix proxy_protocol bug, remove WG UI

**Files:**
- Modify: `templates_for_script/node-angie`

- [ ] **Step 1: Fix proxy_protocol mismatch on default server**

Change line 41:
```nginx
listen                  127.0.0.1:4123 ssl default_server;
```
To:
```nginx
listen                  127.0.0.1:4123 ssl proxy_protocol default_server;
```

- [ ] **Step 2: Remove all unused map blocks**

Delete the WebSocket upgrade map (was only used by WG UI proxy):
```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ""      close;
}
```

Delete the proxy_protocol_addr map (not referenced by any remaining location):
```nginx
map $proxy_protocol_addr $proxy_forwarded_elem {
    ~^[0-9.]+$        "for=$proxy_protocol_addr";
    ~^[0-9A-Fa-f:.]+$ "for=\"[$proxy_protocol_addr]\"";
    default           "for=unknown";
}
```

Delete the http_forwarded map (not referenced by any remaining location):
```nginx
map $http_forwarded $proxy_add_forwarded {
    "~^(,[ \\t]*)*..." "$http_forwarded, $proxy_forwarded_elem";
    default "$proxy_forwarded_elem";
}
```

- [ ] **Step 3: Remove the WG UI location block**

Delete the entire `location ^~ /$WG_UI_PATH/` block (lines 80-87):
```nginx
location ^~ /$WG_UI_PATH/ {
    proxy_pass http://127.0.0.1:51821/;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
}
```

- [ ] **Step 4: Verify**

Run: `grep -c 'proxy_protocol' templates_for_script/node-angie`
Expected: `2` (both server blocks)

Run: `grep 'WG_UI_PATH\|51821\|wg-easy\|http_upgrade\|connection_upgrade' templates_for_script/node-angie`
Expected: No output

Run: `grep -c 'location' templates_for_script/node-angie`
Expected: `2` (Marzban + root `/`)

- [ ] **Step 5: Commit**

```bash
git add templates_for_script/node-angie
git commit -m "fix: proxy_protocol on both server blocks; remove WG UI location"
```

---

### Task 7: Modify `compose-cascade-node` — remove wg-easy

**Files:**
- Modify: `templates_for_script/compose-cascade-node`

- [ ] **Step 1: Remove wg-easy service entirely**

Delete the entire `wg-easy:` service block (lines 25-45 in current file), including all its environment variables, volumes, cap_add, etc.

- [ ] **Step 2: Remove `cap_add: NET_ADMIN` from marzban service**

Delete from the marzban service:
```yaml
cap_add:
  - NET_ADMIN
```

- [ ] **Step 3: Remove `wg-data` volume**

Delete from the volumes section:
```yaml
wg-data:
  driver: local
```

- [ ] **Step 4: Verify the final file**

The file should contain only 2 services: `angie` and `marzban`.

Run: `grep -c 'container_name' templates_for_script/compose-cascade-node`
Expected: `2` (angie + marzban)

Run: `grep -E 'wg-easy|wg-data|WG_|41820|51821|TPROXY|NET_ADMIN' templates_for_script/compose-cascade-node`
Expected: No output

- [ ] **Step 5: Commit**

```bash
git add templates_for_script/compose-cascade-node
git commit -m "feat: remove wg-easy service and TPROXY from VPS2 compose"
```

---

### Task 8: Modify `setup-entry.sh` — add VPS1_DOMAIN, remove WG code

**Files:**
- Modify: `setup-entry.sh`

This is the largest change. Apply edits in order.

- [ ] **Step 1: Remove iptables-legacy switch**

Delete lines 15-17:
```bash
# Switch to iptables-legacy (TPROXY module requires legacy, nft backend ignores legacy rules)
update-alternatives --set iptables /usr/sbin/iptables-legacy 2>/dev/null || true
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy 2>/dev/null || true
```

- [ ] **Step 2: Add VPS1_DOMAIN prompt after VPS1 connection info prompts**

After the `read -ep "Enter XHTTP path:"` line (line 84), add:
```bash
read -ep "Enter VPS1 domain:"$'\n' VPS1_DOMAIN; export VPS1_DOMAIN
```

Add validation after existing validation block (after line 91). Reject IPs explicitly — spec requires domain, not IP:
```bash
[[ "$VPS1_DOMAIN" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { echo "VPS1_DOMAIN must be a domain name, not an IP address"; exit 1; }
[[ "$VPS1_DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]*[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]] || { echo "Invalid VPS1_DOMAIN format"; exit 1; }
```

- [ ] **Step 3: Remove WG-related secret generation**

Delete bcrypt install and WG password hashing (lines 167-170):
```bash
export WG_ADMIN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
pip3 install bcrypt -q 2>/dev/null || apt-get install -y python3-bcrypt -q 2>/dev/null
WG_ADMIN_HASH_RAW=$(python3 -c "import bcrypt; print(bcrypt.hashpw(b'$WG_ADMIN_PASS', bcrypt.gensalt()).decode())")
export WG_ADMIN_HASH="${WG_ADMIN_HASH_RAW//\$/\$\$}"
```

Delete WG_UI_PATH generation (line 171):
```bash
export WG_UI_PATH=$(openssl rand -hex 8)
```

- [ ] **Step 4: Update envsubst calls**

Change the node-xray envsubst to pass `$VPS1_DOMAIN`. The current line:
```bash
fetch_template "node-xray" | envsubst > ./node/xray_config.json
```
Must become (explicit variable list to include VPS1_DOMAIN):
```bash
fetch_template "node-xray" | envsubst '$CLIENT_UUID $CLIENT_XHTTP_PATH $XRAY_PIK $XRAY_PBK $SHORT_IDS $VPS1_IP $VPS1_PBK $VPS1_SHORT_ID $UUID_LINK $XHTTP_PATH $VPS1_DOMAIN $VLESS_DOMAIN' > ./node/xray_config.json
```

Change the node-angie envsubst to remove WG_UI_PATH:
```bash
fetch_template "node-angie" | envsubst '$VLESS_DOMAIN $WG_UI_PATH $MARZBAN_PATH $MARZBAN_SUB_PATH' > ./angie.conf
```
To:
```bash
fetch_template "node-angie" | envsubst '$VLESS_DOMAIN $MARZBAN_PATH $MARZBAN_SUB_PATH' > ./angie.conf
```

Change the compose envsubst to remove WG variables:
```bash
fetch_template "compose-cascade-node" | envsubst '$VLESS_DOMAIN $WG_ADMIN_HASH $WG_UI_PATH' > ./docker-compose.yml
```
To:
```bash
fetch_template "compose-cascade-node" | envsubst '$VLESS_DOMAIN' > ./docker-compose.yml
```

- [ ] **Step 5: Remove ip_forward sysctl**

Delete (line 151):
```bash
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
```

- [ ] **Step 6: Remove iptables rule for WG port 41820**

Delete:
```bash
iptables_add INPUT -p udp -m udp --dport 41820 -j ACCEPT
```

- [ ] **Step 7: WARP — оставить без изменений**

WARP не входит в scope этого плана (спека: "обсудить отдельно"). Не трогаем промпт, функцию `warp_install` и её вызов. Они остаются как есть.

- [ ] **Step 8: Update output section**

Remove WG UI output lines:
```bash
echo " WireGuard UI: https://$VLESS_DOMAIN/$WG_UI_PATH/"
echo " WG admin password: $WG_ADMIN_PASS"
```

- [ ] **Step 9: Verify**

Run: `grep -n 'WG_\|wg-easy\|wg_easy\|wireguard\|TPROXY\|tproxy\|41820\|51821\|iptables-legacy\|ip_forward\|bcrypt' setup-entry.sh`
Expected: No output (all WG/TPROXY references removed). Note: WARP references remain intentionally — out of scope.

Run: `grep -n 'VPS1_DOMAIN' setup-entry.sh`
Expected: prompt line + validation line + envsubst line

- [ ] **Step 10: Commit**

```bash
git add setup-entry.sh
git commit -m "feat: add VPS1_DOMAIN; remove WireGuard, TPROXY, WARP from VPS2 setup"
```

---

### Task 9: Update `CLAUDE.md`

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update architecture section**

Replace the traffic flow block:
```
Client → VPS2:443 (VLESS+REALITY) → XHTTP+REALITY (packet-up) → VPS1:49321 → Internet
Client → VPS2:51820 (WireGuard) → TPROXY → XRay chain → VPS1:49321 → Internet
```
With:
```
Client → VPS2:443 (VLESS+REALITY, steal_oneself) → XHTTP+REALITY (packet-up) → VPS1:49321 (steal_oneself) → Internet
```

- [ ] **Step 2: Update VPS1 description**

Change:
```
XRay on VPS1 listens on 49321, handles VLESS with REALITY (steals dl.google.com). VPS1 Marzban panel is accessible via SSH tunnel only — no reverse proxy exposed.
```
To:
```
XRay on VPS1 listens on 49321, handles VLESS with REALITY (steal_oneself with own domain + Angie). VPS1 Marzban panel is accessible via SSH tunnel only.
```

- [ ] **Step 3: Update setup-entry.sh description**

Change:
```
`setup-entry.sh` — VPS2 installer (Marzban panel + steal_oneself + chain outbound + TPROXY + wg-easy)
```
To:
```
`setup-entry.sh` — VPS2 installer (Marzban panel + steal_oneself + chain outbound)
```

- [ ] **Step 4: Update Important Notes**

Remove bullet:
```
- WG client traffic routed through TPROXY → dokodemo-door → chain outbound
```

Change:
```
- REALITY on VPS1 steals `dl.google.com` — no own domain needed on VPS1
```
To:
```
- REALITY on VPS1 uses steal_oneself with own domain + Angie for TLS termination
```

Add:
```
- VPS1 exposes port 80 for ACME HTTP-01 certificate renewal only
- Both VPS use own domains — eliminates ASN mismatch detectable by TSPU
```

Remove bullet:
```
- No WireGuard tunnel between servers — all inter-server traffic via XHTTP+REALITY on 49321
```

- [ ] **Step 5: Update Templates table**

Remove `compose-cascade-node` WG reference. Add `panel-angie` entry:

```
| `panel-angie` | VPS1: Angie (TLS + ACME + Confluence camouflage) |
```

- [ ] **Step 6: Update VPS1 port description**

Change:
```
- VPS1 only exposes port 49321 (XHTTP+REALITY inbound) + SSH — no 80/443/4123
```
To:
```
- VPS1 exposes port 49321 (XHTTP+REALITY steal_oneself) + 80 (ACME) + SSH — no 443/4123
```

- [ ] **Step 7: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md — steal_oneself on both VPS, remove WG references"
```

---

### Task 10: Update `README.md`

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Review current README**

Read the file and identify all WireGuard/TPROXY/WARP references and dl.google.com mentions.

- [ ] **Step 2: Update architecture description**

Remove all WireGuard, TPROXY, wg-easy references. Update VPS1 description to mention Angie + own domain. Add note about 2 domains required.

Update Quick Start section — VPS1 now prompts for domain.

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: update README — steal_oneself architecture, remove WG"
```
