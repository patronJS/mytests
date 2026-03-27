# Implementation Plan: Ubuntu 24.04 Optimization & Full Revision

Based on: `docs/superpowers/specs/2026-03-27-ubuntu2404-optimization-design.md`

## Step Order Rationale

Templates first (no logic changes, low risk), then scripts (depend on correct templates), then docs, then Ansible deletion last (keeps reference available during doc cleanup).

---

## Step 1: Fix templates

### 1a: Add `:ro` mounts

Files: `compose-xray`, `compose-marzban`, `compose-node`

Add `:ro` to all config/static file mounts (angie.conf, index.html, xray config, marzban xray_config.json, ssl_client_cert.pem). Do NOT add `:ro` to data volumes (angie-data, marzban_lib, wg-data).

### 1b: Fix `compose-panel` xray-core mount

File: `compose-panel`

Change:
```yaml
- ./marzban/xray-core:/var/lib/marzban/xray-core:ro
```
To:
```yaml
- ./marzban/xray-core:/code/xray-core:ro
```

### 1c: Auto-detect network interface in `wg-tunnel-panel`

File: `templates_for_script/wg-tunnel-panel`

Replace all `eth0` occurrences with `$DEFAULT_IFACE`. The variable will be exported by `setup-panel.sh` (Step 2).

**Verification:** `grep -r 'eth0' templates_for_script/` — should return nothing.

---

## Step 2: Fix bash scripts

### 2a: `vps-setup.sh` — hardening

1. Fix shebang: `#/bin/bash` → `#!/bin/bash`
2. Add strict mode: `set -e` → `set -euo pipefail`
3. Add `XRAY_VERSION="v26.3.23"` variable, replace all hardcoded `v26.2.6` references
4. Quote idn: `$(echo $input_domain | idn)` → `$(echo "$input_domain" | idn)`
5. Fix ssh-keygen check:
   ```bash
   # Before
   ssh-keygen -l -f ./test_pbk
   PBK_STATUS=$(echo $?)
   if [ "$PBK_STATUS" -eq 255 ]; then

   # After
   if ! ssh-keygen -l -f ./test_pbk; then
   ```
6. BBR sysctl — add duplicate guards:
   ```bash
   # Before
   echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf

   # After
   if ! sysctl net.ipv4.tcp_congestion_control | grep -q bbr; then
     echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
     echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
   fi
   sysctl -p > /dev/null
   ```
7. Add `chmod 600` on xray config, marzban .env; `chmod 644` on angie.conf, index.html, docker-compose.yml
8. WARP: replace `$(lsb_release -cs)` with `$(. /etc/os-release && echo $VERSION_CODENAME)`
9. iptables idempotency — use `iptables -C` (check) before each `iptables -A` (append):
   ```bash
   iptables_add() {
     iptables -C "$@" 2>/dev/null || iptables -A "$@"
   }
   iptables_add INPUT -p icmp -j ACCEPT
   iptables_add INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
   # ... etc
   ```
   This approach is safe for SSH: it never flushes existing rules, only adds missing ones. Applies to `edit_iptables()` and `edit_iptables_node()` functions.

**Verification:** `bash -n vps-setup.sh` — syntax check passes.

### 2b: `setup-panel.sh` — fixes

1. Guard `--add-wg-peer` args:
   ```bash
   # Before
   if [[ "$1" == "--add-wg-peer" ]]; then
     WG_PBK="$2"
     VPS2_IP="$3"

   # After
   if [[ "${1:-}" == "--add-wg-peer" ]]; then
     WG_PBK="${2:-}"
     VPS2_IP="${3:-}"
   ```
2. Quote idn: `$(echo $input_domain | idn)` → `$(echo "$input_domain" | idn)`
3. Add `DEFAULT_IFACE` detection before WG template download:
   ```bash
   export DEFAULT_IFACE=$(ip route show default | awk '{print $5}' | head -1)
   if [[ -z "$DEFAULT_IFACE" ]]; then
     echo "Could not detect default network interface"
     exit 1
   fi
   ```
4. iptables idempotency: same `iptables_add` helper as 2a.9

**Verification:** `bash -n setup-panel.sh` — syntax check passes.

### 2c: `setup-node.sh` — fixes

1. Quote idn: `$(echo $input_domain | idn)` → `$(echo "$input_domain" | idn)`
2. Fix ssh-keygen check (same pattern as 2a.5)
3. `/etc/hosts` duplicate guard:
   ```bash
   # Before
   echo "$VPS1_IP $PANEL_DOMAIN" >> /etc/hosts

   # After
   grep -q "$PANEL_DOMAIN" /etc/hosts || echo "$VPS1_IP $PANEL_DOMAIN" >> /etc/hosts
   ```
4. WARP: replace `$(lsb_release -cs)` with `$(. /etc/os-release && echo $VERSION_CODENAME)`
5. iptables idempotency: same `iptables_add` helper

**Verification:** `bash -n setup-node.sh` — syntax check passes.

---

## Step 3: Update documentation

### 3a: `CLAUDE.md`

- Remove "Ansible role" section from Architecture
- Remove `tasks/`, `templates/`, `handlers/`, `defaults/`, `vars/`, `meta/` from descriptions
- Remove Ansible commands section
- Remove File Mapping table (Ansible↔Script mapping)
- Keep script-only docs, cascade docs, templates_for_script references
- Update any version references (v26.2.6 → v26.3.23)

### 3b: `README.md`

- Remove Ansible Galaxy badge/link references
- Remove Ansible install/usage instructions
- Keep bash script instructions

### 3c: `install_in_docker.md`

- Review for Ansible references, remove if found
- Do NOT delete file — it is a Docker manual guide, not Ansible-specific

**Verification:** `grep -ri ansible CLAUDE.md README.md install_in_docker.md` — should return nothing.

---

## Step 4: Remove Ansible role

Delete directories and files:
- `tasks/` (all 7 files)
- `templates/` (all 5 files)
- `handlers/main.yml`
- `defaults/main.yml`
- `vars/main.yml`
- `meta/main.yml`
- `tests/test.yml`

**Verification:** `ls tasks/ templates/ handlers/ defaults/ vars/ meta/ tests/` — all should fail with "No such file or directory".

---

## Step 5: Final verification

1. `bash -n vps-setup.sh && bash -n setup-panel.sh && bash -n setup-node.sh` — all pass
2. `grep -r 'eth0' templates_for_script/` — no results
3. `grep -r 'v26.2.6' vps-setup.sh setup-panel.sh setup-node.sh templates_for_script/` — no results
4. `grep -r 'lsb_release' *.sh` — no results
5. `grep -ri 'ansible' CLAUDE.md README.md install_in_docker.md` — no results
6. `ls tasks/ templates/ handlers/ defaults/ vars/ meta/ tests/` — all fail
7. Verify `:ro` mounts: `grep -L ':ro' templates_for_script/compose-xray templates_for_script/compose-marzban templates_for_script/compose-node templates_for_script/compose-panel` — no results (all files contain `:ro`)
