#!/bin/sh

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

# --- iptables (legacy for Synology DSM) ---
IPT=""
if command -v iptables-legacy >/dev/null 2>&1; then
    IPT="iptables-legacy"
elif command -v iptables >/dev/null 2>&1; then
    IPT="iptables"
else
    apk add --no-cache iptables 2>/dev/null
    if command -v iptables-legacy >/dev/null 2>&1; then
        IPT="iptables-legacy"
    elif command -v iptables >/dev/null 2>&1; then
        IPT="iptables"
    fi
fi

if [ -n "$IPT" ]; then
    echo "[routing] using $IPT"
    # Allow forwarding wg0 <-> tun0
    $IPT -C FORWARD -i wg0 -o tun0 -j ACCEPT 2>/dev/null || \
        $IPT -A FORWARD -i wg0 -o tun0 -j ACCEPT
    $IPT -C FORWARD -i tun0 -o wg0 -j ACCEPT 2>/dev/null || \
        $IPT -A FORWARD -i tun0 -o wg0 -j ACCEPT
    # NAT for tun0 (proxy traffic)
    $IPT -t nat -C POSTROUTING -o tun0 -j MASQUERADE 2>/dev/null || \
        $IPT -t nat -A POSTROUTING -o tun0 -j MASQUERADE
    echo "[routing] iptables rules applied"
else
    echo "[routing] WARNING: iptables not available"
fi

# --- policy routing (clean up duplicates from previous runs) ---
ip rule del iif wg0 table 100 priority 100 2>/dev/null || true
ip rule add iif wg0 table 100 priority 100 2>/dev/null || true

# Table 100: LAN stays on wg0
ip route replace 192.168.0.0/16 dev wg0 table 100 2>/dev/null || true
ip route replace 10.0.0.0/8 dev wg0 table 100 2>/dev/null || true
ip route replace 172.16.0.0/12 dev wg0 table 100 2>/dev/null || true

echo "[routing] table 100: LAN via wg0, waiting for tun0..."

# --- background: wait for tun0, then set default route through proxy ---
(
    while ! ip link show tun0 >/dev/null 2>&1; do
        sleep 1
    done
    set_sysctl net.ipv4.conf.tun0.rp_filter 0
    set_sysctl net.ipv4.conf.wg0.rp_filter 0

    ip route replace default dev tun0 table 100
    echo "[routing] default route set to tun0 — full proxy mode"
) &

echo "[routing] setup complete"
