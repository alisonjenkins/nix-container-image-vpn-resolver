# vpn-resolver-check: readiness/liveness probe. Succeeds only if a real query
# resolves through the inner netns, i.e. through the tunnel.

VETH_INNER_IP="${VETH_INNER_IP:-169.254.53.2}"
PROBE_NAME="${PROBE_NAME:-cloudflare.com}"

out="$(dig @"$VETH_INNER_IP" "$PROBE_NAME" A +time=3 +tries=1 +noall +comments)"
grep -q 'status: NOERROR' <<<"$out"
