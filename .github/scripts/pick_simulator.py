#!/usr/bin/env python3
"""Pick a simulator device type + runtime pair that actually exists on the runner.

Xcode drops older device types over time, so the requested model is a
preference, not an assumption: fall back to the nearest iPhone rather than
failing the run.
"""
import json
import os
import subprocess
import sys

PREFERRED = ["iPhone 14", "iPhone 14 Pro", "iPhone 14 Plus", "iPhone 14 Pro Max"]


def simctl_json(*args):
    out = subprocess.run(
        ["xcrun", "simctl", "list", *args, "-j"], check=True, capture_output=True, text=True
    ).stdout
    return json.loads(out)


def runtime_sort_key(runtime):
    parts = []
    for chunk in str(runtime.get("version", "0")).split("."):
        parts.append(int(chunk) if chunk.isdigit() else 0)
    return parts


def main():
    device_types = simctl_json("devicetypes")["devicetypes"]
    runtimes = [
        r
        for r in simctl_json("runtimes")["runtimes"]
        if r.get("isAvailable") and "iOS" in r.get("name", "")
    ]
    if not runtimes:
        sys.exit("no available iOS simulator runtime on this runner")
    runtimes.sort(key=runtime_sort_key, reverse=True)

    by_name = {t["name"]: t for t in device_types}
    candidates = [by_name[n] for n in PREFERRED if n in by_name]
    # Last resort: any iPhone, newest-looking last in simctl's own ordering.
    candidates += [t for t in device_types if t["name"].startswith("iPhone")][::-1]

    for device in candidates:
        for runtime in runtimes:
            supported = runtime.get("supportedDeviceTypes")
            if supported is not None:
                ids = {d.get("identifier") for d in supported}
                if device["identifier"] not in ids:
                    continue
            with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
                fh.write(f"device_type={device['identifier']}\n")
                fh.write(f"device_name={device['name']}\n")
                fh.write(f"runtime={runtime['identifier']}\n")
                fh.write(f"runtime_name={runtime['name']}\n")
            print(f"Using {device['name']} on {runtime['name']}")
            if device["name"] != PREFERRED[0]:
                print(f"::warning::{PREFERRED[0]} unavailable; used {device['name']} instead")
            return

    sys.exit("no usable iPhone device type / runtime combination found")


if __name__ == "__main__":
    main()
