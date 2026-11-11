# vpn-resolver-watchdog: restart the container when the tunnel goes stale.
#
# Restarting is the whole remedy: Kubernetes restarts the container, setup
# rebuilds the netns and tunnel from scratch, and the kill switches stay in
# force the whole time, so a broken tunnel can only mean no answers.

NETNS="${NETNS:-vpn}"
WG_MAX_HANDSHAKE_AGE="${WG_MAX_HANDSHAKE_AGE:-300}"
WG_STARTUP_GRACE="${WG_STARTUP_GRACE:-60}"
WATCHDOG_INTERVAL="${WATCHDOG_INTERVAL:-15}"
WATCHDOG_KILL_PID="${WATCHDOG_KILL_PID:-1}"

log() { echo "[vpn-resolver-watchdog] $*" >&2; }

sleep "$WG_STARTUP_GRACE"
while true; do
  last="$(ip netns exec "$NETNS" wg show wg0 latest-handshakes 2>/dev/null | awk '{ print $2; exit }')"
  now="$(date +%s)"
  if [[ -z $last || $last == 0 ]]; then
    age="never"
  else
    age=$((now - last))
  fi
  if [[ $age == never ]] || ((age > WG_MAX_HANDSHAKE_AGE)); then
    log "last handshake: $age (limit ${WG_MAX_HANDSHAKE_AGE}s), restarting the container"
    kill -TERM "$WATCHDOG_KILL_PID"
    exit 1
  fi
  sleep "$WATCHDOG_INTERVAL"
done
