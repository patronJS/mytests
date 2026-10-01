#!/bin/sh
# OpenVPN route-up hook, runs after every (re)connect. OpenVPN itself installs
# no routes (route-nopull, route-noexec); this sends table 100 (wg0 traffic)
# into the tunnel. OpenVPN passes the tunnel device name in $dev.
dev=${dev:?dev is not set by OpenVPN}
sysctl -w "net.ipv4.conf.$dev.rp_filter=0" >/dev/null
ip route replace default dev "$dev" table 100 || exit 1
echo "[route-up] table 100: default dev $dev"
