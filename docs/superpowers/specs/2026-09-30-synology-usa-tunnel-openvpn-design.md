# Design: Synology-USA-tunnel — WireGuard → VLESS → OpenVPN chain

- **Status:** approved in brainstorming (2026-09-30), pending written-spec review
- **Scope:** `Synology-USA-tunnel/` only. `synology-split-tunnel/` and the VPS installers are untouched.
- **Target platform:** Synology DSM + Docker (Alpine-based images), by the user's explicit
  decision. The repository's Ubuntu 24.04 rule is scoped to the VPS installers (`CLAUDE.md`
  updated accordingly on the user's request).
- **Reference:** `/Users/csscoder/Development/LOCAL_PRJ_AI/16_worked_proxy_chain` (working
  VLESS → OpenVPN chain via `socks-proxy`; reused ideas, not files).

## Goal

Devices in the Mikrotik `vpn-clients` address-list exit to the internet from an OpenVPN
server in the USA. The OpenVPN connection is carried inside VLESS+Reality so the ISP/DPI
sees only TLS to the VLESS server.

Physical path (both directions):

```
PC → Mikrotik → WireGuard → Synology → VLESS server → OpenVPN server (USA) → internet
```

Nesting on the Synology: OpenVPN is the inner layer (encrypted for the USA server),
VLESS is the outer layer. The VLESS server is a plain relay and needs no changes.

### Who sees what

| Observer | Sees |
|---|---|
| ISP / DPI | TLS to the VLESS server only |
| VLESS server | an opaque OpenVPN stream to the USA server |
| OpenVPN server | client traffic, coming from the VLESS server's IP |
| Websites | the OpenVPN server's (USA) IP |

## Decisions (from brainstorming)

1. Exit IP = OpenVPN server (USA); VLESS = obfuscation hop.
2. Approach A: OpenVPN client runs on the Synology in the shared wg-easy network namespace;
   sing-box becomes a local SOCKS → VLESS relay (no TUN).
3. OpenVPN client stays on the Synology (not on the VLESS server).
4. Ports and container names of wg-easy stay as in `synology-split-tunnel` (51820/udp,
   51821/tcp). The two stacks are run one at a time, manually.
5. End-to-end test on the developer Mac may use the working VLESS/OpenVPN secrets from
   `16_worked_proxy_chain`, locally only, never committed.

## Architecture

```
Mikrotik ──WG──▶ wg0 ─┐   shared netns (owner: wg-easy)
                      │  ip rule iif wg0 → table 100
                      ▼
              table 100: default dev tun0            (set by OpenVPN route-up hook)
                         unreachable default metric 4000 (kill switch, always present)
                      │  iptables MASQUERADE -o tun0
                      ▼
              openvpn (tun0) ──transport: socks-proxy 127.0.0.1:1080──▶ sing-box mixed-in
                                                                          │ VLESS+Reality
                                                                          ▼ eth0 (main table)
                                                     VLESS server → OpenVPN server (USA) → internet
```

OpenVPN adds no routes to the main table: its existing routes, its default route and the
path to the VLESS server stay as they are, so sing-box's own connection to the VLESS server
leaves via `eth0`. The only main-table change is the kernel's connected route for the
`tun0` subnet, created when the tunnel address is assigned. Only traffic arriving on `wg0`
is policy-routed into `tun0`.

### Containers

All three share wg-easy's network namespace (`network_mode: "service:wg-easy"`).

| Service | Image | Role |
|---|---|---|
| `wg-easy` | `ghcr.io/wg-easy/wg-easy:15.2.2` | WireGuard server. Unchanged from the current copy, including `net.ipv4.ip_forward=0` at start and the `ip6tables` stub |
| `sing-box` | `ghcr.io/sagernet/sing-box:v1.13.6` | `mixed` inbound on `127.0.0.1:1080` → VLESS outbound. No TUN, no `privileged`, no `/dev/net/tun`, plain `sing-box run` entrypoint |
| `openvpn` | local build from `openvpn-client/` | Owns `tun0`. Entrypoint runs `setup-routing.sh` (fail → exit 1), prepares the profile, `exec openvpn`. Needs `privileged: true` (writes `/proc/sys`) and `/dev/net/tun` |

`depends_on`: `sing-box` → `wg-easy`; `openvpn` → `wg-easy`, `sing-box`. Restart policy
`unless-stopped` for all.

### Files

```
Synology-USA-tunnel/
├── docker-compose.yml          # wg-easy + sing-box + openvpn
├── README.md                   # rewritten for this chain
├── sing-box/config.json        # mixed 127.0.0.1:1080 → VLESS (placeholders in git)
├── openvpn/                    # user drops files here; gitignored except .gitkeep
│   ├── <any-name>.ovpn         #   exactly one profile, proto tcp
│   └── cred.txt                #   optional: username / password (2 lines)
├── openvpn-client/
│   ├── Dockerfile              # alpine + openvpn + iptables (+ iptables-legacy)
│   ├── entrypoint.sh           # validate + prepare profile, exec openvpn
│   └── route-up.sh             # OpenVPN hook: default dev tun0 in table 100
├── scripts/
│   ├── setup-routing.sh        # kill switch, forwarding, iptables, LAN routes
│   └── ip6tables-stub.sh       # unchanged
└── tests/                      # Docker-based checks, no secrets
    ├── test-routing.sh
    └── test-entrypoint.sh
```

`old-tunnel/` is not part of this project (already removed from the working tree).

Root `.gitignore` gains:

```
Synology-USA-tunnel/openvpn/*
!Synology-USA-tunnel/openvpn/.gitkeep
```

## Components

### sing-box (`sing-box/config.json`)

```json
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    { "type": "mixed", "tag": "socks-in", "listen": "127.0.0.1", "listen_port": 1080 }
  ],
  "outbounds": [
    {
      "type": "vless", "tag": "proxy",
      "server": "<YOUR_VPS_IP>", "server_port": 443, "uuid": "<YOUR_UUID>",
      "tls": {
        "enabled": true, "server_name": "<YOUR_SNI>",
        "reality": { "enabled": true, "public_key": "<YOUR_REALITY_PUBLIC_KEY>", "short_id": "<YOUR_SHORT_ID>" },
        "utls": { "enabled": true, "fingerprint": "firefox" }
      }
    }
  ],
  "route": { "final": "proxy" }
}
```

`listen: 127.0.0.1` keeps the SOCKS port unreachable from `wg0` and the LAN (loopback is
not routable). `flow` stays absent, as in the current config; add it only if the VLESS
server requires it.

### openvpn-client image (`openvpn-client/Dockerfile`)

- Base `alpine:3.20` (as in the reference). Packages: `openvpn`, `iptables`,
  `iptables-legacy`. `ip` comes from busybox (the routing script is already proven with
  busybox `ip`).
- `COPY entrypoint.sh route-up.sh /`; `ENTRYPOINT ["/entrypoint.sh"]`.
- `scripts/setup-routing.sh` is bind-mounted read-only at `/setup-routing.sh` (same
  pattern as today; the tests run the same file).

### entrypoint.sh (POSIX sh)

1. `/setup-routing.sh || exit 1` — kill switch, forwarding, iptables, LAN routes.
2. Profile discovery: exactly one `/openvpn/*.ovpn`; 0 or >1 → `ERROR`, exit 1.
3. Validation, each failure → `ERROR` + exit 1. Supported format: a flat profile with
   inline or file-based certificates; anything the checks cannot reason about is rejected.
   - At least one `remote` line. Every `remote` host is a numeric IPv4 address; hostnames
     are rejected (resolving one locally would send a DNS query to the ISP outside VLESS).
   - Effective transport is TCP for every remote: each `remote` line has either no protocol
     suffix or a `tcp*` suffix; if any `remote` line has no suffix, a `proto tcp*` line
     (`tcp`, `tcp-client`, `tcp4-client`, …) must be present. Any `udp*` suffix or a missing
     TCP `proto` is rejected (`socks-proxy` is TCP-only; UDP would bypass VLESS).
   - `<connection>` blocks and `config` includes are rejected (their semantics are not parsed).
   - If the profile contains `auth-user-pass`, `/openvpn/cred.txt` must exist.
4. Build `/tmp/run.ovpn` from the profile (source file never modified):
   - drop lines: `dev`, `dev-type`, `up`, `down`, `script-security`, `route-up`,
     `redirect-gateway`, `socks-proxy`, `http-proxy`, `auth-user-pass`;
   - append:
     ```
     dev tun0
     dev-type tun
     socks-proxy 127.0.0.1 1080
     route-nopull
     route-noexec
     script-security 2
     route-up /route-up.sh
     auth-user-pass /openvpn/cred.txt   # only if the profile had auth-user-pass
     ```
5. `cd /openvpn && exec openvpn --config /tmp/run.ovpn`. The working directory makes
   relative `ca`/`cert`/`key`/`tls-auth` paths resolve next to the profile.

`route-nopull` ignores server-pushed routes including `redirect-gateway`; `route-noexec`
stops OpenVPN from installing any route at all, including `route` lines inside the profile.
Otherwise the whole namespace (and sing-box's own VLESS connection) could be sent into
`tun0` — a loop. Apart from the kernel's connected route for the `tun0` subnet (created
by address assignment, not by OpenVPN's route logic), the only route the session
contributes is the one `route-up.sh` writes into table 100.

### route-up.sh

Runs after every (re)connect. Sets `net.ipv4.conf.tun0.rp_filter=0` and
`ip route replace default dev "$dev" table 100`, logs one line. Replaces the background
"wait for tun0" loop of `setup-routing.sh`, which only fired once and would not restore
the route if OpenVPN recreated `tun0`.

### scripts/setup-routing.sh

Same as the current copy except:

- the background tun0 loop is removed (moved to `route-up.sh`); its
  `net.ipv4.conf.wg0.rp_filter=0` step stays in `setup-routing.sh`, executed after `wg0`
  appears (changing `all`/`default` does not reset an existing interface's value);
- the iptables section no longer installs packages at runtime (`iptables` is in the image;
  prefer `iptables-legacy` when present, as today). MASQUERADE on `tun0` is now required
  (the OpenVPN server only accepts packets from its assigned client IP), so a missing
  iptables binary, or a failure to add any of the FORWARD/MASQUERADE rules → `ERROR`,
  exit 1 (no success message after a failed rule).

Kept unchanged: kill switch first (idempotent, fail closed with `ip_forward=0`), stale
`tun0` cleanup, rp_filter sysctls, `ip_forward=1` after the kill switch, LAN routes in
table 100.

## Data flow

1. A packet from a `vpn-clients` device arrives on `wg0`.
2. `ip rule iif wg0` → table 100 → `default dev tun0`. LAN ranges stay on `wg0`.
3. MASQUERADE rewrites the source to the OpenVPN client address.
4. OpenVPN encrypts it and sends it over its TCP connection, which goes through sing-box's
   SOCKS on `127.0.0.1:1080`.
5. sing-box wraps the stream in VLESS+Reality and connects to the VLESS server via `eth0`.
6. The VLESS server relays the stream to the OpenVPN server; it exits in the USA.
7. Replies follow the reverse path; conntrack reverses the NAT back to the device address.

## Failure handling

The rule: traffic from `wg0` never leaves via `eth0`.

| Event | Behavior | Recovery |
|---|---|---|
| Synology boot / first start | wg-easy starts with forwarding off; `openvpn` installs the kill switch, enables forwarding; `route-up` adds the tun0 route after connect | automatic |
| sing-box down/restart | OpenVPN's TCP connection drops; OpenVPN reconnects; traffic is blocked meanwhile | automatic; `route-up` restores the route |
| OpenVPN process exits | container exits, `tun0` disappears, `unreachable` blocks | `restart: unless-stopped`; script rerun is idempotent |
| Bad profile / `AUTH_FAILED` | container restarts in a loop, traffic blocked, reason in `docker logs openvpn` | fix `openvpn/` |
| wg-easy alone restarted/recreated | new netns has forwarding off → blocked; sing-box/openvpn stay attached to the old netns | `docker compose up -d --force-recreate sing-box openvpn` (README) |

## Testing

### Automated (local Docker, no secrets) — committed in `tests/`

1. `test-routing.sh` — runs `scripts/setup-routing.sh` and `openvpn-client/route-up.sh`
   inside the built `openvpn` image with dummy `wg0`/`tun0` and the compose `ip_forward`
   value. Cases: first start (wg0 before script) blocked; steady state (tun0 up → via tun0,
   LAN → wg0); tun0 gone → blocked; rerun with 0 leaks and single rule/route; fail closed
   (ip_forward 1 → 0); route restored by `route-up.sh` after tun0 is recreated; missing
   iptables → exit 1; iptables present but adding MASQUERADE fails → exit 1; `wg0`
   created with `rp_filter=1` → 0 after the script.
2. `test-entrypoint.sh` — runs the profile preparation against sample profiles and asserts:
   `dev tun` → `dev tun0`; `up`/`down`/`script-security`/`redirect-gateway` stripped;
   `socks-proxy`, `route-nopull`, `route-noexec`, `route-up` appended; `auth-user-pass`
   rewritten when `cred.txt` exists. Rejected: `proto udp`; `proto tcp-client` with
   `remote IP PORT udp`; mixed TCP/UDP remotes; hostname `remote`; no `remote`;
   `<connection>` block; `config` include; `auth-user-pass` without `cred.txt`; 0 or 2
   profiles. Test hook: with `OVPN_DRY_RUN=1` the entrypoint skips
   `setup-routing.sh`, prints `/tmp/run.ovpn` and exits 0 instead of `exec openvpn`, so
   this test needs no privileges.

### End-to-end on the Mac (secrets from 16_worked_proxy_chain, local only)

The real `sing-box` and `openvpn` services with real VLESS and OpenVPN credentials.
Mikrotik and WireGuard cannot be driven locally, so wg-easy is replaced by a minimal
namespace-owner container with the same sysctls (`ip_forward=0`). Inside that namespace a
veth pair is created: the router-side end is named `wg0`, the other end sits in a client
network namespace (`10.8.0.2`, default via `10.8.0.1`). WireGuard itself is not exercised
(it is unchanged). Checks:

- a request from the client namespace reports the OpenVPN server's exit IP;
- `docker stop sing-box` → client requests fail (no fallback to the host IP);
- `docker stop openvpn` → client requests fail;
- after restarts the exit IP returns;
- `route-up.sh` fires with `route-noexec` (table 100 gets `default dev tun0`); after
  connect, the main table keeps all pre-existing routes and its default route, the route
  to the VLESS server IP still resolves via `eth0`, and the only added route is the
  connected route of the `tun0` subnet — also with a profile that contains a `route` line
  to the VLESS server IP.

Secrets stay in a scratch directory outside the repository.

### Manual acceptance on the Synology

- from a `vpn-clients` PC, `curl ifconfig.me` returns the USA IP;
- `docker stop openvpn` → no internet on that PC; `docker start openvpn` → restored;
- `docker stop sing-box` → no internet; start → restored;
- `docker logs openvpn` shows the kill switch line and `route-up` line, no errors.

## Acceptance criteria

1. Exit IP of `vpn-clients` traffic equals the OpenVPN server IP.
2. No path from `wg0` to `eth0` at any time (startup, sing-box down, OpenVPN down, reruns).
3. UDP or mixed-transport profiles, hostname remotes, unsupported constructs
   (`<connection>`, `config`) and missing credentials fail loudly at start.
4. User secrets (`openvpn/*`, real `sing-box/config.json` values) are never committed.
5. All automated tests pass; `docker compose config -q` and `shellcheck` are clean.
6. README documents setup (where to put the profile and its companion files, IP-only
   `remote`), recovery commands, and diagnostics.

## Risks and open items

- **Synology kernel netfilter.** DSM may lack `nf_tables`; the script prefers
  `iptables-legacy`. Cannot be verified locally — check `docker logs openvpn` on first run.
- **TCP-over-TCP.** OpenVPN/TCP inside VLESS/TCP degrades under packet loss; inherent to
  the chosen transport.
- **MTU/MSS.** Not tuned; Mikrotik MSS clamping stays. Add `mssfix` only if breakage is
  observed.

## Non-goals

- DNS handling for clients (queries follow the device's resolver).
- Changes to `synology-split-tunnel/`, VPS installers, or the VLESS server.
- Running OpenVPN on the VLESS server.
- Automatic recovery from a wg-easy-only restart (documented manual command instead).
