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

    # 1. The requested model, already on the image.
    for want in PREFERRED:
        if want in by_name:
            udid, runtime = by_name[want]
            emit(device_name=want, existing_udid=udid, runtime_name=runtime)
            print(f"Using preinstalled {want} ({runtime})")
            if want != PREFERRED[0]:
                print(f"::warning::{PREFERRED[0]} unavailable; used {want} instead")
            return

    device_types = simctl("devicetypes")["devicetypes"]
    types_by_name = {t["name"]: t for t in device_types}
    runtimes = [
        r
        for r in simctl("runtimes")["runtimes"]
        if r.get("isAvailable") and "iOS" in r.get("name", "")
    ]
    runtimes.sort(key=version_key, reverse=True)

    def runtime_for(device):
        for runtime in runtimes:
            supported = runtime.get("supportedDeviceTypes")
            if supported is None:
                return runtime
            if device["identifier"] in {d.get("identifier") for d in supported}:
                return runtime
        return None

    # 2. The requested model, created on demand. Worth the extra boot time:
    #    screenshots are model-specific, so falling back to another phone
    #    silently changes what the caller asked for.
    for want in PREFERRED:
        device = types_by_name.get(want)
        if not device:
            continue
        runtime = runtime_for(device)
        if not runtime:
            continue
        emit(
            device_name=device["name"],
            device_type=device["identifier"],
            runtime=runtime["identifier"],
            runtime_name=runtime["name"],
        )
        print(f"Creating {device['name']} on {runtime['name']}")
        if want != PREFERRED[0]:
            print(f"::warning::{PREFERRED[0]} unavailable; created {want} instead")
        return

    # 3. Last resort: any iPhone at all, loudly flagged.
    iphones = [entry for entry in available if entry[0].startswith("iPhone")]
    if iphones:
        name, udid, runtime = iphones[-1]
        emit(device_name=name, existing_udid=udid, runtime_name=runtime)
        print(f"::warning::no iPhone 14 device type on this runner; used {name} ({runtime})")
        return

    sys.exit("no usable iPhone device type / runtime combination found")
