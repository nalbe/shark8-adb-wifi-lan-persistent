#!/system/bin/sh
# ADB over Wi-Fi - Persistent, LAN-only (KernelSU module), v5.2
#
# On EVERY boot:
#   1. Fences port 5555 in a dedicated ADB_WIFI chain: REJECT everything
#      (v4 + v6) BEFORE adbd is told to listen
#   2. Applies the LAN ACCEPT rule for the subnet wlan0 is on right now
#   3. Sets service.adb.tcp.port 5555 and bounces adbd, so it starts listening
#      only after the fence and the LAN rule are in place
#   4. Starts the watch.sh daemon, which retargets that ACCEPT rule on every
#      wlan0 address change, i.e. every Wi-Fi connect/disconnect
#
# Why: on this GSI/vendor mix adbd ignores adb key auth on plain TCP, so the
# iptables subnet fence IS the security boundary.
#
# Gotcha handled: `setprop ctl.restart adbd` makes init SIGKILL adbd's whole
# process group. When this script is launched from an `adb shell` session it
# lives IN that group and would die mid-run. The adbd bounce therefore runs
# in a detached setsid child.
#
# Safety (bootloop lessons from earlier versions):
#   - NO persist.adb.tcp.port  (persist property; bricked adbd on this device)
#   - NO service.adb.adb_root  (clashed with KernelSU root handling)
#   - Bounded waits only, no open-ended loops
#   - Nothing that keeps the port reachable depends on the daemon surviving:
#     step 2 is synchronous, the daemon only keeps the rule fresh afterwards
#
# Customization: create /data/adb/modules/adb_wifi/config with:
#   LAN_SUBNETS="auto"                       (default: /24 of wlan0, live-tracked)
#   LAN_SUBNETS="rfc1918"                    (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
#   LAN_SUBNETS="192.168.0.0/16 10.0.0.0/8"  (explicit list, space separated)

TB=/system/bin
MODULE_DIR=/data/adb/modules/adb_wifi
RUN_DIR=$MODULE_DIR/run
TAG=adb_wifi

# ---------------------------------------------------------------------------
# 0. Logging (root shell context writes logcat fine; ksud exec context may
#    not - failures are silently ignored, that is OK)
# ---------------------------------------------------------------------------
log() { $TB/log -p i -t "$TAG" "$1" 2>/dev/null; }

log "=== adb_wifi service start ==="

# ---------------------------------------------------------------------------
# 1. Bootstrap firewall: REJECT 5555 from everywhere (v4 + v6)
#    Idempotent, never flushes: watch.sh owns the ACCEPT rules above the
#    terminal REJECT, and wiping them here would lock the port until the next
#    wlan0 address change.
# ---------------------------------------------------------------------------
log "step 1: bootstrap"
$TB/iptables -N ADB_WIFI 2>/dev/null
$TB/iptables -C INPUT -p tcp --dport 5555 -j ADB_WIFI 2>/dev/null ||
  $TB/iptables -I INPUT 1 -p tcp --dport 5555 -j ADB_WIFI
$TB/iptables -C ADB_WIFI -j REJECT 2>/dev/null ||
  $TB/iptables -A ADB_WIFI -j REJECT

$TB/ip6tables -N ADB_WIFI6 2>/dev/null
$TB/ip6tables -C INPUT -p tcp --dport 5555 -j ADB_WIFI6 2>/dev/null ||
  $TB/ip6tables -I INPUT 1 -p tcp --dport 5555 -j ADB_WIFI6
$TB/ip6tables -C ADB_WIFI6 -j REJECT 2>/dev/null ||
  $TB/ip6tables -A ADB_WIFI6 -j REJECT

log "firewall bootstrap: REJECT 5555 installed"

# ---------------------------------------------------------------------------
# 2. LAN policy for this boot, synchronous: the port has to be reachable the
#    moment adbd starts listening, so the daemon stays off this path
# ---------------------------------------------------------------------------
log "step 2: lan policy"
$TB/sh "$MODULE_DIR/watch.sh" once

# ---------------------------------------------------------------------------
# 3. adbd on TCP 5555, bounced in a DETACHED child (survives the
#    process-group kill init sends when ctl.restart fires)
# ---------------------------------------------------------------------------
log "step 3: adbd"
setprop service.adb.tcp.port 5555
setsid sh -c 'sleep 2; setprop ctl.restart adbd' &

# ---------------------------------------------------------------------------
# 4. LAN policy daemon for later Wi-Fi changes
# ---------------------------------------------------------------------------
log "step 4: watcher"
mkdir -p "$RUN_DIR"
if [ -f "$RUN_DIR/watch.pid" ]; then
  OLD=$(cat "$RUN_DIR/watch.pid" 2>/dev/null)
  if [ -n "$OLD" ]; then
    kill "$OLD" 2>/dev/null
  fi
  rm -f "$RUN_DIR/watch.pid"
fi
setsid $TB/sh "$MODULE_DIR/watch.sh" </dev/null >/dev/null 2>&1 &

log "=== adb_wifi service end ==="
