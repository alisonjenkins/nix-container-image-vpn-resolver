# vpn-resolver-setup: build the pod's leak-proof network layout.
#
# Layout after this script (see README.md for the full picture):
#
#   pod netns (eth0 from the CNI)          inner netns "$NETNS"
#   ─────────────────────────────          ─────────────────────
#   nftables kill switch: output drop      lo
#   except UDP to the WireGuard endpoint   wg0  ← only route out (default dev wg0)
#   and DNS handed to the inner netns      veth-in  ← /30 back to the pod, no other route
#   veth-out ─────────────────────────────┘
#
# wg0 is created in the pod netns and then moved into the inner netns, so its
# encrypted UDP socket stays in the pod netns (https://www.wireguard.com/netns/).
# Unbound runs in the inner netns: if wg0 goes away it has no route at all.
#
# Re-runnable: a container restart inside the same pod rebuilds everything.

WG_CONFIG="${WG_CONFIG:-/etc/wireguard/wg0.conf}"
# Comma-separated sources allowed to query: the pod CIDR, plus the node IPs
# when CoreDNS runs with hostNetwork.
ALLOWED_CLIENTS="${ALLOWED_CLIENTS:-10.42.0.0/16}"
POD_IF="${POD_IF:-eth0}"
NETNS="${NETNS:-vpn}"
VETH_OUTER_IP="${VETH_OUTER_IP:-169.254.53.1}"
VETH_INNER_IP="${VETH_INNER_IP:-169.254.53.2}"
WG_MTU="${WG_MTU:-1420}"
WG_KEEPALIVE="${WG_KEEPALIVE:-25}"
WG_USERSPACE="${WG_USERSPACE:-0}"

log() { echo "[vpn-resolver-setup] $*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}
is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

[[ -r $WG_CONFIG ]] || die "cannot read WireGuard config $WG_CONFIG"

# Print the value of KEY in [SECTION] of the wg-quick style config.
conf_value() {
  awk -v want_sec="$1" -v want_key="$2" '
    { line = $0; sub(/#.*/, "", line); gsub(/^[ \t]+|[ \t]+$/, "", line) }
    line ~ /^\[.*\]$/ { sec = substr(line, 2, length(line) - 2); next }
    sec == want_sec {
      n = index(line, "=")
      if (n == 0) next
      k = substr(line, 1, n - 1); v = substr(line, n + 1)
      gsub(/[ \t]+/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
      if (tolower(k) == tolower(want_key)) { print v; exit }
    }' "$WG_CONFIG"
}

# The config minus the wg-quick-only keys that `wg setconf` rejects.
stripped_config() {
  grep -viE '^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=' "$WG_CONFIG"
}

peers=$(grep -ciE '^[[:space:]]*\[Peer\]' "$WG_CONFIG" || true)
[[ $peers == 1 ]] || die "expected exactly one [Peer] in $WG_CONFIG, found $peers"

WG_ADDRESS=""
IFS=',' read -ra addrs <<<"$(conf_value Interface Address)"
for a in "${addrs[@]}"; do
  a="${a// /}"
  if [[ $a =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
    WG_ADDRESS="$a"
    break
  fi
done
[[ -n $WG_ADDRESS ]] || die "no IPv4 Address in [Interface]"

ENDPOINT="$(conf_value Peer Endpoint)"
ENDPOINT_IP="${ENDPOINT%:*}"
ENDPOINT_PORT="${ENDPOINT##*:}"
is_ipv4 "$ENDPOINT_IP" ||
  die "Endpoint must be an IPv4 address, not '$ENDPOINT_IP': resolving a hostname would need DNS outside the tunnel"
[[ $ENDPOINT_PORT =~ ^[0-9]+$ ]] || die "Endpoint has no port"
PEER_PUBKEY="$(conf_value Peer PublicKey)"
[[ -n $PEER_PUBKEY ]] || die "no PublicKey in [Peer]"

log "endpoint $ENDPOINT_IP:$ENDPOINT_PORT, tunnel address $WG_ADDRESS, netns $NETNS"

# ── 0. Clear anything left by an earlier container start in this pod ────────
ip netns del "$NETNS" 2>/dev/null || true
ip link del veth-out 2>/dev/null || true
ip link del wg0 2>/dev/null || true

# ── 1. Kill switch for the pod netns, loaded atomically before anything else ─
# One transaction: the add/delete pair replaces an old table in place, so there
# is never a moment without rules.
nft -f - <<EOF
table inet vpn_resolver
delete table inet vpn_resolver
table inet vpn_resolver {
  chain output {
    type filter hook output priority 0; policy drop;
    oif "lo" accept
    meta nfproto ipv6 drop
    ct state established,related accept
    oifname "veth-out" ip daddr $VETH_INNER_IP accept
    oifname "$POD_IF" ip daddr $ENDPOINT_IP udp dport $ENDPOINT_PORT accept
  }
  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    meta nfproto ipv6 drop
    ct state established,related accept
  }
  chain forward {
    type filter hook forward priority 0; policy drop;
    meta nfproto ipv6 drop
    ct state established,related accept
    iifname "$POD_IF" oifname "veth-out" ip saddr { $ALLOWED_CLIENTS } ip daddr $VETH_INNER_IP meta l4proto { tcp, udp } th dport 53 accept
  }
  chain prerouting {
    type nat hook prerouting priority dstnat; policy accept;
    iifname "$POD_IF" ip saddr { $ALLOWED_CLIENTS } meta l4proto { tcp, udp } th dport 53 dnat ip to $VETH_INNER_IP:53
  }
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    oifname "veth-out" ip daddr $VETH_INNER_IP masquerade
  }
}
EOF
log "pod kill switch loaded"

# DNAT into the inner netns is forwarding, so the pod netns must forward.
echo 1 >/proc/sys/net/ipv4/ip_forward

# ── 2. Inner netns ─────────────────────────────────────────────────────────
mkdir -p /run/netns /var/run/wireguard
ip netns add "$NETNS"
ip -n "$NETNS" link set lo up
ip netns exec "$NETNS" sh -c 'echo 1 > /proc/sys/net/ipv6/conf/all/disable_ipv6' 2>/dev/null || true

# Kill switch inside the inner netns too: out only via wg0, in only DNS from
# the pod side. Belt and braces on top of the routing table.
ip netns exec "$NETNS" nft -f - <<EOF
table inet vpn_inner
delete table inet vpn_inner
table inet vpn_inner {
  chain output {
    type filter hook output priority 0; policy drop;
    oif "lo" accept
    meta nfproto ipv6 drop
    oifname "wg0" accept
    oifname "veth-in" ct state established,related accept
  }
  chain input {
    type filter hook input priority 0; policy drop;
    iif "lo" accept
    meta nfproto ipv6 drop
    iifname "wg0" ct state established,related accept
    iifname "veth-in" ip saddr $VETH_OUTER_IP meta l4proto { tcp, udp } th dport 53 accept
  }
}
EOF
log "inner kill switch loaded"

# ── 3. WireGuard: create in the pod netns, configure, move inside ──────────
if [[ $WG_USERSPACE == 1 ]]; then
  # For hosts without the kernel module (and the test suite). The tun device
  # moves the same way; wireguard-go's UDP socket stays in the pod netns.
  wireguard-go wg0
else
  ip link add wg0 type wireguard
fi
wg setconf wg0 <(stripped_config)
wg set wg0 peer "$PEER_PUBKEY" persistent-keepalive "$WG_KEEPALIVE"
ip link set wg0 netns "$NETNS"
ip -n "$NETNS" addr add "$WG_ADDRESS" dev wg0
ip -n "$NETNS" link set wg0 mtu "$WG_MTU" up
ip -n "$NETNS" route add default dev wg0

# ── 4. veth pair so the pod can hand queries to the inner netns ────────────
ip link add veth-out type veth peer name veth-in netns "$NETNS"
ip addr add "$VETH_OUTER_IP/30" dev veth-out
ip link set veth-out up
ip -n "$NETNS" addr add "$VETH_INNER_IP/30" dev veth-in
ip -n "$NETNS" link set veth-in up

# ── 5. Prove the inner netns has exactly the layout we intended ────────────
links="$(ip -n "$NETNS" -o link show | awk -F': ' '{ sub(/@.*/, "", $2); print $2 }' | sort | tr '\n' ' ')"
[[ $links == "lo veth-in wg0 " ]] || die "unexpected interfaces in $NETNS: $links"

routes="$(ip -n "$NETNS" -4 route show)"
[[ $(grep -c . <<<"$routes") == 2 ]] || die "unexpected routes in $NETNS: $routes"
grep -qE '^default dev wg0( |$)' <<<"$routes" || die "default route is not via wg0: $routes"
grep -qE '^[0-9./]+ dev veth-in .*scope link' <<<"$routes" || die "missing veth link route: $routes"
if ip -n "$NETNS" -6 route show 2>/dev/null | grep -q .; then
  die "inner netns has IPv6 routes"
fi

log "ready: $NETNS has only lo, wg0 (default route) and veth-in"
