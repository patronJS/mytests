# Synology-USA-tunnel OpenVPN Chain Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Devices in the Mikrotik `vpn-clients` list exit to the internet from a USA OpenVPN server, with the OpenVPN connection carried inside VLESS+Reality and a kill switch that never lets `wg0` traffic leave via `eth0`.

**Architecture:** Three containers share wg-easy's network namespace. sing-box becomes a plain local SOCKS (`127.0.0.1:1080`) → VLESS relay. A new locally built `openvpn` container runs `setup-routing.sh` (kill switch, forwarding, NAT), validates and rewrites the user's `.ovpn` so OpenVPN reaches its server only through the SOCKS proxy and installs no routes, then a `route-up.sh` hook points policy table 100 (traffic from `wg0`) at `tun0` after every connect.

**Tech Stack:** Docker Compose, Alpine 3.20 (`openvpn`, `iptables`, `iptables-legacy`), POSIX sh + busybox awk, sing-box v1.13.6, wg-easy 15.2.2, shellcheck, jq (host-side checks only).

**Spec:** `docs/superpowers/specs/2026-09-30-synology-usa-tunnel-openvpn-design.md`

## Global Constraints

- Target platform: Synology DSM + Docker with Alpine-based images. The repo's Ubuntu 24.04 rule applies only to the VPS installers, not to this subproject.
- Scope: only `Synology-USA-tunnel/` and the root `.gitignore`. Do not touch `synology-split-tunnel/`, the VPS installers, or the VLESS server.
- Images: `ghcr.io/wg-easy/wg-easy:15.2.2`, `ghcr.io/sagernet/sing-box:v1.13.6`, openvpn image built from `alpine:3.20` with exactly `openvpn iptables iptables-legacy`. No other packages or dependencies.
- wg-easy keeps ports `51820/udp`, `51821/tcp`, container name `wg-easy`, `net.ipv4.ip_forward=0` at start and the `ip6tables` stub. Container names: `wg-easy`, `sing-box`, `openvpn`. Restart policy `unless-stopped` for all.
- All three services use `network_mode: "service:wg-easy"`. sing-box: no TUN, no `privileged`, no `/dev/net/tun`. openvpn: `privileged: true` and `/dev/net/tun`.
- sing-box SOCKS inbound listens on `127.0.0.1:1080` only.
- Traffic from `wg0` never leaves via `eth0`: kill switch = `unreachable default metric 4000 table 100` + `ip rule iif wg0 table 100 priority 100`, installed before forwarding is enabled.
- OpenVPN never changes the main routing table: `route-nopull` + `route-noexec`; the only route it contributes is `default dev $dev table 100` from `route-up.sh`.
- Shell scripts are POSIX `sh` (busybox in the image), shellcheck-clean with no unexplained disables.
- Secrets (`openvpn/*`, real `sing-box/config.json` values, anything from `16_worked_proxy_chain`) are never committed. The end-to-end secrets live only in a scratch directory outside the repository.
- Language: code, comments, commit messages in English. `README.md` stays in Russian, like the existing subproject READMEs.
- Git: work on `feat/synology-usa-tunnel` (current branch). Stage only the files named in each task. Pre-existing uncommitted changes (`synology-split-tunnel/*`, the `Synology-USA-tunnel/old-tunnel/` deletion, `OpenWrt/worked-setup.json`) are the user's work: never stage, revert or stash them. Commit messages: short conventional subject, no attribution trailers.
- Tests need a running Docker daemon that allows `--privileged` (Docker Desktop on the Mac is fine). Run them from the repo root as `sh Synology-USA-tunnel/tests/<name>.sh`.

## Review Focus

1. **Windows line endings and no final newline** (common in provider downloads): the profile is accepted, `/tmp/run.ovpn` has no `\r`, and the appended directives start on their own lines. Test: Task 1, case "CRLF profile without final newline".
2. **Commented-out alternatives** (`;remote 1.2.3.4 1194 udp`, `# remote host`, `#proto udp`, as providers ship them): ignored, not rejected. Test: Task 1, case "commented-out directives are ignored".
3. **Directive spellings that dodge naive matching** (tab-indented `proto  udp`, `--remote host`, which OpenVPN accepts in files): validated like plain lines, so UDP or a hostname cannot slip through; an out-of-range octet (`300.1.1.1`) would be resolved as a hostname, so it is rejected too. Tests: Task 1, cases "indented proto udp", "--remote with hostname", "out-of-range IPv4 octet".
4. **Real-world `openvpn/` folder** (profile named `US East - Chicago.ovpn` next to `cred.txt`, `ca.crt`, `.DS_Store`): exactly one profile is found and accepted. Test: Task 1, case "profile name with spaces next to companion files".
5. **Container restart keeps `/tmp`** (`restart: unless-stopped` reuses the container filesystem): `/tmp/run.ovpn` is rebuilt, not appended to twice. Test: Task 1, case "second start in the same container rebuilds the profile".

## File Map

| File | Task | Responsibility |
|------|------|----------------|
| `Synology-USA-tunnel/openvpn-client/Dockerfile` | 1, 2 | openvpn image: alpine + openvpn + iptables, copies the two scripts |
| `Synology-USA-tunnel/openvpn-client/entrypoint.sh` | 1 | run `setup-routing.sh`, validate + rewrite the profile, `exec openvpn` |
| `Synology-USA-tunnel/tests/test-entrypoint.sh` | 1 | dry-run profile tests (no privileges) |
| `Synology-USA-tunnel/openvpn-client/route-up.sh` | 2 | OpenVPN hook: `default dev $dev table 100`, `rp_filter=0` |
| `Synology-USA-tunnel/scripts/setup-routing.sh` | 2 | kill switch, forwarding, iptables (now mandatory), LAN routes; no tun0 loop |
| `Synology-USA-tunnel/tests/test-routing.sh` | 2 | privileged routing tests with dummy `wg0`/`tun0` |
| `Synology-USA-tunnel/sing-box/config.json` | 3 | `mixed` inbound 127.0.0.1:1080 → VLESS (placeholders) |
| `Synology-USA-tunnel/docker-compose.yml` | 3 | wg-easy + sing-box + openvpn |
| `.gitignore`, `Synology-USA-tunnel/openvpn/.gitkeep` | 3 | keep user profiles out of git |
| `Synology-USA-tunnel/README.md` | 3 | setup, recovery, diagnostics (Russian) |
| `Synology-USA-tunnel/scripts/ip6tables-stub.sh` | — | unchanged |

---

### Task 1: OpenVPN profile preparation (image + entrypoint)

**Files:**
- Create: `Synology-USA-tunnel/openvpn-client/Dockerfile`
- Create: `Synology-USA-tunnel/openvpn-client/entrypoint.sh`
- Test: `Synology-USA-tunnel/tests/test-entrypoint.sh`

**Interfaces:**
- Consumes: `/setup-routing.sh` (bind-mounted at runtime; exit non-zero = fail). Not called when `OVPN_DRY_RUN=1`.
- Produces:
  - Docker image built from `openvpn-client/`, `ENTRYPOINT ["/entrypoint.sh"]`, tests tag it `usa-tunnel-openvpn:test`.
  - `/entrypoint.sh`: reads exactly one `/openvpn/*.ovpn` (+ optional `/openvpn/cred.txt`), writes `/tmp/run.ovpn`, runs `cd /openvpn && exec openvpn --config /tmp/run.ovpn`. Errors print `[openvpn] ERROR: <reason>` on stdout and exit 1. `OVPN_DRY_RUN=1`: skips `/setup-routing.sh`, prints `/tmp/run.ovpn` to stdout, exits 0.
  - `/tmp/run.ovpn` ends with: `dev tun0`, `dev-type tun`, `socks-proxy 127.0.0.1 1080`, `route-nopull`, `route-noexec`, `script-security 2`, `route-up /route-up.sh`, and `auth-user-pass /openvpn/cred.txt` only when the profile had `auth-user-pass`. `/route-up.sh` itself arrives in Task 2.

- [ ] **Step 1: Scaffold the image with a stub entrypoint**

Create `Synology-USA-tunnel/openvpn-client/Dockerfile`:

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache openvpn iptables iptables-legacy
COPY entrypoint.sh /
RUN chmod +x /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
```

Create `Synology-USA-tunnel/openvpn-client/entrypoint.sh` (stub, replaced in Step 4):

```sh
#!/bin/sh
echo "not implemented"
exit 1
```

- [ ] **Step 2: Write the failing test**

Create `Synology-USA-tunnel/tests/test-entrypoint.sh`:

```sh
#!/bin/sh
# Profile tests: run openvpn-client/entrypoint.sh with OVPN_DRY_RUN=1 against
# sample profiles. Needs Docker, no privileges, no secrets.
# Usage: sh tests/test-entrypoint.sh
cd "$(dirname "$0")/.." || exit 1
IMAGE=usa-tunnel-openvpn:test
docker build -q -t "$IMAGE" openvpn-client >/dev/null || exit 1

WORK=$(mktemp -d)
trap 'rm -r "$WORK"' EXIT

# A valid flat profile: TCP, IP remote, inline CA, auth-user-pass, and every
# directive the entrypoint must strip. base PROTO_LINE REMOTE_LINES builds
# variants around the same top and bottom.
TOP='client
dev tun'
BOTTOM='nobind
persist-tun
up /etc/openvpn/up.sh
down /etc/openvpn/down.sh
script-security 2
redirect-gateway def1
auth-user-pass
<ca>
-----BEGIN CERTIFICATE-----
MIIBtestonly
-----END CERTIFICATE-----
</ca>'
base() { printf '%s\n%s\n%s\n%s\n' "$TOP" "$1" "$2" "$BOTTOM"; }
BASE=$(base "proto tcp" "remote 203.0.113.10 443")

failures=0
# new_dir: create an empty /openvpn stand-in and print its path.
new_dir() { mktemp -d "$WORK/case.XXXXXX" || exit 1; }
# run DIR: run the entrypoint in dry-run mode on DIR; sets $out and $rc.
run() {
    out=$(docker run --rm -e OVPN_DRY_RUN=1 -v "$1:/openvpn:ro" "$IMAGE" 2>&1)
    rc=$?
}
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1: $2"; echo "$out" | sed 's/^/  /'; failures=$((failures + 1)); }
has() { printf '%s\n' "$out" | grep -qx -- "$1"; }
count() { printf '%s\n' "$out" | grep -cx -- "$1"; }
# accepts NAME DIR: the profile is accepted.
accepts() { run "$2"; if [ "$rc" -eq 0 ]; then pass "$1"; else fail "$1" "expected exit 0, got $rc"; fi; }
# rejects NAME DIR MESSAGE: exit 1 with an ERROR line containing MESSAGE.
rejects() {
    run "$2"
    if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep "ERROR" | grep -qF -- "$3"; then
        pass "$1"
    else
        fail "$1" "expected rejection with '$3', got exit $rc"
    fi
}
# profile DIR TEXT [NAME]: write a profile file into DIR.
profile() { printf '%s\n' "$2" > "$1/${3:-client.ovpn}"; }

# --- accepted profile is rewritten --------------------------------------------
d=$(new_dir); profile "$d" "$BASE"; printf 'user\npass\n' > "$d/cred.txt"
run "$d"
if [ "$rc" -ne 0 ]; then fail "rewrite" "exit $rc"
elif ! has "dev tun0" || ! has "dev-type tun" || has "dev tun"; then fail "rewrite" "dev tun -> dev tun0"
elif has "up /etc/openvpn/up.sh" || has "down /etc/openvpn/down.sh" || has "redirect-gateway def1"; then fail "rewrite" "up/down/redirect-gateway not stripped"
elif [ "$(count "script-security 2")" != 1 ] || [ "$(count "script-security.*")" != 1 ]; then fail "rewrite" "script-security not replaced"
elif ! has "socks-proxy 127.0.0.1 1080" || ! has "route-nopull" || ! has "route-noexec" || ! has "route-up /route-up.sh"; then fail "rewrite" "chain directives not appended"
elif ! has "auth-user-pass /openvpn/cred.txt" || has "auth-user-pass"; then fail "rewrite" "auth-user-pass not rewritten"
elif ! has "remote 203.0.113.10 443" || ! has "MIIBtestonly" || ! has "</ca>"; then fail "rewrite" "kept lines lost"
else pass "rewrite: dev, hooks, redirect-gateway, auth-user-pass, chain directives"
fi

d=$(new_dir); profile "$d" "$(printf '%s\n' "$BASE" | grep -v '^auth-user-pass')"
run "$d"
if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -q '^auth-user-pass'; then pass "no auth-user-pass: no cred.txt needed"
else fail "no auth-user-pass: no cred.txt needed" "exit $rc"; fi

d=$(new_dir); profile "$d" "$(base 'proto tcp4-client' 'remote 203.0.113.10 443 tcp-client
remote 203.0.113.11')"; : > "$d/cred.txt"
accepts "proto tcp4-client, tcp-client suffix and bare remote" "$d"

# --- rejected profiles ---------------------------------------------------------
d=$(new_dir); profile "$d" "$(base 'proto udp' 'remote 203.0.113.10 443')"; : > "$d/cred.txt"
rejects "proto udp" "$d" "proto must be tcp"

d=$(new_dir); profile "$d" "$(base 'proto tcp-client' 'remote 203.0.113.10 1194 udp')"; : > "$d/cred.txt"
rejects "proto tcp-client with udp remote" "$d" "remote must use TCP"

d=$(new_dir); profile "$d" "$(base 'proto tcp' 'remote 203.0.113.10 443 tcp
remote 203.0.113.11 1194 udp')"; : > "$d/cred.txt"
rejects "mixed TCP/UDP remotes" "$d" "remote must use TCP"

d=$(new_dir); profile "$d" "$(base 'proto tcp' 'remote vpn.example.com 443')"; : > "$d/cred.txt"
rejects "hostname remote" "$d" "numeric IPv4"

d=$(new_dir); profile "$d" "$(base 'proto tcp' '')"; : > "$d/cred.txt"
rejects "no remote" "$d" "no remote line"

d=$(new_dir); profile "$d" "$(base 'proto tcp' '')
<connection>
remote 203.0.113.10 443 tcp
</connection>"; : > "$d/cred.txt"
rejects "<connection> block" "$d" "<connection> blocks are not supported"

d=$(new_dir); profile "$d" "$BASE
config extra.conf"; : > "$d/cred.txt"
rejects "config include" "$d" "config includes are not supported"

d=$(new_dir); profile "$d" "$BASE"
rejects "auth-user-pass without cred.txt" "$d" "cred.txt is missing"

d=$(new_dir)
rejects "no profile" "$d" "no .ovpn profile"

d=$(new_dir); profile "$d" "$BASE" a.ovpn; profile "$d" "$BASE" b.ovpn; : > "$d/cred.txt"
rejects "two profiles" "$d" "found 2"

# --- review focus ------------------------------------------------------------
d=$(new_dir); printf '%s\n' "$BASE" | awk 'NR > 1 { printf "\r\n" } { printf "%s", $0 }' > "$d/client.ovpn"; : > "$d/cred.txt"
run "$d"
if [ "$rc" -eq 0 ] && has "</ca>" && has "dev tun0" && ! printf '%s' "$out" | grep -q "$(printf '\r')"; then pass "CRLF profile without final newline"
else fail "CRLF profile without final newline" "exit $rc or broken lines"; fi

d=$(new_dir); profile "$d" "$BASE
# remote vpn.example.com 443
;remote 203.0.113.12 1194 udp
#proto udp"; : > "$d/cred.txt"
accepts "commented-out directives are ignored" "$d"

d=$(new_dir); profile "$d" "$BASE
--remote vpn.example.com 443"; : > "$d/cred.txt"
rejects "--remote with hostname" "$d" "numeric IPv4"

d=$(new_dir); profile "$d" "$(base '	proto  udp' 'remote 203.0.113.10 443')"; : > "$d/cred.txt"
rejects "indented proto udp" "$d" "proto must be tcp"

d=$(new_dir); profile "$d" "$(base 'proto tcp' 'remote 300.1.1.1 443')"; : > "$d/cred.txt"
rejects "out-of-range IPv4 octet" "$d" "numeric IPv4"

d=$(new_dir); profile "$d" "$BASE" "US East - Chicago.ovpn"; : > "$d/cred.txt"; : > "$d/ca.crt"; : > "$d/.DS_Store"
accepts "profile name with spaces next to companion files" "$d"

d=$(new_dir); profile "$d" "$BASE"; : > "$d/cred.txt"
out=$(docker run --rm -e OVPN_DRY_RUN=1 -v "$d:/openvpn:ro" --entrypoint /bin/sh "$IMAGE" -c '/entrypoint.sh >/dev/null 2>&1; /entrypoint.sh 2>&1')
rc=$?
if [ "$rc" -eq 0 ] && [ "$(count "dev tun0")" = 1 ] && [ "$(count "socks-proxy 127.0.0.1 1080")" = 1 ]; then pass "second start in the same container rebuilds the profile"
else fail "second start in the same container rebuilds the profile" "exit $rc or duplicated lines"; fi

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
echo "all entrypoint cases passed"
```

Run: `chmod +x Synology-USA-tunnel/tests/test-entrypoint.sh Synology-USA-tunnel/openvpn-client/entrypoint.sh`

- [ ] **Step 3: Run the test to verify it fails**

Run: `sh Synology-USA-tunnel/tests/test-entrypoint.sh`
Expected: every case prints `FAIL` (the stub exits 1 without an `ERROR` line), last line `20 case(s) failed`, exit code 1.

- [ ] **Step 4: Implement the entrypoint**

Replace `Synology-USA-tunnel/openvpn-client/entrypoint.sh` with:

```sh
#!/bin/sh
# Validate the single profile in /openvpn, build /tmp/run.ovpn that reaches
# the server only through sing-box's SOCKS inbound and installs no routes
# (route-up.sh sets table 100), then run OpenVPN.
# OVPN_DRY_RUN=1 (tests): skip setup-routing.sh, print /tmp/run.ovpn, exit 0.

die() { echo "[openvpn] ERROR: $*"; exit 1; }

[ "${OVPN_DRY_RUN:-}" = 1 ] || /setup-routing.sh || exit 1

set -- /openvpn/*.ovpn
[ -e "$1" ] || die "no .ovpn profile in /openvpn"
[ $# -eq 1 ] || die "expected one .ovpn profile in /openvpn, found $#"
echo "[openvpn] profile: $1" >&2

# One pass over the profile (CRs stripped): reject what cannot be proven to go
# through the SOCKS proxy, copy the kept lines to /tmp/run.ovpn and print
# "auth" if the profile uses auth-user-pass. On rejection print the reason.
result=$(tr -d '\r' < "$1" | awk -v out=/tmp/run.ovpn '
function fail(msg) { print msg; failed = 1; exit 1 }
function ipv4(h,  o, i) {
    if (h !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
    split(h, o, ".")
    for (i = 1; i <= 4; i++) if (o[i] + 0 > 255) return 0
    return 1
}
BEGIN {
    n = split("dev dev-type up down script-security route-up redirect-gateway socks-proxy http-proxy auth-user-pass", d, " ")
    for (i = 1; i <= n; i++) drop[d[i]] = 1
}
inline { print > out; if ($1 ~ /^<\//) inline = 0; next }   # inline <tag> block: copy verbatim
{ sub(/^--/, "", $1) }                                     # OpenVPN accepts "--remote" in files too
$1 ~ /^<connection>/ { fail("<connection> blocks are not supported") }
$1 ~ /^<[^\/]/ { inline = 1; print > out; next }
$1 == "config" { fail("config includes are not supported") }
$1 == "proto" { proto = $2 }
$1 == "auth-user-pass" { auth = 1 }
$1 == "remote" {
    remotes++
    if (!ipv4($2)) fail("remote must be a numeric IPv4 address (a hostname would be resolved outside VLESS): " $0)
    if (NF >= 4 && $4 !~ /^tcp/) fail("remote must use TCP (socks-proxy is TCP-only): " $0)
    if (NF < 4) bare = 1
}
!($1 in drop) { print > out }
END {
    if (failed) exit 1
    if (!remotes) fail("no remote line")
    if (bare && proto !~ /^tcp/) fail("proto must be tcp (socks-proxy is TCP-only), got: " (proto == "" ? "none" : proto))
    if (auth) print "auth"
}') || die "$result"

if [ "$result" = auth ] && [ ! -f /openvpn/cred.txt ]; then
    die "profile uses auth-user-pass but /openvpn/cred.txt is missing"
fi

{
    echo "dev tun0"
    echo "dev-type tun"
    echo "socks-proxy 127.0.0.1 1080"
    echo "route-nopull"
    echo "route-noexec"
    echo "script-security 2"
    echo "route-up /route-up.sh"
    if [ "$result" = auth ]; then echo "auth-user-pass /openvpn/cred.txt"; fi
} >> /tmp/run.ovpn

if [ "${OVPN_DRY_RUN:-}" = 1 ]; then
    cat /tmp/run.ovpn
    exit 0
fi

# Relative ca/cert/key/tls-auth paths resolve next to the profile.
cd /openvpn || exit 1
exec openvpn --config /tmp/run.ovpn
```

Notes for the implementer:
- The awk program runs once per line after `tr -d '\r'`. Inside an inline `<tag>…</tag>` block every line is copied verbatim and never parsed as a directive. Comment lines (`#…`, `;…`) match no rule and are copied as-is.
- `print > out` truncates `/tmp/run.ovpn` on the first write of each run, so a container restart rebuilds the file.
- In awk, `exit` inside a rule still runs `END`; the `failed` flag stops `END` from overriding the first error.

- [ ] **Step 5: Run the test to verify it passes**

Run: `sh Synology-USA-tunnel/tests/test-entrypoint.sh`
Expected: 20 lines starting with `PASS`, last line `all entrypoint cases passed`, exit code 0.

- [ ] **Step 6: Lint**

Run: `shellcheck Synology-USA-tunnel/openvpn-client/entrypoint.sh Synology-USA-tunnel/tests/test-entrypoint.sh`
Expected: no output, exit code 0.

- [ ] **Step 7: Commit**

```bash
git add Synology-USA-tunnel/openvpn-client/Dockerfile Synology-USA-tunnel/openvpn-client/entrypoint.sh Synology-USA-tunnel/tests/test-entrypoint.sh
git commit -m "feat(usa-tunnel): add OpenVPN client image with profile validation"
```

---

### Task 2: Routing — route-up hook and mandatory NAT

**Files:**
- Create: `Synology-USA-tunnel/openvpn-client/route-up.sh`
- Modify: `Synology-USA-tunnel/openvpn-client/Dockerfile` (copy `route-up.sh`)
- Modify: `Synology-USA-tunnel/scripts/setup-routing.sh` (whole file replaced below)
- Test: `Synology-USA-tunnel/tests/test-routing.sh`

**Interfaces:**
- Consumes: image from Task 1 (`openvpn-client/`, tag `usa-tunnel-openvpn:test` in tests); `/tmp/run.ovpn` already contains `script-security 2` and `route-up /route-up.sh`.
- Produces:
  - `/route-up.sh` in the image: reads `$dev` (set by OpenVPN; exits non-zero with a message if unset), sets `net.ipv4.conf.$dev.rp_filter=0`, runs `ip route replace default dev "$dev" table 100`, prints `[route-up] table 100: default dev <dev>`.
  - `scripts/setup-routing.sh` (bind-mounted at `/setup-routing.sh`): exit 0 = kill switch, forwarding, `wg0` rp_filter, iptables rules and LAN routes all in place; exit 1 on a kill-switch failure (sets `ip_forward=0`), missing iptables (`[routing] ERROR: iptables not found`) or a failed rule (`[routing] ERROR: cannot add iptables rules`). Waits for `wg0` to exist. No background processes.

- [ ] **Step 1: Write the failing test**

Create `Synology-USA-tunnel/tests/test-routing.sh`:

```sh
#!/bin/sh
# shellcheck disable=SC2016  # case scripts are single-quoted on purpose: they expand in the container
# Routing tests: run scripts/setup-routing.sh and openvpn-client/route-up.sh in
# the openvpn image with dummy wg0/tun0 and the compose sysctl ip_forward=0.
# Needs Docker with privileged containers. No secrets.
# Usage: sh tests/test-routing.sh
cd "$(dirname "$0")/.." || exit 1
IMAGE=usa-tunnel-openvpn:test
docker build -q -t "$IMAGE" openvpn-client >/dev/null || exit 1

# Helpers available inside every case.
PRELUDE='
check() { if eval "$1"; then :; else echo "  FAILED: $1"; cat /tmp/setup.log 2>/dev/null; ip rule show; ip route show table 100; exit 1; fi; }
dummy() { ip link add "$1" type dummy && ip link set "$1" up; }
route() { ip route get "$1" from 10.8.0.2 iif wg0 2>&1; }
fwd() { cat /proc/sys/net/ipv4/ip_forward; }
blocked() { [ "$(fwd)" = 1 ] && route 1.1.1.1 | grep -q unreachable; }
via() { route "$1" | grep -q "dev $2 "; }
setup() { timeout 30 /setup-routing.sh > /tmp/setup.log 2>&1; }
# fake NAME PATTERN REAL: NAME fails when its arguments contain PATTERN, else runs REAL.
fake() {
    mkdir -p /usr/local/sbin
    printf "#!/bin/sh\ncase \"\$*\" in *\"%s\"*) exit 1;; esac\nexec %s \"\$@\"\n" "$2" "$3" > "/usr/local/sbin/$1"
    chmod +x "/usr/local/sbin/$1"
}
up() { dev=tun0 /route-up.sh; }
'

failures=0
# run_case NAME SCRIPT: run SCRIPT in a fresh container; it passes if SCRIPT exits 0.
run_case() {
    if out=$(docker run --rm --privileged --sysctl net.ipv4.ip_forward=0 \
        -v "$PWD/scripts/setup-routing.sh:/setup-routing.sh:ro" \
        --entrypoint /bin/sh "$IMAGE" -c "$PRELUDE
$2" 2>&1); then
        echo "PASS $1"
    else
        echo "FAIL $1"
        echo "$out" | sed 's/^/  /'
        failures=$((failures + 1))
    fi
}

run_case "first start: wg0 exists, no tun0 -> blocked, forwarding on" '
dummy wg0
check setup
check blocked
check "via 192.168.88.10 wg0"
'

run_case "steady state: tun0 up -> internet via tun0, LAN via wg0" '
dummy wg0; setup; dummy tun0; up
check "via 1.1.1.1 tun0"
check "via 192.168.88.10 wg0"
check "via 10.1.2.3 wg0"
check "via 172.16.5.5 wg0"
'

run_case "tun0 gone -> blocked" '
dummy wg0; setup; dummy tun0; up
ip link del tun0
check blocked
'

run_case "route-up.sh restores the route after tun0 is recreated" '
dummy wg0; setup; dummy tun0; up
ip link del tun0; dummy tun0
check blocked
check up
check "via 1.1.1.1 tun0"
'

run_case "rerun: never via eth0, single rule/route/iptables rules" '
dummy wg0; setup; dummy tun0; up
( i=0; while [ $i -lt 300 ]; do route 1.1.1.1; i=$((i + 1)); done > /tmp/samples ) &
sampler=$!
check setup
wait $sampler
check "[ \$(grep -c . /tmp/samples) -gt 0 ]"
check "! grep -q \"dev eth0\" /tmp/samples"
check blocked
check "[ \$(ip rule show | grep -c \"iif wg0 lookup 100\") = 1 ]"
check "[ \$(ip route show table 100 | grep -c \"^unreachable default\") = 1 ]"
check "[ \$(iptables-legacy -t nat -S POSTROUTING | grep -c MASQUERADE) = 1 ]"
check "[ \$(iptables-legacy -S FORWARD | grep -c -- \"-A FORWARD\") = 2 ]"
'

run_case "kill switch cannot be installed -> exit 1, forwarding off" '
sysctl -w net.ipv4.ip_forward=1 >/dev/null
fake ip unreachable /sbin/ip
check "! setup"
check "grep -q ERROR /tmp/setup.log"
check "[ \$(fwd) = 0 ]"
'

run_case "iptables missing -> exit 1" '
dummy wg0
rm /sbin/iptables /sbin/iptables-legacy /sbin/iptables-nft
check "! setup"
check "grep -q \"ERROR: iptables not found\" /tmp/setup.log"
check blocked
'

run_case "MASQUERADE cannot be added -> exit 1, no success line" '
dummy wg0
fake iptables-legacy "-A POSTROUTING" /sbin/iptables-legacy
check "! setup"
check "grep -q \"ERROR: cannot add iptables rules\" /tmp/setup.log"
check "! grep -q \"iptables rules applied\" /tmp/setup.log"
check blocked
'

run_case "wg0 created with rp_filter=1 -> 0 after setup" '
sysctl -w net.ipv4.conf.default.rp_filter=1 >/dev/null
dummy wg0
check "[ \$(cat /proc/sys/net/ipv4/conf/wg0/rp_filter) = 1 ]"
check setup
check "[ \$(cat /proc/sys/net/ipv4/conf/wg0/rp_filter) = 0 ]"
'

run_case "route-up.sh sets rp_filter=0 on tun0" '
dummy wg0; setup
sysctl -w net.ipv4.conf.default.rp_filter=1 >/dev/null
dummy tun0
check up
check "[ \$(cat /proc/sys/net/ipv4/conf/tun0/rp_filter) = 0 ]"
'

[ "$failures" -eq 0 ] || { echo "$failures case(s) failed"; exit 1; }
echo "all routing cases passed"
```

Run: `chmod +x Synology-USA-tunnel/tests/test-routing.sh`

- [ ] **Step 2: Run the test to verify it fails**

Run: `sh Synology-USA-tunnel/tests/test-routing.sh`
Expected: exit code 1, last line `6 case(s) failed`. Failing: `steady state…`, `route-up.sh restores the route…`, `route-up.sh sets rp_filter=0 on tun0` (no `/route-up.sh` in the image yet), `iptables missing -> exit 1` (old script falls back to `apk add` and exits 0), `MASQUERADE cannot be added…` (old script ignores rule failures), `wg0 created with rp_filter=1…` (old script sets it only in the tun0 background loop). The other four pass already: they pin behavior that must not regress.

- [ ] **Step 3: Add route-up.sh to the image**

Create `Synology-USA-tunnel/openvpn-client/route-up.sh`:

```sh
#!/bin/sh
# OpenVPN route-up hook, runs after every (re)connect. OpenVPN itself installs
# no routes (route-nopull, route-noexec); this sends table 100 (wg0 traffic)
# into the tunnel. OpenVPN passes the tunnel device name in $dev.
dev=${dev:?dev is not set by OpenVPN}
sysctl -w "net.ipv4.conf.$dev.rp_filter=0" >/dev/null
ip route replace default dev "$dev" table 100 || exit 1
echo "[route-up] table 100: default dev $dev"
```

Replace `Synology-USA-tunnel/openvpn-client/Dockerfile` with:

```dockerfile
FROM alpine:3.20
RUN apk add --no-cache openvpn iptables iptables-legacy
COPY entrypoint.sh route-up.sh /
RUN chmod +x /entrypoint.sh /route-up.sh
ENTRYPOINT ["/entrypoint.sh"]
```

Run: `chmod +x Synology-USA-tunnel/openvpn-client/route-up.sh`

- [ ] **Step 4: Update setup-routing.sh**

Replace `Synology-USA-tunnel/scripts/setup-routing.sh` with the content below. Changes against the current file: comment no longer mentions `apk add`/sing-box; `net.ipv4.conf.wg0.rp_filter=0` is set right after the other sysctls (wg0 exists by then); the iptables block no longer installs packages and exits 1 on a missing binary or a failed rule; the background tun0 loop is gone (moved to `route-up.sh`). Kill switch, stale tun0 cleanup, the wg0 wait, sysctls and LAN routes are unchanged.

```sh
#!/bin/sh

# Kill switch first, before waiting for wg0:
# while tun0 is absent (startup, OpenVPN down) wg0 traffic would fall through
# to the main table -> eth0. A high-metric unreachable default in table 100
# stays behind the tun0 default (metric 0) and blocks that leak. Both steps are
# idempotent (no flush/del), so a rerun never opens a gap; the iif rule matches
# by name, so wg0 does not have to exist yet. On failure, fail closed.
if ! ip route replace unreachable default metric 4000 table 100 || \
   ! { ip rule show | grep -q "iif wg0 lookup 100" || \
       ip rule add iif wg0 table 100 priority 100; }; then
    echo "[routing] ERROR: cannot install kill switch, disabling forwarding"
    sysctl -w net.ipv4.ip_forward=0
    exit 1
fi
echo "[routing] kill switch: wg0 traffic blocked unless tun0 is up"

# Clean up stale tun0 from a previous crash / restart
ip link set tun0 down 2>/dev/null || true
ip link delete tun0 2>/dev/null || true

echo "[routing] waiting for wg0..."
while ! ip link show wg0 >/dev/null 2>&1; do
    sleep 2
done
echo "[routing] wg0 is up"

# --- sysctls ---
set_sysctl() {
    if sysctl -w "$1=$2" 2>/dev/null; then
        echo "[routing] sysctl $1=$2 OK"
    else
        echo "[routing] WARNING: cannot set $1=$2"
    fi
}

set_sysctl net.ipv4.ip_forward 1
set_sysctl net.ipv4.conf.all.src_valid_mark 1
set_sysctl net.ipv4.conf.all.rp_filter 0
set_sysctl net.ipv4.conf.default.rp_filter 0

# wg0 exists now; changing all/default above does not reset its own value.
set_sysctl net.ipv4.conf.wg0.rp_filter 0

# --- iptables (legacy for Synology DSM) ---
# MASQUERADE is required: the OpenVPN server accepts only its client address.
if command -v iptables-legacy >/dev/null 2>&1; then
    IPT="iptables-legacy"
elif command -v iptables >/dev/null 2>&1; then
    IPT="iptables"
else
    echo "[routing] ERROR: iptables not found"
    exit 1
fi
echo "[routing] using $IPT"

# add_rule TABLE CHAIN ARGS...: append the rule unless it already exists.
add_rule() {
    table=$1
    shift
    "$IPT" -t "$table" -C "$@" 2>/dev/null || "$IPT" -t "$table" -A "$@"
}

if ! add_rule filter FORWARD -i wg0 -o tun0 -j ACCEPT ||
   ! add_rule filter FORWARD -i tun0 -o wg0 -j ACCEPT ||
   ! add_rule nat POSTROUTING -o tun0 -j MASQUERADE; then
    echo "[routing] ERROR: cannot add iptables rules"
    exit 1
fi
echo "[routing] iptables rules applied"

# --- policy routing (iif wg0 -> table 100 installed above) ---
# Table 100: LAN stays on wg0
ip route replace 192.168.0.0/16 dev wg0 table 100 2>/dev/null || true
ip route replace 10.0.0.0/8 dev wg0 table 100 2>/dev/null || true
ip route replace 172.16.0.0/12 dev wg0 table 100 2>/dev/null || true

echo "[routing] table 100: LAN via wg0, default via tun0 is set by route-up.sh"
echo "[routing] setup complete"
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `sh Synology-USA-tunnel/tests/test-routing.sh`
Expected: 10 lines starting with `PASS`, last line `all routing cases passed`, exit code 0.

Run: `sh Synology-USA-tunnel/tests/test-entrypoint.sh`
Expected: last line `all entrypoint cases passed` (the image changed, so re-check).

- [ ] **Step 6: Lint**

Run: `shellcheck Synology-USA-tunnel/openvpn-client/*.sh Synology-USA-tunnel/scripts/*.sh Synology-USA-tunnel/tests/*.sh`
Expected: no output, exit code 0.

- [ ] **Step 7: Commit**

```bash
git add Synology-USA-tunnel/openvpn-client/route-up.sh Synology-USA-tunnel/openvpn-client/Dockerfile Synology-USA-tunnel/scripts/setup-routing.sh Synology-USA-tunnel/tests/test-routing.sh
git commit -m "feat(usa-tunnel): route wg0 into tun0 via OpenVPN route-up hook"
```

---

### Task 3: Stack wiring — compose, sing-box SOCKS relay, gitignore, README

**Files:**
- Modify: `Synology-USA-tunnel/sing-box/config.json` (whole file replaced)
- Modify: `Synology-USA-tunnel/docker-compose.yml` (whole file replaced)
- Modify: `.gitignore` (append two lines)
- Create: `Synology-USA-tunnel/openvpn/.gitkeep` (empty)
- Modify: `Synology-USA-tunnel/README.md` (whole file replaced)

**Interfaces:**
- Consumes: `openvpn-client/` build context (Tasks 1–2), `scripts/setup-routing.sh` (Task 2), `scripts/ip6tables-stub.sh` (unchanged).
- Produces: compose services `wg-easy`, `sing-box`, `openvpn` (image tag `usa-tunnel-openvpn`); sing-box outbound tag `proxy`; bind mounts `./openvpn:/openvpn:ro`, `./scripts/setup-routing.sh:/setup-routing.sh:ro`, `./sing-box:/etc/sing-box:ro`. Task 4 overrides only `wg-easy` and the two secret-bearing mounts.

- [ ] **Step 1: Write the failing checks**

Run from the repo root:

```bash
cd Synology-USA-tunnel
jq -e '.inbounds == [{"type":"mixed","tag":"socks-in","listen":"127.0.0.1","listen_port":1080}] and .route == {"final":"proxy"} and .outbounds[0].tls.server_name == "<YOUR_SNI>"' sing-box/config.json
docker compose config --format json | jq -e '(.services["sing-box"] | .privileged != true and .devices == null and .entrypoint == null and .command == ["run","-c","/etc/sing-box/config.json"] and .network_mode == "service:wg-easy") and (.services.openvpn | .privileged == true and .network_mode == "service:wg-easy" and (.build.context | endswith("/openvpn-client")) and ([.volumes[].target] | sort) == ["/openvpn","/setup-routing.sh"] and ([.depends_on | keys[]] | sort) == ["sing-box","wg-easy"])'
cd ..
git check-ignore -v Synology-USA-tunnel/openvpn/client.ovpn Synology-USA-tunnel/openvpn/cred.txt
```

Expected: both `jq -e` print `false` (exit 1); `git check-ignore` prints nothing (exit 1).

- [ ] **Step 2: Replace the sing-box config**

Replace `Synology-USA-tunnel/sing-box/config.json` with:

```json
{
  "log": {
    "level": "warn",
    "timestamp": true
  },

  "inbounds": [
    {
      "type": "mixed",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": 1080
    }
  ],

  "outbounds": [
    {
      "type": "vless",
      "tag": "proxy",
      "server": "<YOUR_VPS_IP>",
      "server_port": 443,
      "uuid": "<YOUR_UUID>",
      "tls": {
        "enabled": true,
        "server_name": "<YOUR_SNI>",
        "reality": {
          "enabled": true,
          "public_key": "<YOUR_REALITY_PUBLIC_KEY>",
          "short_id": "<YOUR_SHORT_ID>"
        },
        "utls": {
          "enabled": true,
          "fingerprint": "firefox"
        }
      }
    }
  ],

  "route": {
    "final": "proxy"
  }
}
```

- [ ] **Step 3: Replace the compose file**

Replace `Synology-USA-tunnel/docker-compose.yml` with:

```yaml
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15.2.2
    container_name: wg-easy
    # wg-easy v15 ignores WG_* vars: host, port, DNS, allowed IPs and
    # keepalive live in the Web UI (Admin Panel), stored in ./wg-data.
    environment:
      - INSECURE=true
      - DISABLE_IPV6=true
    volumes:
      - ./wg-data:/etc/wireguard
      - ./scripts/ip6tables-stub.sh:/usr/sbin/ip6tables:ro
    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    sysctls:
      # Forwarding starts OFF: the openvpn container's setup-routing.sh enables
      # it only after the kill switch is installed, so wg0 can never egress via
      # eth0 before it.
      - net.ipv4.ip_forward=0
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv6.conf.all.disable_ipv6=0
      - net.ipv6.conf.default.disable_ipv6=0
    restart: unless-stopped

  # Local SOCKS (127.0.0.1:1080) -> VLESS+Reality. Plain proxy: no TUN, no
  # routing changes; its own connection leaves via eth0 (main table).
  sing-box:
    image: ghcr.io/sagernet/sing-box:v1.13.6
    container_name: sing-box
    command: ["run", "-c", "/etc/sing-box/config.json"]
    volumes:
      - ./sing-box:/etc/sing-box:ro
    network_mode: "service:wg-easy"
    depends_on:
      - wg-easy
    restart: unless-stopped

  # OpenVPN client (tun0) whose TCP connection goes through sing-box's SOCKS.
  # Runs setup-routing.sh (kill switch, forwarding, NAT); route-up.sh points
  # table 100 (wg0 traffic) at tun0 after every connect.
  openvpn:
    build: ./openvpn-client
    image: usa-tunnel-openvpn
    container_name: openvpn
    volumes:
      - ./openvpn:/openvpn:ro
      - ./scripts/setup-routing.sh:/setup-routing.sh:ro
    devices:
      - /dev/net/tun:/dev/net/tun
    # Writes /proc/sys (ip_forward, rp_filter) in the shared namespace.
    privileged: true
    network_mode: "service:wg-easy"
    depends_on:
      - wg-easy
      - sing-box
    restart: unless-stopped
```

- [ ] **Step 4: Ignore user profiles**

Append to the root `.gitignore`:

```
Synology-USA-tunnel/openvpn/*
!Synology-USA-tunnel/openvpn/.gitkeep
```

Run: `mkdir -p Synology-USA-tunnel/openvpn && touch Synology-USA-tunnel/openvpn/.gitkeep`

- [ ] **Step 5: Run the checks to verify they pass**

Run the three commands from Step 1 again.
Expected: both `jq -e` print `true`; `git check-ignore -v` prints two lines pointing at `.gitignore:<n>:Synology-USA-tunnel/openvpn/*`.

Also run:

```bash
cd Synology-USA-tunnel
docker compose config -q && echo COMPOSE_OK
sed -e 's/<YOUR_VPS_IP>/203.0.113.1/' -e 's/<YOUR_UUID>/11111111-2222-3333-4444-555555555555/' \
    -e 's/<YOUR_SNI>/example.com/' -e 's/<YOUR_REALITY_PUBLIC_KEY>/jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0/' \
    -e 's/<YOUR_SHORT_ID>/0123abcd/' sing-box/config.json > "${TMPDIR:-/tmp}/singbox-check.json"
docker run --rm -v "${TMPDIR:-/tmp}/singbox-check.json:/c.json:ro" ghcr.io/sagernet/sing-box:v1.13.6 check -c /c.json && echo SINGBOX_OK
git -C .. check-ignore -q Synology-USA-tunnel/openvpn/.gitkeep || echo GITKEEP_TRACKABLE
cd ..
```

Expected: `COMPOSE_OK`, `SINGBOX_OK`, `GITKEEP_TRACKABLE`. (The dummy values are not secrets; the unfilled template fails `sing-box check` on the placeholder public key, which is expected.)

- [ ] **Step 6: Rewrite the README**

Replace `Synology-USA-tunnel/README.md` with the content below. The `## Настройка Mikrotik` section is copied verbatim from the current README.

~~~~markdown
# USA-туннель (Synology + Mikrotik): WireGuard → VLESS → OpenVPN

Трафик устройств из address-list `vpn-clients` выходит в интернет с OpenVPN-сервера в США.
Соединение OpenVPN идёт внутри VLESS+REALITY: провайдер и DPI видят только TLS до VLESS-сервера.

## Архитектура

```
ПК (vpn-clients) → Mikrotik → WireGuard → Synology → VLESS-сервер → OpenVPN-сервер (США) → Интернет
```

Внутри Synology (все контейнеры в одном network namespace wg-easy):

```
wg0 ──ip rule iif wg0──▶ table 100: default dev tun0      (ставит route-up.sh после подключения)
                                    unreachable default    (kill switch, есть всегда)
        │ MASQUERADE -o tun0
        ▼
openvpn (tun0) ──TCP через SOCKS 127.0.0.1:1080──▶ sing-box ──VLESS+REALITY──▶ eth0
```

OpenVPN не меняет основную таблицу маршрутизации: маршрут sing-box до VLESS-сервера остаётся через `eth0`.
В `tun0` уходит только трафик, пришедший из `wg0`. Нет `tun0` — трафик из `wg0` блокируется (kill switch), мимо цепочки он не уходит.

| Кто | Что видит |
|-----|-----------|
| Провайдер / DPI | TLS до VLESS-сервера |
| VLESS-сервер | зашифрованный поток OpenVPN до сервера в США |
| OpenVPN-сервер | трафик клиентов с IP VLESS-сервера |
| Сайты | IP OpenVPN-сервера (США) |

### Контейнеры

| Контейнер | Образ | Назначение |
|-----------|-------|------------|
| wg-easy | `ghcr.io/wg-easy/wg-easy:15.2.2` | WireGuard-сервер + Web UI |
| sing-box | `ghcr.io/sagernet/sing-box:v1.13.6` | SOCKS `127.0.0.1:1080` → VLESS+REALITY |
| openvpn | собирается из `openvpn-client/` | OpenVPN-клиент (`tun0`), kill switch и policy routing |

## Структура файлов

```
Synology-USA-tunnel/
├── docker-compose.yml
├── sing-box/config.json        # <-- подставить VLESS credentials
├── openvpn/                    # <-- положить профиль OpenVPN (не коммитится)
│   ├── <любое-имя>.ovpn        #     ровно один профиль
│   └── cred.txt                #     логин и пароль, если профиль требует auth-user-pass
├── openvpn-client/             # образ OpenVPN-клиента (Dockerfile, entrypoint.sh, route-up.sh)
├── scripts/
│   ├── setup-routing.sh        # kill switch, форвардинг, NAT, LAN-маршруты
│   └── ip6tables-stub.sh       # заглушка для Synology DSM
├── tests/                      # локальные тесты (Docker), на Synology не нужны
└── wg-data/                    # создаётся wg-easy (ключи WireGuard)
```

## Установка

### 1. Заполнить VLESS credentials

В `sing-box/config.json` заменить 5 плейсхолдеров:

```json
"server": "<YOUR_VPS_IP>",
"uuid": "<YOUR_UUID>",
"server_name": "<YOUR_SNI>",
"public_key": "<YOUR_REALITY_PUBLIC_KEY>",
"short_id": "<YOUR_SHORT_ID>"
```

Значения взять из панели Marzban или существующего конфига. Если VLESS-сервер требует `flow`, добавить его в outbound.

### 2. Положить профиль OpenVPN

В `openvpn/` положить **ровно один** файл `*.ovpn` и всё, на что он ссылается по относительному пути (`ca.crt`, `client.key` и т.п.). Если в профиле есть строка `auth-user-pass`, рядом положить `cred.txt` из двух строк:

```
логин
пароль
```

Требования к профилю (иначе контейнер `openvpn` не стартует и пишет `ERROR` в лог):

- **Только TCP**: `proto tcp` (или `tcp-client`, `tcp4-client`) либо суффикс `tcp` в каждой строке `remote`. UDP через SOCKS-прокси не работает.
- **`remote` только с IPv4-адресом**. Имя хоста пришлось бы резолвить через DNS провайдера, мимо VLESS. Заменить имя на IP: `dig +short vpn.example.com`.
- Без блоков `<connection>` и директивы `config`.

Сам файл не меняется. При старте из него собирается `/tmp/run.ovpn`: удаляются `dev`, `dev-type`, `up`, `down`, `script-security`, `route-up`, `redirect-gateway`, `socks-proxy`, `http-proxy`, `auth-user-pass`; добавляются `dev tun0`, `socks-proxy 127.0.0.1 1080`, `route-nopull`, `route-noexec`, `route-up /route-up.sh` и `auth-user-pass /openvpn/cred.txt`. Маршруты, которые присылает сервер или которые записаны в профиле, игнорируются.

### 3. Скопировать на Synology

```bash
mkdir -p /volume1/docker/Synology-USA-tunnel

# scp, rsync или Synology File Station — всю папку Synology-USA-tunnel/ (tests/ можно не копировать)

cd /volume1/docker/Synology-USA-tunnel
chmod +x scripts/*.sh openvpn-client/*.sh
chmod 600 sing-box/config.json openvpn/*
```

### 4. Остановить другой стек

Этот стек и `synology-split-tunnel` используют одни и те же порты (51820/udp, 51821/tcp) и имена контейнеров, поэтому запускается только один из них:

```bash
cd /volume1/docker/synology-split-tunnel
docker compose down
```

Чтобы Mikrotik-пир подключился без перенастройки, перенести ключи WireGuard: скопировать `wg-data/` из `synology-split-tunnel` в `Synology-USA-tunnel`. Настройки WireGuard (Host, Port, DNS, Allowed IPs, Keepalive) в wg-easy v15 задаются в Web UI и хранятся в `wg-data/`.

### 5. Запуск

```bash
cd /volume1/docker/Synology-USA-tunnel
docker compose up -d --build
```

### 6. Проверка запуска

```bash
docker logs openvpn

# Ожидаемый вывод (фрагменты):
# [routing] kill switch: wg0 traffic blocked unless tun0 is up
# [routing] wg0 is up
# [routing] using iptables-legacy
# [routing] iptables rules applied
# [routing] setup complete
# [openvpn] profile: /openvpn/<имя>.ovpn
# ... Initialization Sequence Completed
# [route-up] table 100: default dev tun0
```

### 7. Тест с ПК из vpn-clients

```bash
# Должен вернуть IP OpenVPN-сервера в США (не провайдера и не VLESS-сервера)
curl -s https://ifconfig.me
```

Проверка kill switch:

```bash
docker stop openvpn     # на ПК интернета нет
docker start openvpn    # через 10–60 с интернет вернулся, IP снова американский
docker stop sing-box    # на ПК интернета нет
docker start sing-box   # OpenVPN переподключается сам (до нескольких минут)
```

## Восстановление

| Ситуация | Команда |
|----------|---------|
| Перезапущен или пересоздан только wg-easy (обновление образа, `up` только для wg-easy) | `docker compose up -d --force-recreate sing-box openvpn` — sing-box и openvpn остаются в старом namespace, а в новом форвардинг выключен |
| Изменён профиль или `cred.txt` | `docker restart openvpn` |
| Изменён `sing-box/config.json` | `docker restart sing-box` (OpenVPN переподключится сам) |
| Обновить образ OpenVPN-клиента | `docker compose build --pull openvpn && docker compose up -d openvpn` |

## Настройка Mikrotik

Если WG-туннель уже настроен — **менять ничего не нужно**.

```routeros
# Проверить что всё на месте:
/ip firewall address-list print where list=vpn-clients
/ip firewall mangle print where new-routing-mark=via-wg
/interface wireguard print
```

### MSS clamping (обязательно)

Без MSS clamping сайты грузятся медленно или не грузятся вовсе из-за фрагментации пакетов в WG-туннеле.

```routeros
/ip firewall mangle add chain=forward protocol=tcp tcp-flags=syn out-interface=wg-tunnel action=change-mss new-mss=clamp-to-pmtu passthrough=yes comment="MSS clamp WG out"
/ip firewall mangle add chain=forward protocol=tcp tcp-flags=syn in-interface=wg-tunnel action=change-mss new-mss=clamp-to-pmtu passthrough=yes comment="MSS clamp WG in"
```

### Исключение сервисов из туннеля

Некоторые сервисы (корпоративные VPN, банковские приложения и т.д.) не работают через цепочку прокси из-за MTU или гео-ограничений. Их нужно пускать напрямую, минуя WG-туннель.

Правило ставится **перед** `via-wg` (параметр `place-before=3`):

```routeros
# Исключить IP из туннеля (трафик пойдёт напрямую)
/ip firewall mangle add chain=prerouting action=accept dst-address=89.175.46.105 src-address-list=vpn-clients comment="HSE VPN direct" place-before=3

# Можно добавить несколько адресов или подсети
/ip firewall mangle add chain=prerouting action=accept dst-address=1.2.3.0/24 src-address-list=vpn-clients comment="Bank direct" place-before=3
```

Проверить порядок правил:
```routeros
/ip firewall mangle print
# accept-правила должны стоять ДО правила с mark-routing via-wg
```

### Управление списком vpn-clients

```routeros
# Добавить устройство
/ip firewall address-list add list=vpn-clients address=192.168.88.100

# Удалить устройство
/ip firewall address-list remove [find where list=vpn-clients address=192.168.88.100]

# Показать текущий список
/ip firewall address-list print where list=vpn-clients
```

### Настройка Mikrotik с нуля

См. [../docs/](../docs/) — полная конфигурация WireGuard + mangle.

## Диагностика

| Симптом | Что проверить |
|---------|---------------|
| `openvpn` перезапускается, в логе `[openvpn] ERROR: ...` | Профиль отклонён, причина в сообщении: UDP, имя хоста в `remote`, `<connection>`, `config`, нет `cred.txt`, ноль или несколько `.ovpn` |
| В логе `AUTH_FAILED` | Логин/пароль в `openvpn/cred.txt` |
| Нет строки `[route-up]`, в логе повторяются попытки подключения к `127.0.0.1:1080` | sing-box или VLESS: `docker logs sing-box`, credentials в `config.json` |
| `[routing] ERROR: iptables not found` или `cannot add iptables rules` | Ядро DSM не поддерживает нужный netfilter. Проверить: `docker run --rm --privileged --entrypoint iptables-legacy usa-tunnel-openvpn -t nat -S` |
| Нет интернета у vpn-clients, в логе всё без ошибок | `docker exec openvpn ip route show table 100` — должна быть строка `default dev tun0`. Без неё трафик блокируется kill switch (намеренно) |
| Сайты не открываются или грузятся частично | MSS clamping на Mikrotik (см. выше) |
| Медленно | TCP внутри TCP (OpenVPN/TCP через VLESS) проседает при потерях — это свойство схемы. Проверить MSS clamping и CPU Synology |
| WG handshake не проходит | Сверить ключи в wg-easy Web UI и peer на Mikrotik |
| Web UI wg-easy недоступен | `http://192.168.88.20:51821` (только из LAN) |

### Полезные команды

```bash
docker logs -f openvpn                          # kill switch, OpenVPN, route-up
docker logs -f sing-box                         # VLESS
docker exec wg-easy wg show                     # WireGuard
docker exec openvpn ip rule show                # должно быть: iif wg0 lookup 100
docker exec openvpn ip route show table 100     # default dev tun0 + unreachable default
docker exec openvpn cat /tmp/run.ovpn           # профиль, с которым запущен OpenVPN
```

## Безопасность

- `openvpn/` и заполненный `sing-box/config.json` содержат секреты: `chmod 600`, в git не коммитятся (`openvpn/*` в `.gitignore`, в репозитории `config.json` только с плейсхолдерами).
- SOCKS-порт sing-box слушает только `127.0.0.1`: из `wg0` и LAN он недоступен.
- DNS клиентов не перехватывается: запросы идут на резолвер, настроенный на устройстве.
- Web UI wg-easy (`51821/tcp`) доступен только из LAN; ключи WireGuard в `wg-data/` — ограничить доступ к директории.
~~~~

Check: `grep -c 'sing-box/config.json\|openvpn/\|cred.txt\|remote\|force-recreate sing-box openvpn\|docker logs openvpn' Synology-USA-tunnel/README.md` prints a number ≥ 6 (setup, IP-only `remote`, recovery and diagnostics are all present).

- [ ] **Step 7: Commit**

```bash
git add .gitignore Synology-USA-tunnel/openvpn/.gitkeep Synology-USA-tunnel/sing-box/config.json Synology-USA-tunnel/docker-compose.yml Synology-USA-tunnel/README.md
git diff --cached --stat
git commit -m "feat(usa-tunnel): wire sing-box SOCKS relay and OpenVPN client into compose"
```

Expected `--stat`: exactly those five files. If anything else is staged, unstage it before committing.

---

### Task 4: End-to-end check on the Mac and final verification (no commit)

Real sing-box and openvpn services with the working secrets from `16_worked_proxy_chain`, wg-easy replaced by a namespace-owner stand-in that creates a veth `wg0` and a client namespace `10.8.0.2`. Nothing from this task is committed.

**Files:**
- Create (scratch, outside the repo): `$E2E/env.sh`, `$E2E/override.yml`, `$E2E/sing-box/config.json`, `$E2E/openvpn/*`

**Interfaces:**
- Consumes: the committed stack from Tasks 1–3 (`Synology-USA-tunnel/docker-compose.yml`, `openvpn-client/`, `scripts/setup-routing.sh`); reference secrets in `/Users/csscoder/Development/LOCAL_PRJ_AI/16_worked_proxy_chain` (`singbox/config.json` with one `vless` outbound, `openVPN/*.ovpn` with `proto tcp` and an IPv4 `remote`, `openVPN/cred.txt`).
- Produces: a pass/fail report for the spec's end-to-end checks.

Each Bash call starts a fresh shell (zsh on this Mac), so every step begins with `. "$E2E/env.sh"` after exporting `E2E`. Never print secret files (`cat`, `jq .`) into the conversation.

- [ ] **Step 1: Prepare the scratch directory**

```bash
export E2E="${TMPDIR:-/tmp}/usa-tunnel-e2e"
mkdir -p "$E2E/sing-box" "$E2E/openvpn"
cat > "$E2E/env.sh" <<'EOF'
REPO=/Users/csscoder/Development/MY_PRIVATE_WORKS/MyWgBooster
REF=/Users/csscoder/Development/LOCAL_PRJ_AI/16_worked_proxy_chain
dc() { docker compose -p usa-e2e -f "$REPO/Synology-USA-tunnel/docker-compose.yml" -f "$E2E/override.yml" "$@"; }
# client: HTTPS request from the client namespace behind wg0 (IP URL: no DNS there).
client() { docker exec wg-easy ip netns exec client curl -s --max-time 15 https://1.1.1.1/cdn-cgi/trace; }
# wait_us: poll up to 300 s until the client exits in the USA.
wait_us() { i=0; while [ $i -lt 60 ]; do client | grep -q '^loc=US' && return 0; sleep 5; i=$((i + 1)); done; return 1; }
# wait_route_up: poll up to 180 s for a route-up log line newer than $SINCE (default: any).
wait_route_up() { i=0; while [ $i -lt 36 ]; do docker logs --since "${SINCE:-0}" openvpn 2>&1 | grep -q '\[route-up\]' && return 0; sleep 5; i=$((i + 1)); done; return 1; }
# wait_standin: poll up to 60 s for the namespace owner to finish its setup.
wait_standin() { i=0; while [ $i -lt 30 ]; do docker logs wg-easy 2>&1 | grep -q 'stand-in ready' && return 0; sleep 2; i=$((i + 1)); done; return 1; }
VLESS_IP=$(jq -r '.outbounds[0].server' "$E2E/sing-box/config.json" 2>/dev/null)
EOF
. "$E2E/env.sh"
jq --slurpfile ref "$REF/singbox/config.json" \
   '.outbounds = [$ref[0].outbounds[] | select(.type == "vless") | .tag = "proxy"]' \
   "$REPO/Synology-USA-tunnel/sing-box/config.json" > "$E2E/sing-box/config.json"
cp "$REF"/openVPN/*.ovpn "$REF/openVPN/cred.txt" "$E2E/openvpn/"
cat > "$E2E/override.yml" <<EOF
services:
  wg-easy:
    image: alpine:3.20
    environment: !reset []
    volumes: !reset []
    ports: !reset []
    privileged: true
    command:
      - /bin/sh
      - -c
      - |
        apk add --no-cache iproute2 curl >/dev/null || exit 1
        ip netns add client
        ip link add wg0 type veth peer name c0
        ip link set c0 netns client
        ip addr add 10.8.0.1/24 dev wg0
        ip link set wg0 up
        ip -n client addr add 10.8.0.2/24 dev c0
        ip -n client link set c0 up
        ip -n client link set lo up
        ip -n client route add default via 10.8.0.1
        echo stand-in ready
        exec sleep infinity
  sing-box:
    volumes: !override
      - $E2E/sing-box:/etc/sing-box:ro
  openvpn:
    volumes: !override
      - $E2E/openvpn:/openvpn:ro
      - $REPO/Synology-USA-tunnel/scripts/setup-routing.sh:/setup-routing.sh:ro
EOF
. "$E2E/env.sh"
jq -e '.outbounds | length == 1 and .[0].type == "vless"' "$E2E/sing-box/config.json" && echo "VLESS_IP set: $([ -n "$VLESS_IP" ] && echo yes)"
ls "$E2E/openvpn"
git -C "$REPO" status --short | grep -i 'e2e\|cred\|ovpn' || echo "repo clean of secrets"
```

Expected: `true`, `VLESS_IP set: yes`, one `.ovpn` plus `cred.txt` listed, `repo clean of secrets`.

- [ ] **Step 2: Start the namespace owner and sing-box, snapshot the main table**

```bash
export E2E="${TMPDIR:-/tmp}/usa-tunnel-e2e"; . "$E2E/env.sh"
dc up -d wg-easy sing-box
wait_standin && echo STANDIN_OK
docker exec wg-easy cat /proc/sys/net/ipv4/ip_forward
docker exec wg-easy ip route show > "$E2E/main-before.txt"
docker exec wg-easy ip route get "$VLESS_IP" | head -1
docker exec wg-easy curl -s --max-time 15 https://1.1.1.1/cdn-cgi/trace | grep '^ip=' > "$E2E/host-ip.txt"; cat "$E2E/host-ip.txt"
```

Expected: `STANDIN_OK`, `ip_forward` = `0`, the VLESS route line contains `dev eth0`, `host-ip.txt` holds the host's own egress IP (`ip=…`).

- [ ] **Step 3: Start openvpn, check exit IP and routing**

```bash
export E2E="${TMPDIR:-/tmp}/usa-tunnel-e2e"; . "$E2E/env.sh"
dc up -d --build openvpn
wait_route_up && echo ROUTE_UP_OK
docker logs openvpn 2>&1 | grep -E '\[routing\]|\[route-up\]|Initialization Sequence Completed|ERROR'
docker exec wg-easy ip route show table 100
docker exec wg-easy ip route show > "$E2E/main-after.txt"
diff "$E2E/main-before.txt" "$E2E/main-after.txt" | grep '^[<>]'
diff "$E2E/main-before.txt" "$E2E/main-after.txt" | grep '^[<>]' | grep -v '^> .* dev tun0 proto kernel' || echo "MAIN_TABLE_OK"
docker exec wg-easy ip route get "$VLESS_IP" | head -1
wait_us && echo EXIT_US_OK
client | grep -E '^(ip|loc)='
```

Expected: `ROUTE_UP_OK`; log shows the kill switch line, `iptables rules applied`, `setup complete`, `Initialization Sequence Completed`, `[route-up] table 100: default dev tun0`, no `ERROR`; table 100 contains `default dev tun0` and `unreachable default … metric 4000`; the diff shows exactly one `>` line, the connected `tun0` subnet route (`… dev tun0 proto kernel scope link src …`), and `MAIN_TABLE_OK`; the VLESS route still has `dev eth0`; `EXIT_US_OK`; the client `ip=` differs from `host-ip.txt` and from `$VLESS_IP`, `loc=US`.

- [ ] **Step 4: Kill switch — sing-box down**

```bash
export E2E="${TMPDIR:-/tmp}/usa-tunnel-e2e"; . "$E2E/env.sh"
docker stop sing-box
client | grep -E '^(ip|loc)=' || echo "BLOCKED_OK"
docker start sing-box
wait_us && echo "RESTORED_OK"
```

Expected: `BLOCKED_OK` (no `ip=` line at all, in particular not the host IP), then `RESTORED_OK` within 300 s (OpenVPN reconnects with backoff).

- [ ] **Step 5: Kill switch — openvpn down**

```bash
export E2E="${TMPDIR:-/tmp}/usa-tunnel-e2e"; . "$E2E/env.sh"
docker stop openvpn
client | grep -E '^(ip|loc)=' || echo "BLOCKED_OK"
docker exec wg-easy ip route show table 100
docker start openvpn
wait_us && echo "RESTORED_OK"
docker exec wg-easy ip rule show | grep -c 'iif wg0 lookup 100'
```

Expected: `BLOCKED_OK`; table 100 shows only `unreachable default` and the LAN routes (no `tun0`); `RESTORED_OK`; rule count `1` (rerun is idempotent).

- [ ] **Step 6: Profile with a `route` line to the VLESS server**

```bash
export E2E="${TMPDIR:-/tmp}/usa-tunnel-e2e"; . "$E2E/env.sh"
P=$(ls "$E2E"/openvpn/*.ovpn)
printf 'route %s 255.255.255.255\n' "$VLESS_IP" >> "$P"
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker restart openvpn
wait_route_up && wait_us && echo "RESTORED_OK"
docker exec wg-easy ip route get "$VLESS_IP" | head -1
docker exec wg-easy ip route show > "$E2E/main-after-route.txt"
diff "$E2E/main-before.txt" "$E2E/main-after-route.txt" | grep '^[<>]' | grep -v '^> .* dev tun0 proto kernel' || echo "MAIN_TABLE_OK"
```

Expected: `RESTORED_OK`; the VLESS route still has `dev eth0` (not `tun0`); `MAIN_TABLE_OK`.

- [ ] **Step 7: Tear down and remove secrets**

```bash
export E2E="${TMPDIR:-/tmp}/usa-tunnel-e2e"; . "$E2E/env.sh"
dc down
rm -r "$E2E"
git -C "$REPO" status --short
```

Expected: containers removed; `$E2E` gone; `git status` shows only the pre-existing user changes listed in Global Constraints. If a safety hook blocks `rm -r`, ask the user to delete `$E2E` (it holds VPN credentials).

- [ ] **Step 8: Final verification**

```bash
cd /Users/csscoder/Development/MY_PRIVATE_WORKS/MyWgBooster
shellcheck Synology-USA-tunnel/openvpn-client/*.sh Synology-USA-tunnel/scripts/*.sh Synology-USA-tunnel/tests/*.sh && echo SHELLCHECK_OK
(cd Synology-USA-tunnel && docker compose config -q) && echo COMPOSE_OK
sh Synology-USA-tunnel/tests/test-entrypoint.sh | tail -1
sh Synology-USA-tunnel/tests/test-routing.sh | tail -1
git log --oneline -4
git show --stat HEAD~2 HEAD~1 HEAD | grep -iE 'cred|\.ovpn$' || echo "NO_SECRETS_COMMITTED"
```

Expected: `SHELLCHECK_OK`, `COMPOSE_OK`, `all entrypoint cases passed`, `all routing cases passed`, the three task commits on top, `NO_SECRETS_COMMITTED`.

- [ ] **Step 9: Report**

Report to the user (Russian): each spec end-to-end check with PASS/FAIL and evidence (exit `ip=`/`loc=`, main-table diff line, route-up log line), anything skipped, and the items that remain for manual acceptance on the Synology (spec "Manual acceptance": USA exit IP from a `vpn-clients` PC, stop/start `openvpn` and `sing-box`, `docker logs openvpn` shows the kill switch and `route-up` lines; DSM netfilter support for `iptables-legacy` is unverified until then).
