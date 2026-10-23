import asyncio
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock
import urllib.error
import urllib.parse
import urllib.request

from bridge import Telemetry, load_serial, nut_client

NUT_BIN = Path(r"C:\NUT\bin")


class SafetyTests(unittest.TestCase):
    def setUp(self):
        self.state = Telemetry()
        self.state.connected = True
        self.state.update("battery_level", 90, now=100)
        self.state.update("plugged_in_ac", 1, now=100)

    def test_zero_input_watts_is_not_an_outage(self):
        self.state.update("ac_input_power", 0, now=100)
        self.assertEqual(self.state.nut_values(101)["ups.status"], "OL")

    def test_low_battery_requires_confirmed_ac_loss(self):
        self.state.update("battery_level", 10, now=100)
        self.assertEqual(self.state.nut_values(101)["ups.status"], "OL")
        self.state.update("plugged_in_ac", 0, now=100)
        self.assertEqual(self.state.nut_values(101)["ups.status"], "OB LB")

    def test_old_ac_flag_cannot_be_refreshed_by_other_packets(self):
        self.state.update("battery_level", 10, now=160)
        self.assertIsNone(self.state.nut_values(160))

    def test_disconnect_immediately_invalidates_cached_readings(self):
        self.state.connected = False
        self.assertIsNone(self.state.nut_values(101))

    def test_invalid_values_are_unavailable(self):
        for value in (-1, 101, float("nan"), float("inf")):
            self.state.update("battery_level", value, now=100)
            self.assertIsNone(self.state.nut_values(101))

    def test_firmware_without_plug_flag_uses_measured_ac_power(self):
        self.state.updated.pop("plugged_in_ac")
        self.state.update("ac_input_power", 254, now=100)
        self.assertEqual(self.state.nut_values(101)["ups.status"], "OL")

    def test_zero_watts_without_plug_flag_is_not_an_outage(self):
        self.state.updated.pop("plugged_in_ac")
        self.state.update("ac_input_power", 0, now=100)
        self.assertIsNone(self.state.nut_values(101))

    def test_battery_power_must_corroborate_ac_loss_and_persist(self):
        self.state.updated.pop("plugged_in_ac")
        self.state.update("ac_input_power", 0, now=100)
        self.state.update("battery_net_power", -270, now=100)
        self.state.update("output_power", 254, now=100)
        self.state.update("battery_level", 10, now=100)
        self.assertIsNone(self.state.nut_values(101))
        self.assertEqual(self.state.nut_values(104)["ups.status"], "OB LB")
        self.state.update("ac_input_power", 254, now=105)
        self.assertEqual(self.state.nut_values(105)["ups.status"], "OL")


class SerialConfigTests(unittest.TestCase):
    def load(self, content, env=None):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "serial.txt"
            if content is not None:
                path.write_bytes(content)
            environment = {key: value for key, value in os.environ.items() if key != "ECOFLOW_SERIAL"}
            if env is not None:
                environment["ECOFLOW_SERIAL"] = env
            with mock.patch.dict(os.environ, environment, clear=True):
                return load_serial(path)

    def test_missing_serial_is_empty(self):
        self.assertEqual(self.load(None), "")

    def test_file_variants(self):
        self.assertEqual(self.load(b"ABC123\r\n"), "ABC123")
        self.assertEqual(self.load(b"\xef\xbb\xbfABC123"), "ABC123")
        self.assertEqual(self.load("ABC123\r\n".encode("utf-16")), "ABC123")

    def test_environment_wins_and_garbage_is_rejected(self):
        self.assertEqual(self.load(b"ABC123", env="XYZ789"), "XYZ789")
        self.assertEqual(self.load(b"not a serial"), "")
        self.assertEqual(self.load(b"A" * 17), "")


@unittest.skipUnless((NUT_BIN / "upsc.exe").exists() and (NUT_BIN / "dummy-ups.exe").exists(),
                     r"needs NUT for Windows in C:\NUT")
class NutProtocolTests(unittest.IsolatedAsyncioTestCase):
    async def test_windows_nut_repeater_reads_source(self):
        state = Telemetry()
        state.connected = True
        state.update("battery_level", 90)
        state.update("plugged_in_ac", 1)
        server = await asyncio.start_server(lambda r, w: nut_client(r, w, state), "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        async with server:
            proc = await asyncio.create_subprocess_exec(
                r"C:\NUT\bin\dummy-ups.exe", "-s", "ecoflow_ble_probe", "-d", "1",
                "-x", f"port=ecoflow_ble@127.0.0.1:{port}", "-x", "mode=repeater",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            try:
                output, error = await asyncio.wait_for(proc.communicate(), 15)
            except TimeoutError:
                proc.kill()
                await proc.wait()
                raise
            self.assertEqual(proc.returncode, 0, error.decode())
            self.assertIn(b"ups.status: OL", output)

    async def test_windows_upsc_and_fail_closed_stale(self):
        state = Telemetry()
        state.connected = True
        state.update("battery_level", 90)
        state.update("plugged_in_ac", 1)
        server = await asyncio.start_server(lambda r, w: nut_client(r, w, state), "127.0.0.1", 0)
        port = server.sockets[0].getsockname()[1]
        async with server:
            proc = await asyncio.create_subprocess_exec(
                r"C:\NUT\bin\upsc.exe", f"ecoflow_ble@127.0.0.1:{port}",
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            output, error = await asyncio.wait_for(proc.communicate(), 10)
            self.assertEqual(proc.returncode, 0, error.decode())
            self.assertIn(b"ups.status: OL", output)
            state.connected = False
            reader, writer = await asyncio.open_connection("127.0.0.1", port)
            writer.write(b"LIST VAR ecoflow_ble\n")
            await writer.drain()
            self.assertEqual(await reader.readline(), b"ERR DATA-STALE\n")
            writer.write(b"INSTCMD ecoflow_ble load.off\n")
            await writer.drain()
            self.assertEqual(await reader.readline(), b"ERR FEATURE-NOT-SUPPORTED\n")
            writer.close()
            await writer.wait_closed()


def verify_setup_form():
    url = Path(__file__).with_name("setup-url.txt").read_text().strip()
    page = urllib.request.urlopen(url).read()
    assert b'name="csrf"' in page
    request = urllib.request.Request(url, data=urllib.parse.urlencode({"csrf": url.rsplit("/", 1)[-1]}).encode())
    try:
        urllib.request.urlopen(request)
        raise AssertionError("Empty form must not be accepted")
    except urllib.error.HTTPError as error:
        assert error.code == 400
        assert b"Enter your EcoFlow email" in error.read()
    print("Setup form submission passed without an Origin header.")


if __name__ == "__main__":
    import sys
    if "--setup" in sys.argv:
        verify_setup_form()
    else:
        unittest.main()
