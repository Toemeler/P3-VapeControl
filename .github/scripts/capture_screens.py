#!/usr/bin/env python3
"""Install the app and screenshot every tab, in light and dark appearance.

simctl cannot tap, so tabs are not reachable by driving the UI. The app reads
its initial tab from the `uiTab` launch argument instead, and this script
relaunches once per tab.

Every simctl call runs with a deadline: simctl blocks indefinitely when the
simulator is wedged, and macOS ships no coreutils `timeout` to bound it with.

Usage: capture_screens.py <udid> <app path> <bundle id> <output dir>
"""
import os
import subprocess
import sys
import time

TABS = [("scan", 0), ("device", 1), ("log", 2)]
APPEARANCES = ["light", "dark"]
SPRINGBOARD_TIMEOUT = 180


def run(args, timeout, check=True):
    print(f"$ {' '.join(args)}", flush=True)
    try:
        result = subprocess.run(args, timeout=timeout, capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        sys.exit(f"::error::timed out after {timeout}s: {' '.join(args)}")
    for stream, target in ((result.stdout, sys.stdout), (result.stderr, sys.stderr)):
        if stream.strip():
            print(stream.strip(), file=target, flush=True)
    if check and result.returncode != 0:
        sys.exit(f"::error::command failed ({result.returncode}): {' '.join(args)}")
    return result


def wait_for_springboard(udid):
    """Booted is not ready: installing before SpringBoard is up can wedge simctl."""
    deadline = time.time() + SPRINGBOARD_TIMEOUT
    while time.time() < deadline:
        result = subprocess.run(
            ["xcrun", "simctl", "spawn", udid, "launchctl", "print", "system"],
            capture_output=True,
            text=True,
            timeout=60,
        )
        if "SpringBoard" in result.stdout:
            print("SpringBoard is up", flush=True)
            return
        time.sleep(5)
    print("::warning::SpringBoard never appeared; continuing anyway", flush=True)


def dump_crash_reports():
    reports = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    if not os.path.isdir(reports):
        return
    for name in sorted(os.listdir(reports)):
        if "PaxController" in name:
            print(f"--- {name} ---", flush=True)
            with open(os.path.join(reports, name), errors="replace") as fh:
                print("".join(fh.readlines()[:80]), flush=True)


def launch(udid, bundle_id, tab):
    result = run(
        [
            "xcrun", "simctl", "launch", "--terminate-running-process",
            udid, bundle_id, "-uiTab", str(tab),
        ],
        timeout=120,
    )
    pid = result.stdout.strip().rsplit(":", 1)[-1].strip()
    time.sleep(6)
    # Simulator apps are ordinary host processes, so ps is the honest check;
    # launchctl inside the simulator does not list them under the bundle id.
    if subprocess.run(["ps", "-p", pid], capture_output=True).returncode != 0:
        dump_crash_reports()
        sys.exit(f"::error::{bundle_id} (pid {pid}) exited after launch - it likely crashed")
    return pid


def main():
    udid, app_path, bundle_id, out_dir = sys.argv[1:5]
    os.makedirs(out_dir, exist_ok=True)

    wait_for_springboard(udid)
    run(["xcrun", "simctl", "install", udid, app_path], timeout=180)

    index = 0
    for name, tab in TABS:
        launch(udid, bundle_id, tab)
        for appearance in APPEARANCES:
            index += 1
            run(["xcrun", "simctl", "ui", udid, "appearance", appearance], timeout=60, check=False)
            time.sleep(2)
            path = os.path.join(out_dir, f"{index:02d}-{name}-{appearance}.png")
            run(["xcrun", "simctl", "io", udid, "screenshot", path], timeout=90)
            print(f"captured {path}", flush=True)

    print(f"{index} screenshots written to {out_dir}", flush=True)


if __name__ == "__main__":
    main()
