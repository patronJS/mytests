# Cascade Config Hardening

**Date:** 2026-03-28
**Scope:** Hardening existing XRay/Angie templates across all installer paths — no architectural changes

**Files affected:**

| Category | Files |
|----------|-------|
| Cascade templates | `panel-xray`, `node-xray`, `panel-angie`, `node-angie`, `compose-cascade-node` |
| Legacy/standalone templates | `xray`, `angie`, `angie-marzban`, `xray_outbound`, `sing_box_outbound` |
| Camouflage | `confluence` |
| Installer scripts | `vps-setup.sh`, `setup-panel.sh`, `setup-node.sh` |

## Context

Current two-VPS cascade (VPS2 entry with steal_oneself + chain outbound -> VPS1 exit with XHTTP+REALITY) is architecturally sound. This spec covers config-level hardening to reduce fingerprinting surface, fix security gaps, and improve camouflage quality.

Three installer paths exist and all must be hardened consistently:
1. **Cascade** — `setup-panel.sh` + `setup-node.sh` (uses `panel-*`, `node-*` templates)
2. **Standalone xray** — `vps-setup.sh` mode=xray (uses `xray`, `angie` templates)
3. **Standalone marzban** — `vps-setup.sh` mode=marzban (uses `xray`, `angie-marzban` templates)

### What stays unchanged

- REALITY protocol, XHTTP transport, steal_oneself pattern
- `ssl_reject_handshake on` on Angie default_server
- iptables rules restricting VPS2 ports to VPS1 only
- `sniffing.routeOnly: true`
- `stream-one` mode for chain outbound
- Own domain with ACME (correct SNI/ASN match)
- REALITY dest -> local Angie (real cert + OCSP stapling > external proxy)
- `chrome` fingerprint (most common, best camouflage)
- DNS config (1.1.1.1/8.8.8.8 — used for routing only, not client queries)

## Changes

### H1. Fix empty shortId across all standalone artifacts

**Severity:** HIGH

**Problem:** `templates_for_script/xray:33` has `"shortIds": [""]` — empty string means REALITY accepts any probe with empty shortId. The client is still required to hold the REALITY public key, so this is not "zero verification", but it materially weakens admission control.

The same gap exists in client output artifacts:
- `templates_for_script/xray_outbound:26` — expects `$XRAY_SID` which is never exported
- `templates_for_script/sing_box_outbound:18` — hardcodes `"short_id": ""`
- `vps-setup.sh` — emits `sid=` (empty) in the clipboard URI

**Files:** `templates_for_script/xray`, `xray_outbound`, `sing_box_outbound`, `vps-setup.sh`

**Fix:** Generate and export `SHORT_ID` in `vps-setup.sh` (same as cascade scripts already do):

```bash
SHORT_ID=$(openssl rand -hex 8)
export SHORT_ID
```

Server template (`xray`):
```json
"shortIds": ["$SHORT_ID"]
```

Client template (`xray_outbound`):
```json
"shortId": "$SHORT_ID"
```

Client template (`sing_box_outbound`):
```json
"short_id": "$SHORT_ID"
```

Clipboard URI in `vps-setup.sh`: emit `sid=$SHORT_ID`.

**Verification:** Deploy standalone mode; connect with correct shortId — success; connect with empty or random shortId — fail.

### H2. Add `server_tokens off` to all Angie configs

**Files:** `templates_for_script/panel-angie`, `node-angie`, `angie`, `angie-marzban`
**Severity:** HIGH

**Problem:** Angie returns `Server: angie/X.Y.Z` header by default. Leaks exact software and version to any probe.

**Fix:** Add `server_tokens off;` inside the `http {}` block (after `access_log` or `log_format` line):

```nginx
http {
    server_tokens off;
    ...
}
```

**Verification:** `curl -sI https://$DOMAIN | grep -i server` — should return `Server: angie` without version, or no Server header.

### H3. Disable client IP logging in all Angie configs

**Files:** `templates_for_script/panel-angie`, `node-angie`, `angie`, `angie-marzban`
**Severity:** HIGH

**Problem:** `log_format main '[$time_local] $proxy_protocol_addr ...'` records real client IPs via PROXY_PROTOCOL. Server compromise -> client list exposure.

**Note:** This covers only Angie access logs. Marzban, wg-easy, and Docker container logs may still retain admin/operational metadata — that is out of scope for this spec.

**Fix:** Replace access_log with:
```nginx
access_log off;
```

Error log (`error_log notice`) stays for troubleshooting.

**Verification:** After restart, verify no new entries appear in `/var/log/angie/access.log`. Existing file may remain on disk but should stop receiving entries.

### H4. Embed camouflage page logo as inline asset

**File:** `templates_for_script/confluence`
**Line:** 136
**Severity:** MEDIUM (downgraded from HIGH after review)

**Problem:** `<img src="https://cdn.icon-icons.com/icons2/2429/PNG/512/confluence_logo_icon_147305.png">` — external resource. Issues:
1. CDN unavailable -> broken page on probe (suspicious for a "corporate" login page)
2. Probing client (browser/bot) makes a third-party request to the CDN, creating an external dependency in the camouflage

**Clarification:** The server does NOT make a secondary request to the CDN — the external fetch happens client-side in the browser. The risk is camouflage reliability, not server-side traffic correlation.

**Fix:** Hardcode the Confluence SVG logo as an inline data URI directly in the template (preferred — zero external dependencies at both deploy and runtime):

```html
<img src="data:image/svg+xml;base64,..." alt="Confluence">
```

Do NOT use a build-time `curl | base64 -w0` step — the `-w0` flag is GNU-specific and not portable to macOS/BSD. Vendor the data URI as a static string in the template.

**Verification:** Open camouflage page in browser with network tab — zero external requests.

### H5. Multiple shortIds across all templates

**Files:** `templates_for_script/panel-xray`, `node-xray`, `xray`
**Scripts:** `vps-setup.sh`, `setup-panel.sh`, `setup-node.sh`
**Severity:** MEDIUM

**Problem:** Single shortId per inbound. A single value creates a static fingerprint for the installation. Multiple shortIds of varying lengths increase entropy.

**Technical basis:** XRay validates each shortId independently (`infra/conf/transport_internet.go`). Valid lengths: 0-16 hex chars, must be even. Different lengths in one array are fully supported.

**Fix:** Generate 4 shortIds of different lengths in setup scripts:

```bash
SID1=$(openssl rand -hex 2)   # 4 chars
SID2=$(openssl rand -hex 4)   # 8 chars
SID3=$(openssl rand -hex 6)   # 12 chars
SID4=$(openssl rand -hex 8)   # 16 chars
export SHORT_IDS="\"$SID1\",\"$SID2\",\"$SID3\",\"$SID4\""
```

Server templates change to:
```json
"shortIds": [$SHORT_IDS]
```

**Rollout requirements** (critical — all must ship atomically):
- `setup-panel.sh` must output the full shortId list AND a recommended single value for the node outbound
- `setup-node.sh` must relax `PANEL_SHORT_ID` validation from "exactly 16 hex" to "any valid even-length hex, 2-16 chars"
- Client outbound configs (`xray_outbound`, `sing_box_outbound`) use a single selected shortId from the list
- `vps-setup.sh` standalone path must also generate and output the shortId list

**Verification:** Test connection with each shortId — all must work. Test with random shortId — must fail.

### H6. Remove publicKey from standalone xray inbound

**File:** `templates_for_script/xray`
**Line:** 31
**Severity:** LOW (downgraded from MEDIUM after review)

**Problem:** `"publicKey": "$XRAY_PBK"` in `realitySettings` of the inbound config. The inbound only needs `privateKey` to function. XRay ignores publicKey on inbound when `dest` is set.

**Rationale:** This is dead-config cleanup, not a major security fix. The publicKey is not secret (it's distributed to all clients), but keeping unused fields in server configs adds noise and reduces config clarity.

**Fix:** Remove the `publicKey` line from the inbound `realitySettings`:

```json
"realitySettings": {
    "xver": 1,
    "dest": "127.0.0.1:4123",
    "serverNames": ["$VLESS_DOMAIN"],
    "privateKey": "$XRAY_PIK",
    "shortIds": ["$SHORT_ID"]
}
```

**Note:** publicKey is still output to the user for client config — it just doesn't belong in the server-side inbound config.

**Verification:** Restart XRay, confirm connection works without publicKey in inbound.

### H7. XHTTP extra headers on chain outbound (OPTIONAL)

**File:** `templates_for_script/node-xray`
**Lines:** 62-67 (xhttpSettings block)
**Severity:** LOW
**Status:** Optional — implement only after H1-H6, validate with packet capture before merging

**Problem:** XHTTP transport between VPS2->VPS1 has no extra HTTP headers. Adding headers could make the XHTTP stream less distinguishable from legitimate web traffic.

**Caveats identified in review:**
1. XRay's XHTTP server does NOT enforce or validate arbitrary request headers — `extra.headers` on inbound is effectively a no-op for matching purposes
2. XRay injects its own default fetch-profile headers; adding browser-navigation headers (like `Accept: text/html...`) creates a **mixed fingerprint** that may be MORE distinctive, not less
3. A hardcoded Chrome 131 UA string is stale for 2026

**Fix (simplified, outbound-only):** If implemented, apply ONLY to the chain-vps1 outbound on VPS2. Do NOT add `extra.headers` to inbound configs.

```json
"xhttpSettings": {
    "host": "$PANEL_DOMAIN",
    "path": "/$XHTTP_PATH",
    "mode": "stream-one"
}
```

Adding `host` as a top-level field is safe and ensures the Host header matches the target domain. For custom User-Agent, prefer XRay's built-in synthesis — no hardcoded UA strings.

**Important:** `$PANEL_DOMAIN` and VPS1's `$VLESS_DOMAIN` must resolve to the same server. If they differ, connections will fail.

**Decision gate:** Do not merge H7 until:
- Packet capture confirms stable request framing
- Cross-version testing shows no regression
- The fingerprint is verified to be coherent (not mixed)

**Verification:** tcpdump/wireshark between VPS2->VPS1, verify connection stability and header profile.

## Implementation Phases

### Phase 1: Correct spec scope (this document)
Already done. All installer paths and client artifacts now in scope.

### Phase 2: Urgent REALITY fixes (H1 + H6)
Ship atomically — server template and all client artifacts must agree.
- Generate `SHORT_ID` in `vps-setup.sh`
- Fix `xray`, `xray_outbound`, `sing_box_outbound` templates
- Fix clipboard URI output
- Remove `publicKey` from `xray` inbound

### Phase 3: Reduce passive disclosure (H2 + H3 + H4)
Low-risk template changes, can ship independently.
- `server_tokens off` in all 4 Angie templates
- `access_log off` in all 4 Angie templates
- Embed logo in `confluence` template

### Phase 4: Multi-shortId rollout (H5)
Coordinated script + template + validation change. Ship after Phase 2.
- Generate multiple shortIds in all setup scripts
- Update all server templates
- Relax validation in `setup-node.sh`
- Update operator output in `setup-panel.sh`

### Phase 5: XHTTP headers (H7) — OPTIONAL
Go/no-go decision after Phase 2-4 are stable.
- Outbound-only, minimal changes
- Packet capture validation required

## Risk Assessment

| Change | Risk | Breakage scenario | Rollback |
|--------|------|-------------------|----------|
| H1 | Medium if partial | Server rejects empty shortId but client still sends empty -> connection fails | Revert shortId line; must update server AND clients atomically |
| H2 | None | — | Remove `server_tokens off` |
| H3 | Low | Lose HTTP request visibility for troubleshooting | Re-enable access_log |
| H4 | None | Larger HTML file (~5-10KB) | Revert to external URL |
| H5 | Medium-High if partial | Scripts/templates/validation desync -> operator confusion or connection failure | Revert to single shortId; must revert scripts AND templates atomically |
| H6 | None | — | Re-add publicKey line |
| H7 | High | Mixed fingerprint more distinctive; stale UA; transport breakage | Remove `extra`/`host` additions |

## Review Record

### Review 1: Claude CLI via PAL (2026-03-28)

| Concern | Verdict | Reason |
|---------|---------|--------|
| H1 "already fixed in code" | **Rejected** | File confirmed: line 33 is `""` (empty string) |
| H5 "shortIds must be uniform length" | **Rejected** | XRay source: each shortId validated independently |
| H6 "publicKey already absent" | **Rejected** | File confirmed: line 31 contains `"publicKey": "$XRAY_PBK"` |
| H7 "`extra` field doesn't exist" | **Rejected** | Added in PR #4000 (Nov 2024) |
| H7 "Host can't be in headers" | **Accepted** | XRay rejects Host inside headers map |

### Review 2: Codex GPT-5 via PAL (2026-03-28)

| Finding | Severity | Action taken |
|---------|----------|-------------|
| H1 scope incomplete: `xray_outbound`, `sing_box_outbound`, `vps-setup.sh` also have empty shortIds | HIGH | **Accepted** — H1 scope expanded to all client artifacts |
| H2/H3 should cover legacy templates `angie`, `angie-marzban` | HIGH | **Accepted** — added to file lists |
| H4 rationale #2 incorrect: server doesn't fetch CDN, client does | MEDIUM | **Accepted** — rationale corrected |
| H5 rollout incomplete: `setup-node.sh` validates 16 hex, `setup-panel.sh` outputs single value | HIGH | **Accepted** — rollout requirements added |
| H6 "information leak" overstated: publicKey is not secret | MEDIUM | **Accepted** — severity downgraded, rationale corrected |
| H7 inbound `extra.headers` don't enforce matching | HIGH | **Accepted** — H7 simplified to outbound-only, made optional |
| H7 Chrome 131 UA stale, `Accept` conflicts with fetch profile | HIGH | **Accepted** — removed hardcoded headers, prefer XRay built-in synthesis |
| H7 `$PANEL_DOMAIN` vs `$VLESS_DOMAIN` mismatch risk | HIGH | **Accepted** — explicit note added |
| H3 verification: existing log file may remain | MEDIUM | **Accepted** — verification text corrected |
| Legacy `vps-setup.sh` paths remain un-hardened | MEDIUM | **Accepted** — all installer paths now in scope |

### Additional suggestions evaluated

| Suggestion | Decision | Reason |
|------------|----------|--------|
| `ssl_early_data off` | Not needed | REALITY doesn't use standard TLS 0-RTT |
| Rate limiting on Marzban panel | Out of scope | Path already randomized |
| Restrict admin by IP/WG instead of path | Good idea, out of scope | Requires architectural change |
| Lower `error_log` from `notice` to `error` | Optional | Acceptable if debugging cost is low |
| Audit Marzban/wg-easy/Docker container logs | Out of scope | Different log surfaces |

### Verification sources

- **shortIds**: XRay source `infra/conf/transport_internet.go`, REALITY.ENG.md examples
- **XHTTP extra**: PR [XTLS/Xray-core#4000](https://github.com/XTLS/Xray-core/pull/4000), `SplitHTTPConfig` struct
- **Host header restriction**: XRay source `strings.ToLower(k) == "host"` -> error
- **Inbound header non-enforcement**: XRay `transport/internet/splithttp/hub.go` validates host and path only

## Out of Scope

- Adding new inbounds (Hysteria2, CDN fallback)
- Relay through Russian VPS
- Port rotation or alternative ports
- TLS fragmentation (client-side only)
- Monitoring/alerting for IP blocklists
- Marzban/wg-easy/Docker container log hardening
- Admin path access control beyond randomization
