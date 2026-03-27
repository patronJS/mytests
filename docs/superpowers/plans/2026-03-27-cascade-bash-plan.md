# Cascade XHTTP+REALITY Bash Scripts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Create two bash scripts (`setup-panel.sh` + `setup-node.sh`) and supporting templates for a two-VPS cascade bridge with XHTTP+REALITY, Marzban panel/node, and WireGuard.

**Architecture:** VPS1 (Germany, panel) accepts XHTTP+REALITY from VPS2. VPS2 (Russia, node) serves clients via XHTTP+REALITY / TCP Vision / WireGuard, chains all traffic to VPS1. Scripts download templates from GitHub, generate secrets at runtime, use envsubst.

**Tech Stack:** Bash, Docker Compose, XRay v26.3.23, Marzban, Angie, WireGuard (wg-easy), envsubst

**Spec:** `docs/superpowers/specs/2026-03-27-cascade-xhttp-design-v3.md`

---

## File Map

### Files to CREATE

| File | Responsibility |
|------|----------------|
| `setup-panel.sh` | VPS1 installer: Marzban panel + XRay XHTTP+REALITY inbound + WG tunnel |
| `setup-node.sh` | VPS2 installer: Marzban node + steal_oneself + chain outbound + wg-easy |
| `templates_for_script/panel-xray` | VPS1 XRay config ($VAR syntax) |
| `templates_for_script/panel-angie` | VPS1 Angie config |
| `templates_for_script/compose-panel` | VPS1 Docker Compose |
| `templates_for_script/node-xray` | VPS2 XRay config (steal_oneself + chain) |
| `templates_for_script/node-angie` | VPS2 Angie config (wg-easy UI proxy) |
| `templates_for_script/compose-cascade-node` | VPS2 Docker Compose (angie + marzban-node + wg-easy) |
| `templates_for_script/wg-tunnel-panel` | VPS1 WireGuard p2p tunnel config |
| `templates_for_script/wg-tunnel-node` | VPS2 WireGuard p2p tunnel config |

### Files UNCHANGED

| File | Reason |
|------|--------|
| `vps-setup.sh` | Existing single-VPS script, kept as-is |
| `templates_for_script/angie` | Used by vps-setup.sh |
| `templates_for_script/angie-marzban` | Used by vps-setup.sh |
| `templates_for_script/compose-*` (existing) | Used by vps-setup.sh |
| `templates_for_script/confluence` | Shared camouflage page — used by both old and new scripts |
| `templates_for_script/marzban` | Marzban .env template — reused by setup-panel.sh |
| `templates_for_script/xray_outbound` | Client config output template |
| `templates_for_script/sing_box_outbound` | Client config output template |
| `templates_for_script/00-disable-password` | SSH hardening template |
| All Ansible files (`tasks/`, `templates/`, `defaults/`, `handlers/`, `meta/`, `vars/`) | Not modified — Ansible role stays for Galaxy users |

---

## Task 1: VPS1 templates (panel-xray, panel-angie, compose-panel, wg-tunnel-panel)

**Files:**
- Create: `templates_for_script/panel-xray`
- Create: `templates_for_script/panel-angie`
- Create: `templates_for_script/compose-panel`
- Create: `templates_for_script/wg-tunnel-panel`

- [ ] **Step 1: Write `templates_for_script/panel-xray`**

XRay XHTTP+REALITY inbound for VPS1. Uses `$VAR` for envsubst:

```json
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "vless",
    "settings": {
      "clients": [{"id": "$UUID_LINK", "encryption": "none"}],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "xhttp",
      "security": "reality",
      "xhttpSettings": {
        "path": "/$XHTTP_PATH"
      },
      "realitySettings": {
        "dest": "127.0.0.1:4123",
        "xver": 1,
        "serverNames": ["$VLESS_DOMAIN"],
        "privateKey": "$XRAY_PIK",
        "shortIds": ["$SHORT_ID"]
      }
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls"],
      "routeOnly": true
    }
  }],
  "outbounds": [
    {"protocol": "freedom", "tag": "direct", "settings": {"domainStrategy": "UseIPv4"}},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "rules": [{"protocol": "bittorrent", "outboundTag": "block"}],
    "domainStrategy": "IPIfNonMatch"
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  }
}
```

- [ ] **Step 2: Write `templates_for_script/panel-angie`**

Based on existing `templates_for_script/angie-marzban` but for VPS1 panel. Uses `$VLESS_DOMAIN`, `$MARZBAN_PATH`, `$MARZBAN_SUB_PATH` (envsubst allowlist — Angie vars like `$host`, `$uri` must not be expanded).

Copy `templates_for_script/angie-marzban` as starting point, then verify it matches the spec section 4.1 pattern: ACME on :4123, proxy_protocol, Marzban location block at `/(MARZBAN_PATH|statics|MARZBAN_SUB_PATH|api|docs|redoc|openapi.json)`.

- [ ] **Step 3: Write `templates_for_script/compose-panel`**

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
      - ./marzban/xray_config.json:/code/xray_config.json:ro
      - ./marzban/xray-core:/var/lib/marzban/xray-core:ro
      - ./marzban_lib:/var/lib/marzban

volumes:
  angie-data:
    driver: local
    external: false
    name: angie-data
```

- [ ] **Step 4: Write `templates_for_script/wg-tunnel-panel`**

```ini
[Interface]
PrivateKey = $WG_TUNNEL_PIK
Address = 10.9.0.1/24
ListenPort = 51830
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i wg-tunnel -o eth0 -j ACCEPT; iptables -A FORWARD -i eth0 -o wg-tunnel -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg-tunnel -o eth0 -j ACCEPT; iptables -D FORWARD -i eth0 -o wg-tunnel -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE

# [Peer]
# PublicKey = <VPS2_WG_PBK>
# AllowedIPs = 10.8.0.0/24, 10.9.0.2/32
# Endpoint = <VPS2_IP>:51830
```

Note: `[Peer]` is commented out — VPS2 PBK is unknown until `setup-node.sh` runs. The `--add-wg-peer` flag in `setup-panel.sh` uncomments and fills this.

- [ ] **Step 5: Commit**

```bash
git add templates_for_script/panel-xray templates_for_script/panel-angie templates_for_script/compose-panel templates_for_script/wg-tunnel-panel
git commit -m "feat: add VPS1 panel templates for cascade XHTTP setup"
```

---

## Task 2: VPS2 templates (node-xray, node-angie, compose-cascade-node, wg-tunnel-node)

**Files:**
- Create: `templates_for_script/node-xray`
- Create: `templates_for_script/node-angie`
- Create: `templates_for_script/compose-cascade-node`
- Create: `templates_for_script/wg-tunnel-node`

- [ ] **Step 1: Write `templates_for_script/node-xray`**

Steal_oneself + chain outbound. All vars use `$VAR` syntax:

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
          "shortIds": ["$SHORT_ID"]
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
    }
  ],
  "outbounds": [
    {
      "tag": "chain-vps1",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$PANEL_DOMAIN",
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
          "serverName": "$PANEL_DOMAIN",
          "fingerprint": "chrome",
          "publicKey": "$PANEL_PBK",
          "shortId": "$PANEL_SHORT_ID"
        }
      }
    },
    {"protocol": "freedom", "tag": "direct"},
    {"protocol": "blackhole", "tag": "block"}
  ],
  "routing": {
    "rules": [
      {"protocol": "bittorrent", "outboundTag": "block"},
      {"inboundTag": ["reality-tcp", "xhttp-in"], "outboundTag": "chain-vps1"}
    ],
    "domainStrategy": "IPIfNonMatch"
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4"
  }
}
```

- [ ] **Step 2: Write `templates_for_script/node-angie`**

Based on existing `templates_for_script/angie` (standalone xray version) but with wg-easy UI proxy block. Envsubst allowlist: `$VLESS_DOMAIN $WG_UI_PATH`.

Add inside the `server` block with `server_name`:
```nginx
        location /$WG_UI_PATH/ {
            proxy_pass http://127.0.0.1:51821/;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
        }
```

- [ ] **Step 3: Write `templates_for_script/compose-cascade-node`**

Copy the Docker Compose from spec section 5.2 verbatim. Uses `$VLESS_DOMAIN`, `$WG_ADMIN_HASH` for envsubst.

- [ ] **Step 4: Write `templates_for_script/wg-tunnel-node`**

```ini
[Interface]
PrivateKey = $WG_TUNNEL_PIK
Address = 10.9.0.2/24
Table = off

[Peer]
PublicKey = $WG_TUNNEL_PEER_PBK
Endpoint = $VPS1_IP:51830
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
```

Note: `Table = off` prevents wg-quick from adding a default route that would hijack all host traffic.

- [ ] **Step 5: Commit**

```bash
git add templates_for_script/node-xray templates_for_script/node-angie templates_for_script/compose-cascade-node templates_for_script/wg-tunnel-node
git commit -m "feat: add VPS2 node templates for cascade XHTTP setup"
```

---

## Task 3: Write `setup-panel.sh`

**Files:**
- Create: `setup-panel.sh`

- [ ] **Step 1: Write the script**

The script follows spec section 9.1 steps 1-16. Structure it using the same patterns as existing `vps-setup.sh`:
- `set -e` at the top
- `GIT_BRANCH` and `GIT_REPO` exports for template URLs
- Functions for reusable logic (`docker_install`, `yq_install`, `bbr_enable`)
- Interactive prompts with `read -ep`

Key sections in order:

1. **Argument parsing**: check for `--add-wg-peer <PBK> <VPS2_IP>` flag — if present, append peer to wg-tunnel.conf, restart wg-quick@wg-tunnel, run `ping -c 3 10.9.0.2` to verify connectivity, then exit
2. **Root check** + deps install (`idn sudo dnsutils wamerican wireguard-tools zip unzip`)
3. **Domain input** + DNS verification (same pattern as vps-setup.sh lines 32-72)
4. **Docker + yq install** (same functions as vps-setup.sh)
5. **BBR + ip_forward** — check sysctl, append if missing, `sysctl -p`
6. **Secret generation**:
   ```bash
   export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core x25519 | head -n1 | cut -d' ' -f 2)
   export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core x25519 -i $XRAY_PIK | tail -2 | head -1 | cut -d' ' -f 2)
   export UUID_LINK=$(docker run --rm ghcr.io/xtls/xray-core uuid)
   export XHTTP_PATH=$(openssl rand -hex 12)
   export SHORT_ID=$(openssl rand -hex 8)
   export MARZBAN_USER=$(grep -E '^[a-z]{4,6}$' /usr/share/dict/words | shuf -n 1)
   export MARZBAN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
   export MARZBAN_PATH=$(openssl rand -hex 8)
   export MARZBAN_SUB_PATH=$(openssl rand -hex 8)
   export WG_TUNNEL_PIK=$(wg genkey)
   export WG_TUNNEL_PBK=$(echo $WG_TUNNEL_PIK | wg pubkey)
   ```
7. **XRay core download** — detect `$ARCH`, download to `/opt/xray-vps-setup/marzban/xray-core/`
8. **Template download + envsubst**:
   ```bash
   mkdir -p /opt/xray-vps-setup/marzban
   cd /opt/xray-vps-setup
   wget -qO- "$TEMPLATE_URL/panel-xray" | envsubst > ./marzban/xray_config.json
   wget -qO- "$TEMPLATE_URL/panel-angie" | envsubst '$VLESS_DOMAIN $MARZBAN_PATH $MARZBAN_SUB_PATH' > ./angie.conf
   wget -qO- "$TEMPLATE_URL/compose-panel" | envsubst > ./docker-compose.yml
   wget -qO- "$TEMPLATE_URL/marzban" | envsubst > ./marzban/.env
   wget -qO- "$TEMPLATE_URL/confluence" | envsubst > ./index.html
   ```
9. **File permissions**: `chmod 600` on xray_config.json, .env; `chmod 644` on angie.conf, index.html, docker-compose.yml
10. **WG tunnel config**: envsubst wg-tunnel-panel to `/etc/wireguard/wg-tunnel.conf`, `chmod 600`, `systemctl enable wg-quick@wg-tunnel`
11. **Docker compose up**
12. **Marzban init**: `sleep 5; docker exec marzban marzban-cli admin import-from-env`
13. **Update panel default host**: same API logic as vps-setup.sh lines 477-510
14. **iptables** (UNCONDITIONAL — always applied, not inside SSH-hardening branch):
    - 443 open, 80 open, SSH port, 51830/udp from anywhere
    - ICMP, ESTABLISHED/RELATED, loopback
    - default DROP
    - `netfilter-persistent save`
15. **Output**: print panel URL, credentials, and all values needed for setup-node.sh

- [ ] **Step 2: Make executable**

```bash
chmod +x setup-panel.sh
```

- [ ] **Step 3: Commit**

```bash
git add setup-panel.sh
git commit -m "feat: add setup-panel.sh for VPS1 cascade deployment"
```

---

## Task 4: Write `setup-node.sh`

**Files:**
- Create: `setup-node.sh`

- [ ] **Step 1: Write the script**

Follows spec section 9.2 steps 1-22. Same patterns as vps-setup.sh.

Key sections in order:

1. **Root check** + deps install
2. **Domain input** + DNS verification
3. **VPS1 connection info prompts**:
   ```bash
   read -ep "Enter VPS1 panel domain:"$'\n' PANEL_DOMAIN
   export PANEL_DOMAIN
   read -ep "Enter VPS1 IP address:"$'\n' VPS1_IP
   export VPS1_IP
   read -ep "Enter VPS1 public key (PBK):"$'\n' PANEL_PBK
   export PANEL_PBK
   read -ep "Enter VPS1 short ID:"$'\n' PANEL_SHORT_ID
   export PANEL_SHORT_ID
   read -ep "Enter inter-VPS UUID:"$'\n' UUID_LINK
   export UUID_LINK
   read -ep "Enter XHTTP path:"$'\n' XHTTP_PATH
   export XHTTP_PATH
   read -ep "Enter VPS1 WG tunnel public key:"$'\n' PANEL_WG_PBK
   export PANEL_WG_PBK
   ```
4. **Panel credentials** for node_api_setup:
   ```bash
   read -ep "Enter panel admin username:"$'\n' PANEL_USER
   export PANEL_USER
   read -s -ep "Enter panel admin password:"$'\n' PANEL_PASS
   export PANEL_PASS
   echo
   ```
5. **Validate inputs** — fail fast on typos:
   ```bash
   # UUID format: 8-4-4-4-12 hex
   [[ "$UUID_LINK" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "Invalid UUID_LINK format"; exit 1; }
   # PBK: base64-like, 43 chars
   [[ ${#PANEL_PBK} -ge 40 ]] || { echo "PANEL_PBK looks too short"; exit 1; }
   # SHORT_ID: hex, 16 chars
   [[ "$PANEL_SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || { echo "Invalid PANEL_SHORT_ID format"; exit 1; }
   # IP: basic IPv4 check
   [[ "$VPS1_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid VPS1_IP format"; exit 1; }
   # XHTTP_PATH: hex, 24 chars
   [[ "$XHTTP_PATH" =~ ^[0-9a-f]{24}$ ]] || { echo "Invalid XHTTP_PATH format"; exit 1; }
   # WG PBK: base64, 44 chars with trailing =
   [[ ${#PANEL_WG_PBK} -ge 40 ]] || { echo "PANEL_WG_PBK looks too short"; exit 1; }
   ```
6. **Optional config prompts** (SSH hardening, WARP)
6. **Docker + yq install, BBR + ip_forward**
7. **Local secret generation**:
   ```bash
   export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core x25519 | head -n1 | cut -d' ' -f 2)
   export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core x25519 -i $XRAY_PIK | tail -2 | head -1 | cut -d' ' -f 2)
   export SHORT_ID=$(openssl rand -hex 8)
   export CLIENT_UUID=$(docker run --rm ghcr.io/xtls/xray-core uuid)
   export CLIENT_XHTTP_PATH=$(openssl rand -hex 12)
   export WG_TUNNEL_PIK=$(wg genkey)
   export WG_TUNNEL_PBK=$(echo $WG_TUNNEL_PIK | wg pubkey)
   export WG_ADMIN_PASS=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 13; echo)
   export WG_ADMIN_HASH=$(docker run --rm ghcr.io/wg-easy/wg-easy wgpw "$WG_ADMIN_PASS")
   export WG_UI_PATH=$(openssl rand -hex 8)
   ```
8. **XRay core download** to `/opt/xray-vps-setup/node/xray-core/`
9. **Template download + envsubst**:
   ```bash
   mkdir -p /opt/xray-vps-setup/node
   cd /opt/xray-vps-setup
   wget -qO- "$TEMPLATE_URL/node-xray" | envsubst > ./node/xray_config.json
   wget -qO- "$TEMPLATE_URL/node-angie" | envsubst '$VLESS_DOMAIN $WG_UI_PATH' > ./angie.conf
   wget -qO- "$TEMPLATE_URL/compose-cascade-node" | envsubst > ./docker-compose.yml
   wget -qO- "$TEMPLATE_URL/confluence" | envsubst > ./index.html
   touch ./ssl_client_cert.pem
   ```
10. **File permissions**: `chmod 600` on sensitive files
11. **WG tunnel config**: alias the peer key `export WG_TUNNEL_PEER_PBK="$PANEL_WG_PBK"`, then envsubst `wg-tunnel-node` with `$WG_TUNNEL_PIK`, `$WG_TUNNEL_PEER_PBK`, `$VPS1_IP` to `/etc/wireguard/wg-tunnel.conf`; `systemctl enable --now wg-quick@wg-tunnel`
12. **DNS fallback**: `echo "$VPS1_IP $PANEL_DOMAIN" >> /etc/hosts`
13. **Start angie + wg-easy ONLY** (not marzban-node yet):
    ```bash
    docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d angie wg-easy
    ```
14. **`node_api_setup()`**: Copy and adapt from existing vps-setup.sh lines 206-363. Key changes:
    - Uses `$PANEL_DOMAIN`, `$PANEL_USER`, `$PANEL_PASS` from prompts
    - Writes cert to `/opt/xray-vps-setup/ssl_client_cert.pem`
    - Uses ports 62050/62051 instead of 62001/62002
    - Verifies cert is non-empty before proceeding
15. **Start marzban-node**:
    ```bash
    docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d marzban-node
    ```
16. **iptables** (UNCONDITIONAL — always applied, not inside SSH-hardening branch):
    - 443, 80, 51820/udp open
    - 62050/62051 restricted to `$VPS1_IP` (ACCEPT from VPS1, REJECT from others)
    - SSH port, ICMP, ESTABLISHED/RELATED, loopback
    - default DROP
    - `netfilter-persistent save`
17. **Optional SSH hardening** (same pattern as vps-setup.sh)
18. **Optional WARP** (same pattern as vps-setup.sh, with config path `/opt/xray-vps-setup/node/xray_config.json`)
19. **Output**: print to stdout:
    - VLESS+XHTTP+REALITY clipboard URI
    - VLESS+REALITY TCP clipboard URI
    - XRay outbound JSON block for XHTTP client (spec section 11)
    - WG UI URL + admin password
    - VPS1 WG peer setup instructions (config file edit + systemctl restart)
    - Post-setup verification checklist (ping 10.9.0.1, connect from client)

- [ ] **Step 2: Make executable**

```bash
chmod +x setup-node.sh
```

- [ ] **Step 3: Commit**

```bash
git add setup-node.sh
git commit -m "feat: add setup-node.sh for VPS2 cascade deployment"
```

---

## Task 5: Verify templates and scripts

- [ ] **Step 1: Validate JSON templates**

```bash
python3 -c "import json; json.load(open('templates_for_script/panel-xray'))"
python3 -c "import json; json.load(open('templates_for_script/node-xray'))"
```

Expected: No errors. Note: `$VAR` placeholders will be in the JSON — python will parse them as string values, which is fine.

Wait — JSON with unquoted `$VAR` won't parse. Templates contain `"$UUID_LINK"` (quoted), so this will parse as a string. Verify this is the case for all vars.

- [ ] **Step 2: Check envsubst variable coverage**

```bash
# Panel templates — vars that need to be exported
grep -ohP '\$[A-Z_]+' templates_for_script/panel-xray | sort -u
grep -ohP '\$[A-Z_]+' templates_for_script/node-xray | sort -u
```

Cross-reference every `$VAR` found against the export statements in setup-panel.sh / setup-node.sh. Every var must be exported before envsubst runs.

- [ ] **Step 3: Shellcheck**

```bash
shellcheck setup-panel.sh
shellcheck setup-node.sh
```

Fix any warnings. Common issues: unquoted variables, missing `export`, unused vars.

- [ ] **Step 4: Commit fixes**

```bash
git add -A
git commit -m "fix: template and script validation fixes"
```

---

## Task 6: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md**

Add the cascade architecture alongside existing content. Key additions:

- **Cascade mode**: describe `setup-panel.sh` + `setup-node.sh` workflow
- **Commands**: add cascade deployment commands
- **File Mapping**: add new templates with `panel-`/`node-` prefix
- **Important Notes**: XHTTP requires no Vision flow, `mode: stream-one`, XRay >= v26.2.6

Keep existing single-VPS documentation intact — `vps-setup.sh` still works.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with cascade XHTTP architecture"
```
