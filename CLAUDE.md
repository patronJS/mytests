# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Two-VPS cascade architecture for VLESS proxy (XRay/Marzban) with REALITY protocol, designed to bypass DPI.

VPS1 (exit, Marzban panel, no domain) + VPS2 (entry, independent Marzban panel). Uses XHTTP+REALITY transport between VPS2→VPS1 on port 49321.

## Architecture

### Delivery mechanism

Two bash scripts (`setup-vps1.sh` for VPS1, `setup-vps2.sh` for VPS2) — download config templates from `templates_for_script/` via raw GitHub URLs, use `envsubst` for templating. Produce Docker Compose stacks in `/opt/xray-vps-setup/` with XRay/Marzban containers using `network_mode: host`.

### Traffic flow

```
Client → VPS2:443 (VLESS+REALITY, steal_oneself) → XHTTP+REALITY (packet-up) → VPS1:49321 (steal_oneself) → Internet
```

- `setup-vps1.sh` — VPS1 installer (Marzban panel + XHTTP inbound on 49321, no domain required)
- `setup-vps2.sh` — VPS2 installer (Marzban panel + steal_oneself + chain outbound)

XRay on VPS1 listens on 49321, handles VLESS with REALITY (steal_oneself with own domain + Angie). VPS1 Marzban panel is accessible via SSH tunnel only.

### Generated secrets

Scripts generate at runtime: x25519 key pairs (PIK/PBK), XRay UUIDs, admin credentials + randomized panel/subscription/UI paths.

## Commands

### Quick Start

```bash
# 1. On VPS1 (Germany):
tmux
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-vps1.sh)
# Copy the output values

# 2. On VPS2 (Russia):
tmux
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-vps2.sh)
# Paste VPS1 values when prompted
```

## Templates (`templates_for_script/`)

| Template | Purpose |
|----------|---------|
| `panel-xray` | VPS1: XRay XHTTP+REALITY inbound on 49321 |
| `panel-angie` | VPS1: Angie (TLS + ACME + Confluence camouflage) |
| `compose-panel` | VPS1: Docker Compose (angie + marzban) |
| `node-xray` | VPS2: XRay steal_oneself + chain outbound |
| `node-angie` | VPS2: Angie (TLS + ACME + Confluence camouflage) |
| `compose-cascade-node` | VPS2: Docker Compose (angie + marzban) |
| `marzban` | Marzban `.env` |
| `confluence` | Camouflage HTML page |
| `00-disable-password` | SSH hardening config |

Templates use `$ENVVAR` syntax (processed via `envsubst`).

## Important Notes

- VPS1 exposes port 49321 (XHTTP+REALITY steal_oneself) + 80 (ACME) + SSH — no 443/4123
- VPS2 ports 80, 443 reserved for Angie — SSH must not use them
- WARP integration patches XRay config post-deploy via `yq` to add SOCKS outbound on port 40000
- XRay core version is pinned to v26.3.27
- XHTTP transport requires XRay >= v26.3.23
- `flow: xtls-rprx-vision` MUST NOT be set on XHTTP inbounds or outbounds
- `mode: "packet-up"` pinned in chain outbound (stream-one deprecated; auto has bug #5635)
- `xPaddingBytes: 300-2000` set on XHTTP transport for traffic shaping
- REALITY on VPS1 uses steal_oneself with own domain + Angie for TLS termination
- VPS1 Marzban panel accessible via SSH tunnel only (no public reverse proxy)
- VPS1 exposes port 80 for ACME HTTP-01 certificate renewal only
- Both VPS use own domains — eliminates ASN mismatch detectable by TSPU
