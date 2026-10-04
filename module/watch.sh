#!/system/bin/sh
# ADB over Wi-Fi - LAN policy applier/watcher (KernelSU module), v5.1
#
#   watch.sh once    apply the LAN policy now and exit  (boot path, no daemon)
#   watch.sh         apply it, then follow wlan0 address events forever
#
# The netlink event behind "watch" is wlan0 gaining/losing an IPv4 address,
# i.e. Wi-Fi connecting/disconnecting, so the ACCEPT list always describes the
# network the phone is actually on. The terminal REJECT rule is never removed:
# while the list is rewritten, port 5555 stays closed to everyone else.

TB=/system/bin
TAG=adb_wifi
MODULE_DIR=/data/adb/modules/adb_wifi
CONFIG=$MODULE_DIR/config
RUN_DIR=$MODULE_DIR/run
PIDFILE=$RUN_DIR/watch.pid
FIFO=$RUN_DIR/wlan0-events
IFACE=wlan0
WAIT_TRIES=20
WAIT_SLEEP=2

log() { $TB/log -p i -t "$TAG" "$1" 2>/dev/null; }

# /24 of the interface's current IPv4 address, empty when it has none
lan_subnet() {
  $TB/ip -f inet addr show "$IFACE" 2>/dev/null | awk '/inet /{print $2; exit}' |
    awk -F. '{print $1"."$2"."$3".0/24"}'
}

wait_for_address() {
  i=0
  while [ -z "$SUBNET" ] && [ "$i" -lt "$WAIT_TRIES" ]; do
    SUBNET=$(lan_subnet)
    [ -n "$SUBNET" ] && return 0
    sleep "$WAIT_SLEEP"
    i=$((i + 1))
  done
  [ -n "$SUBNET" ]
}

drop_accepts() {
  $TB/iptables -S ADB_WIFI 2>/dev/null | grep -- ' -j ACCEPT$' | while read -r rule; do
    $TB/iptables -D ADB_WIFI ${rule#-A ADB_WIFI } 2>/dev/null
  done
}

apply() {
  drop_accepts
  for s in $1; do
    $TB/iptables -I ADB_WIFI 1 -s "$s" -j ACCEPT
  done
  log "5555 accept=[$1]"
}

LAN_SUBNETS=auto
if [ -f "$CONFIG" ]; then
  . "$CONFIG"
fi

SUBNET=
case "$LAN_SUBNETS" in
  ""|auto)
    wait_for_address
    if [ -n "$SUBNET" ]; then
      apply "$SUBNET"
    else
      log "no address on $IFACE, 5555 stays closed"
      exit 1
    fi
    ;;
  rfc1918)
    apply "10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
    ;;
  *)
    apply "$LAN_SUBNETS"
    ;;
esac

if [ "$1" = once ]; then
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
CURRENT=$SUBNET
while read -r _event; do
  NEW=$(lan_subnet)
  [ "$NEW" = "$CURRENT" ] && continue
  apply "$NEW"
  CURRENT=$NEW
done < "$FIFO"
