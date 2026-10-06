#!/bin/sh
# Harness for module/common.sh, module/watch.sh, module/service.sh.
# Runs the scripts against a stub iptables/ip/log set so the config parser, the
# policy resolution and the fence bookkeeping can be checked off-device.
# Usage: sh run-tests.sh <path-to-module-dir>

SRC=${1:?module dir}
BASE=$(cd "$(dirname "$0")" && pwd)/sandbox
MOD=$BASE/mod
STUBS=$BASE/stubs
RULES=$BASE/rules
PATH="$STUBS:$PATH"
export PATH
export FWLOG=$BASE/fw.log
export BASE_OUT=$BASE/out.log
export RULES_DIR=$RULES
export IPV4_OUT=$BASE/ip4.txt
export IPV6_OUT=$BASE/ip6.txt
export IW_OUT=$BASE/iw.out
export MON_OUT=$BASE/mon.out
export MON_COUNT=$BASE/mon.count
export MON_EXIT=
export GETPROP_DIR=$BASE/props
export IFACE_PATH=$BASE/iface

rm -rf "$BASE"
mkdir -p "$MOD" "$STUBS" "$RULES" "$GETPROP_DIR"
export BASE
cp "$SRC/common.sh" "$SRC/watch.sh" "$SRC/service.sh" "$MOD/"

# point the scripts at the stubs and shrink the boot wait for the tests
sed -i "s|^TB=/system/bin$|TB=$STUBS|" "$MOD/common.sh"
sed -i "s|^WAIT_TRIES=20$|WAIT_TRIES=1|; s|^WAIT_SLEEP=2$|WAIT_SLEEP=0|" "$MOD/watch.sh"
sed -i "s|^IFACE_PATH=/sys/class/net/\$IFACE$|IFACE_PATH=$IFACE_PATH|" "$MOD/common.sh"
if ! grep -q "^TB=$STUBS\$" "$MOD/common.sh"; then
  echo "FATAL: TB rewrite failed"
  exit 1
fi
if ! grep -q "^IFACE_PATH=$IFACE_PATH\$" "$MOD/common.sh"; then
  echo "FATAL: IFACE_PATH rewrite failed"
  exit 1
fi

cat > "$STUBS/log" <<'EOF'
#!/bin/sh
echo "LOG $*" >> "$BASE_OUT"
EOF

cat > "$STUBS/setprop" <<'EOF'
#!/bin/sh
echo "setprop $*" >> "$BASE_OUT"
EOF

cat > "$STUBS/getprop" <<'EOF'
#!/bin/sh
cat "$GETPROP_DIR/$1" 2>/dev/null
EOF

cat > "$STUBS/setsid" <<'EOF'
#!/bin/sh
echo "setsid $*" >> "$BASE_OUT"
EOF

cat > "$STUBS/sh" <<'EOF'
#!/bin/sh
exec /usr/bin/sh "$@"
EOF

cat > "$STUBS/ip" <<'EOF'
#!/bin/sh
if [ "$1" = -f ]; then
  case "$2 $3" in
    "inet addr")  cat "$IPV4_OUT" 2>/dev/null ;;
    "inet6 addr") cat "$IPV6_OUT" 2>/dev/null ;;
  esac
  exit 0
fi
case "$1 $2" in
  "monitor address"|"monitor all")
    n=$(cat "$MON_COUNT" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" > "$MON_COUNT"
    if [ -n "$MON_EXIT" ] && [ "$n" -le "$MON_EXIT" ]; then exit 0; fi
    trap 'exit 0' TERM INT
    while :; do
      cat "$MON_OUT" 2>/dev/null
      sleep 1
    done ;;
  *) : ;;
esac
EOF

# iw dev wlan0 link, driven by a file so a test can put the phone on any network
cat > "$STUBS/iw" <<'EOF'
#!/bin/sh
cat "$IW_OUT" 2>/dev/null
EOF

# iptables emulator: -N -A -I -C -D -S, one rule file per chain, matching the
# -p tcp / -m tcp normalization the real binary does
cat > "$STUBS/iptables" <<'EOF'
#!/bin/sh
name=$(basename "$0")
echo "$name $*" >> "$FWLOG"
op=$1; shift
chain=$1; shift
f=$RULES_DIR/$chain
if [ "$1" = "${1%%[!0-9]*}" ]; then shift; fi
rule() {
  s=$(printf '%s' "$*" | sed 's/ -m tcp//g')
  printf -- '-A %s' "$chain"
  prev=
  for w in $s; do
    printf -- ' %s' "$w"
    if [ "$w" = tcp ] && [ "$prev" = -p ]; then printf -- ' -m tcp'; fi
    prev=$w
  done
}
case $op in
  -N) [ -f "$f" ] || : > "$f"; exit 0 ;;
  -S) [ -f "$f" ] && cat "$f"; exit 0 ;;
  -C)
    r=$(rule "$@")
    if [ -f "$f" ] && grep -qxF -- "$r" "$f"; then exit 0; fi
    exit 1 ;;
  -A) r=$(rule "$@"); echo "$r" >> "$f"; exit 0 ;;
  -I) r=$(rule "$@"); { echo "$r"; [ -f "$f" ] && cat "$f"; } > "$f.new"; mv "$f.new" "$f"; exit 0 ;;
  -D)
    r=$(rule "$@")
    if [ -f "$f" ]; then grep -vxF -- "$r" "$f" > "$f.new"; mv "$f.new" "$f"; fi
    exit 0 ;;
esac
exit 0
EOF
cp "$STUBS/iptables" "$STUBS/ip6tables"
chmod 755 "$STUBS"/*

cat > "$BASE/ip4.default" <<'EOF'
2: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP
    inet 192.168.1.42/24 brd 192.168.1.255 scope global wlan0
EOF

cat > "$BASE/ip6.default" <<'EOF'
2: wlan0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 state UP
    inet6 fe80::9a1b/64 scope link
    inet6 fd12:3456:789a::42/64 scope global
    inet6 fd12:3456:789a:abcd:1111:2222:3333:4444/64 scope global
EOF
cp "$BASE/ip4.default" "$IPV4_OUT"
cp "$BASE/ip6.default" "$IPV6_OUT"

cat > "$BASE/iw.default" <<'EOF'
Connected to 00:eb:d8:60:0f:84 (on wlan0)
	SSID: openwrt
	freq: 5240
	signal: -65 dBm
EOF
cp "$BASE/iw.default" "$IW_OUT"

# service.adb.tls.port, 0 while Wireless debugging is off
echo 0 > "$GETPROP_DIR/service.adb.tls.port"

cat > "$BASE/mon.default" <<'EOF'
[ADDR]Deleted 38: wlan0    inet 192.168.1.42/24 scope global wlan0
EOF
cp "$BASE/mon.default" "$MON_OUT"

FAIL=0
PASS=0

reset_env() {
  : > "$FWLOG"
  : > "$BASE_OUT"
  rm -f "$MOD/config" "$MON_COUNT"
  MON_EXIT=
  export MON_EXIT
  : > "$IFACE_PATH"
  cp "$BASE/ip4.default" "$IPV4_OUT"
  cp "$BASE/ip6.default" "$IPV6_OUT"
  cp "$BASE/iw.default" "$IW_OUT"
  cp "$BASE/mon.default" "$MON_OUT"
  echo 0 > "$GETPROP_DIR/service.adb.tls.port"
}

chain_state() {
  if [ -f "$RULES_DIR/$1" ]; then cat "$RULES_DIR/$1"; fi
}

check() { # description, pattern, file, expect-hit(1|0)
  if grep -q -- "$2" "$3" 2>/dev/null; then hit=1; else hit=0; fi
  if [ "$hit" = "$4" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1 (pattern: $2, expected present=$4)"
    echo "  --- $(basename "$3") ---"
    sed 's/^/  | /' "$3" 2>/dev/null
  fi
}

check_chain() { # description, chain, expected rule lines on stdin
  expected=$(cat)
  actual=$(chain_state "$2")
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $1"
    echo "  --- expected $2 ---"
    printf '%s\n' "$expected" | sed 's/^/  > /'
    echo "  --- actual $2 ---"
    printf '%s\n' "$actual" | sed 's/^/  | /'
  fi
}

echo "== auto v4, no v6 =="
reset_env
: > "$RULES/INPUT"
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 10.10.0.0/16 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
: > "$RULES/ADB_WIFI6"
"$STUBS/sh" "$MOD/watch.sh" once
check_chain "v4 chain holds the live subnet above the reject" ADB_WIFI <<'EOF'
-A ADB_WIFI -s 192.168.1.0/24 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
check_chain "v6 chain untouched, nothing accepted" ADB_WIFI6 </dev/null
check "policy logged with port" "port 5555 gate=subnet net=\[-/-\] accept4=\[192.168.1.0/24\] accept6=\[\]" "$BASE_OUT" 1

echo "== ipv6 auto takes the first global prefix, host bits zeroed =="
reset_env
echo "IPV6_SUBNETS=auto" > "$MOD/config"
"$STUBS/sh" "$MOD/watch.sh" once
check "v6 accept" "ip6tables -I ADB_WIFI6 1 -s fd12:3456:789a::/64 -j ACCEPT" "$FWLOG" 1
check "link-local skipped" "fe80" "$FWLOG" 0
check "host bits not leaked" "::42\|abcd:1111" "$FWLOG" 0

echo "== LAN_SUBNETS=none closes the port =="
reset_env
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 10.10.0.0/16 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
printf 'LAN_SUBNETS="none"\n' > "$MOD/config"
"$STUBS/sh" "$MOD/watch.sh" once
check_chain "only the terminal reject is left" ADB_WIFI <<'EOF'
-A ADB_WIFI -j REJECT
EOF
check "closed state logged" "accept4=\[\] accept6=\[\]" "$BASE_OUT" 1

echo "== explicit v4 list, two ranges =="
reset_env
echo 'LAN_SUBNETS="192.168.0.0/16 10.0.0.0/8"' > "$MOD/config"
: > "$RULES/ADB_WIFI"
"$STUBS/sh" "$MOD/watch.sh" once
check_chain "both ranges inserted, terminal reject first from the fence setup" ADB_WIFI <<'EOF'
-A ADB_WIFI -s 10.0.0.0/8 -j ACCEPT
-A ADB_WIFI -s 192.168.0.0/16 -j ACCEPT
EOF
check "auto subnet not used" "192.168.1.0/24" "$FWLOG" 0

echo "== explicit v6 list with v4 default =="
reset_env
echo 'IPV6_SUBNETS="fd00::/8"' > "$MOD/config"
: > "$RULES/ADB_WIFI"
: > "$RULES/ADB_WIFI6"
"$STUBS/sh" "$MOD/watch.sh" once
check_chain "v6 range only" ADB_WIFI6 <<'EOF'
-A ADB_WIFI6 -s fd00::/8 -j ACCEPT
EOF
check "v4 still auto" "iptables -I ADB_WIFI 1 -s 192.168.1.0/24 -j ACCEPT" "$FWLOG" 1

echo "== port is configurable =="
reset_env
echo "ADB_PORT=5556" > "$MOD/config"
"$STUBS/sh" "$MOD/watch.sh" once
check "port in the policy log line" "port 5556" "$BASE_OUT" 1

echo "== comments, blanks, spaces around key and value =="
reset_env
cat > "$MOD/config" <<'EOF'
# leading comment

   ADB_PORT = 5560
LAN_SUBNETS=192.168.5.0/24    # trailing comment
IPV6_SUBNETS = off
VERBOSE=1
EOF
"$STUBS/sh" "$MOD/watch.sh" once
check "port parsed" "port 5560" "$BASE_OUT" 1
check "v4 from file" "iptables -I ADB_WIFI 1 -s 192.168.5.0/24 -j ACCEPT" "$FWLOG" 1
check "verbose logged" "verbose=1" "$BASE_OUT" 1
check "quoted single value" "accept4=\[192.168.5.0/24\]" "$BASE_OUT" 1

echo "== auto with no address keeps the port closed =="
reset_env
: > "$BASE/ip4.txt"
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 10.10.0.0/16 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
"$STUBS/sh" "$MOD/watch.sh" once
check_chain "stale range dropped" ADB_WIFI <<'EOF'
-A ADB_WIFI -j REJECT
EOF
check "closed state logged" "stays closed" "$BASE_OUT" 1

echo "== ssid gate admits a listed network name =="
reset_env
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 10.10.0.0/16 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
printf 'GATE=ssid\nTRUSTED_SSIDS="HomeNet openwrt"\n' > "$MOD/config"
"$STUBS/sh" "$MOD/watch.sh" once
check_chain "live subnet of the trusted network accepted" ADB_WIFI <<'EOF'
-A ADB_WIFI -s 192.168.1.0/24 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
check "network name and radio address logged" "net=\[openwrt/00:eb:d8:60:0f:84\]" "$BASE_OUT" 1

echo "== ssid gate closes the port on any other network =="
reset_env
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 192.168.1.0/24 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
printf 'GATE=ssid\nTRUSTED_SSIDS="HomeNet"\n' > "$MOD/config"
"$STUBS/sh" "$MOD/watch.sh" once
check_chain "nothing accepted off a trusted network" ADB_WIFI <<'EOF'
-A ADB_WIFI -j REJECT
EOF
check "refusal names the network" "network \[openwrt/00:eb:d8:60:0f:84\] is not in the trusted lists" "$BASE_OUT" 1

echo "== a listed radio address opens a network whose name is not listed =="
reset_env
: > "$RULES/ADB_WIFI"
printf 'GATE=ssid\nTRUSTED_BSSIDS="aa:bb:cc:dd:ee:ff 00:EB:D8:60:0F:84"\n' > "$MOD/config"
"$STUBS/sh" "$MOD/watch.sh" once
check "subnet accepted" "iptables -I ADB_WIFI 1 -s 192.168.1.0/24 -j ACCEPT" "$FWLOG" 1

echo "== an interface that is not associated is not trusted =="
reset_env
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 192.168.1.0/24 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
echo 'Not connected.' > "$IW_OUT"
printf 'GATE=ssid\nTRUSTED_SSIDS="openwrt"\n' > "$MOD/config"
"$STUBS/sh" "$MOD/watch.sh" once
check_chain "no accept while off any network" ADB_WIFI <<'EOF'
-A ADB_WIFI -j REJECT
EOF
check "refusal shows the empty association" "network \[-/-\] is not in the trusted lists" "$BASE_OUT" 1

echo "== ssid gate needs something to trust =="
reset_env
: > "$RULES/ADB_WIFI"
echo "GATE=ssid" > "$MOD/config"
"$STUBS/sh" "$MOD/watch.sh" once >/dev/null 2>&1
check "refused" "FATAL.*gate ssid needs TRUSTED_SSIDS or TRUSTED_BSSIDS" "$BASE_OUT" 1
check_chain "no rule touched" ADB_WIFI </dev/null

echo "== ssid gate needs iw to read the network name =="
reset_env
: > "$RULES/ADB_WIFI"
printf 'GATE=ssid\nTRUSTED_SSIDS="openwrt"\n' > "$MOD/config"
mv "$STUBS/iw" "$BASE/iw.stub"
"$STUBS/sh" "$MOD/watch.sh" once >/dev/null 2>&1
check "refused" "FATAL.*gate ssid needs .*/iw" "$BASE_OUT" 1
mv "$BASE/iw.stub" "$STUBS/iw"

echo "== bad config stops the policy before any rule is touched =="
reset_env
printf 'LAN_SUBNETS=\n' > "$MOD/config"
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 10.10.0.0/16 -j ACCEPT
EOF
"$STUBS/sh" "$MOD/watch.sh" once >/dev/null 2>&1
rc=$?
check "empty value refused" "FATAL.*LAN_SUBNETS has no value" "$BASE_OUT" 1
check_chain "existing rules left alone" ADB_WIFI <<'EOF'
-A ADB_WIFI -s 10.10.0.0/16 -j ACCEPT
EOF
if [ "$rc" -eq 1 ]; then PASS=$((PASS + 1)); else FAIL=$((FAIL + 1)); echo "  FAIL: exit code $rc, expected 1"; fi

for bad in "LAN_SUBNET=auto|unknown key LAN_SUBNET" \
           "ADB_PORT=99999|ADB_PORT must be 1-65535" \
           "ADB_PORT=12345678901234567890|ADB_PORT must be 1-65535" \
           "ADB_PORT=abc|ADB_PORT must be a number" \
           "VERBOSE=yes|VERBOSE must be 0 or 1" \
           "GATE=mac|GATE must be subnet or ssid" \
           "TRUSTED_BSSIDS=00-eb-d8|TRUSTED_BSSIDS must be a list of xx:xx:xx:xx:xx:xx" \
           "LAN_SUBNETS=192.168.0.0|LAN_SUBNETS must be auto, none or an IPv4 CIDR list" \
           "LAN_SUBNETS=192.168.1.0/33|LAN_SUBNETS must be auto, none or an IPv4 CIDR list" \
           "LAN_SUBNETS=1.2.3/24|LAN_SUBNETS must be auto, none or an IPv4 CIDR list" \
           "LAN_SUBNETS=300.1.1.1/24|LAN_SUBNETS must be auto, none or an IPv4 CIDR list" \
           "LAN_SUBNETS=fd00::/8|LAN_SUBNETS must be auto, none or an IPv4 CIDR list" \
           "IPV6_SUBNETS=nope|IPV6_SUBNETS must be off, auto or an IPv6 CIDR list" \
           "IPV6_SUBNETS=192.168.1.0/24|IPV6_SUBNETS must be off, auto or an IPv6 CIDR list" \
           "IPV6_SUBNETS=fd00::/129|IPV6_SUBNETS must be off, auto or an IPv6 CIDR list" \
           "oops|expected KEY=value"; do
  reset_env
  echo "${bad%%|*}" > "$MOD/config"
  "$STUBS/sh" "$MOD/watch.sh" once >/dev/null 2>&1
  check "refused: ${bad%%|*}" "FATAL.*${bad#*|}" "$BASE_OUT" 1
done

echo "== service.sh keeps an existing fence and drops the rest =="
reset_env
cat > "$RULES/INPUT" <<'EOF'
-P INPUT ACCEPT
-A INPUT -p tcp -m tcp --dport 5555 -j ADB_WIFI
-A INPUT -p tcp -m tcp --dport 5556 -j ADB_WIFI
-A INPUT -p tcp -m tcp --dport 5555 -j ADB_WIFI6
-A INPUT -p tcp -m tcp --dport 5556 -j ADB_WIFI6
-A INPUT -j ACCEPT
EOF
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -j REJECT
EOF
: > "$RULES/ADB_WIFI6"
echo "ADB_PORT=5556" > "$MOD/config"
"$STUBS/sh" "$MOD/service.sh" >/dev/null 2>&1
check_chain "only the configured port stays fenced" INPUT <<'EOF'
-P INPUT ACCEPT
-A INPUT -p tcp -m tcp --dport 5556 -j ADB_WIFI
-A INPUT -p tcp -m tcp --dport 5556 -j ADB_WIFI6
-A INPUT -j ACCEPT
EOF
check "stale jump reported" "stale fence dropped: .*--dport 5555 -j ADB_WIFI$" "$BASE_OUT" 1
check "adbd told the configured port" "setprop service.adb.tcp.port 5556" "$BASE_OUT" 1
check "adbd bounce detached" "setsid sh -c .*ctl.restart adbd" "$BASE_OUT" 1
check "boot policy applied" "iptables -I ADB_WIFI 1 -s 192.168.1.0/24 -j ACCEPT" "$FWLOG" 1
check "watcher started" "setsid .*watch.sh" "$BASE_OUT" 1

echo "== service.sh installs a fence that is not there yet =="
reset_env
printf -- "-P INPUT ACCEPT\n" > "$RULES/INPUT"
rm -f "$RULES/ADB_WIFI" "$RULES/ADB_WIFI6"
echo "ADB_PORT=5560" > "$MOD/config"
"$STUBS/sh" "$MOD/service.sh" >/dev/null 2>&1
check_chain "jumps inserted at the top of INPUT" INPUT <<'EOF'
-A INPUT -p tcp -m tcp --dport 5560 -j ADB_WIFI6
-A INPUT -p tcp -m tcp --dport 5560 -j ADB_WIFI
-P INPUT ACCEPT
EOF
check "v4 chain created with terminal reject" "^iptables -N ADB_WIFI$" "$FWLOG" 1
check "v6 chain created with terminal reject" "^ip6tables -N ADB_WIFI6$" "$FWLOG" 1
check_chain "accept sits above the terminal reject" ADB_WIFI <<'EOF'
-A ADB_WIFI -s 192.168.1.0/24 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF

echo "== service.sh reports an unfenced Wireless debugging port =="
reset_env
: > "$RULES/INPUT"
echo 37123 > "$GETPROP_DIR/service.adb.tls.port"
"$STUBS/sh" "$MOD/service.sh" >/dev/null 2>&1
check "second door reported" "WARNING: Android Wireless debugging listens on port 37123" "$BASE_OUT" 1
reset_env
: > "$RULES/INPUT"
"$STUBS/sh" "$MOD/service.sh" >/dev/null 2>&1
check "quiet while Wireless debugging is off" "WARNING" "$BASE_OUT" 0

echo "== service.sh refuses to boot on a broken config =="
reset_env
: > "$RULES/INPUT"
echo "IPV6_SUBNETS=nope" > "$MOD/config"
"$STUBS/sh" "$MOD/service.sh" >/dev/null 2>&1
check "refused" "FATAL.*IPV6_SUBNETS must be off, auto or an IPv6 CIDR list" "$BASE_OUT" 1
check_chain "no fence installed" INPUT </dev/null
check "adbd untouched" "setprop service.adb.tcp.port" "$BASE_OUT" 0
check "watcher not started" "setsid .*watch.sh" "$BASE_OUT" 0

echo "== service.sh stays off the network when the fence cannot be read back =="
reset_env
: > "$RULES/INPUT"
rm -f "$RULES/ADB_WIFI" "$RULES/ADB_WIFI6"
mv "$STUBS/ip6tables" "$BASE/ip6tables.stub"
"$STUBS/sh" "$MOD/service.sh" >/dev/null 2>&1
check "unverifiable fence reported" "FATAL.*fence for port 5555 did not install" "$BASE_OUT" 1
check_chain "the v4 half is installed but that is not enough" INPUT <<'EOF'
-A INPUT -p tcp -m tcp --dport 5555 -j ADB_WIFI
EOF
check "adbd untouched" "setprop service.adb.tcp.port" "$BASE_OUT" 0
check "watcher not started" "setsid .*watch.sh" "$BASE_OUT" 0
mv "$BASE/ip6tables.stub" "$STUBS/ip6tables"

echo "== refresh is idempotent, and repeated boots do not pile rules up =="
reset_env
: > "$RULES/ADB_WIFI"
: > "$RULES/ADB_WIFI6"
cp "$MOD/watch.sh" "$MOD/watch.orig"
sed -i 's|^if \[ "\$MODE" = once \]; then|refresh\nif [ "$MODE" = once ]; then|' "$MOD/watch.sh"
"$STUBS/sh" "$MOD/watch.sh" once
n=$(grep -c 'iptables -I ADB_WIFI 1' "$FWLOG")
if [ "$n" = "1" ]; then PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); echo "  FAIL: an event with an unchanged subnet rewrote the rule ($n writes)"
fi
cp "$MOD/watch.orig" "$MOD/watch.sh"

reset_env
: > "$RULES/ADB_WIFI"
: > "$RULES/ADB_WIFI6"
for pass in 1 2 3; do
  "$STUBS/sh" "$MOD/watch.sh" once
done
check_chain "one range after three boots" ADB_WIFI <<'EOF'
-A ADB_WIFI -s 192.168.1.0/24 -j ACCEPT
EOF

echo "== a move to another network closes the port, no reboot =="
reset_env
: > "$RULES/ADB_WIFI"
: > "$RULES/ADB_WIFI6"
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 192.168.1.0/24 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
cat > "$BASE/iw.moved" <<'EOF'
Connected to 11:22:33:44:55:66 (on wlan0)
	SSID: CafeWiFi
EOF
printf 'GATE=ssid\nTRUSTED_SSIDS="openwrt"\n' > "$MOD/config"
cp "$MOD/watch.sh" "$MOD/watch.orig"
sed -i 's|^if \[ "\$MODE" = once \]; then|cp "$BASE/iw.moved" "$IW_OUT"\nrefresh\nif [ "$MODE" = once ]; then|' "$MOD/watch.sh"
"$STUBS/sh" "$MOD/watch.sh" once
check_chain "the trusted network was open, then closed" ADB_WIFI <<'EOF'
-A ADB_WIFI -j REJECT
EOF
check "the move is what closed it" "network \[CafeWiFi/11:22:33:44:55:66\] is not in the trusted lists" "$BASE_OUT" 1
cp "$MOD/watch.orig" "$MOD/watch.sh"

echo "== only address, link and route events are read =="
reset_env
: > "$RULES/ADB_WIFI"
: > "$RULES/ADB_WIFI6"
cat > "$BASE/mon.neigh" <<'EOF'
[NEIGH]192.168.1.1 lladdr 00:eb:d8:60:0f:85 PROBE
       valid_lft forever preferred_lft forever
[RULE]16000:	from all fwmark 0xd0068/0xdffff iif lo lookup 1014
Unknown message: type=0x00000051(81) flags=0x00000000(0) len=0x0000001c(28)
EOF
cp "$BASE/mon.neigh" "$MON_OUT"
"$STUBS/sh" "$MOD/watch.sh" &
DPID=$!
sleep 4
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null
check "chatter beyond address, link and route dropped" "event:" "$BASE_OUT" 0
check "no rewrite for chatter" "iptables -I ADB_WIFI" "$FWLOG" 1

echo "== an address event retargets the policy, no reboot =="
reset_env
: > "$RULES/ADB_WIFI"
: > "$RULES/ADB_WIFI6"
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 192.168.1.0/24 -j ACCEPT
EOF
printf 'LAN_SUBNETS="10.0.0.0/8"\n' > "$MOD/config"
"$STUBS/sh" "$MOD/watch.sh" &
DPID=$!
sleep 4
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null
check "address event retargeted the policy" "iptables -I ADB_WIFI 1 -s 10.0.0.0/8 -j ACCEPT" "$FWLOG" 1
rm -f "$MOD/run/watch.pid"

echo "== the daemon acts on the address it finds instead of waiting for one =="
reset_env
cat > "$RULES/ADB_WIFI" <<'EOF'
-A ADB_WIFI -s 192.168.1.0/24 -j ACCEPT
-A ADB_WIFI -j REJECT
EOF
: > "$RULES/ADB_WIFI6"
: > "$IPV4_OUT"
sed -i 's|^WAIT_TRIES=1$|WAIT_TRIES=20|; s|^WAIT_SLEEP=0$|WAIT_SLEEP=3|' "$MOD/watch.sh"
"$STUBS/sh" "$MOD/watch.sh" &
DPID=$!
sleep 1
check_chain "stale range dropped right away" ADB_WIFI <<'EOF'
-A ADB_WIFI -j REJECT
EOF
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null
sed -i 's|^WAIT_TRIES=20$|WAIT_TRIES=1|; s|^WAIT_SLEEP=3$|WAIT_SLEEP=0|' "$MOD/watch.sh"
rm -f "$MOD/run/watch.pid" "$MOD/run/wlan0-events"

echo "== the daemon outlives an event source that dies, and waits for the interface =="
reset_env
printf 'VERBOSE=1\n' > "$MOD/config"
: > "$RULES/ADB_WIFI"
: > "$RULES/ADB_WIFI6"
rm -f "$IFACE_PATH"
MON_EXIT=9
export MON_EXIT
"$STUBS/sh" "$MOD/watch.sh" &
DPID=$!
sleep 3
kill -0 "$DPID" 2>/dev/null && echo "alive without an interface" >> "$BASE_OUT"
check "daemon waits for the interface instead of dying" "alive without an interface" "$BASE_OUT" 1
check "no monitor started without an interface" "monitor" "$MON_COUNT" 0
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null
rm -f "$MOD/run/watch.pid" "$MOD/run/wlan0-events"
: > "$IFACE_PATH"
MON_EXIT=3
export MON_EXIT
"$STUBS/sh" "$MOD/watch.sh" &
DPID=$!
sleep 8
kill -0 "$DPID" 2>/dev/null && echo "alive while the source dies" >> "$BASE_OUT"
kill "$DPID" 2>/dev/null
wait "$DPID" 2>/dev/null
check "daemon alive while the source keeps dying" "alive while the source dies" "$BASE_OUT" 1
n=$(grep -c "event source gone, restarting" "$BASE_OUT")
if [ "$n" = "3" ]; then PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); echo "  FAIL: source restarted $n times, expected 3"
fi
check "events read from the restarted source" "event: \[ADDR\]" "$BASE_OUT" 1
rm -f "$MOD/run/watch.pid"

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]
