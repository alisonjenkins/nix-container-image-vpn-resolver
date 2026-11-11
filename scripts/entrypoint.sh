# vpn-resolver-entrypoint: build the netns layout, start the watchdog, then
# run Unbound inside the inner netns as PID 1.

NETNS="${NETNS:-vpn}"
VETH_OUTER_IP="${VETH_OUTER_IP:-169.254.53.1}"
VETH_INNER_IP="${VETH_INNER_IP:-169.254.53.2}"
UNBOUND_DIR="${UNBOUND_DIR:-/var/lib/unbound}"
UNBOUND_USER="${UNBOUND_USER:-nobody}"
# Space-separated Unbound forward-addr entries (addr@port#tls-name).
UPSTREAMS="${UPSTREAMS:-9.9.9.9@853#dns.quad9.net 149.112.112.112@853#dns.quad9.net 1.1.1.1@853#cloudflare-dns.com 1.0.0.1@853#cloudflare-dns.com}"
FORWARD_TLS="${FORWARD_TLS:-yes}"
WATCHDOG="${WATCHDOG:-1}"
# DNSSEC validation. Only the test suite turns it off (its fake zone is unsigned).
DNSSEC="${DNSSEC:-yes}"

vpn-resolver-setup

mkdir -p "$UNBOUND_DIR"
[[ -f $UNBOUND_DIR/root.key ]] || cp @rootKey@ "$UNBOUND_DIR/root.key"
chmod u+w "$UNBOUND_DIR/root.key"
chown -R "$UNBOUND_USER" "$UNBOUND_DIR"

conf="$UNBOUND_DIR/unbound.conf"
{
  cat <<CONF
server:
    chroot: ""
    username: "$UNBOUND_USER"
    directory: "$UNBOUND_DIR"
    pidfile: ""
    use-syslog: no
    logfile: ""
    verbosity: 1
    log-queries: no

    interface: $VETH_INNER_IP
    port: 53
    do-ip4: yes
    do-ip6: no
    do-udp: yes
    do-tcp: yes

    access-control: 0.0.0.0/0 refuse
    access-control: $VETH_OUTER_IP/32 allow

    num-threads: 2
    msg-cache-size: 64m
    rrset-cache-size: 128m
    cache-min-ttl: 60
    cache-max-ttl: 86400
    prefetch: yes
    prefetch-key: yes
    serve-expired: yes
    serve-expired-ttl: 3600

    hide-identity: yes
    hide-version: yes
    harden-glue: yes
    harden-dnssec-stripped: yes
    harden-below-nxdomain: yes
    harden-referral-path: yes
    use-caps-for-id: yes
    qname-minimisation: yes

CONF
  if [[ $DNSSEC == yes ]]; then
    cat <<CONF
    auto-trust-anchor-file: "$UNBOUND_DIR/root.key"
    val-clean-additional: yes
CONF
  else
    echo '    module-config: "iterator"'
  fi
  cat <<CONF
    tls-cert-bundle: "@caBundle@"

forward-zone:
    name: "."
    forward-tls-upstream: $FORWARD_TLS
CONF
  for u in $UPSTREAMS; do
    echo "    forward-addr: $u"
  done
} >"$conf"

if [[ $WATCHDOG == 1 ]]; then
  vpn-resolver-watchdog &
fi

echo "[vpn-resolver-entrypoint] starting unbound in netns $NETNS" >&2
exec ip netns exec "$NETNS" unbound -d -c "$conf"
