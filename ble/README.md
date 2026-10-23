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
pinned to a known-good commit. Tested on a DELTA 3 Plus. Physical mains-loss and shutdown were **not** exercised.

## Safety properties

- **Read-only.** Config writes, output control, clock sync and NUT instant commands are all blocked; the local
  NUT source accepts no authentication, writes or shutdown commands.
- **Stale means stale.** `DATA-STALE` on disconnect or when the battery reading is >45 s old; a silent stream is
  reconnected after 60 s; dummy-ups propagates that, so NUT never keeps a "healthy" state it can't back up.
- **Never guesses an outage.** This firmware omits the AC-plug flag, so positive AC-input watts mean `OL`. Zero
  watts alone never means `OB`: fresh battery discharge must cover at least half the output (min 10 W) for 3 s,
  otherwise the status is unavailable. An explicit fresh plug flag wins if the firmware sends one.
- Low battery is 15 % while on battery (`battery.charge.low`); NUT's own shutdown rules apply.

## Install (Windows 10/11, elevated PowerShell, NUT already installed in `C:\NUT`)

```powershell
git clone --recurse-submodules https://github.com/twolven/ecoflow-delta3-windows-ups
cd ecoflow-delta3-windows-ups\ble
uv venv --python 3.13 .venv
uv pip install --python .venv\Scripts\python.exe -r requirements-lock.txt

.venv\Scripts\python.exe scan.py --save        # finds your unit, writes serial.txt
.venv\Scripts\python.exe setup_login.py        # one-time: saves your EcoFlow numeric user ID (see below)
.venv\Scripts\python.exe stage_machine.py      # re-encrypts it for the SYSTEM service
.\Install-EcoFlowBLE.ps1
```

Close the EcoFlow phone app first — the unit accepts **one** BLE connection.

`Install-EcoFlowBLE.ps1` copies a private runtime to `C:\ProgramData\EcoFlowBLE` (admin-only write), proves two
read/reconnect cycles as SYSTEM, registers the `EcoFlowBLE` startup task, then rewrites `C:\NUT\etc\ups.conf` to
`dummy-ups` in repeater mode (`port = ecoflow_ble@127.0.0.1:3494`) and restarts the NUT service. The previous
`ups.conf` is saved as `ups.conf.bak-ble-<timestamp>` and restored automatically if live data doesn't appear.
The old USB driver config is therefore **replaced** — keep that backup if you want to go back.

### The account ID

The EcoFlow BLE handshake needs your numeric EcoFlow **user ID** (not a password). `setup_login.py` runs a
loopback-only page on `127.0.0.1` that either takes the ID directly or signs in to EcoFlow's own HTTPS login once
to read it; the password is never stored. Only the ID is kept, encrypted with Windows DPAPI (user scope, then
machine scope for the service). Nothing from your account is in this repository.

## Files

| | |
|---|---|
| `bridge.py` | BLE client + loopback NUT source; `--probe` runs two test cycles |
| `scan.py` | lists EcoFlow units, `--save` stores the serial in `serial.txt` |
| `setup_login.py`, `secure_store.py`, `stage_machine.py` | one-time account-ID setup, DPAPI storage |
| `Install-EcoFlowBLE.ps1` | installer with probe, cutover and rollback |
| `test_bridge.py` | safety tests: `python -m unittest test_bridge` |

Runtime state: `health.json` and a rotating `bridge.log` in `C:\ProgramData\EcoFlowBLE`.

## Tray fix

The tray in `../tray/NutTray.cs` now parses `battery.charge` as a decimal. The bridge reports values like
`88.61`, which the old integer parser rejected, showing `--` / −1 % despite live data.

## Caveats

- A phone using Bluetooth at the same time can interrupt telemetry.
- Not affiliated with EcoFlow. The BLE protocol comes from the community `ha-ef-ble` project.
