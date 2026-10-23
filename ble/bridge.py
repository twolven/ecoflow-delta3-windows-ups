"""Read-only EcoFlow BLE telemetry and a loopback NUT source server.

Production NUT can consume this through dummy-ups in repeater mode, which marks
data stale if this process dies or returns DATA-STALE. No outlet control API.
"""
import argparse
import asyncio
import contextlib
import json
import logging
from logging.handlers import RotatingFileHandler
import math
import os
from pathlib import Path
import shlex
import sys
import time

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "vendor" / "ha-ef-ble" / "custom_components" / "ef_ble"))
from bleak import BleakScanner
from eflib.devices.delta3_plus import Device
from eflib.pb import pd335_sys_pb2
from eflib.logging_util import LogOptions
from secure_store import load_user_id

def load_serial(path=ROOT / "serial.txt"):
    """Serial of the unit to monitor: ECOFLOW_SERIAL, else serial.txt written by scan.py --save.

    Returns "" when nothing usable is configured; the bridge then refuses to start.
    """
    serial = os.environ.get("ECOFLOW_SERIAL", "").strip()
    if not serial and path.exists():
        raw = path.read_bytes()
        # Tolerate hand-written files: PowerShell 5 `>` writes UTF-16, Notepad may add a BOM.
        encoding = "utf-16" if raw[:2] in (b"\xff\xfe", b"\xfe\xff") else "utf-8-sig"
        serial = raw.decode(encoding, errors="replace").strip()
    # Advertised serials are up to 16 ASCII letters/digits.
    if not (serial.isascii() and serial.isalnum() and len(serial) <= 16):
        return ""
    return serial


SERIAL = load_serial()
UPS = "ecoflow_ble"
PORT = 3494
STALE_SECONDS = 45
FIELDS = {
    "cms_batt_soc": "battery_level",
    "plug_in_info_ac_charger_flag": "plugged_in_ac",
    "pow_get_ac_in": "ac_input_power",
    "pow_get_ac_out": "ac_output_power",
    "pow_in_sum_w": "input_power",
    "pow_out_sum_w": "output_power",
    "cms_dsg_rem_time": "remaining_time_discharging",
    "bms_max_cell_temp": "cell_temperature",
    "pow_get_bms": "battery_net_power",
}
LOG = logging.getLogger("ecoflow_bridge")


class Telemetry:
    def __init__(self):
        self.connected = False
        self.values = {}
        self.updated = {}
        self.connection = "waiting_for_setup"
        self.battery_since = None

    def update(self, name, value, now=None):
        self.values[name] = value
        self.updated[name] = time.monotonic() if now is None else now

    def fresh(self, name, now):
        return name in self.updated and now - self.updated[name] < STALE_SECONDS

    def nut_values(self, now=None):
        now = time.monotonic() if now is None else now
        required = ("battery_level",)
        if not self.connected or not all(self.fresh(key, now) for key in required):
            return None
        battery = self.values["battery_level"]
        if not isinstance(battery, (float, int)) or not math.isfinite(battery) or not 0 <= battery <= 100:
            return None
        status = self.power_source(now)
        if status is None:
            return None
        plugged = status == "OL"
        if not plugged and battery <= 15:
            status += " LB"
        result = {
            "device.mfr": "EcoFlow", "device.model": "DELTA 3 Plus",
            "device.serial": SERIAL, "device.type": "ups",
            "ups.mfr": "EcoFlow", "ups.model": "DELTA 3 Plus",
            "ups.serial": SERIAL, "ups.status": status,
            "battery.charge": str(round(battery, 2)), "battery.charge.low": "15",
            "driver.name": "ecoflow-ble-readonly", "driver.version": "1.0",
        }
        for source, target in (("ac_input_power", "input.realpower"),
                               ("ac_output_power", "ups.realpower"),
                               ("cell_temperature", "battery.temperature")):
            value = self.values.get(source)
            if self.fresh(source, now) and isinstance(value, (int, float)) and math.isfinite(value):
                result[target] = str(round(value, 2))
        minutes = self.values.get("remaining_time_discharging")
        if (not plugged and self.fresh("remaining_time_discharging", now)
                and isinstance(minutes, (int, float)) and 0 < minutes < 5999):
            result["battery.runtime"] = str(round(minutes * 60))
        return result

    def power_source(self, now):
        ac_watts = self.values.get("ac_input_power")
        fresh_ac = self.fresh("ac_input_power", now) and isinstance(ac_watts, (int, float)) and math.isfinite(ac_watts)
        if self.fresh("plugged_in_ac", now):
            plugged = self.values["plugged_in_ac"]
            if plugged not in (0, 1, False, True):
                return None
            # Inconsistent measurements must never generate a low-battery shutdown.
            if not plugged and fresh_ac and ac_watts > 10:
                return None
            self.battery_since = None
            return "OL" if plugged else "OB"
        # Some firmware never sends the optional AC-plug flag (protobuf field 202).
        # Positive AC input proves mains is supplying power. Zero watts alone
        # cannot prove an outage; require sustained matching battery discharge.
        if fresh_ac and ac_watts > 10:
            self.battery_since = None
            return "OL"
        battery_net = self.values.get("battery_net_power")
        output = self.values.get("output_power")
        corroborated = (fresh_ac and 0 <= ac_watts <= 10
                        and self.fresh("battery_net_power", now)
                        and self.fresh("output_power", now)
                        and isinstance(battery_net, (int, float))
                        and isinstance(output, (int, float))
                        and math.isfinite(battery_net) and math.isfinite(output)
                        and output >= 10 and -battery_net >= max(10, output * 0.5))
        if not corroborated:
            self.battery_since = None
            return None
        self.battery_since = now if self.battery_since is None else self.battery_since
        return "OB" if now - self.battery_since >= 3 else None

    def write_health(self):
        now = time.monotonic()
        payload = {"time": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                   "connection": self.connection, "connected": self.connected,
                   "fresh": self.nut_values(now) is not None,
                   "values": self.values,
                   "field_age_seconds": {key: round(now - value, 1) for key, value in self.updated.items()}}
        temporary = ROOT / "health.json.tmp"
        temporary.write_text(json.dumps(payload, indent=2))
        temporary.replace(ROOT / "health.json")


class ReadOnlyDelta(Device):
    """DELTA 3 Plus, with configuration writes and clock synchronization blocked."""
    def __init__(self, ble_device, advertisement, telemetry):
        super().__init__(ble_device, advertisement, SERIAL)
        self.telemetry = telemetry

    async def _send_config_packet(self, message):
        raise PermissionError("This telemetry bridge does not permit configuration writes")

    async def data_parse(self, packet):
        # Only telemetry uploads are parsed. Ignore time-setting requests.
        if packet.src == 0x02 and packet.cmd_set == 0xFE and packet.cmd_id == 0x15:
            message = pd335_sys_pb2.DisplayPropertyUpload()
            message.ParseFromString(packet.payload)
            diagnostic = {field.name: {"field": field.number, "value": value}
                          for field, value in message.ListFields()
                          if isinstance(value, (int, float, bool))
                          and any(key in field.name for key in ("plug", "flow", "ac_", "pow_"))}
            (ROOT / "firmware-fields.json").write_text(json.dumps(diagnostic, indent=2))
            result = await super().data_parse(packet)
            for field, value in message.ListFields():
                if field.name in FIELDS:
                    if field.name == "pow_get_ac_out":
                        value = abs(value)
                    self.telemetry.update(FIELDS[field.name], value)
            return result
        return True


async def discover():
    advertisement = None

    def matches(device, adv):
        nonlocal advertisement
        data = adv.manufacturer_data.get(0xB5B5, b"")
        if data[1:17].strip(b"\0") == SERIAL.encode():
            advertisement = adv
            return True
        return False

    device = await BleakScanner.find_device_by_filter(matches, timeout=20)
    if device is None:
        raise RuntimeError("Target EcoFlow is not advertising; its Bluetooth connection may be in use")
    return device, advertisement


async def connect_once(telemetry):
    telemetry.values.clear()
    telemetry.updated.clear()
    telemetry.battery_since = None
    telemetry.connection = "discovering"
    telemetry.write_health()
    ble_device, adv = await discover()
    device = ReadOnlyDelta(ble_device, adv, telemetry)
    device.with_disabled_reconnect().with_logging_options(LogOptions.MASKED)

    def state_changed(state):
        telemetry.connection = str(state)
        telemetry.connected = state.authenticated
        telemetry.write_health()
        LOG.info("Bluetooth state: %s", state)

    device.on_connection_state_change(state_changed)
    try:
        LOG.info("Connecting to DELTA 3 Plus; encryption type %s", device.scan_record.encrypt_type)
        await device.connect(user_id=load_user_id(ROOT / "user-id.dpapi"), max_attempts=1)
        await asyncio.wait_for(device.wait_until_authenticated_or_error(raise_on_error=True), timeout=35)
        if not telemetry.connected:
            raise RuntimeError("Bluetooth authentication did not complete")
        return device
    except BaseException:
        with contextlib.suppress(Exception):
            await device.disconnect()
        raise


async def telemetry_worker(telemetry, probe=False):
    deadline = time.monotonic() + 1800
    while not (ROOT / "user-id.dpapi").exists():
        if time.monotonic() > deadline:
            raise TimeoutError("Setup did not complete within 30 minutes")
        await asyncio.sleep(2)
    LOG.info("Account ID available; beginning read-only BLE connection")
    cycle = 0
    while True:
        device = None
        try:
            cycle += 1
            device = await connect_once(telemetry)
            start = time.monotonic()
            last_good = start
            next_report = 0
            valid_samples = 0
            while telemetry.connected:
                telemetry.write_health()
                now = time.monotonic()
                if telemetry.nut_values() is not None:
                    last_good = now
                    valid_samples += 1
                    if now >= next_report:
                        LOG.info("Live telemetry: %s", json.dumps(telemetry.values, sort_keys=True))
                        next_report = now + 30
                if probe and now - start >= 25:
                    if valid_samples == 0:
                        raise RuntimeError("Authenticated but required battery/AC-presence fields were not received")
                    LOG.info("Probe cycle %s passed with %s valid samples", cycle, valid_samples)
                    break
                if not valid_samples and now - start > 60:
                    raise RuntimeError("No complete telemetry after 60 seconds")
                if now - last_good > 60:
                    raise RuntimeError("Telemetry stopped updating; reconnecting Bluetooth")
                await asyncio.sleep(1)
            if probe and cycle >= 2:
                return
        except Exception as error:
            LOG.error("Connection attempt failed: %s: %s", type(error).__name__, error)
            if probe:
                raise
        finally:
            telemetry.connected = False
            telemetry.connection = "disconnected"
            telemetry.write_health()
            if device is not None:
                with contextlib.suppress(Exception):
                    await device.disconnect()
        await asyncio.sleep(5 if probe else 15)


def quote(value):
    return '"' + str(value).replace('\\', '\\\\').replace('"', '\\"') + '"'


async def nut_client(reader, writer, telemetry):
    try:
        while line := await asyncio.wait_for(reader.readline(), timeout=90):
            if len(line) > 4096:
                break
            parts = shlex.split(line.decode("utf-8").strip())
            command = [part.upper() for part in parts]
            response = "ERR FEATURE-NOT-SUPPORTED"
            if command == ["VER"]:
                response = "EcoFlow BLE read-only NUT source 1.0"
            elif command == ["NETVER"]:
                response = "1.3"
            elif command == ["LIST", "UPS"]:
                response = f'BEGIN LIST UPS\nUPS {UPS} "EcoFlow DELTA 3 Plus Bluetooth"\nEND LIST UPS'
            elif len(parts) >= 3 and command[:2] == ["GET", "UPSDESC"] and parts[2] == UPS:
                response = f'UPSDESC {UPS} "EcoFlow DELTA 3 Plus Bluetooth"'
            elif command[:2] in (["GET", "VAR"], ["LIST", "VAR"]):
                if len(parts) < 3 or parts[2] != UPS:
                    response = "ERR UNKNOWN-UPS"
                elif (values := telemetry.nut_values()) is None:
                    response = "ERR DATA-STALE"
                elif command[:2] == ["LIST", "VAR"]:
                    rows = [f"VAR {UPS} {key} {quote(value)}" for key, value in sorted(values.items())]
                    response = f"BEGIN LIST VAR {UPS}\n" + "\n".join(rows) + f"\nEND LIST VAR {UPS}"
                elif len(parts) == 4 and parts[3] in values:
                    response = f"VAR {UPS} {parts[3]} {quote(values[parts[3]])}"
                else:
                    response = "ERR VAR-NOT-SUPPORTED"
            elif command == ["LOGOUT"]:
                writer.write(b"OK Goodbye\n")
                await writer.drain()
                break
            # No authentication, writes, instant commands or shutdown commands accepted.
            writer.write((response + "\n").encode())
            await writer.drain()
    except (ConnectionError, TimeoutError, ValueError, UnicodeError):
        pass
    finally:
        writer.close()
        with contextlib.suppress(Exception):
            await writer.wait_closed()


async def main(probe=False):
    telemetry = Telemetry()
    telemetry.write_health()
    server = await asyncio.start_server(lambda r, w: nut_client(r, w, telemetry), "127.0.0.1", PORT, limit=4096)
    LOG.info("Read-only NUT source listening on 127.0.0.1:%s; waiting for setup", PORT)
    async with server:
        await telemetry_worker(telemetry, probe)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--probe", action="store_true", help="Test two read-only connect/read/disconnect cycles")
    args = parser.parse_args()
    handler = RotatingFileHandler(ROOT / "bridge.log", maxBytes=2_000_000, backupCount=3, encoding="utf-8")
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s", handlers=[handler, logging.StreamHandler()])
    if not SERIAL:
        # Logged as well: under the SYSTEM task (pythonw) there is no console to show the exit message.
        LOG.error("No valid EcoFlow serial configured. Run scan.py --save, or set ECOFLOW_SERIAL.")
        raise SystemExit("No valid EcoFlow serial configured. Run scan.py --save, or set ECOFLOW_SERIAL.")
    asyncio.run(main(args.probe))
