# nix-container-image-vpn-resolver

A DNS resolver container that can only ever reach the internet through a
WireGuard tunnel. Built with Nix. It's meant to run as a pod in the home
Kubernetes cluster, one pod per VPN server, behind CoreDNS.

## How it stops leaks

A query can only get out by passing three separate barriers. Each one fails
closed on its own:

1. **No route.** Unbound runs in its own network namespace (`vpn`). Its only
   interfaces are `lo`, `wg0`, and a /30 veth link back to the pod, and its
   only default route is `wg0`. Following
   [WireGuard's namespace pattern](https://www.wireguard.com/netns/), `wg0` is
   created in the pod's namespace and then moved, so the encrypted UDP socket
   stays outside while the cleartext side sits inside. If the tunnel goes away,
   Unbound gets "network unreachable". It has nowhere else to send a query.
2. **nftables in both namespaces**, each loaded as a single atomic `nft -f`
   before WireGuard or Unbound start. The pod namespace may only send UDP to
   the WireGuard endpoint IP and port, and hand DNS to the inner namespace. The
   inner namespace may only send out through `wg0`. IPv6 is dropped everywhere.
3. **CiliumNetworkPolicy** outside the pod (see
   [examples/kubernetes.yaml](examples/kubernetes.yaml)). The pod can only send
   WireGuard to its own endpoint, whatever happens inside the container.

On top of that, every upstream query is DNS-over-TLS (Quad9 and Cloudflare by
default), and the endpoint must be an IP address, so no hostname ever needs
resolving outside the tunnel.

```
           pod network namespace                       inner namespace "vpn"
 CoreDNS ─▶ eth0 :53 ─DNAT─▶ veth-out 169.254.53.1 ═══ veth-in 169.254.53.2 ─▶ Unbound
            eth0 ◀── UDP 51820 to the endpoint only ◀═ wg0 (default route) ◀───┘
```

## What happens at start-up

`vpn-resolver-entrypoint` runs `vpn-resolver-setup`, which does this in order:

1. Parses `/etc/wireguard/wg0.conf` (wg-quick format, exactly as Proton hands
   it out). It refuses a hostname endpoint or more than one peer.
2. Loads the pod kill switch.
3. Creates the `vpn` namespace and its kill switch.
4. Creates `wg0`, configures it (with a 25-second keepalive), moves it into
   `vpn`, and adds the default route.
5. Adds the veth pair, with DNAT and masquerade so the inner namespace never
   needs a route to the pod network.
6. Checks that the inner namespace has exactly `lo`, `veth-in` and `wg0`, and
   exactly two routes. If not, it refuses to start.

It then starts `vpn-resolver-watchdog`, which restarts the container if the
last handshake is older than 5 minutes, and `exec`s Unbound inside `vpn` as
PID 1. Unbound drops to `nobody` after binding port 53. A container restart
rebuilds everything, and the old kill switch stays in place until the new one
replaces it.

`vpn-resolver-check` is the readiness and liveness probe. It succeeds only if
a real query comes back NOERROR through the tunnel.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `WG_CONFIG` | `/etc/wireguard/wg0.conf` | WireGuard config (mount it from a Secret) |
| `ALLOWED_CLIENTS` | `10.42.0.0/16` | Comma-separated sources that may query: the pod CIDR, plus node IPs if CoreDNS uses hostNetwork |
| `POD_IF` | `eth0` | The pod's CNI interface |
| `UPSTREAMS` | Quad9 + Cloudflare on 853 | Space-separated Unbound `forward-addr` entries |
| `FORWARD_TLS` | `yes` | DNS-over-TLS to the upstreams |
| `WG_MAX_HANDSHAKE_AGE` | `300` | Seconds before the watchdog restarts the container |
| `WG_USERSPACE` | `0` | `1` uses wireguard-go instead of the kernel module |
| `PROBE_NAME` | `cloudflare.com` | Name the probe resolves |

The container needs `privileged: true` (network namespaces, WireGuard,
nftables). Keep it in a namespace of its own.

## Building and testing

```bash
just build   # nix build .#container and podman load
just test    # namespace leak test as root (wireguard-go)
just test 0  # the same with the kernel WireGuard module
```

The leak test (`tests/netns-test.sh`) builds a fake LAN, VPN provider and
public resolver out of network namespaces. It then checks:

- Queries resolve through the tunnel.
- The inner namespace holds only the expected interfaces.
- Nothing except WireGuard ever leaves the pod, even when the pod tries to
  reach a public resolver directly.
- With `wg0` deleted, the inner namespace reports "network unreachable" and
  uncached names fail.
- As a control, the leak counter does catch a deliberate leak once the kill
  switch is removed.

CI runs it with both kernel and userspace WireGuard on every push, and pushes
the image to `ghcr.io/alisonjenkins/vpn-resolver` from `main`.
