# EcoFlow DELTA 3 Plus as a Windows UPS — without EcoFlow's software

Battery percentage in the taskbar, on-battery / low-battery notifications, and automatic shutdown for an
**EcoFlow DELTA 3 Plus** (and RIVER 3 Plus / DELTA 3 Max Plus / Ultra Plus — same USB ID `3746:FFFF`) on
Windows 10/11, using [Network UPS Tools](https://networkupstools.org/) and a ~15 KB tray app. No EcoFlow
account, no 156 MB "Power Manager", no cloud.

![tray icon](docs/tray.png)

## Why this exists

The DELTA 3 Plus has a USB-C port labelled for UPS/HID use. Plugged into Windows it *should* enumerate as a
standard **HID Power Device** and show up under *Batteries* as "HID UPS Battery" with a battery icon — and on
the firmware EcoFlow shipped in 2024 it did ([Reddit report](https://www.reddit.com/r/Ecoflow_community/comments/1fzi3n6/delta_3_plus_ups_feature/),
hardware ID `HID\VID_3746&PID_FFFF`, a single-interface device).

**Current firmware breaks that.** The device is now a *composite* device — HID interface **plus** a CDC serial
port (`COM x`) that EcoFlow's own Power Manager app talks to — and the HID interface fails on Windows with

```
USB Input Device   USB\VID_3746&PID_FFFF&MI_00   Code 10   NTSTATUS 0xC00000B9 (STATUS_COULD_NOT_INTERPRET)
```

`0xC00000B9` is `hidclass.sys` refusing the HID report descriptor. The config descriptor advertises a
376-byte report descriptor, but the device returns **nothing** for the interface-level `GET_DESCRIPTOR(HID)`
request (NUT's driver logs `HID descriptor too short (expected 9, got 0)` and falls back to the 376). Linux's
HID parser and NUT tolerate that; Windows' does not. There is no user-mode fix for this — only EcoFlow (firmware)
or a signed kernel filter driver could restore the native battery icon.
`docs/Dump-UsbDescriptors.ps1` reproduces the descriptor dump so you can verify your own unit.

So instead: put Microsoft's inbox **WinUSB** driver on that one interface, let NUT's `usbhid-ups` (which has
had an `EcoFlow HID` subdriver since 2.8.5) read it, and draw our own icon.

## What you get

- **Tray icon**: bold percentage + status bar (green = on line, orange + dot = on battery, red = low, grey = no
  data), pinned to the always-visible area. Hover for status, double-click for details.
- **Notifications** on power lost / restored / low battery / lost contact.
- **Automatic shutdown** at a configurable charge % (the EcoFlow reports its own low-battery threshold as
  **0 %**, i.e. never — this repo overrides it, default 15 %).
- **Settings dialog** (right-click → Settings…): threshold, shutdown on/off, countdown, poll interval,
  notifications. Saving rewrites the NUT config and restarts the service (one UAC prompt).
- `C:\NUT\bin\upsc.exe ecoflow@127.0.0.1` for scripts. upsd listens on **127.0.0.1 only**.

## Install

Requirements: Windows 10/11 x64, [7-Zip](https://7-zip.org) (`winget install 7zip.7zip`), a USB **data** cable
from the EcoFlow's USB-C *HID* port to the PC.

```powershell
# elevated PowerShell
git clone https://github.com/twolven/ecoflow-delta3-windows-ups
cd ecoflow-delta3-windows-ups
.\Install.ps1                      # -LowBatteryPercent 20  -InstallDir D:\NUT  -NoTray  -SkipZadig
```

The installer downloads NUT 2.8.5 for Windows, writes the config, opens **Zadig** for the one step that needs
a click (select `EF-UPS-DELTA 3 Plus (Interface 0)` → *Replace Driver* → WinUSB), installs the `Network UPS
Tools` service, verifies it reads the battery, builds `NutTray.exe` from source with the C# compiler that
ships in Windows, registers it as a logon task, and flips the taskbar "always show" switch.

**Interface 0 only.** Interfaces 1/2 are the serial port; leave them on `usbser` if you ever want Power Manager.

## USB link died? Use Bluetooth instead

On some units the USB HID link drops out after a while and stays gone until a power cycle. [`ble/`](ble/) is a
read-only Bluetooth LE bridge that feeds the same NUT service, so the tray, `upsmon` and `upsc` keep working
without the USB cable. See [`ble/README.md`](ble/README.md).

## Uninstall

```powershell
.\Uninstall.ps1                    # removes service + tray; keeps C:\NUT
.\Uninstall.ps1 -RestoreHidDriver  # also drops the WinUSB binding so Windows retries its own HID stack
.\Uninstall.ps1 -Purge             # and deletes C:\NUT
```

Use `-RestoreHidDriver` after an EcoFlow firmware update to check whether the native "HID UPS Battery" is back.

## Layout

```
Install.ps1                 one-shot installer (idempotent)
Uninstall.ps1
ble/                        optional Bluetooth bridge (no USB needed)
tray/NutTray.cs             tray app — single C# file, built by the installer with csc.exe
docs/Dump-UsbDescriptors.ps1  read a USB device's config/HID descriptors via the hub IOCTL (no admin, no driver)
```

Installed tree: `C:\NUT\{bin,etc,tray}` — `etc\ups.conf` (driver, LB override), `etc\upsmon.conf`
(shutdown command), `tray\NutTray.ini` (poll/notify).

## Notes

- `battery.runtime` from this firmware is garbage (hundreds of thousands of seconds); shutdown is driven by
  charge % only (`override.battery.runtime.low = 0`).
- `ignorelb` is set so NUT computes LB from `battery.charge.low` instead of trusting the UPS flag.
- Transfer time is 10 ms; a decent ATX PSU (16 ms hold-up) rides through it. Measured by others, not here.
- Tested on Windows 11 24H2/25H2 with NUT 2.8.5 and DELTA 3 Plus firmware from September 2026.

## License

MIT.
