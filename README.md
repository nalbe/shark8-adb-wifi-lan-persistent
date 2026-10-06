# shark8-adb-wifi-lan-persistent

KernelSU module: persistent ADB over Wi-Fi, firewalled to your LAN only.

Tested on: Blackview Shark 8, Android 13 AOSP GSI (`TP1A.220624.014`, user build,
release keys) on stock vendor, KernelSU 0.9.4.

## Why

On this class of GSI/vendor mix (`ro.debuggable=1`), `adbd` **does not enforce
adb key authentication on plain TCP**. We verified empirically that
`persist.adb.secure`, `persist.adb.authorization` and even a populated
`/data/misc/adb/adb_keys` are all ignored: a brand-new, never-authorized key
connects and gets `root` instantly.

Since you cannot trust the key layer, this module enforces security at the
**network layer** instead:

- adbd listens on TCP `5555` (configurable)
- `iptables` accepts connections **only from your LAN subnet**
- everything else (VPN, WAN, other subnets, IPv6) is rejected
- USB adb is untouched, so there is always a wired way back in

## How it works

`service.sh` runs at every boot, in this order:

1. **Fence first.** `iptables` chain `ADB_WIFI` with a terminal `REJECT` of the
   configured port for IPv4 and IPv6. Idempotent, never flushed. The four rules
   are then read back: a fence that did not install stops the script with a
   `FATAL` and adbd is never told to listen, since a missing rule would leave
   the port open to everyone.
2. **LAN rule.** `watch.sh once` applies the `ACCEPT` rules for the network
   wlan0 is on at that moment (bounded wait, max 40s).
3. **Then adbd.** `setprop service.adb.tcp.port` plus a detached `setsid`
   bounce, so `adbd` never listens before the fence and the LAN rules are in
   place.
4. **Watcher daemon.** `watch.sh` follows wlan0 address changes forever and
   rewrites the `ACCEPT` lists on each one.

The watcher is what makes the trigger correct. `ip monitor all dev wlan0`
reports wlan0 gaining or losing its address, which *is* Wi-Fi
connecting/disconnecting, so:

```
03:00:56  port 5555 accept4=[] accept6=[]                  Wi-Fi off -> port closed
03:01:16  port 5555 accept4=[192.168.1.0/24] accept6=[]   Wi-Fi on  -> ADB reachable
```

No polling, no timers, no dependence on how long boot takes. Wi-Fi enabled but
not yet associated never opens the port, because there is nothing to connect
to.

The terminal `REJECT` rule is never removed, not even while the `ACCEPT` list
is being rewritten, so the port stays closed to everyone else at all times.

Reachability at boot deliberately does **not** depend on the daemon: step 2 is
synchronous inside `service.sh`, the daemon only keeps the rule fresh after
that. A daemon that fails to start costs you roaming, not access.

Every step is logged under the `adb_wifi` tag (`logcat -s adb_wifi:*`).

## Install

Flash the release zip in the KernelSU app: **Modules -> Install from storage ->
`shark8-adb-wifi-lan-persistent-<version>.zip`**, then reboot. The zip holds the
module files at its root (`module.prop`, `service.sh`, `watch.sh`), which is
exactly what the installer expects; `module/` in this repo is only the source
layout.

Or push the files onto a rooted device by hand:

```
adb push module/module.prop  /data/adb/modules/adb_wifi/module.prop
adb push module/service.sh   /data/adb/modules/adb_wifi/service.sh
adb push module/watch.sh     /data/adb/modules/adb_wifi/watch.sh
adb shell chmod 755 /data/adb/modules/adb_wifi/service.sh
adb shell chmod 755 /data/adb/modules/adb_wifi/watch.sh
adb reboot
```

Then connect from your PC:

```
adb connect <phone-ip>:5555
```

## Upgrading

The module publishes an update manifest (`updateJson` in `module.prop` ->
`update.json` in this repo), so the KernelSU app shows **Update** on the module
as soon as a newer `versionCode` is published. Tap it, reboot, done. Upgrades
keep your `/data/adb/modules/adb_wifi/config`.

By hand, push the three files over the installed ones and reboot; keep the
config file if you have one. To remove the module, uninstall it in the
KernelSU app, which deletes the module directory.

## Building

```
powershell -ExecutionPolicy Bypass -File build.ps1
```

`module/module.prop` is the source of truth: `version` names the zip and the
tag, `versionCode` is what the manager compares. Put the release changelog in
`notes.txt` (one paragraph) - the build reads it into `update.json` and it is
the release body. Output is `release\shark8-adb-wifi-lan-persistent-<version>.zip`
plus `update.json` at the repo root; commit `update.json`, tag `v<version>`,
attach the zip to the release.

The scripts are tested off-device against stub `ip`/`iptables`/`log` binaries:

```
sh test/run-tests.sh module
```

That harness covers config parsing, the policy the watcher installs for every
`auto`/`none`/list combination, the fence bookkeeping in `service.sh`, and the
refusal to run on a broken config. What it cannot cover is the netlink event
loop and the real iptables, which is what the on-device check above is for.

## Verifying it on the device

Turn Wi-Fi off and on again; the log must show the `ACCEPT` list going empty
and coming back. Note that `svc wifi` does **not** exist on this build - use
`cmd wifi set-wifi-enabled disabled|enabled`.

```
adb shell cmd wifi set-wifi-enabled disabled
adb shell cmd wifi set-wifi-enabled enabled
adb logcat -s adb_wifi:*
```

If port 5555 ever stops answering while the phone is on your LAN, the module
is not what is broken - check the chain first:

```
adb shell iptables -S ADB_WIFI      # needs a root adbd: adb root
adb shell cat /data/adb/modules/adb_wifi/run/watch.pid
adb shell cat /proc/<pid>/cmdline   # must be watch.sh
```

Android's stock **Wireless debugging** (Developer options) is the independent
escape hatch: it publishes `_adb-tls-connect._tcp` over mDNS, so
`adb mdns services` finds the live port even when 5555 is firewalled.

### The Wireless debugging toggle stays off

The module opens the port itself, so the **Wireless debugging** toggle in
Developer options stays off and never changes. The toggle does not reflect
this module - nothing here reads it or waits for it, and you do not need to
enable anything.

Two ways to tell them apart:

- `adb connect <ip>:5555` is the module: firewalled to your LAN.
- A port from `adb mdns services` is Android's wireless debugging: a separate
  listener with no fence on it, reachable by anything that can see its mDNS
  advertisement. On a phone where `adbd` does not check keys, that is an
  unauthenticated root door - so use it only as an escape hatch and turn it
  straight back off.

Every boot reads `service.adb.tls.port` and logs a `WARNING` line when it is
not `0`, so a logcat sweep says whether the second door is open. The module
reports it and leaves it to you: silencing it means switching the toggle off,
which is the only way to keep the fence the whole perimeter.

## Configuration

Everything configurable lives in `/data/adb/modules/adb_wifi/config`, one
`KEY=value` per line, `#` for comments. The file is parsed line by line, never
sourced: an unknown key or a malformed value aborts the boot script with a
`FATAL` in the log instead of quietly running as root. A missing config means
all defaults.

| Key | Default | Values |
| --- | --- | --- |
| `ADB_PORT` | `5555` | port adbd listens on, 1-65535 |
| `LAN_SUBNETS` | `auto` | `auto`, `none`, or a space separated IPv4 CIDR list |
| `IPV6_SUBNETS` | `off` | `off`, `auto`, or a space separated IPv6 CIDR list |
| `GATE` | `subnet` | `subnet` or `ssid` |
| `TRUSTED_SSIDS` | empty | space separated network names, used by `GATE=ssid` |
| `TRUSTED_BSSIDS` | empty | space separated radio addresses, used by `GATE=ssid` |
| `VERBOSE` | `0` | `1` logs every firewall rewrite at debug level |

```
ADB_PORT=5555

# IPv4 the firewall lets reach the port:
#   auto    the /24 wlan0 is on right now, live-tracked
#   none    nothing is allowed: the port stays closed to the network
#   list    your own ranges, e.g. the usual home routers
LAN_SUBNETS="192.168.0.0/16 10.0.0.0/8"

# IPv6 is rejected outright unless you ask for it. auto takes the /64 wlan0 is
# on and skips link-local, which only ever reaches neighbours on the same link.
IPV6_SUBNETS="off"

VERBOSE=0
```

`auto` for IPv4 tracks wlan0, so the phone is reachable on whatever LAN it joins;
a pinned list is worth it if you roam onto untrusted networks, since it does not
follow the phone off your own range. `192.168.0.0/16` covers both `192.168.0.x`
and `192.168.1.x`, i.e. most home routers.

`none` is the kill switch: the fence stays up, no `ACCEPT` is installed, so the
port is closed from everywhere without uninstalling anything.

Changing `ADB_PORT` re-fences on the new port at the next boot and drops the
fence rules for the old one; `adbd` follows the new port after its bounce.

### Gating on the network instead of the address

A pinned range only holds while nobody else hands out that range. Cafe routers
pick their own, and `192.168.1.0/24` is a favourite, so on someone else's Wi-Fi a
subnet rule can admit you to exactly the network you wanted to keep out.
`GATE=ssid` asks a different question: not who is connecting but which network the
phone is on. Off a listed network the port is closed to everybody, whatever
address you are handed.

```
GATE="ssid"
TRUSTED_SSIDS="HomeNet openwrt"
```

Inside a trusted network the address rules apply as usual, so `LAN_SUBNETS=auto`
still means "the LAN I am on" and a pinned list still narrows it from there.
`TRUSTED_BSSIDS` takes the same gate on radio addresses, which is what to use when
a name is one you would rather not write down, when the name itself contains a
space (names are matched as space separated words), when the network hides its
name and there is none to match, or when you want the gate to hold against an
access point that merely claims a listed name. Case does not matter there. Read
both off the phone with `iw dev wlan0 link`.

The name is read again on every wlan0 address or link event, so leaving for an
unlisted network closes the port within a moment, without a reboot: moving between
access points re-associates the interface, which is what triggers the re-read. Boot
behaves the same way - the port opens once the phone has associated with a listed
network, a few seconds after `adbd` starts listening. An interface that is not
associated has no name and is not trusted.

The watcher follows `ip monitor all`, which also carries the neighbour updates a busy
LAN produces one per ARP exchange, along with routing-rule chatter and messages it
cannot interpret. None of those can move the phone to another network, so they are
dropped before the name is read again; address, link and route events all pass
through.

What this gate is not: a network name is public. Anyone can put up an access point
that announces a name from your list, and to that the gate answers "trusted". That
is what `TRUSTED_BSSIDS` is for - a radio address cannot be announced by somebody
else's hardware, at the cost of listing a router per access point. What either key
buys you is not being debuggable by accident, which is the failure this module
exists to prevent.

Gating on the peer's hardware address would be the tighter answer, and it does not
work here: `iptables -m mac` only matches when bridged frames reach the IP hooks,
which needs `net.bridge.bridge-nf-call-iptables`, and a kernel without
`br_netfilter` never hands a hardware address to them at all. Measured on this
device (5.10 GSI, no `br_netfilter`): the rule installs, iptables accepts it, and
a peer presenting exactly the listed MAC is still rejected, because the rule never
matches. No configuration fixes that.

## License

MIT
