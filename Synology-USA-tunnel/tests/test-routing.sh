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
