#!/system/bin/sh
# ADB over Wi-Fi (Persistent, LAN-locked) - config, defaults, logging
#
# Sourced by service.sh and watch.sh, which set MODULE_DIR to ${0%/*} first.
#
# Config file: $MODULE_DIR/config, one KEY=value per line, parsed line by line
# and never sourced, so a typo fails the boot script instead of running as root.
#   ADB_PORT      port adbd listens on                      default 5555
#   LAN_SUBNETS   auto | none | IPv4 CIDR list             default auto
#   IPV6_SUBNETS  off | auto | IPv6 CIDR list              default off
#   GATE          what admits a source: subnet | ssid        default subnet
#   TRUSTED_SSIDS network names that open the port under the ssid gate
#   TRUSTED_BSSIDS radio addresses that open it as well
#   VERBOSE       1 for debug-level firewall logs            default 0

TB=/system/bin
MODULE_DIR=${MODULE_DIR:?}
CONFIG=$MODULE_DIR/config
RUN_DIR=$MODULE_DIR/run
TAG=adb_wifi
IFACE=wlan0
IFACE_PATH=/sys/class/net/$IFACE

ADB_PORT=5555
LAN_SUBNETS=auto
IPV6_SUBNETS=off
GATE=subnet
TRUSTED_SSIDS=
TRUSTED_BSSIDS=
VERBOSE=0

SPC=" "
TAB=$(printf '\t')

log()  { $TB/log -p i -t "$TAG" "$1" 2>/dev/null; }
logv() { if [ "$VERBOSE" = "1" ]; then $TB/log -p d -t "$TAG" "$1" 2>/dev/null; fi; }
die()  { log "FATAL: $1"; exit 1; }

# trim blanks and one layer of quotes, result in STRIPPED
strip() {
    _s=$1
    while :; do
        case $_s in
            "$SPC"*|"$TAB"*) _s=${_s#?} ;;
            *) break ;;
        esac
    done
    while :; do
        case $_s in
            *"$SPC"|*"$TAB") _s=${_s%?} ;;
            *) break ;;
        esac
    done
    case $_s in
        \"*\") [ "$_s" = '"' ] || { _s=${_s#\"}; _s=${_s%\"}; } ;;
        \'*\') { _s=${_s#\'}; _s=${_s%\'}; } ;;
    esac
    STRIPPED=$_s
}

# CIDR list of one address family, in $1 and $2. Anything iptables would refuse
# has to be refused here, or the rule is silently missing while the log names it.
valid_subnets() {
    [ -n "$2" ] || return 1
    for _s in $2; do
        case $_s in
            */*) ;;
            *) return 1 ;;
        esac
        _net=${_s%/*}
        _len=${_s##*/}
        case $_len in ''|*[!0-9]*|????*) return 1 ;; esac
        if [ "$1" = 6 ]; then
            case $_net in
                *:*) ;;
                *) return 1 ;;
            esac
            case $_net in
                *[!0-9a-fA-F:.]*) return 1 ;;
            esac
            [ "$_len" -le 128 ] || return 1
        else
            case $_net in
                *:*) return 1 ;;
            esac
            _octets=0
            _rest=$_net.
            while [ -n "$_rest" ]; do
                _oct=${_rest%%.*}
                _rest=${_rest#*.}
                _octets=$((_octets + 1))
                case $_oct in ''|*[!0-9]*|????*) return 1 ;; esac
                [ "$_oct" -le 255 ] || return 1
            done
            [ "$_octets" -eq 4 ] || return 1
            [ "$_len" -le 32 ] || return 1
        fi
    done
    return 0
}

valid_bssids() {
    [ -n "$1" ] || return 1
    for _b in $1; do
        [ "${#_b}" -eq 17 ] || return 1
        case $_b in
            [0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# one KEY=value assignment, CFG_ERR says why it was refused
cfg_set() {
    CFG_ERR=
    case $1 in
        *=*) ;;
        *) CFG_ERR="expected KEY=value"; return 1 ;;
    esac
    strip "${1%%=*}"; _key=$STRIPPED
    strip "${1#*=}";  _val=$STRIPPED
    if [ -z "$_key" ]; then CFG_ERR="empty key"; return 1; fi
    if [ -z "$_val" ]; then CFG_ERR="$_key has no value"; return 1; fi

    case $_key in
        ADB_PORT)
            case $_val in
                *[!0-9]*) CFG_ERR="ADB_PORT must be a number"; return 1 ;;
                ??????*) CFG_ERR="ADB_PORT must be 1-65535"; return 1 ;;
            esac
            if [ "$_val" -lt 1 ] || [ "$_val" -gt 65535 ]; then
                CFG_ERR="ADB_PORT must be 1-65535"
                return 1
            fi
            ADB_PORT=$_val
            ;;
        LAN_SUBNETS)
            case $_val in
                auto|none) LAN_SUBNETS=$_val ;;
                *) valid_subnets 4 "$_val" || { CFG_ERR="LAN_SUBNETS must be auto, none or an IPv4 CIDR list"; return 1; }
                   LAN_SUBNETS=$_val ;;
            esac
            ;;
        IPV6_SUBNETS)
            case $_val in
                off|auto) IPV6_SUBNETS=$_val ;;
                *) valid_subnets 6 "$_val" || { CFG_ERR="IPV6_SUBNETS must be off, auto or an IPv6 CIDR list"; return 1; }
                   IPV6_SUBNETS=$_val ;;
            esac
            ;;
        GATE)
            case $_val in
                subnet|ssid) GATE=$_val ;;
                *) CFG_ERR="GATE must be subnet or ssid"; return 1 ;;
            esac
            ;;
        TRUSTED_SSIDS)
            TRUSTED_SSIDS=$_val
            ;;
        TRUSTED_BSSIDS)
            valid_bssids "$_val" || { CFG_ERR="TRUSTED_BSSIDS must be a list of xx:xx:xx:xx:xx:xx"; return 1; }
            # iw reports the radio address in lower case, so the list is folded
            # here once instead of on every event
            TRUSTED_BSSIDS=$(printf '%s' "$_val" | tr 'A-F' 'a-f')
            ;;
        VERBOSE)
            case $_val in
                0|1) VERBOSE=$_val ;;
                *) CFG_ERR="VERBOSE must be 0 or 1"; return 1 ;;
            esac
            ;;
        *)
            CFG_ERR="unknown key $_key"
            return 1
            ;;
    esac
    return 0
}

cfg_load() {
    [ -f "$CONFIG" ] || return 0
    _no=0
    while IFS= read -r _line || [ -n "$_line" ]; do
        _no=$((_no + 1))
        _line=${_line%%#*}
        strip "$_line"
        [ -n "$STRIPPED" ] || continue
        if ! cfg_set "$STRIPPED"; then
            die "$CONFIG line $_no: $CFG_ERR"
        fi
    done < "$CONFIG"
    if [ "$GATE" = ssid ]; then
        [ -n "$TRUSTED_SSIDS$TRUSTED_BSSIDS" ] ||
            die "gate ssid needs TRUSTED_SSIDS or TRUSTED_BSSIDS, no network would open the port"
        [ -x "$TB/iw" ] ||
            die "gate ssid needs $TB/iw to read the name of the network $IFACE is on"
    fi
    logv "config: port=$ADB_PORT lan=[$LAN_SUBNETS] lan6=[$IPV6_SUBNETS] gate=$GATE ssids=[$TRUSTED_SSIDS] bssids=[$TRUSTED_BSSIDS] verbose=$VERBOSE"
}
