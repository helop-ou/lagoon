#!/usr/bin/env python3
"""Prints an xcodebuild destination for the first named simulator that can run.

    scripts/pick-simulator.py [--minimum 27.2] [--create] tvOS "Apple TV 4K (4th generation)" …

A runner image can keep a device whose runtime it no longer has: simctl still
lists it, and xcodebuild then fails with "Unable to find a destination". Only
devices on an installed runtime count, newest runtime first, so the job fails
here with the devices it has rather than later without them.

--minimum skips older runtimes, for tests whose references were recorded on
one. --create makes the first named device on the newest runtime that
supports it when none exists, as after downloading a runtime.
"""
import json
import subprocess
import sys

PLATFORMS = {"iOS", "tvOS"}


def simctl(*arguments):
    return json.loads(subprocess.check_output(["xcrun", "simctl", "list", "-j", *arguments], text=True))


def version_key(version):
    return tuple(int(part) for part in version.split(".") if part.isdigit())


def main():
    arguments = sys.argv[1:]
    minimum = ()
    create = False
    while arguments and arguments[0].startswith("--"):
        option = arguments.pop(0)
        if option == "--minimum" and arguments:
            minimum = version_key(arguments.pop(0))
        elif option == "--create":
            create = True
        else:
            sys.exit(__doc__)
    if len(arguments) < 2 or arguments[0] not in PLATFORMS:
        sys.exit(__doc__)
    platform, names = arguments[0], arguments[1:]

    runtimes = sorted(
        (runtime for runtime in simctl("runtimes")["runtimes"]
         if runtime.get("isAvailable") and runtime.get("platform") == platform
         and version_key(runtime["version"]) >= minimum),
        key=lambda runtime: version_key(runtime["version"]),
        reverse=True,
    )
    devices = simctl("devices", "available")["devices"]
    for name in names:
        for runtime in runtimes:
            for device in devices.get(runtime["identifier"], []):
                if device.get("name") == name and device.get("isAvailable"):
                    print(f"platform={platform} Simulator,id={device['udid']}")
                    print(f"Using {name}, {platform} {runtime['version']}", file=sys.stderr)
                    return

    if create:
        types = {kind["name"]: kind["identifier"] for kind in simctl("devicetypes")["devicetypes"]}
        for runtime in runtimes:
            supported = {kind["identifier"] for kind in runtime.get("supportedDeviceTypes", [])}
            for name in names:
                if types.get(name) in supported:
                    udid = subprocess.check_output(
                        ["xcrun", "simctl", "create", name, types[name], runtime["identifier"]], text=True
                    ).strip()
                    print(f"platform={platform} Simulator,id={udid}")
                    print(f"Created {name}, {platform} {runtime['version']}", file=sys.stderr)
                    return

    print(f"error: no {platform} simulator named any of {names} on an installed runtime", file=sys.stderr)
    for runtime in runtimes:
        for device in devices.get(runtime["identifier"], []):
            print(f"  {platform} {runtime['version']}: {device.get('name')}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
