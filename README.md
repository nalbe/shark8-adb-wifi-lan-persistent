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

`service.sh` runs at every boot:

1. waits for `sys.boot_completed` (bounded, max ~60s, never an infinite loop)
2. computes your LAN subnet from the phone's `wlan0` address (the `/24` it lives in)
3. `setprop service.adb.tcp.port 5555` + `setprop ctl.restart adbd`
4. `iptables` rules: `ACCEPT` tcp/5555 from the allowed subnets, `REJECT` the rest
5. `ip6tables`: reject tcp/5555 outright (no LAN v6 clients expected)

## Install

```
adb push module/service.sh   /data/adb/modules/adb_wifi/service.sh
adb push module/module.prop  /data/adb/modules/adb_wifi/module.prop
adb shell chmod 755 /data/adb/modules/adb_wifi/service.sh
adb reboot
```

Or: put the `module/` tree (renamed to `adb_wifi/`) under `/data/adb/modules/`
via Root Explorer / KernelSU manager and reboot.

Then connect from your PC:

```
adb connect <phone-ip>:5555
```

## Customizing the allowed range

Create `/data/adb/modules/adb_wifi/config` with:

```
# Default: the /24 subnet of the phone's wlan0 interface
LAN_SUBNETS="auto"

# Or: standard RFC1918 private ranges
LAN_SUBNETS="rfc1918"                  # 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16

# Or: your own explicit list (space separated)
LAN_SUBNETS="192.168.0.0/16 10.0.0.0/8"
```

`192.168.0.0/16` in the explicit list covers every common home router range
(`192.168.0.x` and `192.168.1.x`); `auto` is recommended because it adapts
precisely to whatever LAN the phone is currently on.

## Bootloop safety (lessons learned)

An earlier version of this module broke the device. The causes, avoided here:

- `setprop persist.adb.tcp.port 5555` — a *persistent* property; if adbd
  misbehaved it poisoned every subsequent boot
- `setprop service.adb.adb_root 1` — clashed with KernelSU's own root handling
- an infinite `while`-wait on `sys.boot_completed` in `service.sh`

Current version uses only runtime props, a bounded boot-wait, and the firewall
adds no persistent state. A bad boot is self-healing.

## License

MIT