#!/usr/bin/env python3
"""A third real MCP "App": a mock smart-home device — get_device_state
and set_device_state over a small fixed set of devices, persisted to a
JSON file.

CLAUDE.md's Phase 2 bring-up list calls for a real Home Assistant
integration ("enough to prove the hub can see and act on at least one
real IoT device"); hub/README.md already discloses that as unbuilt —
there's no real IoT hardware in this environment to integrate with.
This is not that integration. It's a real MCP tool with a mock backend,
built so Phase 5's "full week of simulated real use" can exercise a
genuine "home automation" interaction (CLAUDE.md §5, Phase 5) instead
of silently skipping that category or mislabeling a plain Q&A as one.
Swapping the mock state dict below for a real Home Assistant REST/
WebSocket call is the actual integration work, still unbuilt, still
disclosed rather than implied.
"""
import argparse
import json
import sys
from pathlib import Path

from mcp.server.mcpserver import MCPServer

server = MCPServer("nex-smart-home")
_store_path: Path = Path("devices.json")
_default_devices = {"living_room_light": "off", "front_door_lock": "locked", "thermostat": "68F"}


def _load() -> dict:
    if not _store_path.exists():
        return dict(_default_devices)
    return json.loads(_store_path.read_text())


def _save(devices: dict) -> None:
    _store_path.write_text(json.dumps(devices, indent=2))


@server.tool()
def get_device_state(device: str) -> str:
    """Read a mock device's current state.

    Args:
        device: one of living_room_light, front_door_lock, thermostat.
    """
    devices = _load()
    if device not in devices:
        return f"unknown device {device!r}; known devices: {', '.join(devices)}"
    return f"{device}: {devices[device]}"


@server.tool()
def set_device_state(device: str, state: str) -> str:
    """Set a mock device's state.

    Args:
        device: one of living_room_light, front_door_lock, thermostat.
        state: the new state (e.g. "on", "off", "locked", "72F").
    """
    devices = _load()
    if device not in devices:
        return f"unknown device {device!r}; known devices: {', '.join(devices)}"
    devices[device] = state
    _save(devices)
    return f"{device} set to {state}"


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--store", type=Path, default=Path("devices.json"))
    args = parser.parse_args()
    _store_path = args.store
    if not _store_path.parent.is_dir():
        print(f"--store's parent directory {_store_path.parent} does not exist", file=sys.stderr)
        sys.exit(1)
    server.run(transport="stdio")
