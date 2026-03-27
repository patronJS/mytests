# Cascade XHTTP+REALITY Bridge Architecture

**Date:** 2026-03-27
**Status:** Draft (v3 — bash scripts only, no Ansible)
**Scope:** Two-VPS cascade with XHTTP transport, delivered via standalone bash scripts

---

## 1. Overview

Bridge architecture using two VPS servers to bypass Russian TSPU/DPI:

```
Clients (Russia) --> VPS2 (Russia, Marzban Node) --XHTTP+REALITY--> VPS1 (Germany, Marzban Panel) --> Internet
```

- **VPS1 (Germany):** Marzban panel, exit node, XHTTP+REALITY inbound
- **VPS2 (Russia):** Marzban node, client entry point, chain outbound to VPS1

### Client protocols on VPS2

| Priority | Protocol | Port | Notes |
|----------|----------|------|-------|
| Primary | VLESS+XHTTP+REALITY | 443 | Best DPI resistance, via `steal_oneself` fallback |
| Fallback | VLESS+REALITY (TCP+Vision) | 443 | Same port, direct REALITY inbound |
| Alternative | WireGuard | 51820/udp | `wg-easy` Docker container |

### Inter-VPS link (VPS2 -> VPS1)

- VLESS+XHTTP+REALITY, `stream-one` mode (pinned, not auto — see issue #5635)
- All client inbounds on VPS2 route through single chain outbound to VPS1

### Delivery mechanism

Two standalone bash scripts, no Ansible:

| Script | Target | Purpose |
|--------|--------|---------|
| `setup-panel.sh` | VPS1 (Germany) | Install Marzban panel + XRay XHTTP inbound |
| `setup-node.sh` | VPS2 (Russia) | Install Marzban node + steal_oneself + chain outbound + wg-easy |

Templates live in `templates_for_script/` using `$VAR` syntax for `envsubst`. Scripts download them from raw GitHub URLs at runtime (same pattern as existing `vps-setup.sh`).

---

## 2. Network Architecture

```
                          TSPU/DPI
                            |
Clients (Russia)            |          VPS2 (Russia)                              VPS1 (Germany)
                            |
[VLESS+XHTTP+REALITY]------+-----> :443 steal_oneself ----XHTTP+REALITY----> :443 XRay inbound --> Internet
[VLESS+REALITY TCP]  ------+-----> :443 direct         ----XHTTP+REALITY---->     (Marzban panel)
[WireGuard]          ------+-----> :51820 wg-easy -----WG tunnel (p2p)-----> WG peer --> Internet
                            |        (Marzban node)
                            |
                            |     VPS1 (panel) ---> VPS2:62050 (node API, restricted to VPS1 IP)
```

### Traffic flow detail

1. **XHTTP clients:** TLS ClientHello -> REALITY on :443 -> default fallback -> `@xhttp` unix socket -> XHTTP inbound -> chain outbound to VPS1
2. **TCP Vision clients:** TLS ClientHello -> REALITY on :443 -> direct VLESS+Vision handling (client has `flow: xtls-rprx-vision`, no fallback triggered) -> chain outbound to VPS1
3. **WireGuard clients:** UDP :51820 -> wg-easy container (`network_mode: host`) -> host policy routing via p2p WG tunnel -> VPS1 -> Internet

### Fallback mechanism (steal_oneself)

The `reality-tcp` inbound on :443 has a single default fallback `{"dest": "@xhttp"}`. The demux works as follows:
- Clients connecting with `flow: xtls-rprx-vision` are handled directly by the TCP inbound (Vision flow is consumed at the transport layer, no fallback)
- Clients connecting **without** `flow` (i.e. XHTTP clients) trigger the default fallback to `@xhttp` unix socket
- This is NOT path-based routing — it is flow-based: Vision clients stay, non-Vision clients fall through
- The `path` on the `xhttp-in` inbound is validated after the connection reaches `@xhttp`

---

## 3. Port Allocation

### VPS1 (Germany, Panel)

| Port | Service | Access | iptables |
|------|---------|--------|----------|
| 443 | XRay (VLESS+XHTTP+REALITY inbound) | Public | `-A INPUT -p tcp --dport 443 -j ACCEPT` |
| 80 | Angie (HTTP->HTTPS redirect) | Public | `-A INPUT -p tcp --dport 80 -j ACCEPT` |
| 4123 | Angie internal (TLS, ACME, Marzban panel UI) | Localhost + REALITY dest | No iptables rule needed (localhost only) |
| 51830/udp | WireGuard peer-to-peer tunnel | Only from VPS2 IP | `-A INPUT -s $VPS2_IP -p udp --dport 51830 -j ACCEPT` |
| $SSH_PORT | SSH | Public | `-A INPUT -p tcp --dport $SSH_PORT -j ACCEPT` |

**Note:** Port 443 on VPS1 remains open. REALITY ensures only authorized clients (VPS2 with correct PBK/shortId) can establish a VLESS connection. Unauthorized TLS connections see the camouflage page via Angie fallback. Marzban panel remains accessible at `https://DOMAIN/MARZBAN_PATH`.

### VPS2 (Russia, Node)

| Port | Service | Access | iptables |
|------|---------|--------|----------|
| 443 | XRay (steal_oneself: XHTTP + TCP Vision) | Public (clients) | `-A INPUT -p tcp --dport 443 -j ACCEPT` |
| 80 | Angie (HTTP->HTTPS redirect) | Public | `-A INPUT -p tcp --dport 80 -j ACCEPT` |
| 4123 | Angie internal (TLS, ACME, wg-easy UI proxy) | Localhost + REALITY dest | No iptables rule needed |
| 51820/udp | WireGuard (client-facing, wg-easy) | Public | `-A INPUT -p udp --dport 51820 -j ACCEPT` |
| 51830/udp | WireGuard peer-to-peer tunnel to VPS1 | Only to VPS1 IP | Outbound only, no inbound rule needed |
| 62050/tcp | Marzban Node service port | Only from VPS1 IP | `-A INPUT -s $VPS1_IP -p tcp --dport 62050 -j ACCEPT` |
| 62051/tcp | Marzban Node API port | Only from VPS1 IP | `-A INPUT -s $VPS1_IP -p tcp --dport 62051 -j ACCEPT` |
| $SSH_PORT | SSH | Public | `-A INPUT -p tcp --dport $SSH_PORT -j ACCEPT` |

---

## 4. XRay Configurations

### 4.1 VPS1 — Inbound (accepts traffic from VPS2)

Template: `templates_for_script/panel-xray`

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

**REALITY strategy for VPS1:** Uses own domain (`$VLESS_DOMAIN`) as `serverNames` with `dest: 127.0.0.1:4123` (local Angie). Angie obtains a real TLS certificate for this domain via ACME. This is the "steal oneself" pattern — REALITY verifies the TLS handshake against Angie's real cert. Do NOT use external domains like `www.microsoft.com` here — Angie cannot present their certificates.

### 4.2 VPS2 — Steal oneself + chain outbound

Template: `templates_for_script/node-xray`

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
  }
}
```

**Key points:**
- `reality-tcp`: clients with `flow: xtls-rprx-vision` are handled directly; clients without flow trigger default fallback to `@xhttp`
- `xhttp-in`: unix socket, receives XHTTP clients after fallback, validates `path` at XHTTP layer
- Both inbounds route through `chain-vps1` outbound (XHTTP+REALITY to VPS1)
- `flow` is NOT set in `xhttp-in` or in the outbound — XHTTP is incompatible with Vision
- `mode: stream-one` pinned explicitly for REALITY (auto has known bug #5635)
- `address` in outbound uses `$PANEL_DOMAIN` (not IP) for REALITY serverName matching

**REALITY strategy for VPS2:** Same "steal oneself" pattern as VPS1 — own domain + local Angie cert. Both VPS use their own domains, not external camouflage domains.

### 4.3 DNS strategy for inter-VPS link

The chain outbound on VPS2 connects to `$PANEL_DOMAIN`. If TSPU blocks DNS resolution:
- XRay uses its own DNS config (not system resolver): `1.1.1.1`, `8.8.8.8`
- Fallback: `setup-node.sh` adds VPS1 IP directly to `/etc/hosts` on VPS2
- The `address` field in the outbound can be changed to IP if DNS is fully blocked, but `serverName` in REALITY must still match the domain

---

## 5. Docker Compose

### 5.1 VPS1 (Germany)

Template: `templates_for_script/compose-panel`

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
```

### 5.2 VPS2 (Russia)

Template: `templates_for_script/compose-cascade-node`

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

  marzban-node:
    image: gozargah/marzban-node:latest
    container_name: marzban-node
    restart: always
    network_mode: host
    environment:
      - SERVICE_PORT=62050
      - XRAY_API_PORT=62051
      - SSL_CLIENT_CERT_FILE=/ssl_client_cert.pem
      - XRAY_EXECUTABLE_PATH=/var/lib/marzban/xray-core/xray
    volumes:
      - ./node/xray_config.json:/code/xray_config.json:ro
      - ./node/xray-core:/var/lib/marzban/xray-core:ro
      - ./ssl_client_cert.pem:/ssl_client_cert.pem:ro

  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest
    container_name: wg-easy
    restart: always
    network_mode: host
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      - net.ipv4.ip_forward=1
    environment:
      - WG_HOST=$VLESS_DOMAIN
      - PASSWORD_HASH=$WG_ADMIN_HASH
      - WG_PORT=51820
      - WG_DEFAULT_DNS=1.1.1.1
      - WG_ALLOWED_IPS=0.0.0.0/0
      - PORT=51821
      - WG_POST_UP=ip rule add from 10.8.0.0/24 table 100; ip route add default via 10.9.0.1 dev wg-tunnel table 100
      - WG_POST_DOWN=ip rule del from 10.8.0.0/24 table 100; ip route del default via 10.9.0.1 dev wg-tunnel table 100
    volumes:
      - wg-data:/etc/wireguard

volumes:
  angie-data:
    driver: local
  wg-data:
    driver: local
```

**Notes:**
- `marzban-node` required env vars: `SERVICE_PORT`, `XRAY_API_PORT`, `SSL_CLIENT_CERT_FILE`, `XRAY_EXECUTABLE_PATH`. Validate against the current marzban-node image docs before deploying — the image may expect additional env vars in newer versions.
- All config mounts are `:ro` (read-only) where possible
- `wg-easy` uses `network_mode: host` (same namespace as host) — `WG_POST_UP` can configure host routing tables directly, and the p2p WG tunnel interface (`wg-tunnel`) is visible inside the container
- `WG_POST_DOWN` for clean teardown
- No MASQUERADE on VPS2 — policy routing sends wg-easy client traffic (10.8.0.0/24) directly through the p2p tunnel to VPS1, where VPS1 applies MASQUERADE on exit to the internet. This avoids double NAT.

---

## 6. WireGuard Routing (VPS2 clients -> VPS1 -> Internet)

### Architecture

```
wg-easy clients (10.8.0.0/24)
    |
    v
wg0 interface (VPS2, network_mode: host)
    |
    | ip rule: from 10.8.0.0/24 -> table 100
    | table 100: default via 10.9.0.1 (VPS1 tunnel IP)
    v
wg-tunnel interface (VPS2: 10.9.0.2 <---> VPS1: 10.9.0.1, port 51830)
    |  (no MASQUERADE on VPS2 — packets forwarded with original 10.8.0.0/24 source)
    v
VPS1: FORWARD + MASQUERADE for 10.8.0.0/24 -> eth0 -> Internet
```

### VPS2 — p2p tunnel config (`/etc/wireguard/wg-tunnel.conf`)

Template: `templates_for_script/wg-tunnel-node`

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

### VPS1 — p2p tunnel config (`/etc/wireguard/wg-tunnel.conf`)

Template: `templates_for_script/wg-tunnel-panel`

```ini
[Interface]
PrivateKey = $WG_TUNNEL_PIK
Address = 10.9.0.1/24
ListenPort = 51830
PostUp = sysctl -w net.ipv4.ip_forward=1; iptables -A FORWARD -i wg-tunnel -o eth0 -j ACCEPT; iptables -A FORWARD -i eth0 -o wg-tunnel -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE
PostDown = iptables -D FORWARD -i wg-tunnel -o eth0 -j ACCEPT; iptables -D FORWARD -i eth0 -o wg-tunnel -m state --state RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s 10.8.0.0/24 -o eth0 -j MASQUERADE

[Peer]
PublicKey = $WG_TUNNEL_PEER_PBK
AllowedIPs = 10.8.0.0/24, 10.9.0.2/32
```

### Requirements on VPS1

- `net.ipv4.ip_forward=1` (set by BBR/sysctl step, also enforced in wg-tunnel PostUp as safety net)
- `FORWARD` chain rules for wg-tunnel <-> eth0
- `MASQUERADE` for 10.8.0.0/24 exiting via eth0
- `AllowedIPs` includes both tunnel subnet (10.9.0.0/24) and client subnet (10.8.0.0/24)
- Return traffic: VPS1 knows to route 10.8.0.0/24 back via wg-tunnel because of `AllowedIPs`

### Requirements on VPS2

- `Table = off` in wg-tunnel [Interface] — prevents wg-quick from adding a default route that would hijack all host traffic
- Policy routing table 100 with default via 10.9.0.1
- `ip rule` matching source 10.8.0.0/24
- Both set via `WG_POST_UP` in wg-easy (runs in host namespace)
- No MASQUERADE on VPS2 — traffic is forwarded with original source IPs; VPS1 handles NAT on exit
- The `wg-tunnel` interface is managed by `wg-quick@wg-tunnel` systemd unit (configured by `setup-node.sh`)

---

## 7. Secret Management

### Approach: generate at runtime, pass between scripts manually

No vault, no encrypted storage. Each script generates its own secrets locally on the VPS at runtime. Shared secrets are transferred by the operator copying output from `setup-panel.sh` and pasting into `setup-node.sh` prompts.

### Secrets generated by `setup-panel.sh` (VPS1)

| Secret | Generation method | Shared with VPS2? |
|--------|-------------------|-------------------|
| `XRAY_PIK` | `docker run --rm ghcr.io/xtls/xray-core x25519` | No (private key stays on VPS1) |
| `XRAY_PBK` | derived from PIK via same command | **Yes** — operator copies to `setup-node.sh` |
| `SHORT_ID` | `openssl rand -hex 8` | **Yes** |
| `UUID_LINK` | `docker run --rm ghcr.io/xtls/xray-core uuid` | **Yes** |
| `XHTTP_PATH` | `openssl rand -hex 12` | **Yes** |
| `MARZBAN_USER` | random dictionary word | **Yes** — for node API registration |
| `MARZBAN_PASS` | `tr -dc A-Za-z0-9 </dev/urandom \| head -c 13` | **Yes** — for node API registration |
| `MARZBAN_PATH` | `openssl rand -hex 8` | No |
| `MARZBAN_SUB_PATH` | `openssl rand -hex 8` | No |
| `WG_TUNNEL_PIK` | `wg genkey` | No (private key stays on VPS1) |
| `WG_TUNNEL_PBK` | `echo $PIK \| wg pubkey` | **Yes** — used in VPS2 tunnel peer config |

### Secrets generated by `setup-node.sh` (VPS2)

| Secret | Generation method | Shared with VPS1? |
|--------|-------------------|-------------------|
| `XRAY_PIK` | `docker run --rm ghcr.io/xtls/xray-core x25519` | No |
| `XRAY_PBK` | derived from PIK | No (used by clients) |
| `SHORT_ID` | `openssl rand -hex 8` | No (used by clients) |
| `CLIENT_UUID` | `docker run --rm ghcr.io/xtls/xray-core uuid` | No (used by clients) |
| `CLIENT_XHTTP_PATH` | `openssl rand -hex 12` | No (used by clients) |
| `WG_TUNNEL_PIK` | `wg genkey` | No (private key stays on VPS2) |
| `WG_TUNNEL_PBK` | `echo $PIK \| wg pubkey` | **Yes** — passed to VPS1 WG tunnel peer |
| `WG_ADMIN_HASH` | `docker run --rm ghcr.io/wg-easy/wg-easy wgpw <password>` | No |
| `WG_UI_PATH` | `openssl rand -hex 8` | No (used in node-angie template) |

### Data flow between scripts

```
setup-panel.sh outputs:          operator copies to setup-node.sh:
  PANEL_PBK        ------------>   "Enter VPS1 public key"
  PANEL_SHORT_ID   ------------>   "Enter VPS1 short ID"
  UUID_LINK        ------------>   "Enter inter-VPS UUID"
  XHTTP_PATH       ------------>   "Enter XHTTP path"
  MARZBAN_USER     ------------>   "Enter panel admin username"
  MARZBAN_PASS     ------------>   "Enter panel admin password"
  WG_TUNNEL_PBK    ------------>   "Enter VPS1 WG tunnel public key"
```

After `setup-node.sh` completes, it outputs `WG_TUNNEL_PBK` for VPS2. The operator must add this as a peer on VPS1 — see section 9.3 for the persistent configuration method, or use `setup-panel.sh --add-wg-peer <VPS2_WG_PBK> <VPS2_IP>` which appends the peer to `/etc/wireguard/wg-tunnel.conf` and restarts the service.

### File permissions

All sensitive files written by scripts use:
```bash
chmod 600 /opt/xray-vps-setup/marzban/xray_config.json
chmod 600 /opt/xray-vps-setup/marzban/.env
chmod 600 /opt/xray-vps-setup/ssl_client_cert.pem
chmod 600 /etc/wireguard/wg-tunnel.conf
chmod 644 /opt/xray-vps-setup/angie.conf
chmod 644 /opt/xray-vps-setup/index.html
chmod 644 /opt/xray-vps-setup/docker-compose.yml
```

---

## 8. Script Structure

### Repository layout (new files for cascade)

```
setup-panel.sh                        # VPS1 installer (run on Germany VPS)
setup-node.sh                         # VPS2 installer (run on Russia VPS)
vps-setup.sh                          # Existing single-VPS script (unchanged)

templates_for_script/
  # Existing (unchanged)
  angie                               # Angie config (standalone xray)
  angie-marzban                       # Angie config (single-VPS marzban)
  compose-xray                        # Docker Compose (standalone xray)
  compose-marzban                     # Docker Compose (single-VPS marzban)
  compose-node                        # Docker Compose (single-VPS node)
  confluence                          # Camouflage HTML page
  marzban                             # Marzban .env
  xray                                # XRay config (single-VPS)
  xray_outbound                       # Client XRay outbound
  sing_box_outbound                   # Client sing-box outbound
  00-disable-password                 # SSHD config

  # New (cascade-specific)
  panel-xray                          # VPS1: XRay XHTTP+REALITY inbound config
  panel-angie                         # VPS1: Angie config (TLS + panel proxy)
  compose-panel                       # VPS1: Docker Compose (angie + marzban)
  node-xray                           # VPS2: XRay steal_oneself + chain outbound config
  node-angie                          # VPS2: Angie config (TLS + wg-easy UI proxy)
  compose-cascade-node                # VPS2: Docker Compose (angie + marzban-node + wg-easy)
  wg-tunnel-panel                     # VPS1: WireGuard p2p tunnel config
  wg-tunnel-node                      # VPS2: WireGuard p2p tunnel config
```

### Template variable syntax

All templates use `$VAR` or `${VAR}` syntax for `envsubst`. When only specific variables should be expanded (to avoid clobbering unrelated `$` references in Angie/Docker configs), the script passes an explicit variable list:

```bash
# Expand only specific variables (Angie configs contain $uri, $host etc.)
wget -qO- "$TEMPLATE_URL/panel-angie" | envsubst '$VLESS_DOMAIN $MARZBAN_PATH $MARZBAN_SUB_PATH' > ./angie.conf

# Expand all exported variables (XRay configs, Docker Compose)
wget -qO- "$TEMPLATE_URL/panel-xray" | envsubst > ./marzban/xray_config.json
```

**Note:** The `node-angie` template uses `$WG_UI_PATH` for the wg-easy UI proxy location. Include it in the envsubst variable list:
```bash
wget -qO- "$TEMPLATE_URL/node-angie" | envsubst '$VLESS_DOMAIN $WG_UI_PATH' > ./angie.conf
```

---

## 9. Script Workflow

### 9.1 `setup-panel.sh` (VPS1, Germany)

```
Step  Action                           Details
────  ──────────────────────────────  ──────────────────────────────────────────────
 1    Check root                       Exit if $EUID != 0
 2    Install deps                     apt-get install idn sudo dnsutils wamerican wireguard-tools
 3    Ask domain                       read -ep; convert with idn; export VLESS_DOMAIN
 4    Verify DNS                       dig +short; compare to hostname -I; warn on mismatch
 5    Install Docker                   curl -fsSL https://get.docker.com | sh  (skip if present)
 6    Install yq                       wget yq_linux_$ARCH to /usr/bin/yq
 7    Enable BBR + ip_forward          Append net.core.default_qdisc=fq + net.ipv4.tcp_congestion_control=bbr
                                       to /etc/sysctl.conf; also ensure net.ipv4.ip_forward=1 is present
                                       (grep -q "net.ipv4.ip_forward" /etc/sysctl.conf ||
                                        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf);
                                       sysctl -p  (skip BBR lines if already set)
 8    Generate secrets                 XRAY_PIK     = docker run --rm ghcr.io/xtls/xray-core x25519
                                       XRAY_PBK     = derived from PIK
                                       UUID_LINK    = docker run --rm ghcr.io/xtls/xray-core uuid
                                       XHTTP_PATH   = openssl rand -hex 12
                                       SHORT_ID     = openssl rand -hex 8
                                       MARZBAN_USER = random dictionary word
                                       MARZBAN_PASS = tr -dc A-Za-z0-9 </dev/urandom | head -c 13
                                       MARZBAN_PATH = openssl rand -hex 8
                                       MARZBAN_SUB_PATH = openssl rand -hex 8
                                       WG_TUNNEL_PIK = wg genkey
                                       WG_TUNNEL_PBK = echo $WG_TUNNEL_PIK | wg pubkey
 9    Download XRay core               wget Xray-linux-{64,arm64-v8a}.zip v26.3.23;
                                       unzip to /opt/xray-vps-setup/marzban/xray-core/
10    Download + envsubst templates    panel-xray -> marzban/xray_config.json
                                       panel-angie -> angie.conf
                                       compose-panel -> docker-compose.yml
                                       marzban -> marzban/.env
                                       confluence -> index.html
11    Write WG tunnel config           wg-tunnel-panel -> /etc/wireguard/wg-tunnel.conf
                                       Write full [Interface] section; write [Peer] section
                                       commented out (VPS2 PBK unknown yet):
                                         # [Peer]
                                         # PublicKey = <VPS2_WG_PBK>
                                         # AllowedIPs = 10.8.0.0/24, 10.9.0.2/32
                                       systemctl enable wg-quick@wg-tunnel (enable but don't start — no peer yet)
12    Docker compose up                docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d
13    Wait for Marzban, import admin   sleep 5; docker exec marzban marzban-cli admin import-from-env
14    Update panel default host        Authenticate via API, update host address/SNI to $VLESS_DOMAIN
                                       (same logic as existing vps-setup.sh end_script())
15    Configure iptables               Port 443 open (REALITY protects against unauthorized VLESS connections;
                                       camouflage page served to unknown TLS clients)
                                       Port 80 open, SSH port open, 51830/udp open
                                       Install iptables-persistent; netfilter-persistent save
16    Output connection info           Print to stdout:
                                       ┌─────────────────────────────────────────────────┐
                                       │  Panel URL: https://$VLESS_DOMAIN/$MARZBAN_PATH │
                                       │  Panel user: $MARZBAN_USER                      │
                                       │  Panel pass: $MARZBAN_PASS                      │
                                       │                                                 │
                                       │  === Values for setup-node.sh ===               │
                                       │  PANEL_PBK:      $XRAY_PBK                      │
                                       │  PANEL_SHORT_ID: $SHORT_ID                      │
                                       │  UUID_LINK:      $UUID_LINK                     │
                                       │  XHTTP_PATH:     $XHTTP_PATH                   │
                                       │  WG_TUNNEL_PBK:  $WG_TUNNEL_PBK                 │
                                       │                                                 │
                                       │  After setup-node.sh, add WG tunnel peer:       │
                                       │  Edit /etc/wireguard/wg-tunnel.conf,             │
                                       │  uncomment [Peer] and fill VPS2 values,          │
                                       │  then: systemctl restart wg-quick@wg-tunnel      │
                                       └─────────────────────────────────────────────────┘
```

**`setup-panel.sh --add-wg-peer <PBK> <VPS2_IP>` flag:**

When called with `--add-wg-peer`, the script:
1. Appends the [Peer] section to `/etc/wireguard/wg-tunnel.conf`:
   ```ini
   [Peer]
   PublicKey = <PBK>
   AllowedIPs = 10.8.0.0/24, 10.9.0.2/32
   Endpoint = <VPS2_IP>:51830
   ```
2. Runs `systemctl restart wg-quick@wg-tunnel` to apply
3. Verifies connectivity: `ping -c 3 10.9.0.2`

### 9.2 `setup-node.sh` (VPS2, Russia)

```
Step  Action                           Details
────  ──────────────────────────────  ──────────────────────────────────────────────
 1    Check root                       Exit if $EUID != 0
 2    Install deps                     apt-get install idn sudo dnsutils wamerican wireguard-tools
 3    Ask domain                       read -ep; convert with idn; export VLESS_DOMAIN
 4    Verify DNS                       dig +short; compare to hostname -I; warn on mismatch
 5    Ask VPS1 connection info         PANEL_DOMAIN  = read -ep "Enter VPS1 panel domain"
                                       VPS1_IP       = read -ep "Enter VPS1 IP address"
                                       PANEL_PBK     = read -ep "Enter VPS1 public key (PBK)"
                                       PANEL_SHORT_ID = read -ep "Enter VPS1 short ID"
                                       UUID_LINK     = read -ep "Enter inter-VPS UUID"
                                       XHTTP_PATH    = read -ep "Enter XHTTP path"
                                       PANEL_WG_PBK  = read -ep "Enter VPS1 WG tunnel public key"
 6    Ask panel credentials            PANEL_USER    = read -ep "Enter panel admin username"
                                       PANEL_PASS    = read -sep "Enter panel admin password"
                                       (for node_api_setup() — auto-register via Marzban API)
 7    Ask optional config              configure_ssh_input  = [y/N] SSH hardening
                                       configure_warp_input = [y/N] WARP for Russian sites
 8    Install Docker                   curl -fsSL https://get.docker.com | sh  (skip if present)
 9    Install yq                       wget yq_linux_$ARCH to /usr/bin/yq
10    Enable BBR + ip_forward          Same as panel — sysctl append + sysctl -p;
                                       also ensure net.ipv4.ip_forward=1 is present
                                       (grep -q "net.ipv4.ip_forward" /etc/sysctl.conf ||
                                        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf);
                                       sysctl -p
11    Generate local secrets           XRAY_PIK        = docker run --rm ghcr.io/xtls/xray-core x25519
                                       XRAY_PBK        = derived from PIK
                                       SHORT_ID        = openssl rand -hex 8
                                       CLIENT_UUID     = docker run --rm ghcr.io/xtls/xray-core uuid
                                       CLIENT_XHTTP_PATH = openssl rand -hex 12
                                       WG_TUNNEL_PIK   = wg genkey
                                       WG_TUNNEL_PBK   = echo $WG_TUNNEL_PIK | wg pubkey
                                       WG_ADMIN_PASS   = tr -dc A-Za-z0-9 </dev/urandom | head -c 13
                                       WG_ADMIN_HASH   = docker run --rm ghcr.io/wg-easy/wg-easy wgpw "$WG_ADMIN_PASS"
                                       WG_UI_PATH      = openssl rand -hex 8
12    Download XRay core               wget Xray-linux-{64,arm64-v8a}.zip v26.3.23;
                                       unzip to /opt/xray-vps-setup/node/xray-core/
13    Download + envsubst templates    node-xray -> node/xray_config.json
                                       node-angie -> angie.conf (envsubst list includes $WG_UI_PATH)
                                       compose-cascade-node -> docker-compose.yml
                                       confluence -> index.html
                                       ssl_client_cert.pem -> touch placeholder
14    Setup WG p2p tunnel              wg-tunnel-node -> /etc/wireguard/wg-tunnel.conf
                                       envsubst with $WG_TUNNEL_PIK, $PANEL_WG_PBK, $VPS1_IP
                                       systemctl enable --now wg-quick@wg-tunnel
15    DNS fallback                     echo "$VPS1_IP $PANEL_DOMAIN" >> /etc/hosts
                                       (ensures chain outbound resolves even if TSPU blocks DNS;
                                        uses explicit $VPS1_IP from step 5, does not rely on dig)
16    Start angie + wg-easy            docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d angie wg-easy
                                       (marzban-node NOT started yet — needs cert from node_api_setup)
17    node_api_setup()                 Authenticate to panel API with $PANEL_USER/$PANEL_PASS
                                       Fetch SSL client cert -> /opt/xray-vps-setup/ssl_client_cert.pem
                                       Create node (or reuse existing) on panel
                                       Update XRay config serverNames with node domain
                                       Update panel hosts with node host entries
                                       (Same logic as existing vps-setup.sh node_api_setup())
18    Start marzban-node               docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d marzban-node
                                       (now has valid cert and XRay config)
19    Configure iptables               443 open (clients), 80 open, 51820/udp open
                                       62050/62051 restricted to VPS1 IP
                                       SSH port open, loopback, default DROP
                                       netfilter-persistent save
20    Optional: SSH hardening          If configure_ssh_input == "y":
                                       Create user, add SSH key, disable password auth
                                       Change SSH port, restart sshd
21    Optional: WARP                   If configure_warp_input == "y":
                                       Install cloudflare-warp, register, set proxy mode on port 40000
                                       Inject WARP outbound + routing rules into node/xray_config.json via yq
                                       Restart docker compose
22    Output connection info           Print to stdout:
                                       ┌──────────────────────────────────────────────────────────────┐
                                       │  VLESS+XHTTP+REALITY (primary):                             │
                                       │  vless://CLIENT_UUID@DOMAIN:443?type=xhttp&security=reality  │
                                       │    &pbk=PBK&fp=chrome&sni=DOMAIN&sid=SID                    │
                                       │    &path=%2FCLIENT_XHTTP_PATH#XHTTP                         │
                                       │                                                              │
                                       │  VLESS+REALITY TCP (fallback):                               │
                                       │  vless://CLIENT_UUID@DOMAIN:443?type=tcp&security=reality    │
                                       │    &pbk=PBK&fp=chrome&sni=DOMAIN&sid=SID                    │
                                       │    &flow=xtls-rprx-vision#TCP                                │
                                       │                                                              │
                                       │  WireGuard UI: https://DOMAIN/$WG_UI_PATH                    │
                                       │  WG admin password: $WG_ADMIN_PASS                           │
                                       │                                                              │
                                       │  === For VPS1 WG tunnel peer ===                             │
                                       │  On VPS1, edit /etc/wireguard/wg-tunnel.conf:                │
                                       │  Uncomment/add the [Peer] section:                           │
                                       │    [Peer]                                                    │
                                       │    PublicKey = $WG_TUNNEL_PBK                                │
                                       │    AllowedIPs = 10.8.0.0/24, 10.9.0.2/32                    │
                                       │    Endpoint = <VPS2_IP>:51830                                │
                                       │  Then run: systemctl restart wg-quick@wg-tunnel              │
                                       │                                                              │
                                       │  Or run: setup-panel.sh --add-wg-peer $WG_TUNNEL_PBK        │
                                       │          <VPS2_IP>                                           │
                                       └──────────────────────────────────────────────────────────────┘
```

### 9.3 Post-setup manual steps

After both scripts have run, the operator must:

1. **On VPS1:** Add VPS2 as WG tunnel peer. Edit `/etc/wireguard/wg-tunnel.conf`, uncomment/add the [Peer] section with VPS2's public key and endpoint, then run `systemctl restart wg-quick@wg-tunnel`. Alternatively, run `setup-panel.sh --add-wg-peer <VPS2_WG_PBK> <VPS2_IP>` which appends the peer to the config file and restarts the service. This persists across reboots.
2. **On VPS1:** Verify WG tunnel connectivity: `ping 10.9.0.2` from VPS1
3. **On VPS2:** Verify WG tunnel connectivity: `ping 10.9.0.1` from VPS2
4. **From a client device:** Connect using the VLESS+XHTTP config and verify your IP shows as VPS1 (e.g. visit `https://ipinfo.io`)

These are printed as a checklist at the end of `setup-node.sh` output.

---

## 10. Security

### iptables — VPS1 (Germany)

Applied by `setup-panel.sh`. Port 443 remains open — REALITY ensures only authorized clients (VPS2 with correct PBK/shortId) can establish a VLESS connection. Unauthorized TLS connections see the camouflage page via Angie fallback. Marzban panel remains accessible at `https://DOMAIN/MARZBAN_PATH`.

```
-A INPUT -p icmp -j ACCEPT
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
-A INPUT -p tcp --dport 80 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -p udp --dport 51830 -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-P INPUT DROP
```

### iptables — VPS2 (Russia)

Applied by `setup-node.sh`:

```
-A INPUT -p icmp -j ACCEPT
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p tcp --dport $SSH_PORT -j ACCEPT
-A INPUT -p tcp --dport 80 -j ACCEPT
-A INPUT -p tcp --dport 443 -j ACCEPT
-A INPUT -p udp --dport 51820 -j ACCEPT
-A INPUT -s $VPS1_IP -p tcp --dport 62050 -j ACCEPT
-A INPUT -s $VPS1_IP -p tcp --dport 62051 -j ACCEPT
-A INPUT -p tcp --dport 62050 -j REJECT --reject-with tcp-reset
-A INPUT -p tcp --dport 62051 -j REJECT --reject-with tcp-reset
-A INPUT -i lo -j ACCEPT
-A OUTPUT -o lo -j ACCEPT
-P INPUT DROP
```

### REALITY serverNames strategy

Both VPS use the "steal oneself" pattern consistently:
- **VPS1:** `serverNames: ["$VLESS_DOMAIN"]`, `dest: 127.0.0.1:4123` — Angie serves real cert for this domain
- **VPS2:** `serverNames: ["$VLESS_DOMAIN"]`, `dest: 127.0.0.1:4123` — Angie serves real cert for this domain

Do NOT use external camouflage domains (`www.microsoft.com`, etc.) — Angie cannot present their TLS certificates, and REALITY would fail the handshake verification.

### BBR

Enabled on both VPS via sysctl: `net.ipv4.tcp_congestion_control=bbr`, `net.core.default_qdisc=fq`

### File permissions

All sensitive files written by scripts:
- `mode 0600` for: XRay configs (contain private keys), marzban `.env`, ssl certs, WG tunnel configs
- `mode 0644` for: angie.conf, index.html, docker-compose.yml
- Docker volumes mounted `:ro` where the container should not modify the file

---

## 11. Client Output Configs

After deployment, `setup-node.sh` outputs connection information for end users.

### VLESS+XHTTP+REALITY (primary)

```
Clipboard URI:
vless://$CLIENT_UUID@$VLESS_DOMAIN:443?type=xhttp&security=reality&pbk=$XRAY_PBK&fp=chrome&sni=$VLESS_DOMAIN&sid=$SHORT_ID&path=%2F$CLIENT_XHTTP_PATH#XHTTP

XRay outbound:
{
  "protocol": "vless",
  "settings": {
    "vnext": [{
      "address": "$VLESS_DOMAIN",
      "port": 443,
      "users": [{"id": "$CLIENT_UUID", "encryption": "none"}]
    }]
  },
  "streamSettings": {
    "network": "xhttp",
    "security": "reality",
    "xhttpSettings": {"path": "/$CLIENT_XHTTP_PATH"},
    "realitySettings": {
      "serverName": "$VLESS_DOMAIN",
      "fingerprint": "chrome",
      "publicKey": "$XRAY_PBK",
      "shortId": "$SHORT_ID"
    }
  }
}
```

### VLESS+REALITY TCP (fallback)

```
Clipboard URI:
vless://$CLIENT_UUID@$VLESS_DOMAIN:443?type=tcp&security=reality&pbk=$XRAY_PBK&fp=chrome&sni=$VLESS_DOMAIN&sid=$SHORT_ID&flow=xtls-rprx-vision#TCP

Note: sing-box clients that don't support XHTTP should use this config.
```

### WireGuard

Managed via wg-easy web UI at `https://$VLESS_DOMAIN/$WG_UI_PATH` (proxied by Angie).

---

## 12. Migration Notes

### Breaking changes from current architecture

| Current (`vps-setup.sh`) | New (`setup-panel.sh` + `setup-node.sh`) |
|--------------------------|------------------------------------------|
| `INSTALL_MODE: "xray"/"marzban"/"node"` | Two separate scripts, one per VPS role |
| Single VPS | Two VPS required |
| `flow: xtls-rprx-vision` on all inbounds | No flow on XHTTP inbounds |
| Templates flat in `templates_for_script/` | New templates prefixed `panel-`/`node-` added alongside existing ones |
| Keys generated inline at runtime | Keys still generated at runtime, but shared values passed manually between scripts |
| Single `vps-setup.sh` handles all modes | `setup-panel.sh` and `setup-node.sh` are separate scripts for cascade; `vps-setup.sh` kept for single-VPS |
| node_api_setup() uses ports 62001/62002 | Cascade uses ports 62050/62051 |

### Backward compatibility

- `vps-setup.sh` is kept as-is — continues to work for single-VPS deployments
- Old `INSTALL_MODE` choices (`xray`, `marzban`, `node`) are NOT removed
- New cascade scripts are additive — they coexist with the existing script
- Existing templates in `templates_for_script/` are unchanged; new ones are added with `panel-`/`node-` prefixes

### XRay version

- Minimum: v26.2.6 (XHTTP CDN detection fixes, dynamic User-Agent)
- Recommended: v26.3.23 (latest stable)
- Pinned in both `setup-panel.sh` and `setup-node.sh` as `XRAY_VERSION="v26.3.23"`

---

## 13. Risks and Mitigations

| Risk | Severity | Impact | Mitigation |
|------|----------|--------|------------|
| Marzban-node rejects custom XRay config with steal_oneself | High | Cascade won't work | Test before full implementation; fallback: standalone XRay on VPS2 with direct API integration to panel |
| XHTTP mode auto resolves incorrectly (#5635) | High | Connection fails | Pin `mode: "stream-one"` explicitly |
| VPS2 IP blocked by TSPU | High | All clients lose access | Domain + CDN fallback as future enhancement; IP rotation via hosting provider |
| DNS resolution of VPS1 domain blocked | Medium | Bridge link fails | `/etc/hosts` fallback on VPS2 (step 15 of setup-node.sh); explicit VPS1_IP input in step 5 |
| wg-easy `network_mode: host` requires elevated caps | Medium | Security surface | Acceptable — WG needs NET_ADMIN; iptables restrict exposure |
| sing-box clients don't support XHTTP | Medium | Some clients limited | VLESS+REALITY TCP fallback on same port |
| Manual secret transfer between scripts | Medium | Operator error (typos) | Scripts validate format on input; copy-paste friendly output with clear labels |
| WG tunnel peer must be added manually on VPS1 | Low | WG routing won't work until done | setup-node.sh outputs exact config edits and `systemctl restart` command; `--add-wg-peer` flag available |
| wg-easy routing adds latency vs direct | Low | Slower WG | Acceptable trade-off for exit through clean IP |
| XRay v26.3.23 UDP bug (#5848) | Low | QUIC/mosh broken | Monitor for fix; pin v26.2.6 if needed |
| Secrets visible in terminal output | Low | Shoulder surfing risk | Operator responsibility; scripts use `read -s` for passwords; consider `| tee setup-output.txt` |
