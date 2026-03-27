# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Ansible role + standalone bash script for automated VPS setup with VLESS proxy (XRay/Marzban) behind Angie (nginx fork) with REALITY protocol. Published on [Ansible Galaxy](https://galaxy.ansible.com/ui/standalone/roles/Akiyamov/xray-vps-setup/install/) as `Akiyamov.xray-vps-setup`.

Three installation modes:
- **xray** — standalone XRay VLESS server
- **marzban** — Marzban panel with XRay backend
- **node** — Marzban node connecting to an existing panel (script only)

## Architecture

### Dual delivery mechanism

1. **Ansible role** (`tasks/`, `templates/`, `handlers/`, `defaults/`, `vars/`, `meta/`) — uses Jinja2 templates (`.j2`) and `setup_variant` variable to branch between xray/marzban
2. **Bash script** (`vps-setup.sh`) — self-contained installer that downloads config templates from `templates_for_script/` via raw GitHub URLs, uses `envsubst` for templating

Both paths produce the same result: Docker Compose stack in `/opt/xray-vps-setup/` with Angie + XRay/Marzban containers using `network_mode: host`.

### Traffic flow

```
Client → :443 (XRay VLESS+REALITY) → PROXY_PROTOCOL → :4123 (Angie for TLS certs)
Client → :80 → Angie → 301 redirect to HTTPS
```

XRay listens on 443, handles VLESS with REALITY, and forwards to local Angie only for certificate management via ACME. Marzban panel (when used) is reverse-proxied by Angie at randomized paths.

### Key variables (Ansible)

- `domain` — server domain
- `setup_variant` — `"marzban"` or `"xray"`
- `setup_warp` — enable Cloudflare WARP for Russian sites routing

### Generated secrets

Both paths generate at runtime: x25519 key pair (PIK/PBK), XRay UUID, and (for marzban) admin credentials + randomized panel/subscription paths.

## Commands

### Ansible

```bash
# Test role locally
ansible-playbook tests/test.yml --connection=local

# Run against remote host (requires inventory.yml and playbook.yml — gitignored)
ansible-playbook playbook.yml -e "domain=example.com setup_variant=xray"
```

### Script

```bash
# Run on target VPS (interactive, requires root)
bash vps-setup.sh
```

### Docker Compose (on target VPS after install)

```bash
docker compose -f /opt/xray-vps-setup/docker-compose.yml up -d
docker compose -f /opt/xray-vps-setup/docker-compose.yml down
```

## File Mapping

| Ansible template (`templates/`) | Script template (`templates_for_script/`) | Purpose |
|---|---|---|
| `angie.conf.j2` | `angie`, `angie-marzban` | Angie config (script has separate files for xray/marzban) |
| `xray.json.j2` | `xray` | XRay inbound config |
| `docker_compose.yml.j2` | `compose-xray`, `compose-marzban`, `compose-node` | Docker Compose (script has separate files per mode) |
| `marzban.j2` | `marzban` | Marzban `.env` |
| `confluence.j2` | `confluence` | Camouflage HTML page |

Ansible uses Jinja2 conditionals (`{% if setup_variant == "marzban" %}`), script uses separate template files per mode.

## Important Notes

- Ports 80, 443, 4123 are reserved — SSH must not use them
- WARP integration patches XRay config post-deploy via `yq` to add SOCKS outbound on port 40000
- `templates_for_script/` uses `$ENVVAR` syntax (for `envsubst`), `templates/` uses `{{ var }}` syntax (Jinja2)
- XRay core version is pinned to v26.2.6 in both `install_marzban.yml` and `vps-setup.sh`
- The `install_docker.yml` task hardcodes Ubuntu `focal` repo — may need updating for other distros

## Cascade Mode (Two-VPS Bridge)

Two-VPS architecture for bypassing DPI: VPS1 (exit, Marzban panel) + VPS2 (entry, Marzban node). Uses XHTTP+REALITY transport between VPS2→VPS1.

### Quick Start

```bash
# 1. On VPS1 (Germany):
tmux
bash <(wget -qO- https://raw.githubusercontent.com/Akiyamov/xray-vps-setup/refs/heads/main/setup-panel.sh)
# Copy the output values

# 2. On VPS2 (Russia):
tmux
bash <(wget -qO- https://raw.githubusercontent.com/Akiyamov/xray-vps-setup/refs/heads/main/setup-node.sh)
# Paste VPS1 values when prompted

# 3. Back on VPS1 — add WG tunnel peer:
bash setup-panel.sh --add-wg-peer <VPS2_WG_PBK> <VPS2_IP>
```

### Cascade Architecture

```
Client → VPS2:443 (XHTTP+REALITY / TCP Vision) → XHTTP+REALITY → VPS1:443 → Internet
Client → VPS2:51820 (WireGuard) → WG tunnel → VPS1 → Internet
```

- `setup-panel.sh` — VPS1 installer (Marzban panel + XHTTP inbound + WG tunnel)
- `setup-node.sh` — VPS2 installer (Marzban node + steal_oneself + chain outbound + wg-easy)

### Cascade Templates

| Template | Purpose |
|----------|---------|
| `panel-xray` | VPS1: XRay XHTTP+REALITY inbound |
| `panel-angie` | VPS1: Angie (TLS + Marzban panel proxy) |
| `compose-panel` | VPS1: Docker Compose (angie + marzban) |
| `wg-tunnel-panel` | VPS1: WireGuard p2p tunnel config |
| `node-xray` | VPS2: XRay steal_oneself + chain outbound |
| `node-angie` | VPS2: Angie (TLS + wg-easy UI proxy) |
| `compose-cascade-node` | VPS2: Docker Compose (angie + marzban-node + wg-easy) |
| `wg-tunnel-node` | VPS2: WireGuard p2p tunnel config |

### Cascade-Specific Notes

- XHTTP transport requires XRay >= v26.2.6 (pinned to v26.3.23)
- `flow: xtls-rprx-vision` MUST NOT be set on XHTTP inbounds or outbounds
- `mode: "stream-one"` pinned in chain outbound (auto has bug #5635)
- VPS2 WG tunnel uses `Table = off` to prevent wg-quick from hijacking host routes
- No MASQUERADE on VPS2 — policy routing only; VPS1 handles NAT on exit
- marzban-node starts AFTER ssl_client_cert.pem is fetched from panel API
