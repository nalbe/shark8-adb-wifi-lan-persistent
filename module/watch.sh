#!/system/bin/sh
# ADB over Wi-Fi - LAN policy applier/watcher
#
#   watch.sh once    apply the LAN policy now and exit  (boot path, no daemon)
#   watch.sh         apply it, then follow wlan0 address events forever
#
# The netlink event behind "watch" is wlan0 gaining/losing an address, i.e.
# Wi-Fi connecting/disconnecting, so the ACCEPT lists always describe the
# network the phone is actually on. The terminal REJECT rules are never
# removed: while the lists are rewritten, the port stays closed to everyone
# else. A policy that resolves to nothing (auto with no address, or none)
# installs no ACCEPT at all, which closes the port rather than leaving the
# previous network's ranges in place.

MODE=$1
MODULE_DIR=${0%/*}
. "$MODULE_DIR/common.sh"

PIDFILE=$RUN_DIR/watch.pid
FIFO=$RUN_DIR/wlan0-events
WAIT_TRIES=20
WAIT_SLEEP=2

# /24 of the interface's current IPv4 address, empty when it has none.
# Consumer Wi-Fi is invariably a /24; a bigger LAN belongs in the config as an
# explicit list.
lan_subnet() {
  $TB/ip -f inet addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}' |
    awk -F. '{print $1"."$2"."$3".0/24"}'
}

# /64 of the first global IPv6 address, host bits zeroed. Link-local is
# skipped: it only ever reaches neighbours on the same link.
lan6_subnet() {
  $TB/ip -f inet6 addr show "$IFACE" 2>/dev/null | awk '
    function expand(a,   side, lp, rp, l, r, i) {
      if (index(a, "::") > 0) {
        split(a, side, "::")
        l = split(side[1], lp, ":")
        r = split(side[2], rp, ":")
        for (i = 1; i <= l; i++) f[i] = lp[i]
        for (i = l + 1; i <= 8 - r; i++) f[i] = "0"
        for (i = 1; i <= r; i++) f[8 - r + i] = rp[i]
      } else {
        split(a, f, ":")
      }
    }
    /inet6 / {
      split($2, ab, "/")
      if (ab[1] ~ /^fe80:/) next
      expand(ab[1])
      p = f[1] ":" f[2] ":" f[3] ":" f[4]
      sub(/:0+$/, "", p)
      print p "::/64"
      exit
    }'
}

wait_for_address() {
  i=0
  while [ "$i" -lt "$WAIT_TRIES" ]; do
    SUBNET=$(lan_subnet)
    [ -n "$SUBNET" ] && return 0
    sleep "$WAIT_SLEEP"
    i=$((i + 1))
  done
  SUBNET=$(lan_subnet)
  return 1
}

drop_accepts() {
  $TB/"$1" -S "$2" 2>/dev/null | grep -- ' -j ACCEPT$' | while read -r rule; do
    $TB/"$1" -D "$2" ${rule#-A $2 } 2>/dev/null
  done
}

apply() {
  drop_accepts iptables ADB_WIFI
  for s in $1; do
    $TB/iptables -I ADB_WIFI 1 -s "$s" -j ACCEPT
  done
  drop_accepts ip6tables ADB_WIFI6
  for s in $2; do
    $TB/ip6tables -I ADB_WIFI6 1 -s "$s" -j ACCEPT
  done
  log "port $ADB_PORT accept4=[$1] accept6=[$2]"
}

v4_list() {
  case $LAN_SUBNETS in
    auto)
      if wait_for_address; then printf '%s' "$SUBNET"; fi
      ;;
    none) ;;
    *) printf '%s' "$LAN_SUBNETS" ;;
  esac
}

v6_list() {
  case $IPV6_SUBNETS in
    auto) lan6_subnet ;;
    off) ;;
    *) printf '%s' "$IPV6_SUBNETS" ;;
  esac
}

refresh() {
  NEW4=$(v4_list)
  NEW6=$(v6_list)
  NOW="[$NEW4][$NEW6]"
  [ "$NOW" = "$LAST" ] && return 0
  apply "$NEW4" "$NEW6"
  LAST=$NOW
  if [ -z "$NEW4" ] && [ -z "$NEW6" ]; then
    log "no allowed range resolved, port $ADB_PORT stays closed"
  fi
}

# service.sh applies the boot policy through us, so a broken config has to be
# loud here rather than quietly leaving the previous policy in place
cfg_load
LAST=
refresh

if [ "$MODE" = once ]; then
  exit 0
fi

mkdir -p "$RUN_DIR"
echo $$ > "$PIDFILE"

rm -f "$FIFO"
mkfifo "$FIFO"
$TB/ip monitor address dev "$IFACE" > "$FIFO" &
MON_PID=$!
trap 'kill "$MON_PID" 2>/dev/null; rm -f "$FIFO" "$PIDFILE"; exit 0' TERM INT

log "watching $IFACE for address changes"
while read -r _event; do
  logv "event: $_event"
  refresh
done < "$FIFO"
