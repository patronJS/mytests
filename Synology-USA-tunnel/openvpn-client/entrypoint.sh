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
NR == 1 { sub(/^\357\273\277/, "") }
inline { print > out; if ($1 ~ /^<\//) inline = 0; next }   # inline <tag> block: copy verbatim
{ sub(/^[ \t]*--/, "") }                                  # OpenVPN accepts "--remote" in files too
{
    fields = NF
    for (i = 1; i <= NF; i++) if ($i ~ /^[#;]/) { fields = i - 1; break }
}
$1 ~ /^<connection>/ { fail("<connection> blocks are not supported") }
$1 ~ /^<[^\/]/ { inline = 1; print > out; next }
$1 == "config" { fail("config includes are not supported") }
$1 == "proto" { proto = fields >= 2 ? $2 : "" }
$1 == "auth-user-pass" { auth = 1 }
$1 == "remote" {
    remotes++
    if (!ipv4(fields >= 2 ? $2 : "")) fail("remote must be a numeric IPv4 address (a hostname would be resolved outside VLESS): " $0)
    if (fields >= 4 && $4 !~ /^tcp/) fail("remote must use TCP (socks-proxy is TCP-only): " $0)
    if (fields < 4) bare = 1
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
