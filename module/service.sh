#!/system/bin/sh
# ADB over Wi-Fi - Persistent, LAN-only (KernelSU module)
#
# On EVERY boot:
#   1. Fences the configured port in a dedicated ADB_WIFI chain: REJECT
#      everything (v4 + v6) BEFORE adbd is told to listen
#   2. Applies the LAN policy for the network wlan0 is on right now
#   3. Sets service.adb.tcp.port and bounces adbd, so it starts listening only
#      after the fence and the LAN rule are in place
#   4. Starts the watch.sh daemon, which retargets that policy on every wlan0
#      address change, i.e. every Wi-Fi connect/disconnect
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
#   - Step 1 is read back: adbd is never started on a fence that did not install
#   - Nothing that keeps the port reachable depends on the daemon surviving:
#     step 2 is synchronous, the daemon only keeps the rule fresh afterwards

MODULE_DIR=${0%/*}
. "$MODULE_DIR/common.sh"
cfg_load

log "=== adb_wifi service start (port $ADB_PORT) ==="

# ---------------------------------------------------------------------------
# 1. Bootstrap firewall: REJECT the configured port from everywhere (v4 + v6).
#    Jumps into our chains for other ports are leftovers of an ADB_PORT change
#    and go away here, so only the port we serve is fenced.
# ---------------------------------------------------------------------------
log "step 1: bootstrap"
$TB/iptables -N ADB_WIFI 2>/dev/null
$TB/iptables -S INPUT 2>/dev/null | grep -- ' -j ADB_WIFI$' | while read -r _rule; do
  case $_rule in
    *"--dport $ADB_PORT "*) ;;
    *) $TB/iptables -D INPUT ${_rule#-A INPUT } 2>/dev/null
       log "stale fence dropped: $_rule" ;;
  esac
done
$TB/iptables -C INPUT -p tcp --dport "$ADB_PORT" -j ADB_WIFI 2>/dev/null ||
  $TB/iptables -I INPUT 1 -p tcp --dport "$ADB_PORT" -j ADB_WIFI
$TB/iptables -C ADB_WIFI -j REJECT 2>/dev/null ||
  $TB/iptables -A ADB_WIFI -j REJECT

$TB/ip6tables -N ADB_WIFI6 2>/dev/null
$TB/ip6tables -S INPUT 2>/dev/null | grep -- ' -j ADB_WIFI6$' | while read -r _rule; do
  case $_rule in
    *"--dport $ADB_PORT "*) ;;
    *) $TB/ip6tables -D INPUT ${_rule#-A INPUT } 2>/dev/null
       log "stale fence dropped: $_rule" ;;
  esac
done
$TB/ip6tables -C INPUT -p tcp --dport "$ADB_PORT" -j ADB_WIFI6 2>/dev/null ||
  $TB/ip6tables -I INPUT 1 -p tcp --dport "$ADB_PORT" -j ADB_WIFI6
$TB/ip6tables -C ADB_WIFI6 -j REJECT 2>/dev/null ||
  $TB/ip6tables -A ADB_WIFI6 -j REJECT

# The fence is the security boundary, so it is read back before adbd is told to
# listen: a rule that did not install would leave the port open to everyone
if $TB/iptables -C INPUT -p tcp --dport "$ADB_PORT" -j ADB_WIFI 2>/dev/null &&
   $TB/iptables -C ADB_WIFI -j REJECT 2>/dev/null &&
   $TB/ip6tables -C INPUT -p tcp --dport "$ADB_PORT" -j ADB_WIFI6 2>/dev/null &&
   $TB/ip6tables -C ADB_WIFI6 -j REJECT 2>/dev/null; then
  log "firewall bootstrap: REJECT $ADB_PORT verified"
else
  die "fence for port $ADB_PORT did not install, adbd stays off the network"
fi

# Android's own Wireless debugging is a second door, on a port this module knows
# nothing about, so it can only be reported
_tls=$(getprop service.adb.tls.port 2>/dev/null)
case $_tls in
    0|'') ;;
    *) log "WARNING: Android Wireless debugging listens on port $_tls, outside this fence: turn it off in Developer options" ;;
esac

# ---------------------------------------------------------------------------
# 2. LAN policy for this boot, synchronous: the port has to be reachable the
#    moment adbd starts listening, so the daemon stays off this path
# ---------------------------------------------------------------------------
log "step 2: lan policy"
$TB/sh "$MODULE_DIR/watch.sh" once

# ---------------------------------------------------------------------------
# 3. adbd on the configured port, bounced in a DETACHED child (survives the
#    process-group kill init sends when ctl.restart fires)
# ---------------------------------------------------------------------------
log "step 3: adbd"
setprop service.adb.tcp.port "$ADB_PORT"
setsid sh -c 'sleep 2; setprop ctl.restart adbd' &

# ---------------------------------------------------------------------------
# 4. LAN policy daemon for later Wi-Fi changes
# ---------------------------------------------------------------------------
log "step 4: watcher"
mkdir -p "$RUN_DIR"
# the pidfile survives a reboot and pids are recycled, so it is only ever
# signalled when the process behind it really is the watcher
OLD=$(cat "$RUN_DIR/watch.pid" 2>/dev/null)
if [ -n "$OLD" ] && grep -q "watch.sh" "/proc/$OLD/cmdline" 2>/dev/null; then
  kill "$OLD" 2>/dev/null
fi
rm -f "$RUN_DIR/watch.pid"
setsid $TB/sh "$MODULE_DIR/watch.sh" </dev/null >/dev/null 2>&1 &

log "=== adb_wifi service end ==="
