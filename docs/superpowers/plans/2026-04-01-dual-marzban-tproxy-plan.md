# Dual Independent Marzban + TPROXY Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace broken panel+node architecture with two independent Marzban instances; route WG client traffic through VLESS chain via TPROXY; eliminate WireGuard tunnel between servers.

**Architecture:** VPS1 (Germany) runs Marzban + XRay XHTTP inbound — accepts cascade traffic only. VPS2 (Russia) runs Marzban + XRay with chain outbound to VPS1, plus dokodemo-door TPROXY inbound that captures WG client L3 traffic and routes it through the VLESS chain. No WireGuard between servers.

**Tech Stack:** Bash, Docker Compose, XRay v26.3.23, Marzban (latest), Angie, wg-easy, iptables TPROXY

---

## File Structure

### Modified files

| File | Responsibility |
|------|---------------|
| `setup-panel.sh` | VPS1 installer — simplified, no WG tunnel, no NAT |
| `setup-node.sh` → `setup-entry.sh` | VPS2 installer — own Marzban, TPROXY, no node API |
| `templates_for_script/node-xray` | VPS2 XRay config — add dokodemo-door, update routing |
| `templates_for_script/node-angie` | VPS2 Angie — add Marzban panel location |
| `templates_for_script/compose-cascade-node` | VPS2 Docker Compose — marzban-node → marzban |
| `templates_for_script/compose-panel` | VPS1 Docker Compose — remove :ro from xray_config |
| `README.md` | Full rewrite for new architecture |
| `CLAUDE.md` | Update architecture description |

### Deleted files

| File | Reason |
|------|--------|
| `templates_for_script/wg-tunnel-panel` | No WG tunnel between servers |
| `templates_for_script/wg-tunnel-node` | No WG tunnel between servers |

---

### Task 1: Update node-xray template — add dokodemo-door + update routing

**Files:**
- Modify: `templates_for_script/node-xray`

- [ ] **Step 1: Add tproxy-in inbound and update routing**

Replace the entire file content with:

```json
{
  "log": {"loglevel": "warning"},
  "inbounds": [
    {
      "tag": "reality-tcp",
      "listen": "0.0.0.0",
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$CLIENT_UUID", "flow": "xtls-rprx-vision"}],
        "decryption": "none",
        "fallbacks": [{"dest": "@xhttp"}]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "127.0.0.1:4123",
          "xver": 1,
          "serverNames": ["$VLESS_DOMAIN"],
          "privateKey": "$XRAY_PIK",
          "shortIds": [$SHORT_IDS]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": true
      }
    },
    {
      "tag": "xhttp-in",
      "listen": "@xhttp",
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$CLIENT_UUID"}],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {"path": "/$CLIENT_XHTTP_PATH"}
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": true
      }
    },
    {
      "tag": "tproxy-in",
      "port": 12345,
      "protocol": "dokodemo-door",
      "settings": {
        "network": "tcp,udp",
        "followRedirect": true
      },
      "streamSettings": {
        "sockopt": {
          "tproxy": "tproxy"
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"]
      }
    }
  ],
  "outbounds": [
    {
      "tag": "chain-vps1",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$VPS1_DOMAIN",
          "port": 443,
          "users": [{"id": "$UUID_LINK", "encryption": "none"}]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "xhttpSettings": {
          "path": "/$XHTTP_PATH",
          "mode": "stream-one"
        },
        "realitySettings": {
          "serverName": "$VPS1_DOMAIN",
          "fingerprint": "chrome",
          "publicKey": "$VPS1_PBK",
          "shortId": "$VPS1_SHORT_ID"
        }
      },
      "streamSettings.sockopt": {
        "mark": 255
      }
    },
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "rules": [
      {"protocol": "bittorrent", "outboundTag": "block"},
      {"inboundTag": ["reality-tcp", "xhttp-in", "tproxy-in"], "outboundTag": "chain-vps1"}
    ],
    "domainStrategy": "IPIfNonMatch"
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  }
}
```

Key changes from current:
- Added `tproxy-in` dokodemo-door inbound on port 12345
- Renamed `$PANEL_DOMAIN` → `$VPS1_DOMAIN`, `$PANEL_PBK` → `$VPS1_PBK`, `$PANEL_SHORT_ID` → `$VPS1_SHORT_ID`
- Added `tproxy-in` to routing rule alongside `reality-tcp` and `xhttp-in`
- Added `sockopt.mark: 255` to chain outbound (prevents TPROXY loop — outbound traffic from XRay itself must not be re-captured)
- Removed WARP outbound/routing (WARP will be added dynamically by setup-entry.sh if selected)

**Note on sockopt.mark:** XRay outbound packets get mark 255. The TPROXY iptables rules must exclude mark 255 to prevent loops. This is the standard XRay transparent proxy pattern.

- [ ] **Step 2: Verify JSON is valid (with envsubst placeholders)**

Run: `python3 -c "print('Template syntax OK')"` — JSON can't be validated with `$VAR` placeholders, but visually verify bracket matching.

- [ ] **Step 3: Commit**

```bash
git add templates_for_script/node-xray
git commit -m "feat: add dokodemo-door tproxy inbound for WG clients, rename PANEL vars to VPS1"
```

---

### Task 2: Update compose-cascade-node — replace marzban-node with marzban

**Files:**
- Modify: `templates_for_script/compose-cascade-node`

- [ ] **Step 1: Replace marzban-node service with marzban, update wg-easy POST_UP/DOWN**

Replace entire file with:

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
    env_file: ./node/.env
    network_mode: host
    cap_add:
      - NET_ADMIN
    volumes:
      - ./node/xray_config.json:/code/xray_config.json
      - ./node/xray-core:/code/xray-core:ro
      - marzban_lib:/var/lib/marzban

  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15
    container_name: wg-easy
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    environment:
      - WG_HOST=$VLESS_DOMAIN
      - PASSWORD_HASH=$WG_ADMIN_HASH
      - WG_PORT=51820
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_ALLOWED_IPS=0.0.0.0/0
      - PORT=51821
      - WG_POST_UP=ip rule add fwmark 1 table 100 2>/dev/null; ip route add local 0.0.0.0/0 dev lo table 100 2>/dev/null; iptables -t mangle -A PREROUTING -s 10.8.0.0/24 -m mark ! --mark 255 -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1; iptables -t mangle -A PREROUTING -s 10.8.0.0/24 -m mark ! --mark 255 -p udp -j TPROXY --on-port 12345 --tproxy-mark 1
      - WG_POST_DOWN=iptables -t mangle -D PREROUTING -s 10.8.0.0/24 -m mark ! --mark 255 -p tcp -j TPROXY --on-port 12345 --tproxy-mark 1 2>/dev/null; iptables -t mangle -D PREROUTING -s 10.8.0.0/24 -m mark ! --mark 255 -p udp -j TPROXY --on-port 12345 --tproxy-mark 1 2>/dev/null; ip route del local 0.0.0.0/0 dev lo table 100 2>/dev/null; ip rule del fwmark 1 table 100 2>/dev/null
    volumes:
      - wg-data:/etc/wireguard

volumes:
  angie-data:
    driver: local
    external: false
    name: angie-data
  marzban_lib:
    driver: local
  wg-data:
    driver: local
```

Key changes:
- `marzban-node` → `marzban` (full panel, reads local xray_config.json)
- `env_file: ./node/.env` (own Marzban .env)
- `cap_add: NET_ADMIN` on marzban (needed for XRay TPROXY sockopt)
- `xray_config.json` mounted **without** `:ro` (Marzban needs write access)
- WG_POST_UP/DOWN: replaced WG-tunnel routing with TPROXY rules
- TPROXY rules exclude mark 255 (`-m mark ! --mark 255`) to prevent loop with XRay outbound
- Removed `marzban-node-data` volume, added `marzban_lib`
- Removed `sysctls` (incompatible with network_mode:host)

- [ ] **Step 2: Commit**

```bash
git add templates_for_script/compose-cascade-node
git commit -m "feat: replace marzban-node with standalone marzban, add TPROXY rules"
```

---

### Task 3: Update node-angie — add Marzban panel location

**Files:**
- Modify: `templates_for_script/node-angie`

- [ ] **Step 1: Add Marzban panel location before wg-easy location**

In the server block with `proxy_protocol` (the main HTTPS server), add the Marzban location **before** the wg-easy location. The current wg-easy location is at line 73.

Insert before `location /$WG_UI_PATH/`:

```nginx
        location ~* /($MARZBAN_PATH|statics|$MARZBAN_SUB_PATH|api|docs|redoc|openapi.json) {
            proxy_pass http://127.0.0.1:8000;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        }
```

- [ ] **Step 2: Commit**

```bash
git add templates_for_script/node-angie
git commit -m "feat: add Marzban panel reverse proxy to node-angie"
```

---

### Task 4: Update compose-panel — remove :ro from xray_config

**Files:**
- Modify: `templates_for_script/compose-panel`

- [ ] **Step 1: Remove :ro from xray_config.json mount**

Change line 19 from:
```yaml
      - ./marzban/xray_config.json:/code/xray_config.json:ro
```
to:
```yaml
      - ./marzban/xray_config.json:/code/xray_config.json
```

This fixes the `OSError: Read-only file system` error when Marzban tries to update the config.

- [ ] **Step 2: Commit**

```bash
git add templates_for_script/compose-panel
git commit -m "fix: allow Marzban to write xray_config.json (remove :ro mount)"
```

---

### Task 5: Simplify setup-panel.sh — remove WG tunnel, NAT, simplify output

**Files:**
- Modify: `setup-panel.sh`

- [ ] **Step 1: Remove --add-wg-peer mode**

Delete lines 5-27 (the entire `if [[ "${1:-}" == "--add-wg-peer" ]]` block).

- [ ] **Step 2: Remove wireguard-tools from dependencies**

Line 41: remove `wireguard-tools` from `apt-get install`.

- [ ] **Step 3: Remove WG tunnel key generation**

Delete lines 150-151:
```bash
export WG_TUNNEL_PIK=$(wg genkey)
export WG_TUNNEL_PBK=$(echo $WG_TUNNEL_PIK | wg pubkey)
```

- [ ] **Step 4: Remove WG tunnel config section**

Delete lines 175-186 (entire WireGuard tunnel config block):
```bash
# Detect default network interface
export DEFAULT_IFACE=...
# WireGuard tunnel config
mkdir -p /etc/wireguard
fetch_template "wg-tunnel-panel" ...
systemctl enable wg-quick@wg-tunnel
```

- [ ] **Step 5: Remove ip_forward from sysctl**

Delete line 130:
```bash
grep -q "net.ipv4.ip_forward" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
```

XRay handles outbound via freedom — no kernel forwarding needed.

- [ ] **Step 6: Remove port 51830 from iptables**

Delete line 265:
```bash
iptables_add INPUT -p udp -m udp --dport 51830 -j ACCEPT
```

- [ ] **Step 7: Update output section**

Replace lines 276-291 with:

```bash
echo "========================================="
echo " Panel URL: https://$VLESS_DOMAIN/$MARZBAN_PATH"
echo " Panel user: $MARZBAN_USER"
echo " Panel pass: $MARZBAN_PASS"
echo ""
echo " === Values for setup-entry.sh ==="
echo " VPS1_DOMAIN:    $VLESS_DOMAIN"
echo " VPS1_PBK:       $XRAY_PBK"
echo " VPS1_SHORT_ID:  $SHORT_ID"
echo " UUID_LINK:      $UUID_LINK"
echo " XHTTP_PATH:     $XHTTP_PATH"
echo "========================================="
```

- [ ] **Step 8: Run syntax check**

```bash
bash -n setup-panel.sh
```

Expected: no output (success).

- [ ] **Step 9: Commit**

```bash
git add setup-panel.sh
git commit -m "refactor: simplify VPS1 — remove WG tunnel, NAT, add-wg-peer mode"
```

---

### Task 6: Rewrite setup-entry.sh (rename from setup-node.sh)

**Files:**
- Rename: `setup-node.sh` → `setup-entry.sh`
- Modify: `setup-entry.sh`

- [ ] **Step 1: Rename file**

```bash
git mv setup-node.sh setup-entry.sh
```

- [ ] **Step 2: Update input prompts — remove panel credentials, WG tunnel key, rename vars**

Replace lines 75-100 (VPS1 connection info + panel credentials + validation) with:

```bash
# Ask VPS1 connection info
read -ep "Enter VPS1 domain:"$'\n' VPS1_DOMAIN; export VPS1_DOMAIN
read -ep "Enter VPS1 IP address:"$'\n' VPS1_IP; export VPS1_IP
read -ep "Enter VPS1 public key (PBK):"$'\n' VPS1_PBK; export VPS1_PBK
read -ep "Enter VPS1 short ID:"$'\n' VPS1_SHORT_ID; export VPS1_SHORT_ID
read -ep "Enter inter-VPS UUID:"$'\n' UUID_LINK; export UUID_LINK
read -ep "Enter XHTTP path:"$'\n' XHTTP_PATH; export XHTTP_PATH

# Input validation
[[ "$UUID_LINK" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "Invalid UUID_LINK format"; exit 1; }
[[ ${#VPS1_PBK} -ge 40 ]] || { echo "VPS1_PBK looks too short"; exit 1; }
[[ "$VPS1_SHORT_ID" =~ ^[0-9a-f]{2,16}$ ]] && (( ${#VPS1_SHORT_ID} % 2 == 0 )) || { echo "Invalid VPS1_SHORT_ID: must be 2-16 even-length hex chars"; exit 1; }
[[ "$VPS1_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VPS1_IP format"; exit 1; }
[[ "$XHTTP_PATH" =~ ^[0-9a-f]{24}$ ]] || { echo "Invalid XHTTP_PATH format"; exit 1; }
```

Removed: `PANEL_DOMAIN`, `PANEL_PBK`, `PANEL_SHORT_ID`, `PANEL_WG_PBK`, `PANEL_USER`, `PANEL_PASS`, `VPS2_IP`.

- [ ] **Step 3: Add Marzban credentials generation**

After the secret generation section (after `WG_UI_PATH` generation), add:

```bash
export MARZBAN_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
export MARZBAN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
export MARZBAN_PATH=$(openssl rand -hex 8)
export MARZBAN_SUB_PATH=$(openssl rand -hex 8)
```

- [ ] **Step 4: Remove WG tunnel key generation and config**

Delete these lines:
```bash
export WG_TUNNEL_PIK=$(wg genkey)
export WG_TUNNEL_PBK=$(echo $WG_TUNNEL_PIK | wg pubkey)
export WG_TUNNEL_PEER_PBK="$PANEL_WG_PBK"
```

Delete the WG tunnel config section:
```bash
# WireGuard tunnel config
mkdir -p /etc/wireguard
fetch_template "wg-tunnel-node" | envsubst ...
chmod 600 /etc/wireguard/wg-tunnel.conf
systemctl enable --now wg-quick@wg-tunnel
```

Remove `wireguard-tools` from `apt-get install` dependencies.

- [ ] **Step 5: Add Marzban .env download and update angie envsubst**

In the template download section, add:

```bash
fetch_template "marzban" | envsubst > ./node/.env
chmod 600 ./node/.env
```

Update angie envsubst to include Marzban paths:
```bash
fetch_template "node-angie" | envsubst '$VLESS_DOMAIN $WG_UI_PATH $MARZBAN_PATH $MARZBAN_SUB_PATH' > ./angie.conf
```

- [ ] **Step 6: Remove ssl_client_cert.pem creation**

Delete:
```bash
touch ./ssl_client_cert.pem
```

And remove from chmod:
```bash
chmod 600 ./node/xray_config.json ./ssl_client_cert.pem
```
→
```bash
chmod 600 ./node/xray_config.json ./node/.env
```

- [ ] **Step 7: Remove node_api_setup() and /etc/hosts hack**

Delete entirely:
- `grep -q "$PANEL_DOMAIN" /etc/hosts || echo "$VPS1_IP $PANEL_DOMAIN" >> /etc/hosts`
- `docker compose ... up -d angie wg-easy` (partial start)
- The entire `node_api_setup()` function (lines 218-377)
- `node_api_setup` call
- `docker compose ... up -d marzban-node`

Replace with DNS fallback for chain outbound + single full start:

```bash
# DNS fallback — ensure VPS1 domain resolves for chain outbound
grep -q "$VPS1_DOMAIN" /etc/hosts || echo "$VPS1_IP $VPS1_DOMAIN" >> /etc/hosts

# Start all containers
docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d
```

- [ ] **Step 8: Add Marzban init (same pattern as setup-panel.sh)**

After `docker compose up -d`, add:

```bash
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
```

- [ ] **Step 9: Update iptables — remove 51830, 62050, 62051 rules**

Remove these lines:
```bash
iptables_add INPUT -s $VPS1_IP -p udp -m udp --dport 51830 -j ACCEPT
iptables_add INPUT -p udp -m udp --dport 51830 -j DROP
iptables_add INPUT -s $VPS1_IP -p tcp -m tcp --dport 62050 -j ACCEPT
iptables_add INPUT -s $VPS1_IP -p tcp -m tcp --dport 62051 -j ACCEPT
iptables_add INPUT -p tcp -m tcp --dport 62050 -j REJECT --reject-with tcp-reset
iptables_add INPUT -p tcp -m tcp --dport 62051 -j REJECT --reject-with tcp-reset
```

These ports are no longer used (no WG tunnel, no marzban-node).

- [ ] **Step 10: Update output section**

Replace the output section with:

```bash
# Cleanup temp files
rm -f /tmp/panel_hosts.json /tmp/panel_hosts_updated.json /tmp/xray.zip

# Output
clear
echo "========================================="
echo " VPS2 Marzban Panel: https://$VLESS_DOMAIN/$MARZBAN_PATH"
echo " Panel user: $MARZBAN_USER"
echo " Panel pass: $MARZBAN_PASS"
echo ""
echo " WireGuard UI: https://$VLESS_DOMAIN/$WG_UI_PATH/"
echo " WG admin password: $WG_ADMIN_PASS"
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
```

- [ ] **Step 11: Update version comment**

Change line 22:
```bash
# Pinned versions: yq=v4.52.5, marzban-node=v0.5.2, wg-easy=15, angie=minimal
```
to:
```bash
# Pinned versions: yq=v4.52.5, marzban=latest, wg-easy=15, angie=minimal
```

- [ ] **Step 12: Run syntax check**

```bash
bash -n setup-entry.sh
```

Expected: no output (success).

- [ ] **Step 13: Commit**

```bash
git add setup-entry.sh
git commit -m "feat: rewrite VPS2 installer — own Marzban, TPROXY for WG, no node API"
```

---

### Task 7: Delete WG tunnel templates

**Files:**
- Delete: `templates_for_script/wg-tunnel-panel`
- Delete: `templates_for_script/wg-tunnel-node`

- [ ] **Step 1: Remove files**

```bash
git rm templates_for_script/wg-tunnel-panel templates_for_script/wg-tunnel-node
```

- [ ] **Step 2: Commit**

```bash
git commit -m "chore: remove WG tunnel templates (no longer used)"
```

---

### Task 8: Update README.md

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Rewrite README**

Replace entire content with updated architecture, installation steps, and instructions reflecting:
- Two independent Marzban panels
- No WG tunnel between servers
- TPROXY for WG clients
- `setup-entry.sh` instead of `setup-node.sh`
- Simplified VPS1 prompts (no WG_TUNNEL_PBK)
- VPS2 has its own panel for client management
- No `--add-wg-peer` step
- Updated "Values for setup-entry.sh" table (VPS1_PBK, VPS1_SHORT_ID, no panel credentials)

Key sections to update:
- Architecture diagram: remove WG tunnel line between servers, add TPROXY
- Component list: VPS2 = Marzban panel (not node)
- Step 2 output: remove WG_TUNNEL_PBK
- Step 3: fewer prompts (no panel credentials, no WG key)
- Remove Step 4 (--add-wg-peer)
- Step 5 (verify): remove ping 10.9.0.x, add "check IP at ipinfo.io"
- Important details: update constraints

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: rewrite README for dual Marzban + TPROXY architecture"
```

---

### Task 9: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update architecture and components**

Update:
- Architecture section: two independent Marzban, no WG tunnel
- Traffic flow: add TPROXY path for WG clients
- Script names: `setup-entry.sh`
- Templates table: update compose-cascade-node description, remove wg-tunnel templates
- Important Notes: remove WG tunnel notes, add TPROXY notes

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for dual Marzban + TPROXY architecture"
```

---

### Task 10: Clean VPS servers and test end-to-end

- [ ] **Step 1: Clean VPS1**

SSH to VPS1 and remove all previous installation artifacts.

- [ ] **Step 2: Clean VPS2**

SSH to VPS2 and remove all previous installation artifacts.

- [ ] **Step 3: Push changes to GitHub**

```bash
git push origin main
```

- [ ] **Step 4: Run setup-panel.sh on VPS1**

```bash
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-panel.sh)
```

Save output values.

- [ ] **Step 5: Run setup-entry.sh on VPS2**

```bash
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-entry.sh)
```

Enter VPS1 values from step 4.

- [ ] **Step 6: Create test user in VPS2 Marzban panel**

Open `https://<vps2-domain>/<marzban-path>` and create a user with VLESS proxy.

- [ ] **Step 7: Test VLESS connection**

Connect via VLESS link from VPS2 panel. Verify IP at ipinfo.io shows VPS1 (Germany).

- [ ] **Step 8: Test WireGuard connection**

Create WG config in wg-easy UI. Connect via WireGuard. Verify IP at ipinfo.io shows VPS1 (Germany) — confirming TPROXY routes WG traffic through VLESS chain.
