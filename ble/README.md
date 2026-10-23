# Bluetooth bridge — NUT without the USB link

On some units the USB data link dies after a while (controller lockup, device vanishes from Windows, and only a
power cycle brings it back). This bridge reads the same battery/AC data over **Bluetooth LE** instead and feeds
the same Windows NUT service, so `upsmon`, the tray app and any scripts keep working unchanged:
`upsc ecoflow@127.0.0.1`.

```
EcoFlow --BLE--> bridge.py (read-only NUT source, 127.0.0.1:3494)
                    └─ NUT dummy-ups (repeater) ─> upsd :3493 ─> upsmon / NutTray
```

Built on [rabits/ha-ef-ble](https://github.com/rabits/ha-ef-ble) (`eflib`, Apache-2.0), included as a submodule
pinned to a known-good commit. The bridge has run against a DELTA 3 Plus; see
[What has not been tested](#what-has-not-been-tested).

## Safety properties

- **Read-only.** Config writes, output control, clock sync and NUT instant commands are all blocked; the local
  NUT source accepts no authentication, writes or shutdown commands. (The BLE session itself still sends the
  login handshake and the protocol acknowledgements `eflib` uses to keep telemetry flowing.)
- **Stale means stale.** `DATA-STALE` on disconnect, when the battery reading is >45 s old, or when the power
  source can't be determined (below); a silent stream is reconnected after 60 s. dummy-ups passes the stale
  state on to upsd, so NUT reports the UPS as unavailable rather than keeping the last good values.
- **Never guesses an outage.** This firmware omits the AC-plug flag, so positive AC-input watts mean `OL`. Zero
  watts alone never means `OB`: fresh battery discharge must cover at least half the output (min 10 W) for 3 s,
  otherwise the status is unavailable. An explicit fresh plug flag wins if the firmware sends one.
  The flip side: during a real outage with less than 10 W of total output (PC asleep or off), the bridge
  reports stale data, not `OB`, so NUT sees lost communication instead of an outage.
- **Low battery is fixed at 15 %** while on battery: the bridge itself raises `LB` and reports
  `battery.charge.low = 15`. The main installer's `-LowBatteryPercent` and the tray's threshold setting are not
  carried over to the Bluetooth path (this installer rewrites `ups.conf` without them); change the `15`s in
  `bridge.py` if you need another value. NUT's own `upsmon` shutdown rules then apply as before.

## Install (Windows 10/11, elevated PowerShell)

Prerequisites:

- The main [`Install.ps1`](../Install.ps1) has completed **with its defaults** (`C:\NUT`, UPS name `ecoflow`),
  so the `Network UPS Tools` service and `upsmon` are set up. That installer needs a working USB link once;
  this one then only replaces `ups.conf`. Paths and the UPS name are hard-coded here.
- A Bluetooth LE adapter, and [uv](https://docs.astral.sh/uv/) (`winget install astral-sh.uv`).
- Close the EcoFlow phone app first — the unit accepts **one** BLE connection.

```powershell
git clone --recurse-submodules https://github.com/twolven/ecoflow-delta3-windows-ups
cd ecoflow-delta3-windows-ups\ble
uv venv --python 3.13 .venv
uv pip install --python .venv\Scripts\python.exe -r requirements-lock.txt

.venv\Scripts\python.exe scan.py --save        # finds your unit, writes serial.txt
.venv\Scripts\python.exe setup_login.py        # prints a local URL: open it and save your EcoFlow user ID
.venv\Scripts\python.exe stage_machine.py      # re-encrypts it for the SYSTEM service
.\Install-EcoFlowBLE.ps1
```

`Install-EcoFlowBLE.ps1` copies a private runtime to `C:\ProgramData\EcoFlowBLE` (owned by Administrators,
admin-only write), proves two read/reconnect cycles as SYSTEM, registers the `EcoFlowBLE` startup task, then
rewrites `C:\NUT\etc\ups.conf` to `dummy-ups` in repeater mode (`port = ecoflow_ble@127.0.0.1:3494`) and
restarts the NUT service. The previous `ups.conf` is saved as `ups.conf.bak-ble-<timestamp>` and restored
automatically if live data doesn't appear. The old USB driver config is therefore **replaced** — keep that
backup if you want to go back. On success the machine-scope copy of the account ID is deleted from this
folder; the copy in `C:\ProgramData\EcoFlowBLE` is readable only by SYSTEM and Administrators.

### Going back to USB

There is no uninstaller for the bridge. In an elevated PowerShell: `Stop-ScheduledTask EcoFlowBLE`,
`Disable-ScheduledTask EcoFlowBLE`, copy the `Backup` file named in `C:\ProgramData\EcoFlowBLE\installation.json`
over `C:\NUT\etc\ups.conf`, then `Restart-Service 'Network UPS Tools'`. Delete the task and the folder once you
no longer need them.

### The account ID

The EcoFlow BLE handshake needs your numeric EcoFlow **user ID** (not a password). `setup_login.py` runs a
loopback-only page on `127.0.0.1` that either takes the ID directly or signs in to EcoFlow's HTTPS login once
to read it; the password is never stored. Only the ID is kept, encrypted with Windows DPAPI (user scope, then
machine scope for the service). Treat it as a secret: together with the serial, which the unit broadcasts, it
is what the unit accepts as a BLE login. The page is served only at a random URL, checks the `Host` header
(against DNS rebinding) and a per-run token (against cross-site posts), and stops after setup or 30 minutes.
The email sign-in uses EcoFlow's unofficial app login API, which can change without notice; entering the ID
directly avoids it. Nothing from your account is in this repository.

## Files

| | |
|---|---|
| `bridge.py` | BLE client + loopback NUT source; `--probe` runs two test cycles |
| `scan.py` | lists EcoFlow units, `--save` stores the serial in `serial.txt` |
| `setup_login.py`, `secure_store.py`, `stage_machine.py` | one-time account-ID setup, DPAPI storage |
| `Install-EcoFlowBLE.ps1` | installer with probe, cutover and rollback |
| `test_bridge.py` | safety tests: `python -m unittest test_bridge` (NUT round-trip tests skip without `C:\NUT`) |

Runtime state: `health.json` and a rotating `bridge.log` in `C:\ProgramData\EcoFlowBLE`.

## Tray fix

The tray in `../tray/NutTray.cs` now parses `battery.charge` as a decimal. The bridge reports values like
`88.61`, which the old integer parser rejected, showing `--` / −1 % despite live data.

## What has not been tested

- **A real mains loss and the resulting shutdown.** The OB/LB logic is covered by unit tests only.
- **This published installer end to end.** It is a cleaned-up version of the one used on the test machine
  (personal paths and a machine-specific recovery-task step were removed; ownership/ACL hardening, rollback
  hardening and the serial file were added). The edited script has been syntax-checked, not run. During the
  original cutover the `Network UPS Tools` service hung in `STOP_PENDING` on restart and had to be recovered by
  hand; if `Restart-Service` stalls, end the NUT processes and start the service again.
- `scan.py --save` in its published form (the original only looked for one known serial).
- Other EcoFlow models. The bridge uses `eflib`'s DELTA 3 Plus device class only.

## Caveats

- A phone using Bluetooth at the same time can interrupt telemetry.
- Not affiliated with or endorsed by EcoFlow. BLE protocol support comes from the community `ha-ef-ble`
  project (Apache-2.0, copyright its authors); its `LICENSE` is copied into the install folder with the library.
