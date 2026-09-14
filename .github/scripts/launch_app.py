#!/usr/bin/env python3
"""Install and launch the app on a booted simulator, with real timeouts.

simctl can block indefinitely when the simulator is wedged, and macOS has no
coreutils `timeout`, so every call goes through subprocess with a deadline.

Usage: launch_app.py <udid> <app path> <bundle id>
"""
import os
import subprocess
import sys
import time

BUNDLE_READY_TIMEOUT = 180


def run(args, timeout, check=True):
    print(f"$ {' '.join(args)}", flush=True)
    try:
        result = subprocess.run(args, timeout=timeout, capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        sys.exit(f"::error::timed out after {timeout}s: {' '.join(args)}")
    if result.stdout.strip():
        print(result.stdout.strip(), flush=True)
    if result.stderr.strip():
        print(result.stderr.strip(), file=sys.stderr, flush=True)
    if check and result.returncode != 0:
        sys.exit(f"::error::command failed ({result.returncode}): {' '.join(args)}")
    return result


def wait_for_springboard(udid):
    """Booted != ready. Installing before SpringBoard is up can wedge simctl."""
    deadline = time.time() + BUNDLE_READY_TIMEOUT
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
    print("::warning::SpringBoard never showed up; continuing anyway", flush=True)


def dump_crash_reports():
    reports = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    if not os.path.isdir(reports):
        return
    for name in sorted(os.listdir(reports)):
        if "PaxController" in name:
            print(f"--- {name} ---", flush=True)
            with open(os.path.join(reports, name), errors="replace") as fh:
                print("".join(fh.readlines()[:80]), flush=True)


def main():
    udid, app_path, bundle_id = sys.argv[1], sys.argv[2], sys.argv[3]

    wait_for_springboard(udid)
    run(["xcrun", "simctl", "install", udid, app_path], timeout=180)

    result = run(
        ["xcrun", "simctl", "launch", "--terminate-running-process", udid, bundle_id],
        timeout=120,
    )
    pid = result.stdout.strip().rsplit(":", 1)[-1].strip()
    print(f"launched pid {pid}", flush=True)

    time.sleep(10)

    # Simulator apps are ordinary host processes, so ps is the honest check;
    # launchctl inside the simulator does not list them under the bundle id.
    if subprocess.run(["ps", "-p", pid], capture_output=True).returncode != 0:
        dump_crash_reports()
        sys.exit(f"::error::{bundle_id} (pid {pid}) exited after launch - it likely crashed")

    print(f"app is running as pid {pid}", flush=True)


if __name__ == "__main__":
    main()
