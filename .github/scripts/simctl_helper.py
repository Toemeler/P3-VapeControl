#!/usr/bin/env python3
"""Print a simulator's boot state.

Kept in a file rather than inlined in the workflow: a python -c body inside a
YAML block scalar inherits the block's indentation and fails to parse.

Usage: simctl_helper.py state <udid>   -> Booted / Shutdown / Unknown
"""
import json
import subprocess
import sys


def find_state(udid):
    out = subprocess.run(
        ["xcrun", "simctl", "list", "devices", "-j"], check=True, capture_output=True, text=True
    ).stdout
    for device_list in json.loads(out)["devices"].values():
        for device in device_list:
            if device["udid"] == udid:
                return device["state"]
    return "Unknown"


if __name__ == "__main__":
    print(find_state(sys.argv[2]))
