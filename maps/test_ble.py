#!/usr/bin/env python3
"""Bench-test the ESP32's new binary BLE protocol without needing the phone
app (which doesn't speak it yet). Connects to the device, sends a real route
(borrowed from map data, same trick as visualiser.py's demo route) and then
walks fake telemetry along it — so you can watch the route overlay and live
position/heading render on actual hardware.

Usage:
    pip install bleak
    python3 test_ble.py                 # walk a real nearby road, looping
    python3 test_ble.py --no-route      # telemetry only, no route overlay
    python3 test_ble.py --stationary    # send one fixed telemetry packet and stop
"""
import argparse
import asyncio
import math
import struct
import sys
from pathlib import Path

from bleak import BleakClient, BleakScanner

import map_format
from visualiser import pick_demo_route

MAP_BIN = Path(__file__).parent / "map.bin"
SERVICE_UUID = "12345678-1234-1234-1234-1234567890ab"
CHAR_UUID = "87654321-4321-4321-4321-ba0987654321"

PACKET_TELEMETRY = 0x01
PACKET_ROUTE_START = 0x02
PACKET_ROUTE_CHUNK = 0x03
PACKET_ROUTE_END = 0x04
PACKET_ROUTE_CLEAR = 0x05

MODE_HOME, MODE_NAV, MODE_ARRIVED = 0, 1, 2

CHUNK_POINTS = 20       # comfortably under a negotiated MTU (4 + 20*8 = 164 bytes)
WALK_SPEED_MPS = 4.0    # ~9mph, a plausible cycling pace
TICK_SECONDS = 1.0      # matches the real app's planned ~1Hz telemetry rate


def build_telemetry(x_m: float, y_m: float, heading_deg: float, mode: int) -> bytes:
    x_cm = int(round(x_m * 100))
    y_cm = int(round(y_m * 100))
    heading_dd = int(round(heading_deg * 10))
    return struct.pack("<BiihB", PACKET_TELEMETRY, x_cm, y_cm, heading_dd, mode)


def build_route_start(total_points: int) -> bytes:
    return struct.pack("<BH", PACKET_ROUTE_START, total_points)


def build_route_chunk(seq: int, points) -> bytes:
    header = struct.pack("<BHB", PACKET_ROUTE_CHUNK, seq, len(points))
    body = b"".join(struct.pack("<ii", int(round(x * 100)), int(round(y * 100))) for x, y in points)
    return header + body


def build_route_end() -> bytes:
    return struct.pack("<B", PACKET_ROUTE_END)


def build_route_clear() -> bytes:
    return struct.pack("<B", PACKET_ROUTE_CLEAR)


def walk_positions(route):
    """Yield (x, y, heading_deg) stepping along `route` at WALK_SPEED_MPS, looping
    forever — same "ride" feel as the old on-device demo, but driven externally."""
    if len(route) < 2:
        while True:
            yield route[0][0], route[0][1], 0.0
    while True:
        for (x0, y0), (x1, y1) in zip(route, route[1:]):
            seg_len = math.hypot(x1 - x0, y1 - y0)
            if seg_len == 0:
                continue
            heading = math.degrees(math.atan2(x1 - x0, y1 - y0)) % 360
            steps = max(1, int(seg_len / (WALK_SPEED_MPS * TICK_SECONDS)))
            for i in range(steps):
                t = i / steps
                yield x0 + (x1 - x0) * t, y0 + (y1 - y0) * t, heading


async def scan(timeout=12.0):
    """Full scan returning {address: (BLEDevice, AdvertisementData)}. Checking both
    device.name AND adv.local_name matters — on some OS/bleak combos (notably
    macOS/CoreBluetooth) a device's advertised local name only shows up in the
    advertisement data, not the BLEDevice object's .name field, so a filter that
    only checks device.name can silently find nothing even though the device is
    right there and visible to a phone BLE app."""
    print(f"Scanning for {timeout:.0f}s...")
    return await BleakScanner.discover(timeout=timeout, return_adv=True)


def _has_our_service(adv) -> bool:
    return any(u.lower() == SERVICE_UUID.lower() for u in (adv.service_uuids or []))


def print_scan_results(devices):
    if not devices:
        print("No BLE devices seen at all. This usually means either:")
        print("  - Bluetooth is off, or your laptop's adapter isn't picking anything up")
        print("  - (macOS) Python/Terminal hasn't been granted Bluetooth permission —")
        print("    check System Settings > Privacy & Security > Bluetooth")
        return
    print(f"Found {len(devices)} device(s):")
    for address, (device, adv) in devices.items():
        name = device.name or adv.local_name or "(no name)"
        marker = "  <-- advertises our service UUID" if _has_our_service(adv) else ""
        print(f"  {address}  rssi={adv.rssi:>5}  name={name!r}  services={adv.service_uuids}{marker}")


async def find_device():
    # Match on the advertised service UUID, not name — the ESP32's name often only
    # shows up in a separate scan-response packet that doesn't reliably merge into
    # bleak's results on every OS/backend, but the service UUID rides in the
    # primary advertisement packet and matches every time (confirmed: your last
    # scan found 8 devices and bleak couldn't get a name off any of them, service
    # UUID sidesteps that whole problem).
    devices = await scan()
    for address, (device, adv) in devices.items():
        if _has_our_service(adv):
            name = device.name or adv.local_name or "(unnamed)"
            print(f"Found {name!r} ({address}) advertising our service UUID")
            return device
    print(f"No device advertising service {SERVICE_UUID} found. Here's everything seen instead:")
    print_scan_results(devices)
    sys.exit(1)


async def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--no-route", action="store_true", help="telemetry only, no route overlay")
    parser.add_argument("--stationary", action="store_true", help="send one packet and exit")
    parser.add_argument("--list", action="store_true", help="just scan and print every BLE device seen, then exit")
    args = parser.parse_args()

    if args.list:
        print_scan_results(await scan())
        return

    map_data = map_format.load(MAP_BIN)
    route = [] if args.no_route else pick_demo_route(map_data.ways)
    if not args.no_route and not route:
        print("No suitable road found for a demo route — falling back to --no-route behavior.")

    device = await find_device()
    async with BleakClient(device) as client:
        print("Connected.")

        if route:
            print(f"Sending ROUTE_START + {len(route)} points in chunks of {CHUNK_POINTS}...")
            await client.write_gatt_char(CHAR_UUID, build_route_start(len(route)), response=True)
            for seq, i in enumerate(range(0, len(route), CHUNK_POINTS)):
                chunk = route[i:i + CHUNK_POINTS]
                await client.write_gatt_char(CHAR_UUID, build_route_chunk(seq, chunk), response=True)
            await client.write_gatt_char(CHAR_UUID, build_route_end(), response=True)
            print("ROUTE_END sent — check the device: you should see the orange route overlay appear.")

        mode = MODE_NAV if route else MODE_HOME
        start_x, start_y = (route[0] if route else (0.0, 0.0))

        if args.stationary:
            print(f"Sending one TELEMETRY packet at ({start_x:.0f}, {start_y:.0f})m, then exiting.")
            await client.write_gatt_char(CHAR_UUID, build_telemetry(start_x, start_y, 0.0, mode), response=False)
            return

        print("Walking fake position along the route, ~1/sec. Ctrl+C to stop.")
        print("Watch the device: the map should scroll/rotate under the fixed red marker,")
        print("same as it will during a real ride.")
        positions = walk_positions(route) if route else None
        try:
            while True:
                if positions:
                    x, y, heading = next(positions)
                else:
                    x, y, heading = 0.0, 0.0, 0.0
                await client.write_gatt_char(CHAR_UUID, build_telemetry(x, y, heading, mode), response=False)
                print(f"  telemetry: ({x:7.1f}, {y:7.1f})m  heading={heading:5.1f}")
                await asyncio.sleep(TICK_SECONDS)
        except KeyboardInterrupt:
            print("\nSending ROUTE_CLEAR and exiting.")
            if route:
                await client.write_gatt_char(CHAR_UUID, build_route_clear(), response=True)


if __name__ == "__main__":
    asyncio.run(main())
