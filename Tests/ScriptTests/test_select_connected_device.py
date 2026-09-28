"""Offline selector regression tests: devicectl is always mocked."""

import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).parents[2] / "Scripts" / "select_connected_device.py"
SPEC = importlib.util.spec_from_file_location("select_connected_device", SCRIPT)
selector = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = selector
SPEC.loader.exec_module(selector)


class DeviceSelectorTests(unittest.TestCase):
    def setUp(self):
        self.phone = selector.Device("Fixture iPhone", "PHONE-UDID", "phone-core-id")
        self.pad = selector.Device("Fixture iPad", "PAD-UDID", "pad-core-id")

    def test_single_device_is_unambiguous(self):
        self.assertEqual(selector.select_device([self.pad]), self.pad)

    def test_id_override_takes_precedence_over_optional_name(self):
        selected = selector.select_device(
            [self.phone, self.pad], override_id="pad-core-id", requested="Fixture iPhone")
        self.assertEqual(selected, self.pad)

    def test_optional_exact_name_selects_device_but_duplicate_names_fail(self):
        self.assertEqual(selector.select_device(
            [self.phone, self.pad], requested="Fixture iPhone"), self.phone)
        duplicate = selector.Device(self.phone.name, "OTHER-UDID")
        with self.assertRaises(selector.DeviceSelectionError):
            selector.select_device([self.phone, duplicate], requested=self.phone.name)

    def test_zero_devices_ambiguity_and_unmatched_override_never_choose_silently(self):
        for devices, options in [
            ([], {}), ([self.phone, self.pad], {}),
            ([self.phone], {"override_id": "missing"}),
            ([self.phone], {"override_id": self.phone.name}),
        ]:
            with self.subTest(options=options), self.assertRaises(selector.DeviceSelectionError):
                selector.select_device(devices, **options)

    def test_interactive_picker_has_one_based_bounds_and_stderr_prompt(self):
        for invalid in ["0", "-1", "3", "word", ""]:
            with self.subTest(selection=invalid), self.assertRaises(selector.DeviceSelectionError):
                selector.select_device([self.phone, self.pad], interactive=True,
                                       reader=lambda: invalid, error_stream=io.StringIO())
        output, errors = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(output):
            result = selector.select_device([self.phone, self.pad], interactive=True,
                                            reader=lambda: "2", error_stream=errors)
        self.assertEqual(result, self.pad)
        self.assertEqual(output.getvalue(), "")
        self.assertIn("Device number:", errors.getvalue())

    def test_parser_supports_modern_and_older_devicectl_shapes_and_deduplicates(self):
        devices = selector.parse_devices({"result": {"devices": [
            {"deviceProperties": {"name": "Fixture iPhone"},
             "hardwareProperties": {"udid": "PHONE-UDID"}, "identifier": "phone-core-id"},
            {"properties": {"state": {"name": "Fixture iPad"},
                            "hardware": {"udid": "PAD-UDID"}}, "identifier": "pad-core-id"},
            {"name": "Duplicate", "udid": "PHONE-UDID"}, {}, None,
        ]}})
        self.assertEqual(devices, [self.phone, self.pad])
        for malformed in [{}, {"result": {"devices": {}}}, None]:
            with self.assertRaises(selector.DeviceSelectionError):
                selector.parse_devices(malformed)

    def test_cli_reads_json_file_even_when_console_has_table_and_contacts_only_selection(self):
        calls = []

        def fake_run(command, **kwargs):
            calls.append(command)
            if "--json-output" in command:
                path = Path(command[command.index("--json-output") + 1])
                path.write_text(json.dumps({"result": {"devices": [
                    {"name": "Fixture iPhone", "udid": "PHONE-UDID"},
                    {"name": "Fixture iPad", "udid": "PAD-UDID"},
                ]}}))
            return subprocess.CompletedProcess(command, 0, stdout="A human-readable table\n", stderr="")

        output = io.StringIO()
        with patch.object(selector.subprocess, "run", side_effect=fake_run), \
                patch.dict(os.environ, {"OESAP_DEVICE_ID": "PAD-UDID", "OESAP_DEVICE": ""}), \
                contextlib.redirect_stdout(output):
            selector.main()
        self.assertEqual(output.getvalue(), "PAD-UDID\n")
        self.assertEqual(len(calls), 2)
        self.assertIn("iPad", calls[0][calls[0].index("--filter") + 1])
        self.assertEqual(calls[1], ["xcrun", "devicectl", "device", "info", "details",
                                   "--device", "PAD-UDID"])
        self.assertFalse(any("install" in call or "launch" in call for call in calls))

    def test_failed_or_timed_out_tunnel_does_not_emit_a_device_id(self):
        for failure in [subprocess.CompletedProcess([], 1), subprocess.TimeoutExpired([], 30)]:
            mock_options = {"side_effect": failure} if isinstance(failure, Exception) else {"return_value": failure}
            with patch.object(selector.subprocess, "run", **mock_options), \
                    self.assertRaises(selector.DeviceSelectionError):
                selector.connect_device(self.phone)


if __name__ == "__main__":
    unittest.main()
