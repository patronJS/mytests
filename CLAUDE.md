# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Two-VPS cascade architecture for VLESS proxy (XRay/Marzban) behind Angie (nginx fork) with REALITY protocol, designed to bypass DPI.

VPS1 (exit, Marzban panel) + VPS2 (entry, independent Marzban panel). Uses XHTTP+REALITY transport between VPS2→VPS1.

## Architecture

### Delivery mechanism

Two bash scripts (`setup-panel.sh` for VPS1, `setup-entry.sh` for VPS2) — download config templates from `templates_for_script/` via raw GitHub URLs, use `envsubst` for templating. Produce Docker Compose stacks in `/opt/xray-vps-setup/` with Angie + XRay/Marzban containers using `network_mode: host`.

### Traffic flow

```
Client → VPS2:443 (VLESS+REALITY) → XHTTP+REALITY chain → VPS1:443 → Internet
Client → VPS2:51820 (WireGuard) → TPROXY → XRay chain → VPS1:443 → Internet
```

- `setup-panel.sh` — VPS1 installer (Marzban panel + XHTTP inbound, no WG)
- `setup-entry.sh` — VPS2 installer (Marzban panel + steal_oneself + chain outbound + TPROXY + wg-easy)

XRay listens on 443, handles VLESS with REALITY. Marzban panel is reverse-proxied by Angie at randomized paths.

### Generated secrets

Scripts generate at runtime: x25519 key pairs (PIK/PBK), XRay UUIDs, WireGuard tunnel keys, admin credentials + randomized panel/subscription/UI paths.

## Commands

### Quick Start

```bash
# 1. On VPS1 (Germany):
tmux
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-panel.sh)
# Copy the output values

# 2. On VPS2 (Russia):
tmux
bash <(wget -qO- https://raw.githubusercontent.com/patronJS/mytests/refs/heads/main/setup-entry.sh)
# Paste VPS1 values when prompted
```

## Templates (`templates_for_script/`)

| Template | Purpose |
|----------|---------|
| `panel-xray` | VPS1: XRay XHTTP+REALITY inbound |
| `panel-angie` | VPS1: Angie (TLS + Marzban panel proxy) |
| `compose-panel` | VPS1: Docker Compose (angie + marzban) |
| `node-xray` | VPS2: XRay steal_oneself + chain outbound + dokodemo-door TPROXY |
| `node-angie` | VPS2: Angie (TLS + wg-easy UI proxy) |
| `compose-cascade-node` | VPS2: Docker Compose (angie + marzban + wg-easy) |
| `marzban` | Marzban `.env` |
| `confluence` | Camouflage HTML page |
| `00-disable-password` | SSH hardening config |

Templates use `$ENVVAR` syntax (processed via `envsubst`).

## Important Notes

- Ports 80, 443, 4123 are reserved — SSH must not use them
- WARP integration patches XRay config post-deploy via `yq` to add SOCKS outbound on port 40000
- XRay core version is pinned to v26.3.23
- XHTTP transport requires XRay >= v26.3.23
- `flow: xtls-rprx-vision` MUST NOT be set on XHTTP inbounds or outbounds
- `mode: "stream-one"` pinned in chain outbound (auto has bug #5635)
- WG client traffic routed through TPROXY → dokodemo-door → chain outbound
- No WireGuard tunnel between servers — all inter-server traffic via XHTTP+REALITY
