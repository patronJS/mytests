# Ubuntu 24.04 Optimization & Full Revision

## Summary

Harmonize all bash scripts to consistent quality, fix Ubuntu 24.04 compatibility issues, improve idempotency, remove unused Ansible role, and standardize templates.

## Scope

### 1. Bash Scripts — Bug Fixes & Hardening

#### `vps-setup.sh`

| Line | Issue | Fix |
|------|-------|-----|
| 1 | `#/bin/bash` — broken shebang | `#!/bin/bash` |
| 3 | Only `set -e` | `set -euo pipefail` |
| 34 | Unquoted `$(echo $input_domain \| idn)` | Quote variable |
| 101-103 | `ssh-keygen` failure kills script via `set -e` before `PBK_STATUS` check runs | Rewrite as `if ! ssh-keygen -l -f ./test_pbk; then ... fi` |
| 122-128 | BBR sysctl append without duplicate check | Add `grep -q` guard (matches setup-panel.sh pattern) |
| — | No `chmod` on generated config files | Add `chmod 600/644` (matches cascade scripts) |
| — | XRay version hardcoded to v26.2.6 | Unify to v26.3.23 via `XRAY_VERSION` variable |

#### `setup-panel.sh`

| Line | Issue | Fix |
|------|-------|-----|
| 6-9 | `$1`, `$2`, `$3` with `set -u` crash without args | Guard all: `${1:-}`, `${2:-}`, `${3:-}` with validation after |
| 47 | Unquoted `$(echo $input_domain \| idn)` | Quote variable |

#### `setup-node.sh`

| Line | Issue | Fix |
|------|-------|-----|
| 23 | Unquoted `$(echo $input_domain \| idn)` | Quote variable |
| 101-103 | `ssh-keygen` failure kills script via `set -e` before check runs | `if ! ssh-keygen -l -f ./test_pbk; then ... fi` |
| 186 | `/etc/hosts` append without duplicate check — reruns create duplicates | Add `grep -q` guard before appending |

#### All scripts — idempotency improvements

- `iptables` rules are appended without checking existing rules. On rerun, duplicate rules accumulate.
  Fix: flush and rebuild, or check with `iptables -C` before `-A`.

### 2. Templates — Consistency

#### Docker Compose read-only mounts

Add `:ro` to config mounts in `compose-xray`, `compose-marzban`, and `compose-node` (matches cascade templates):

```yaml
# Before
- ./angie.conf:/etc/angie/angie.conf
- ./index.html:/tmp/index.html

# After
- ./angie.conf:/etc/angie/angie.conf:ro
- ./index.html:/tmp/index.html:ro
```

Same for xray config and marzban xray_config.json mounts in all compose templates.

#### `compose-panel` XRAY_EXECUTABLE_PATH mismatch

Compose mounts `./marzban/xray-core:/var/lib/marzban/xray-core:ro` but marzban `.env` sets `XRAY_EXECUTABLE_PATH = "/code/xray-core/xray"`.

Fix: change compose mount to `./marzban/xray-core:/code/xray-core:ro` so it matches the `.env` path. All compose files will use `/code/xray-core` consistently.

#### XRay version unification

All scripts and templates use `XRAY_VERSION="v26.3.23"` (currently `vps-setup.sh` uses v26.2.6).

### 3. WireGuard Tunnel — Interface Auto-Detection

`wg-tunnel-panel` template hardcodes `eth0`. Ubuntu 24.04 uses predictable interface names (`ens3`, `enp0s3`, etc.).

Fix: auto-detect default interface in `setup-panel.sh`:
```bash
export DEFAULT_IFACE=$(ip route show default | awk '{print $5}' | head -1)
if [[ -z "$DEFAULT_IFACE" ]]; then
  echo "Could not detect default network interface"
  exit 1
fi
```

Replace `eth0` with `$DEFAULT_IFACE` in the `wg-tunnel-panel` template.

### 4. WARP — Distro Detection

`vps-setup.sh` and `setup-node.sh` use `$(lsb_release -cs)` which may be absent on minimal Ubuntu 24.04. (`setup-panel.sh` does not use WARP.)

Fix: replace with `$(. /etc/os-release && echo $VERSION_CODENAME)` — guaranteed present on all Ubuntu.

### 5. Remove Ansible Role

Delete entirely (not used, not maintained):
- `tasks/` (install_docker.yml, install_xray.yml, install_marzban.yml, install_yq.yml, setup_warp.yml, end_xray.yml, main.yml)
- `templates/` (angie.conf.j2, xray.json.j2, docker_compose.yml.j2, marzban.j2, confluence.j2)
- `handlers/main.yml`
- `defaults/main.yml`
- `vars/main.yml`
- `meta/main.yml`
- `tests/test.yml`

Update docs to remove all Ansible references:
- `CLAUDE.md`
- `README.md`
- `install_in_docker.md`

## Out of Scope

- No shared `lib.sh` extraction — scripts remain self-contained for `curl | bash` delivery
- No migration to `nftables` — `iptables` works via `iptables-nft` compatibility layer on Ubuntu 24.04
- No Ansible role modernization — role is being removed entirely
