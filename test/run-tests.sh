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

rm -rf "$BASE"
mkdir -p "$MOD" "$STUBS" "$RULES"
cp "$SRC/common.sh" "$SRC/watch.sh" "$SRC/service.sh" "$MOD/"

# point the scripts at the stubs and shrink the boot wait for the tests
sed -i "s|^TB=/system/bin$|TB=$STUBS|" "$MOD/common.sh"
sed -i "s|^WAIT_TRIES=20$|WAIT_TRIES=1|; s|^WAIT_SLEEP=2$|WAIT_SLEEP=0|" "$MOD/watch.sh"
if ! grep -q "^TB=$STUBS\$" "$MOD/common.sh"; then
  echo "FATAL: TB rewrite failed"
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
case "$1 $2 $3" in
  "-f inet addr")  cat "$IPV4_OUT" 2>/dev/null ;;
  "-f inet6 addr") cat "$IPV6_OUT" 2>/dev/null ;;
  "monitor address")
    trap 'exit 0' TERM INT
    while :; do
      echo "Deleted 192.168.1.42/24 from wlan0"
      sleep 1
    done ;;
  *) : ;;
esac
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

FAIL=0
PASS=0

reset_env() {
  : > "$FWLOG"
  : > "$BASE_OUT"
  rm -f "$MOD/config"
  cp "$BASE/ip4.default" "$IPV4_OUT"
  cp "$BASE/ip6.default" "$IPV6_OUT"
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
check "policy logged with port" "port 5555 accept4=\[192.168.1.0/24\] accept6=\[\]" "$BASE_OUT" 1

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
           "ADB_PORT=abc|ADB_PORT must be a number" \
           "VERBOSE=yes|VERBOSE must be 0 or 1" \
           "LAN_SUBNETS=192.168.0.0|LAN_SUBNETS must be auto, none or a CIDR list" \
           "IPV6_SUBNETS=nope|IPV6_SUBNETS must be off, auto or a CIDR list" \
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

echo "== service.sh refuses to boot on a broken config =="
reset_env
: > "$RULES/INPUT"
echo "IPV6_SUBNETS=nope" > "$MOD/config"
"$STUBS/sh" "$MOD/service.sh" >/dev/null 2>&1
check "refused" "FATAL.*IPV6_SUBNETS must be off, auto or a CIDR list" "$BASE_OUT" 1
check_chain "no fence installed" INPUT </dev/null
check "adbd untouched" "setprop service.adb.tcp.port" "$BASE_OUT" 0
check "watcher not started" "setsid .*watch.sh" "$BASE_OUT" 0

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

echo
echo "passed: $PASS  failed: $FAIL"
[ "$FAIL" -eq 0 ]