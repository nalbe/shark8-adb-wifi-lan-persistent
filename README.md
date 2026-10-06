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

- adbd listens on TCP `5555`
- `iptables` accepts connections **only from your LAN subnet**
- everything else (VPN, WAN, other subnets, IPv6) is rejected
- USB adb is untouched, so there is always a wired way back in

## How it works

`service.sh` runs at every boot, in this order:

1. **Fence first.** `iptables` chain `ADB_WIFI` with a terminal `REJECT` of
   tcp/5555 for IPv4 and IPv6. Idempotent, never flushed.
2. **LAN rule.** `watch.sh once` applies the `ACCEPT` rule for the subnet
   wlan0 is on at that moment (bounded wait, max 40s).
3. **Then adbd.** `setprop service.adb.tcp.port 5555` plus a detached `setsid`
   bounce, so `adbd` never listens on 5555 before the fence and the LAN rule
   are in place.
4. **Watcher daemon.** `watch.sh` follows wlan0 address changes forever and
   rewrites the `ACCEPT` list on each one.

The watcher is what makes the trigger correct. `ip monitor address dev wlan0`
reports wlan0 gaining or losing its IPv4 address, which *is* Wi-Fi
connecting/disconnecting, so:

```
03:00:56  5555 accept=[]                 Wi-Fi off  -> port closed
03:01:16  5555 accept=[192.168.1.0/24]    Wi-Fi on   -> ADB reachable
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

## Customizing the allowed range

Create `/data/adb/modules/adb_wifi/config` with:

```
# Default: the /24 subnet of the phone's wlan0 interface, kept in sync live
LAN_SUBNETS="auto"

# Or: standard RFC1918 private ranges
LAN_SUBNETS="rfc1918"                  # 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16

# Or: your own explicit list (space separated)
LAN_SUBNETS="192.168.0.0/16 10.0.0.0/8"
```

`192.168.0.0/16` in the explicit list covers every common home router range
(`192.168.0.x` and `192.168.1.x`); `auto` adapts to whatever LAN the phone is
on, but a pinned list is worth it if you roam onto untrusted networks, since it
does not follow the phone off your own range.

## Bootloop safety (lessons learned)

An earlier version of this module broke the device, and an even earlier one
locked out ADB over Wi-Fi. Causes, avoided here:

- `setprop persist.adb.tcp.port 5555` - a *persistent* property; if adbd
  misbehaved it poisoned every subsequent boot
- `setprop service.adb.adb_root 1` - clashed with KernelSU's own root handling
- an infinite `while`-wait on `sys.boot_completed` in `service.sh`
- a plain `setprop ctl.restart adbd` from an `adb shell`-launched run: init
  SIGKILLs adbd's whole process group, which takes a script running inside
  that adb session down with it *before* the firewall is applied. The bounce
  therefore runs as a detached `setsid` child.
- a boot path whose reachability depended on a background daemon: if that
  daemon did not come up, port 5555 stayed REJECT-only and there was no way in

Current version uses only runtime props, bounded waits, the firewall lives in
`ADB_WIFI`/`ADB_WIFI6` chains, adbd is told to listen only after the fence, and
the whole run is logged under `adb_wifi`. A bad boot is self-healing.

The published **v3.1** release is the one that locks out: it waits on
`sys.boot_completed` and restarts adbd from inside the adb session, so the
firewall may never get applied. Its release page says so - install the current
version instead.

## License

MIT
