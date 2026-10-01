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
