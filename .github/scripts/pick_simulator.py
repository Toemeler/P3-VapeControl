#!/usr/bin/env python3
"""Choose the simulator to screenshot on.

Order of preference:
  1. an iPhone 14 the runner image already created (warm, boots quickly)
  2. any other preinstalled iPhone
  3. a freshly created device, as a last resort

Creating and cold-booting a device is the slow, stall-prone path, so it is
only used when the image ships nothing usable.
"""
import json
import os
import subprocess
import sys

PREFERRED = ["iPhone 14", "iPhone 14 Pro", "iPhone 14 Plus", "iPhone 14 Pro Max"]


def simctl(*args):
    out = subprocess.run(
        ["xcrun", "simctl", "list", *args, "-j"], check=True, capture_output=True, text=True
    ).stdout
    return json.loads(out)


def emit(**pairs):
    with open(os.environ["GITHUB_OUTPUT"], "a") as fh:
        for key, value in pairs.items():
            fh.write(f"{key}={value}\n")


def version_key(runtime):
    return [int(p) if p.isdigit() else 0 for p in str(runtime.get("version", "0")).split(".")]


def existing_devices():
    found = []
    for runtime, devices in simctl("devices", "available")["devices"].items():
        if "iOS" not in runtime:
            continue
        for device in devices:
            found.append((device["name"], device["udid"], runtime))
    return found


def main():
    available = existing_devices()
    by_name = {}
    for name, udid, runtime in available:
        by_name.setdefault(name, (udid, runtime))

    for want in PREFERRED:
        if want in by_name:
            udid, runtime = by_name[want]
            emit(device_name=want, existing_udid=udid, runtime_name=runtime)
            print(f"Using preinstalled {want} ({runtime})")
            if want != PREFERRED[0]:
                print(f"::warning::{PREFERRED[0]} unavailable; used {want} instead")
            return

    iphones = [entry for entry in available if entry[0].startswith("iPhone")]
    if iphones:
        name, udid, runtime = iphones[-1]
        emit(device_name=name, existing_udid=udid, runtime_name=runtime)
        print(f"::warning::no iPhone 14 variant preinstalled; used {name} ({runtime})")
        return

    # Nothing preinstalled - fall back to creating a device.
    device_types = simctl("devicetypes")["devicetypes"]
    types_by_name = {t["name"]: t for t in device_types}
    runtimes = [
        r for r in simctl("runtimes")["runtimes"] if r.get("isAvailable") and "iOS" in r.get("name", "")
    ]
    if not runtimes:
        sys.exit("no available iOS simulator runtime on this runner")
    runtimes.sort(key=version_key, reverse=True)

    candidates = [types_by_name[n] for n in PREFERRED if n in types_by_name]
    candidates += [t for t in device_types if t["name"].startswith("iPhone")][::-1]
    for device in candidates:
        for runtime in runtimes:
            supported = runtime.get("supportedDeviceTypes")
            if supported is not None:
                if device["identifier"] not in {d.get("identifier") for d in supported}:
                    continue
            emit(
                device_name=device["name"],
                device_type=device["identifier"],
                runtime=runtime["identifier"],
                runtime_name=runtime["name"],
            )
            print(f"::warning::creating a new {device['name']} on {runtime['name']}")
            return

    sys.exit("no usable iPhone device type / runtime combination found")


if __name__ == "__main__":
    main()
