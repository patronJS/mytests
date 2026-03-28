# Cascade Config Hardening — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Harden XRay/Angie config templates to fix REALITY shortId bypass, remove version leaks, disable IP logging, and eliminate external camouflage dependencies.

**Architecture:** Pure template and script edits across 3 installer paths (cascade, standalone xray, standalone marzban). No new files, no architectural changes. All changes are independently reversible.

**Tech Stack:** Bash scripts, XRay JSON configs (envsubst templates), Angie/nginx configs, HTML

**Spec:** `docs/superpowers/specs/2026-03-28-cascade-hardening-design.md`

---

## File Map

| File | Changes | Tasks |
|------|---------|-------|
| `templates_for_script/xray` | Remove `publicKey`, fix `shortIds` | 1, 2 |
| `templates_for_script/xray_outbound` | Fix `shortId` variable | 1 |
| `templates_for_script/sing_box_outbound` | Fix `short_id` variable | 1 |
| `vps-setup.sh` | Generate `SHORT_ID`, fix clipboard URI | 1 |
| `templates_for_script/panel-angie` | `server_tokens off`, `access_log off` | 3 |
| `templates_for_script/node-angie` | `server_tokens off`, `access_log off` | 3 |
| `templates_for_script/angie` | `server_tokens off`, `access_log off` | 3 |
| `templates_for_script/angie-marzban` | `server_tokens off`, `access_log off` | 3 |
| `templates_for_script/confluence` | Embed logo as data URI | 4 |
| `templates_for_script/panel-xray` | Multi-shortId array | 5 |
| `templates_for_script/node-xray` | Multi-shortId array + optional `host` | 5, 6 |
| `setup-panel.sh` | Multi-shortId generation + output | 5 |
| `setup-node.sh` | Relax `PANEL_SHORT_ID` validation | 5 |

---

### Task 1: Fix empty shortId + remove publicKey (H1 + H6) — Phase 2

**Files:**
- Modify: `templates_for_script/xray:24-34`
- Modify: `templates_for_script/xray_outbound:26`
- Modify: `templates_for_script/sing_box_outbound:18`
- Modify: `vps-setup.sh:153-155` (add SHORT_ID generation)
- Modify: `vps-setup.sh:538` (fix clipboard URI)

- [ ] **Step 1: Add SHORT_ID generation to `vps-setup.sh`**

In `vps-setup.sh`, after line 154 (`export XRAY_UUID=...`), add:

```bash
  export SHORT_ID=$(openssl rand -hex 8)
```

The block becomes:
```bash
if [[ "$INSTALL_MODE" != "node" ]]; then
  export XRAY_PIK=$(docker run --rm ghcr.io/xtls/xray-core x25519 | head -n1 | cut -d' ' -f 2)
  export XRAY_PBK=$(docker run --rm ghcr.io/xtls/xray-core x25519 -i $XRAY_PIK | tail -2 | head -1 | cut -d' ' -f 2)
  export XRAY_UUID=$(docker run --rm ghcr.io/xtls/xray-core uuid)
  export SHORT_ID=$(openssl rand -hex 8)
fi
```

- [ ] **Step 2: Fix clipboard URI in `vps-setup.sh`**

In `vps-setup.sh:538`, change `sid=&spx` to `sid=$SHORT_ID&spx`:

```
vless://$XRAY_UUID@$VLESS_DOMAIN:443?type=tcp&security=reality&pbk=$XRAY_PBK&fp=chrome&sni=$VLESS_DOMAIN&sid=$SHORT_ID&spx=%2F&flow=xtls-rprx-vision#Script
```

- [ ] **Step 3: Fix server template — remove publicKey, fix shortIds**

In `templates_for_script/xray`, replace the `realitySettings` block (lines 24-35):

```json
        "realitySettings": {
          "xver": 1,
          "dest": "127.0.0.1:4123",
          "serverNames": [
            "$VLESS_DOMAIN"
          ],
          "privateKey": "$XRAY_PIK",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
```

Removes `"publicKey": "$XRAY_PBK"` and replaces `""` with `"$SHORT_ID"`.

- [ ] **Step 4: Fix xray_outbound template**

In `templates_for_script/xray_outbound:26`, change `$XRAY_SID` to `$SHORT_ID`:

```json
      "shortId": "$SHORT_ID",
```

- [ ] **Step 5: Fix sing_box_outbound template**

In `templates_for_script/sing_box_outbound:18`, change `""` to `"$SHORT_ID"`:

```json
            "short_id": "$SHORT_ID"
```

- [ ] **Step 6: Also add SHORT_ID to the plain data output**

In `vps-setup.sh:547`, update the "Plain data" line:

```
Plain data:
PBK: $XRAY_PBK, UUID: $XRAY_UUID, SID: $SHORT_ID
```

- [ ] **Step 7: Verify consistency (static)**

Run: `grep -rn 'sid=\|shortId\|short_id\|SHORT_ID\|XRAY_SID' vps-setup.sh templates_for_script/xray templates_for_script/xray_outbound templates_for_script/sing_box_outbound`

Expected: All references use `$SHORT_ID`, no empty strings, no `$XRAY_SID`.

- [ ] **Step 8: Verify envsubst produces valid JSON**

Run locally with sample values:
```bash
export SHORT_ID=abcdef0123456789 XRAY_PIK=test XRAY_PBK=test XRAY_UUID=00000000-0000-0000-0000-000000000000 VLESS_DOMAIN=example.com
envsubst < templates_for_script/xray | jq . > /dev/null && echo "Valid JSON" || echo "INVALID JSON"
envsubst < templates_for_script/xray_outbound | jq . > /dev/null && echo "Valid JSON" || echo "INVALID JSON"
envsubst < templates_for_script/sing_box_outbound | jq . > /dev/null && echo "Valid JSON" || echo "INVALID JSON"
```

Expected: All three print "Valid JSON".

- [ ] **Step 9: Commit**

```bash
git add vps-setup.sh templates_for_script/xray templates_for_script/xray_outbound templates_for_script/sing_box_outbound
git commit -m "fix: generate non-empty REALITY shortId for standalone mode (H1+H6)

Empty shortId weakened REALITY admission control. Also removes
unused publicKey from server-side inbound config."
```

---

### Task 2: Verify cascade templates already have shortId (no changes expected)

**Files:**
- Read-only: `templates_for_script/panel-xray`, `templates_for_script/node-xray`
- Read-only: `setup-panel.sh`, `setup-node.sh`

- [ ] **Step 1: Confirm cascade templates use `$SHORT_ID`**

Run: `grep -n 'shortId' templates_for_script/panel-xray templates_for_script/node-xray`

Expected: Both use `"$SHORT_ID"` (not empty string).

- [ ] **Step 2: Confirm cascade scripts generate SHORT_ID**

Run: `grep -n 'SHORT_ID' setup-panel.sh setup-node.sh`

Expected: `setup-panel.sh:118` has `export SHORT_ID=$(openssl rand -hex 8)`, `setup-node.sh:146` has the same.

- [ ] **Step 3: No commit needed — cascade path is already correct**

---

### Task 3: Add server_tokens off + disable access_log in all Angie configs (H2 + H3) — Phase 3

**Files:**
- Modify: `templates_for_script/panel-angie:11-12`
- Modify: `templates_for_script/node-angie:11-12`
- Modify: `templates_for_script/angie:11-12`
- Modify: `templates_for_script/angie-marzban:11-12`

All 4 files have identical lines 10-12:
```nginx
http {
    log_format main '[$time_local] $proxy_protocol_addr "$http_referer" "$http_user_agent"';
    access_log /var/log/angie/access.log main;
```

- [ ] **Step 1: Edit `panel-angie`**

Replace lines 11-12:
```nginx
    log_format main '[$time_local] $proxy_protocol_addr "$http_referer" "$http_user_agent"';
    access_log /var/log/angie/access.log main;
```

With:
```nginx
    server_tokens off;
    access_log off;
```

- [ ] **Step 2: Edit `node-angie`**

Same change as Step 1 — replace `log_format` + `access_log` lines with `server_tokens off;` + `access_log off;`.

- [ ] **Step 3: Edit `angie` (standalone)**

Same change as Step 1.

- [ ] **Step 4: Edit `angie-marzban`**

Same change as Step 1.

- [ ] **Step 5: Verify all 4 files**

Run: `grep -n 'server_tokens\|access_log\|log_format' templates_for_script/panel-angie templates_for_script/node-angie templates_for_script/angie templates_for_script/angie-marzban`

Expected: Each file shows `server_tokens off;` and `access_log off;`. No `log_format`, no `access_log ... main`.

- [ ] **Step 6: Verify the unused `map` blocks referencing `$proxy_protocol_addr`**

The `map $proxy_protocol_addr $proxy_forwarded_elem` blocks (lines 19-23 in all files) reference the now-unlogged variable. These map blocks are still valid nginx syntax even without access_log — they're used by `$proxy_add_forwarded` which may be referenced elsewhere. Leave them for now.

- [ ] **Step 7: Commit**

```bash
git add templates_for_script/panel-angie templates_for_script/node-angie templates_for_script/angie templates_for_script/angie-marzban
git commit -m "fix: hide Angie version, disable client IP logging (H2+H3)

Add server_tokens off to prevent version leak via Server header.
Replace access_log with access_log off for privacy — error_log stays."
```

---

### Task 4: Embed Confluence logo as inline SVG data URI (H4) — Phase 3

**Files:**
- Modify: `templates_for_script/confluence:136`

- [ ] **Step 1: Create vendored inline SVG Confluence logo**

Do NOT use a build-time `curl | base64` step (the `-w0` flag is GNU-specific, not portable). Instead, vendor the Confluence logo as a static inline SVG data URI directly in the template.

Use the official Atlassian Confluence SVG mark. Create the base64 string once on a dev machine and hardcode it:

```bash
# One-time on dev machine — the output goes INTO the template as a static string
curl -sL "https://cdn.icon-icons.com/icons2/2429/PNG/512/confluence_logo_icon_147305.png" | base64 | tr -d '\n'
```

Copy the full base64 output string.

- [ ] **Step 2: Replace img src in `confluence` template**

In `templates_for_script/confluence:136`, replace:
```html
        <img src="https://cdn.icon-icons.com/icons2/2429/PNG/512/confluence_logo_icon_147305.png" alt="Confluence">
```

With (single line, the base64 string is the output from Step 1):
```html
        <img src="data:image/png;base64,HARDCODED_BASE64_STRING_HERE" alt="Confluence" width="120">
```

The base64 string is a **static constant in the template** — no runtime or deploy-time fetching. The `width="120"` matches the existing `.logo img { width: 120px; }` CSS.

- [ ] **Step 4: Verify**

Open the file in a browser. The logo should render without any network requests to external domains.

Run: `grep -c 'cdn.icon-icons.com' templates_for_script/confluence`

Expected: `0`

- [ ] **Step 5: Commit**

```bash
git add templates_for_script/confluence
git commit -m "fix: embed Confluence logo inline, remove CDN dependency (H4)

External logo URL could break camouflage page if CDN is unavailable."
```

---

### Task 5: Multi-shortId support across cascade + standalone (H5) — Phase 4

**Files:**
- Modify: `setup-panel.sh:118` (generate multiple shortIds)
- Modify: `setup-panel.sh:239` (output updated)
- Modify: `setup-node.sh:85` (relax validation)
- Modify: `setup-node.sh:146` (generate multiple shortIds)
- Modify: `vps-setup.sh:155` (generate multiple shortIds)
- Modify: `templates_for_script/xray:32-34`
- Modify: `templates_for_script/panel-xray:22`
- Modify: `templates_for_script/node-xray:22`
- Modify: `vps-setup.sh:547` (standalone output)

- [ ] **Step 1: Create shortId generation helper in `setup-panel.sh`**

In `setup-panel.sh`, replace line 118:
```bash
export SHORT_ID=$(openssl rand -hex 8)
```

With:
```bash
export SID1=$(openssl rand -hex 2)
export SID2=$(openssl rand -hex 4)
export SID3=$(openssl rand -hex 6)
export SID4=$(openssl rand -hex 8)
export SHORT_IDS="\"$SID1\",\"$SID2\",\"$SID3\",\"$SID4\""
export SHORT_ID=$SID4
```

`SHORT_ID` (single, 16 hex) is kept for backward compatibility — it's the recommended value for node outbound and client configs.

- [ ] **Step 2: Update panel output**

In `setup-panel.sh:239`, change:
```bash
echo " PANEL_SHORT_ID: $SHORT_ID"
```

To:
```bash
echo " PANEL_SHORT_ID: $SHORT_ID (recommended for node outbound)"
echo " All shortIds:   $SID1, $SID2, $SID3, $SID4"
```

- [ ] **Step 3: Relax PANEL_SHORT_ID validation in `setup-node.sh`**

In `setup-node.sh:85`, replace:
```bash
[[ "$PANEL_SHORT_ID" =~ ^[0-9a-f]{16}$ ]] || { echo "Invalid PANEL_SHORT_ID format"; exit 1; }
```

With:
```bash
[[ "$PANEL_SHORT_ID" =~ ^[0-9a-f]{2,16}$ ]] && (( ${#PANEL_SHORT_ID} % 2 == 0 )) || { echo "Invalid PANEL_SHORT_ID: must be 2-16 even-length hex chars"; exit 1; }
```

- [ ] **Step 4: Update shortId generation in `setup-node.sh`**

In `setup-node.sh:146`, replace:
```bash
export SHORT_ID=$(openssl rand -hex 8)
```

With:
```bash
export SID1=$(openssl rand -hex 2)
export SID2=$(openssl rand -hex 4)
export SID3=$(openssl rand -hex 6)
export SID4=$(openssl rand -hex 8)
export SHORT_IDS="\"$SID1\",\"$SID2\",\"$SID3\",\"$SID4\""
export SHORT_ID=$SID4
```

- [ ] **Step 5: Update shortId generation in `vps-setup.sh`**

In `vps-setup.sh` (the line added in Task 1), replace:
```bash
  export SHORT_ID=$(openssl rand -hex 8)
```

With:
```bash
  export SID1=$(openssl rand -hex 2)
  export SID2=$(openssl rand -hex 4)
  export SID3=$(openssl rand -hex 6)
  export SID4=$(openssl rand -hex 8)
  export SHORT_IDS="\"$SID1\",\"$SID2\",\"$SID3\",\"$SID4\""
  export SHORT_ID=$SID4
```

- [ ] **Step 6: Update server templates**

In `templates_for_script/xray`, change:
```json
          "shortIds": [
            "$SHORT_ID"
          ]
```

To:
```json
          "shortIds": [$SHORT_IDS]
```

In `templates_for_script/panel-xray`, change:
```json
        "shortIds": ["$SHORT_ID"]
```

To:
```json
        "shortIds": [$SHORT_IDS]
```

In `templates_for_script/node-xray`, change (line 22, reality-tcp inbound):
```json
          "shortIds": ["$SHORT_ID"]
```

To:
```json
          "shortIds": [$SHORT_IDS]
```

- [ ] **Step 7: Update standalone output in `vps-setup.sh`**

**Prerequisite:** Task 1 must be merged first (SHORT_ID already exists in vps-setup.sh).

In `vps-setup.sh:547`, update the "Plain data" line to include all shortIds:

```
Plain data:
PBK: $XRAY_PBK, UUID: $XRAY_UUID, SID: $SHORT_ID
All shortIds: $SID1, $SID2, $SID3, $SID4
```

- [ ] **Step 8: Verify client artifacts still use single SHORT_ID**

Run: `grep -n 'SHORT_ID\|short_id\|shortId' templates_for_script/xray_outbound templates_for_script/sing_box_outbound`

Expected: Both still reference `$SHORT_ID` (single value = SID4, 16 hex). No changes needed for client templates.

- [ ] **Step 9: Verify envsubst produces valid JSON with SHORT_IDS**

```bash
export SID1=ab12 SID2=cd34ef56 SID3=0123456789ab SID4=abcdef0123456789
export SHORT_IDS="\"$SID1\",\"$SID2\",\"$SID3\",\"$SID4\""
export SHORT_ID=$SID4 XRAY_PIK=test VLESS_DOMAIN=example.com
envsubst < templates_for_script/xray | jq '.inbounds[0].streamSettings.realitySettings.shortIds' && echo "Valid"
```

Expected: JSON array with 4 shortIds of different lengths.

- [ ] **Step 10: Commit**

```bash
git add setup-panel.sh setup-node.sh vps-setup.sh templates_for_script/xray templates_for_script/panel-xray templates_for_script/node-xray
git commit -m "feat: multiple REALITY shortIds with varying lengths (H5)

Generate 4 shortIds (4/8/12/16 hex chars) for inbound arrays.
Client configs use the 16-char ID. Relaxed validation in
setup-node.sh to accept 2-16 even-length hex."
```

---

### Task 6: Add XHTTP `host` field to chain outbound (H7 minimal) — Phase 5

**Files:**
- Modify: `templates_for_script/node-xray:64-67`

**Status:** OPTIONAL. Skip if Phase 2-4 testing shows no issues.

- [ ] **Step 1: Add `host` field to chain outbound xhttpSettings**

In `templates_for_script/node-xray`, change the chain-vps1 outbound `xhttpSettings` block:

```json
        "xhttpSettings": {
          "path": "/$XHTTP_PATH",
          "mode": "stream-one"
        },
```

To:
```json
        "xhttpSettings": {
          "host": "$PANEL_DOMAIN",
          "path": "/$XHTTP_PATH",
          "mode": "stream-one"
        },
```

This only adds the `host` field (safe, ensures correct Host header). No `extra.headers`, no hardcoded UA.

- [ ] **Step 2: Verify $PANEL_DOMAIN is available**

Run: `grep -n 'PANEL_DOMAIN' setup-node.sh | head -5`

Expected: `PANEL_DOMAIN` is read from user input and exported.

- [ ] **Step 3: Test cascade connectivity + packet capture**

Deploy to test VPS pair:
1. Verify VPS2->VPS1 chain outbound still connects (basic functionality)
2. Run packet capture on VPS2: `tcpdump -i any port 443 -w /tmp/h7_test.pcap &`
3. Make a test connection through the cascade
4. Stop capture, analyze with: `tshark -r /tmp/h7_test.pcap -Y "http" -T fields -e http.host`
5. Verify Host header matches `$PANEL_DOMAIN`
6. Verify no mixed/stale fingerprint artifacts

- [ ] **Step 4: Commit**

```bash
git add templates_for_script/node-xray
git commit -m "feat: add explicit host to XHTTP chain outbound (H7 minimal)

Ensures Host header matches target domain. No custom UA or extra
headers — uses XRay built-in fetch profile."
```

---

## Post-Implementation Checklist

- [ ] All `grep -rn '""' templates_for_script/xray` shows no empty shortIds
- [ ] All `grep -rn 'publicKey' templates_for_script/xray` shows no matches
- [ ] All `grep -rn 'cdn.icon-icons' templates_for_script/` shows no matches
- [ ] All `grep -rn 'server_tokens' templates_for_script/` shows 4 matches (all `off`)
- [ ] All `grep -rn 'access_log' templates_for_script/` shows 4 matches (all `off`)
- [ ] All `grep -rn 'SHORT_IDS' templates_for_script/` shows 3 matches (xray, panel-xray, node-xray)
- [ ] `vps-setup.sh` clipboard URI contains `sid=$SHORT_ID`

---

## Review Record

### Codex GPT-5 via PAL (2026-03-28)

| Finding | Severity | Action |
|---------|----------|--------|
| Task 4: curl\|base64 contradicts spec (spec says vendored static) | HIGH | Fixed — Task 4 rewritten to use pre-computed static data URI |
| Task 5: standalone output not updated for multi-shortId | HIGH | Fixed — added Step 7 for vps-setup.sh output |
| Task 5: `panel-xray:20` and `node-xray:20` wrong line numbers | MEDIUM | Fixed → `:22` |
| Task 6: `node-xray:63-66` wrong line numbers | MEDIUM | Fixed → `64-67` |
| Task 1: verification too weak (grep only) | MEDIUM | Fixed — added Step 8 (envsubst + jq validation) |
| Task 5: verification too weak | MEDIUM | Fixed — added Step 9 (envsubst + jq for SHORT_IDS array) |
| Task 6: missing packet capture gate | MEDIUM | Fixed — Step 3 expanded with tcpdump + tshark |
