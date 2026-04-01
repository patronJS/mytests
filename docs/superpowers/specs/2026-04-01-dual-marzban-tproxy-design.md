# Design: Dual Independent Marzban with TPROXY for WG Clients

**Date**: 2026-04-01
**Status**: Approved

## Problem

Current panel+node architecture is broken: marzban-node receives XRay config from VPS1 panel via REST API, overwriting the local chain outbound and routing rules on VPS2. Client traffic on VPS2 exits directly instead of cascading through VPS1.

Additionally, WireGuard tunnel between VPS1↔VPS2 is blocked by DPI (WG protocol is detectable). All inter-server traffic must go through XHTTP+REALITY.

## Solution

Two independent Marzban instances (no panel↔node relationship). WG client traffic on VPS2 is transparently proxied through XRay's dokodemo-door (TPROXY) into the VLESS chain outbound to VPS1.

## Architecture

```
VPS1 (Germany — exit)               VPS2 (Russia — entry)
┌─────────────────────┐            ┌──────────────────────────┐
│ Marzban panel       │            │ Marzban panel            │
│ (technical, 1 user) │            │ (client management)      │
│                     │            │                          │
│ XRay inbound        │◄──XHTTP───│ XRay chain outbound      │
│ XHTTP+REALITY :443  │  +REALITY │ (XHTTP+REALITY)          │
│                     │            │                          │
│ Angie (TLS, ACME,   │            │ XRay inbounds:           │
│   reverse proxy)    │            │  - reality-tcp :443      │
│                     │            │  - xhttp-in (@xhttp)     │
│ NO WireGuard        │            │  - tproxy-in :12345      │
│ NO NAT              │            │    (dokodemo-door)       │
│                     │            │                          │
└─────────────────────┘            │ wg-easy :51820           │
                                   │ Angie (TLS, ACME,        │
                                   │   proxy panel + wg-ui)   │
                                   │ iptables TPROXY rules    │
                                   └──────────────────────────┘
```

## Traffic Flows

### VLESS clients (L7, primary)

```
Client → VPS2:443 (VLESS+REALITY) → XRay chain (XHTTP+REALITY) → VPS1:443 → Internet
```

### WG clients (L3 → L7 via TPROXY)

```
Client → VPS2:51820 (WireGuard) → wg-easy
  → iptables TPROXY (mark packets from 10.8.0.0/24)
  → dokodemo-door :12345 (XRay, followRedirect + tproxy)
  → chain outbound (XHTTP+REALITY)
  → VPS1:443 → Internet
```

Both client types exit with VPS1 (Germany) IP. No WireGuard tunnel between servers.

## VPS1 Components

| Component | Purpose |
|-----------|---------|
| Marzban | Technical panel, single user (UUID_LINK for cascade) |
| XRay | XHTTP+REALITY inbound on :443 |
| Angie | TLS certificates (ACME), reverse proxy for Marzban panel |
| iptables | Firewall only (no NAT — XRay handles outbound via freedom) |

## VPS2 Components

| Component | Purpose |
|-----------|---------|
| Marzban | Client panel, user management |
| XRay | reality-tcp + xhttp-in (clients), dokodemo-door (tproxy for WG), chain outbound → VPS1 |
| Angie | TLS certificates, reverse proxy for Marzban + wg-easy UI |
| wg-easy | WireGuard server for clients (:51820) |
| iptables | Firewall + TPROXY rules for WG traffic → dokodemo-door |

## XRay Config: VPS2 (node-xray template)

### Inbounds

1. **reality-tcp** — VLESS+REALITY TCP on :443, steal_oneself with fallback to @xhttp
2. **xhttp-in** — VLESS XHTTP on @xhttp (unix socket fallback from reality-tcp)
3. **tproxy-in** — dokodemo-door on :12345, `followRedirect: true`, `tproxy: "tproxy"`, TCP+UDP

### Outbounds

1. **chain-vps1** — VLESS XHTTP+REALITY to VPS1:443 (mode: stream-one)
2. **direct** — freedom (fallback)
3. **block** — blackhole

### Routing

1. `inboundTag: [reality-tcp, xhttp-in, tproxy-in]` → `chain-vps1`
2. `protocol: bittorrent` → `block`

## TPROXY Setup on VPS2

```bash
# ip rule: packets marked 1 use table 100
ip rule add fwmark 1 table 100
ip route add local 0.0.0.0/0 dev lo table 100

# iptables: mark and redirect WG client traffic
iptables -t mangle -A PREROUTING -s 10.8.0.0/24 -p tcp -j TPROXY \
  --on-port 12345 --tproxy-mark 1
iptables -t mangle -A PREROUTING -s 10.8.0.0/24 -p udp -j TPROXY \
  --on-port 12345 --tproxy-mark 1
```

wg-easy WG_POST_UP/WG_POST_DOWN manages these rules lifecycle.

## File Changes

| File | Action |
|------|--------|
| `setup-panel.sh` | Remove: WG tunnel, NAT, `--add-wg-peer`. Simplify output. |
| `setup-node.sh` → `setup-entry.sh` | Remove: node API, WG tunnel. Add: own Marzban, tproxy iptables. |
| `templates_for_script/panel-xray` | No changes |
| `templates_for_script/node-xray` | Add dokodemo-door inbound, update routing for tproxy-in |
| `templates_for_script/panel-angie` | No changes |
| `templates_for_script/node-angie` | Add location for Marzban panel |
| `templates_for_script/compose-panel` | No changes |
| `templates_for_script/compose-cascade-node` | Replace marzban-node with marzban |
| `templates_for_script/wg-tunnel-panel` | **Delete** |
| `templates_for_script/wg-tunnel-node` | **Delete** |
| `templates_for_script/marzban` | No changes |
| `README.md` | Full rewrite |
| `CLAUDE.md` | Update architecture |

## Removed from VPS1

- WireGuard tunnel (wg-tunnel.conf, wg-quick@wg-tunnel)
- iptables NAT/MASQUERADE rules
- `--add-wg-peer` CLI mode
- WG_TUNNEL_PBK output
- ip_forward sysctl (not needed — XRay handles outbound)

## Removed from VPS2

- Panel admin credentials prompt (no VPS1 API access)
- `node_api_setup()` function (no node registration, cert fetch, host patching)
- ssl_client_cert.pem
- WG tunnel to VPS1
- iptables rules for ports 62050/62051

## Added to VPS2

- Own Marzban panel (credentials, .env, init, host update)
- dokodemo-door inbound in node-xray
- TPROXY iptables rules in wg-easy WG_POST_UP/WG_POST_DOWN
- ip rule/route for TPROXY

## Key Constraints

- XRay core pinned to v26.3.23
- `flow: xtls-rprx-vision` must NOT be set on XHTTP inbound/outbound
- `mode: "stream-one"` in chain outbound (XRay bug #5635)
- Marzban modifies only `clients` in inbounds; outbounds and routing are preserved
- dokodemo-door with tproxy requires `CAP_NET_ADMIN` (Docker container or root)
