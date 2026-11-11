# netns-test: end-to-end leak test for vpn-resolver, run as root.
#
# Builds a fake world out of network namespaces:
#
#   netns "vrt-world"  plays the LAN, CoreDNS and the VPN provider. It runs a
#                      WireGuard server and an "upstream" DNS server reachable
#                      only through the tunnel, plus a decoy "public resolver"
#                      (9.9.9.9) reachable directly. A counter records every
#                      packet from the pod that is not WireGuard.
#   netns "vrt-pod"    plays the Kubernetes pod (eth0 = its CNI interface).
#                      vpn-resolver-entrypoint runs here and creates the
#                      inner netns "vrt-vpn".
#
# Pass = queries resolve through the tunnel, the inner netns has only wg0 and
# veth-in, nothing but WireGuard ever leaves the pod, and with wg0 gone the
# inner netns has no route at all.

[[ $EUID == 0 ]] || {
  echo "run as root" >&2
  exit 1
}

WORLD=vrt-world
POD=vrt-pod
VPN=vrt-vpn
# 1 = wireguard-go in the pod (works anywhere), 0 = the kernel module.
WG_USERSPACE="${WG_USERSPACE:-1}"
TMP="$(mktemp -d)"
chmod 755 "$TMP" # Unbound drops to nobody and must reach its directory
pids=()
failures=0

pass() { echo "PASS: $*"; }
fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}
expect() { # actual expected description
  if [[ $1 == "$2" ]]; then pass "$3"; else fail "$3 (got '$1')"; fi
}

cleanup() {
  for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done
  pkill -f "wireguard-go vrt" 2>/dev/null || true
  ip netns pids "$POD" 2>/dev/null | xargs -r kill 2>/dev/null || true
  ip netns pids "$WORLD" 2>/dev/null | xargs -r kill 2>/dev/null || true
  sleep 1
  ip netns del "$VPN" 2>/dev/null || true
  ip netns del "$POD" 2>/dev/null || true
  ip netns del "$WORLD" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT
for ns in "$VPN" "$POD" "$WORLD"; do ip netns del "$ns" 2>/dev/null || true; done

w() { ip netns exec "$WORLD" "$@"; }
p() { ip netns exec "$POD" "$@"; }

# ── The fake world ────────────────────────────────────────────────────────
ip netns add "$WORLD"
ip netns add "$POD"
ip link add vrt-p0 type veth peer name vrt-w0
ip link set vrt-p0 netns "$POD"
ip link set vrt-w0 netns "$WORLD"
ip -n "$POD" link set vrt-p0 name eth0
ip -n "$POD" link set lo up
ip -n "$POD" addr add 10.99.0.2/24 dev eth0
ip -n "$POD" link set eth0 up
ip -n "$POD" route add default via 10.99.0.1
ip -n "$WORLD" link set lo up
ip -n "$WORLD" addr add 10.99.0.1/24 dev vrt-w0
ip -n "$WORLD" link set vrt-w0 up
ip -n "$WORLD" addr add 9.9.9.9/32 dev lo # decoy public resolver

# Count every connection the pod starts that is not WireGuard to the endpoint.
# (Answers to the LAN's own queries are replies, not new connections.)
w nft -f - <<'EOF'
table inet watch {
  counter leaks {}
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "vrt-w0" ip saddr 10.99.0.2 udp dport 51820 accept
    iifname "vrt-w0" ip saddr 10.99.0.2 ct state new counter name "leaks"
  }
}
EOF
leaks() { w nft list counter inet watch leaks | awk '/packets/ { print $2 }'; }

# WireGuard "provider" in the world netns.
srv_key="$(wg genkey)"
cli_key="$(wg genkey)"
srv_pub="$(wg pubkey <<<"$srv_key")"
cli_pub="$(wg pubkey <<<"$cli_key")"
w wireguard-go vrt-wgs
w wg set vrt-wgs listen-port 51820 private-key <(echo "$srv_key") peer "$cli_pub" allowed-ips 10.2.0.2/32
w ip addr add 10.2.0.1/24 dev vrt-wgs
w ip link set vrt-wgs up

# "Upstream" DNS server, only on the tunnel side.
cat >"$TMP/upstream.conf" <<EOF
server:
    chroot: ""
    username: ""
    directory: "$TMP"
    pidfile: ""
    use-syslog: no
    logfile: ""
    interface: 10.2.0.1
    interface: 9.9.9.9
    access-control: 0.0.0.0/0 allow
    do-ip6: no
    local-zone: "example." static
    local-data: "through-tunnel.example. A 192.0.2.53"
    local-data: "second.example. A 192.0.2.54"
EOF
w unbound -d -c "$TMP/upstream.conf" &
pids+=($!)

# Client config, as Proton would hand it out (wg-quick format).
cat >"$TMP/wg0.conf" <<EOF
[Interface]
PrivateKey = $cli_key
Address = 10.2.0.2/32
DNS = 10.2.0.1

[Peer]
PublicKey = $srv_pub
AllowedIPs = 0.0.0.0/0
Endpoint = 10.99.0.1:51820
EOF

# ── Start vpn-resolver in the pod ─────────────────────────────────────────
p env \
  WG_CONFIG="$TMP/wg0.conf" WG_USERSPACE="$WG_USERSPACE" ALLOWED_CLIENTS=10.99.0.0/24 POD_IF=eth0 \
  NETNS="$VPN" UNBOUND_DIR="$TMP/unbound" UPSTREAMS="10.2.0.1@53" FORWARD_TLS=no \
  WATCHDOG=0 DNSSEC=no vpn-resolver-entrypoint >"$TMP/resolver.log" 2>&1 &
pids+=($!)

ok=""
for _ in $(seq 1 30); do
  ans="$(w dig @10.99.0.2 through-tunnel.example +short +time=1 +tries=1 2>/dev/null || true)"
  if [[ $ans == 192.0.2.53 ]]; then
    ok=1
    break
  fi
  sleep 1
done
if [[ -n $ok ]]; then pass "query from the LAN side resolves through the tunnel"; else
  fail "query never resolved"
  cat "$TMP/resolver.log"
fi

# The inner netns was created inside the pod's own mount namespace (as in a
# real container), so reach it through the Unbound process that lives in it.
upid="$(pgrep -f "unbound -d -c $TMP/unbound/unbound.conf" | head -1)"
v() { nsenter --net="/proc/$upid/ns/net" "$@"; }

if p env NETNS="$VPN" PROBE_NAME=through-tunnel.example vpn-resolver-check; then
  pass "readiness probe succeeds"
else fail "readiness probe failed"; fi

links="$(v ip -o link show 2>/dev/null | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }' | sort | tr '\n' ' ')"
expect "$links" "lo veth-in wg0 " "inner netns holds only lo, veth-in, wg0"

expect "$(leaks)" 0 "no non-WireGuard packets left the pod so far"

# The pod netns itself must not reach the decoy resolver directly.
if p dig @9.9.9.9 through-tunnel.example +time=1 +tries=1 >/dev/null 2>&1; then
  fail "pod netns reached 9.9.9.9 directly"
else pass "pod netns cannot reach a public resolver (UDP)"; fi
if p timeout 3 bash -c 'echo > /dev/tcp/9.9.9.9/53' 2>/dev/null; then
  fail "pod netns opened TCP to 9.9.9.9"
else pass "pod netns cannot reach a public resolver (TCP)"; fi
expect "$(leaks)" 0 "blocked attempts never left the pod"

# ── Tunnel gone: structural isolation ─────────────────────────────────────
v ip link del wg0
out="$(v dig @9.9.9.9 through-tunnel.example +time=1 +tries=1 2>&1 || true)"
if grep -qi 'unreachable' <<<"$out"; then
  pass "with wg0 gone the inner netns has no route at all (network unreachable)"
else fail "inner netns without wg0 did not report unreachable: $out"; fi

ans="$(w dig @10.99.0.2 second.example +short +time=2 +tries=1 2>/dev/null || true)"
if [[ $ans != 192.0.2.54 ]]; then pass "uncached names fail closed with the tunnel down"; else fail "got an answer with no tunnel"; fi

expect "$(leaks)" 0 "still no non-WireGuard packets after the tunnel went down"

# ── Control: prove the leak counter would catch a real leak ───────────────
p nft delete table inet vpn_resolver
p dig @9.9.9.9 through-tunnel.example +time=1 +tries=1 >/dev/null 2>&1 || true
if (($(leaks) > 0)); then
  pass "control: with the pod kill switch removed, the counter catches a direct query"
else fail "control: the leak counter missed a deliberate leak"; fi

echo
if ((failures == 0)); then
  echo "All checks passed."
else
  echo "$failures check(s) failed. Resolver log:"
  cat "$TMP/resolver.log"
  exit 1
fi
