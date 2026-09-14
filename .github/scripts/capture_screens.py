#!/usr/bin/env python3
"""Install the app on a booted simulator and screenshot each of its tabs.

simctl cannot tap, so tabs are not reachable by driving the UI. The app reads
its initial tab from the `uiTab` launch argument instead, and this script
relaunches once per tab.

Every simctl call runs with a deadline, and the ones that race the simulator
coming up are retried: simctl blocks indefinitely when the simulator is
wedged, and macOS ships no coreutils `timeout` to bound it with.

Usage:
  capture_screens.py <udid> <app> <bundle id> <out dir> <name:tab>...
"""
import os
import subprocess
import sys
import time


def run(args, timeout, check=True, fatal=True):
    """Run a command with a deadline.

    Returns None when it times out or fails and `fatal` is False, so callers
    that retry can tell the difference without the process dying.
    """
    print(f"$ {' '.join(args)}", flush=True)
    try:
        result = subprocess.run(args, timeout=timeout, capture_output=True, text=True)
    except subprocess.TimeoutExpired:
        message = f"timed out after {timeout}s: {' '.join(args)}"
        if fatal:
            sys.exit(f"::error::{message}")
        print(message, flush=True)
        return None

    for stream, target in ((result.stdout, sys.stdout), (result.stderr, sys.stderr)):
        if stream.strip():
            print(stream.strip(), file=target, flush=True)
    if result.returncode != 0:
        message = f"command failed ({result.returncode}): {' '.join(args)}"
        if check and fatal:
            sys.exit(f"::error::{message}")
        print(message, flush=True)
        return None
    return result


def dump_crash_reports():
    reports = os.path.expanduser("~/Library/Logs/DiagnosticReports")
    if not os.path.isdir(reports):
        return
    for name in sorted(os.listdir(reports)):
        if "PaxController" in name:
            print(f"--- {name} ---", flush=True)
            with open(os.path.join(reports, name), errors="replace") as fh:
                print("".join(fh.readlines()[:80]), flush=True)


def install(udid, app_path, attempts=6):
    """Install, retrying while the simulator finishes coming up.

    A successful install is the readiness signal. Probing SpringBoard through
    `simctl spawn launchctl print system` looked more precise but hangs past
    any deadline on some runtimes, which is worse than just trying.
    """
    for attempt in range(1, attempts + 1):
        if run(["xcrun", "simctl", "install", udid, app_path], timeout=120, fatal=False):
            return
        print(f"install attempt {attempt} failed; simulator may still be starting", flush=True)
        time.sleep(10)
    sys.exit(f"::error::could not install {app_path} after {attempts} attempts")


def launch(udid, bundle_id, tab, attempts=3):
    """Start the app on a tab and confirm it stayed up."""
    last_pid = ""
    for attempt in range(1, attempts + 1):
        result = run(
            [
                "xcrun", "simctl", "launch", "--terminate-running-process",
                udid, bundle_id, "-uiTab", str(tab),
            ],
            timeout=120,
            fatal=False,
        )
        if result is None:
            print(f"launch attempt {attempt} did not start the app", flush=True)
            time.sleep(5)
            continue

        last_pid = result.stdout.strip().rsplit(":", 1)[-1].strip()
        time.sleep(6)
        # Simulator apps are ordinary host processes, so ps is the honest check;
        # launchctl inside the simulator does not list them under the bundle id.
        if subprocess.run(["ps", "-p", last_pid], capture_output=True).returncode == 0:
            return last_pid
        print(f"launch attempt {attempt}: pid {last_pid} is gone", flush=True)
        time.sleep(5)

    dump_crash_reports()
    sys.exit(
        f"::error::{bundle_id} would not stay running after {attempts} attempts "
        f"(last pid {last_pid or 'none'})"
    )


def main():
    udid, app_path, bundle_id, out_dir = sys.argv[1:5]
    tabs = []
    for spec in sys.argv[5:]:
        name, _, tab = spec.partition(":")
        tabs.append((name, int(tab)))
    if not tabs:
        sys.exit("::error::no tabs requested")

    os.makedirs(out_dir, exist_ok=True)

    install(udid, app_path)
    run(["xcrun", "simctl", "ui", udid, "appearance", "light"], timeout=60,
        check=False, fatal=False)

    for index, (name, tab) in enumerate(tabs, start=1):
        launch(udid, bundle_id, tab)
        path = os.path.join(out_dir, f"{index:02d}-{name}.png")
        run(["xcrun", "simctl", "io", udid, "screenshot", path], timeout=90)
        print(f"captured {path}", flush=True)

    print(f"{len(tabs)} screenshots written to {out_dir}", flush=True)


if __name__ == "__main__":
    main()
