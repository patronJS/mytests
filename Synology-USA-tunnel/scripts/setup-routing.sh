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
