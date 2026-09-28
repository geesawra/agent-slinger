#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
# Adapted from Hydraulophone/Scripts/select_connected_iphone.py.
# The standalone selector is licensed under GPLv3; see LICENSE.device-selector.
"""Select one paired iPhone/iPad and establish its CoreDevice connection.

Only the chosen device is contacted. This helper never builds, installs, or
launches an app. stdout contains only its UDID, suitable for shell substitution.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from typing import Callable, TextIO


class DeviceSelectionError(ValueError):
    pass


@dataclass(frozen=True)
class Device:
    name: str
    udid: str
    identifier: str | None = None


def nested_value(device: dict, *paths: tuple[str, ...]) -> str | None:
    for path in paths:
        value: object = device
        for key in path:
            if not isinstance(value, dict):
                value = None
                break
            value = value.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


def parse_devices(payload: object) -> list[Device]:
    try:
        rows = payload["result"]["devices"]
    except (KeyError, TypeError) as error:
        raise DeviceSelectionError("The devicectl response omitted its device list.") from error
    if not isinstance(rows, list):
        raise DeviceSelectionError("The devicectl device list was not an array.")
    devices: dict[str, Device] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        udid = nested_value(row, ("hardwareProperties", "udid"),
                            ("properties", "hardware", "udid"),
                            ("properties", "udid"), ("udid",))
        if not udid:
            continue
        name = nested_value(row, ("deviceProperties", "name"),
                            ("properties", "state", "name"),
                            ("properties", "device", "name"),
                            ("properties", "name"), ("name",)) or "Unnamed iPhone or iPad"
        devices.setdefault(udid, Device(name, udid, nested_value(row, ("identifier",))))
    return list(devices.values())


def read_devices() -> list[Device]:
    # devicectl can print a human-readable table alongside JSON on stdout.
    # Read its dedicated JSON file instead of depending on console formatting.
    with tempfile.TemporaryDirectory(prefix="oesap-devices-") as directory:
        output = Path(directory) / "devices.json"
        command = [
            "xcrun", "devicectl", "list", "devices", "--filter",
            "Reality = 'physical' AND (Model CONTAINS 'iPhone' OR Model CONTAINS 'iPad')",
            "--json-output", str(output),
        ]
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=90)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise DeviceSelectionError("Could not read paired iPhones and iPads from devicectl.") from error
        if result.returncode != 0:
            raise DeviceSelectionError("devicectl could not list paired iPhones and iPads.")
        try:
            payload = json.loads(output.read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise DeviceSelectionError("Could not read the devicectl JSON device list.") from error
    return parse_devices(payload)


def select_device(
    devices: list[Device], *, override_id: str = "", requested: str = "",
    interactive: bool = False, reader: Callable[[], str] = input,
    error_stream: TextIO | None = None,
) -> Device:
    if not devices:
        raise DeviceSelectionError(
            "No paired physical iPhones or iPads were found. Connect and unlock a device, "
            "then trust this Mac and enable Developer Mode if prompted.")
    override_id, requested = override_id.strip(), requested.strip()
    selector = override_id or requested
    variable = "OESAP_DEVICE_ID" if override_id else "OESAP_DEVICE"
    if selector:
        matches = [device for device in devices if selector in (
            (device.udid, device.identifier) if override_id
            else (device.udid, device.identifier, device.name))]
        if len(matches) == 1:
            return matches[0]
        if len(matches) > 1:
            raise DeviceSelectionError(f"{variable} matches multiple devices; use OESAP_DEVICE_ID with a UDID.")
        available = ", ".join(f"{device.name} ({device.udid})" for device in devices)
        raise DeviceSelectionError(f"No paired device matches {variable}. Available: {available}")
    if len(devices) == 1:
        return devices[0]
    if not interactive:
        raise DeviceSelectionError(
            "Multiple devices are paired. Set OESAP_DEVICE_ID to a UDID, or OESAP_DEVICE "
            "to an exact device name, for non-interactive use.")
    stream = error_stream if error_stream is not None else sys.stderr
    print("Select an iPhone or iPad:", file=stream)
    for index, device in enumerate(devices, start=1):
        print(f"  {index}. {device.name} ({device.udid})", file=stream)
    print("Device number: ", end="", file=stream, flush=True)
    try:
        number = int(reader().strip())
        if not 1 <= number <= len(devices):
            raise ValueError("out of range")
    except (ValueError, EOFError) as error:
        raise DeviceSelectionError("Choose one of the listed device numbers.") from error
    return devices[number - 1]


def connect_device(device: Device) -> None:
    # A paired Wi-Fi device may need a details request to open its live tunnel.
    command = ["xcrun", "devicectl", "device", "info", "details", "--device", device.udid]
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise DeviceSelectionError(
            f"Could not connect to {device.name}. Unlock it and check its connection.") from error
    if result.returncode != 0:
        raise DeviceSelectionError(
            f"Could not connect to {device.name}. Unlock it and check its connection.")


def main() -> None:
    try:
        selected = select_device(
            read_devices(), override_id=os.environ.get("OESAP_DEVICE_ID", ""),
            requested=os.environ.get("OESAP_DEVICE", ""), interactive=sys.stdin.isatty())
        connect_device(selected)
    except DeviceSelectionError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1) from error
    print(selected.udid)


if __name__ == "__main__":
    main()
