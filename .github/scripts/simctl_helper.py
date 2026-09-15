#!/usr/bin/env python3
"""Ask a simulator how far along it is.

Kept in a file rather than inlined in the workflow: a python -c body inside a
YAML block scalar inherits the block's indentation and fails to parse.

Usage:
  simctl_helper.py state <udid>   -> Booted / Shutdown / Unknown
  simctl_helper.py ready <udid>   -> "ready: ..." / "waiting: ..."
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


def probe_ready(udid, timeout=10):
    """Whether the device will actually accept an app launch, and why.

    `simctl list` reports Booted well before SpringBoard is running, and
    `simctl launch` aimed into that window blocks rather than failing - which
    is how a merely cold simulator burns the capture script's entire retry
    budget and takes the job down with it. SpringBoard being up is the honest
    signal that the device can host an app.

    Returns (ready, detail). The detail is carried into the workflow's warning
    so a probe that never succeeds says why, instead of looking like a device
    that was merely slow - which is exactly how a case-sensitive match on the
    service name went unnoticed through a whole green run.
    """
    try:
        probe = subprocess.run(
            ["xcrun", "simctl", "spawn", udid, "launchctl", "print", "system"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return False, "probe timed out"
    except OSError as exc:
        return False, f"probe could not run: {exc}"

    if probe.returncode != 0:
        detail = probe.stderr.strip().splitlines()
        return False, f"launchctl exited {probe.returncode}: {detail[0] if detail else 'no stderr'}"
    # Case-insensitive: launchd lists the job as com.apple.SpringBoard.
    if "springboard" in probe.stdout.lower():
        return True, "springboard running"
    return False, "springboard not listed yet"


if __name__ == "__main__":
    command, udid = sys.argv[1], sys.argv[2]
    if command == "ready":
        ready, detail = probe_ready(udid)
        print(f"{'ready' if ready else 'waiting'}: {detail}")
    else:
        print(find_state(udid))
