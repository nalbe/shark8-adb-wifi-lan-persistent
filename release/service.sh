#!/system/bin/sh
# ADB over Wi-Fi - Persistent, LAN-only (KernelSU module)
#
# On EVERY boot:
#   1. Brings adbd up on TCP port 5555 (plain transport, no TLS pairing)
#   2. Firewalls port 5555 to accept connections ONLY from the LAN,
#      rejecting everything else (IPv4 + IPv6). USB adb stays untouched.
#
# Why this exists:
#   On some builds (GSI on stock vendor, ro.debuggable=1) adbd does NOT
#   enforce adb key auth on plain TCP. persist.adb.secure,
#   persist.adb.authorization and adb_keys were all tested and ignored.
#   The iptables subnet fence below is therefore the ONLY real protection,
#   and it is smarter than key auth anyway: it does not depend on build behavior.
#
# Safety (bootloop lessons from an earlier version):
#   - NO persist.adb.tcp.port  (persist property; bricked adbd on this device)
#   - NO service.adb.adb_root  (clashed with KernelSU root handling)
#   - Bounded boot-wait only, never an infinite loop.
#
# Customization: create /data/adb/modules/adb_wifi/config with:
#   LAN_SUBNETS="auto"                       (default: /24 of wlan0 interface)
#   LAN_SUBNETS="rfc1918"                    (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16)
#   LAN_SUBNETS="192.168.0.0/16 10.0.0.0/8"  (explicit list, space separated)

# ---------------------------------------------------------------------------
# 1. Wait for boot to settle (bounded, max ~60s)
# ---------------------------------------------------------------------------
i=0
while [ "$(getprop sys.boot_completed)" != "1" ] && [ "$i" -lt 30 ]; do
  sleep 2
  i=$((i + 1))
done
sleep 5

# ---------------------------------------------------------------------------
# 2. Modular LAN policy
# ---------------------------------------------------------------------------
CONFIG=/data/adb/modules/adb_wifi/config
LAN_SUBNETS="auto"

if [ -f "$CONFIG" ]; then
  . "$CONFIG"
fi

case "$LAN_SUBNETS" in
  ""|auto)
    WLAN_IP=$(ip -f inet addr show wlan0 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
    # Fallback: first three octets of any non-default route as a sane default
    if [ -z "$WLAN_IP" ]; then
      WLAN_IP=$(ip route 2>/dev/null | awk '$1=="default"{print $5; exit}' | xargs -r -I{} ip -f inet addr show {} 2>/dev/null | awk '/inet /{print $2; exit}' | cut -d/ -f1)
    fi
    if [ -z "$WLAN_IP" ]; then
      WLAN_IP=192.168.1.17
    fi
    LAN_SUBNETS=$(echo "$WLAN_IP" | awk -F. '{print $1"."$2"."$3".0/24"}')
    ;;
  rfc1918)
    LAN_SUBNETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16"
    ;;
esac

# ---------------------------------------------------------------------------
# 3. Enable adbd on TCP 5555
# ---------------------------------------------------------------------------
setprop service.adb.tcp.port 5555
setprop ctl.restart adbd

# ---------------------------------------------------------------------------
# 4. Firewall: ACCEPT 5555 from the allowed subnets, REJECT the rest (v4)
# ---------------------------------------------------------------------------
# Clean up leftovers from previous runs
for s in $LAN_SUBNETS; do
  iptables -D INPUT -p tcp --dport 5555 -s "$s" -j ACCEPT 2>/dev/null
done
iptables -D INPUT -p tcp --dport 5555 -j REJECT 2>/dev/null

# Insert ACCEPT rules at the top of INPUT, one per subnet
for s in $LAN_SUBNETS; do
  iptables -I INPUT 1 -p tcp --dport 5555 -s "$s" -j ACCEPT
done

# REJECT sits right below the last ACCEPT rule (positions 1..N taken)
count=$(echo "$LAN_SUBNETS" | wc -w)
iptables -I INPUT $((count + 1)) -p tcp --dport 5555 -j REJECT

# ---------------------------------------------------------------------------
# 5. IPv6: no LAN clients expected, reject outright
# ---------------------------------------------------------------------------
ip6tables -D INPUT -p tcp --dport 5555 -j REJECT 2>/dev/null
ip6tables -I INPUT 1 -p tcp --dport 5555 -j REJECT

log -p i -t adb_wifi "ADB over Wi-Fi on 5555, LAN-only: $LAN_SUBNETS"