#!/usr/bin/env python3
"""Ask a simulator how far along it is.

Kept in a file rather than inlined in the workflow: a python -c body inside a
YAML block scalar inherits the block's indentation and fails to parse.

Usage:
  simctl_helper.py state <udid>   -> Booted / Shutdown / Unknown
  simctl_helper.py ready <udid>   -> ready / waiting
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


def is_ready(udid, timeout=10):
    """Whether the device will actually accept an app launch.

    `simctl list` reports Booted well before SpringBoard is running, and
    `simctl launch` aimed into that window blocks rather than failing - which
    is how a merely cold simulator burns the capture script's entire retry
    budget and takes the job down with it. SpringBoard being up is the honest
    signal that the device can host an app.

    Anything short of a clear yes counts as waiting: a spawn that is refused
    or times out means the device is still busy starting, which is exactly the
    state the caller is waiting out.
    """
    try:
        probe = subprocess.run(
            ["xcrun", "simctl", "spawn", udid, "launchctl", "print", "system"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (subprocess.TimeoutExpired, OSError):
        return False
    return probe.returncode == 0 and "com.apple.springboard" in probe.stdout


if __name__ == "__main__":
    command, udid = sys.argv[1], sys.argv[2]
    if command == "ready":
        print("ready" if is_ready(udid) else "waiting")
    else:
        print(find_state(udid))
