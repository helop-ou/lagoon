#!/usr/bin/env python3
"""Record pinned native artifacts, slice hashes, binary formats and API imports.

The native libraries ship inside the lagoon-engine package, so this reads the
engine checkout SwiftPM resolved for the app and refuses one that is not the
revision Package.resolved pins. Run it after resolving packages; it inspects
files without invoking a compiler. Undefined imports are an inventory aid, not
proof of runtime use or a complete license/source audit. The output
deliberately preserves that distinction.

  scripts/inventory-native-dependencies.py \
      --engine ~/Library/Developer/Xcode/DerivedData/Lagoon-*/SourcePackages/checkouts/lagoon-engine \
      --report docs/reference/native-dependency-inventory.json
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
RESOLVED = ROOT / "Lagoon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
API_SYMBOLS = {
    "FileTimestamp": {"_stat", "_fstat", "_lstat", "_fstatat", "_getattrlist", "_getattrlistbulk", "_fgetattrlist"},
    "DiskSpace": {"_statfs", "_fstatfs", "_statvfs", "_fstatvfs", "_getattrlist", "_getattrlistbulk", "_fgetattrlist"},
    "SystemBootTime": {"_mach_absolute_time"},
    "UserDefaults": {"_OBJC_CLASS_$_NSUserDefaults"},
}


def sha256(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def output(*args):
    # Some vendored static archives (Libdovi's Rust-built libdovi.a: the
    # `dolby_vision` crate is built with a newer LLVM than Xcode's bundled
    # nm) contain a handful of object members nm cannot parse ("Unknown
    # attribute kind") and exits 1 over, even though it still printed every
    # other member's symbols to stdout. Trust the exit code only when it
    # left us nothing to read; otherwise keep the partial output and say so,
    # rather than silently dropping a target's required-reason scan.
    result = subprocess.run(args, capture_output=True, text=True)
    if result.returncode != 0:
        if not result.stdout.strip():
            raise subprocess.CalledProcessError(result.returncode, args, output=result.stdout, stderr=result.stderr)
        print(f"warning: {' '.join(args)} exited {result.returncode}; keeping its partial stdout "
              f"({result.stderr.count(chr(10))} stderr lines, likely per-member parse errors)", file=sys.stderr)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", type=Path, required=True,
                        help="The resolved checkout: DerivedData/.../SourcePackages/checkouts/lagoon-engine")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    package = args.engine.resolve()
    pin = next(pin for pin in json.loads(RESOLVED.read_text())["pins"] if pin["identity"] == "lagoon-engine")
    revision = output("git", "-C", str(package), "rev-parse", "HEAD")
    if revision != pin["state"]["revision"]:
        raise ValueError(f"{package} is at {revision}, but Package.resolved pins "
                         f"{pin['state']['version']} at {pin['state']['revision']}; resolve packages first")
    targets = []
    for match in re.finditer(r'\.binaryTarget\(\s*name:\s*"([^"]+)"(.*?)\n\s*\)', (package / "Package.swift").read_text(), re.S):
        name, declaration = match.groups()
        target = {"name": name}
        path = re.search(r'\bpath:\s*"([^"]+)"', declaration)
        if not path:
            # Every native library is built or vendored inside the engine; a
            # fetched one would need its resolved artifact found and hashed.
            raise ValueError(f"{name} is not a path: binary target; teach this script where SwiftPM put it")
        target["path"] = path.group(1)
        framework = package / target["path"]
        target["bundled_license_files"] = [str(p.relative_to(framework)) for p in sorted(framework.rglob("*"))
                                            if p.is_file() and p.name.upper().startswith(("LICENSE", "COPYING", "NOTICE"))]
        provenance = framework / "BUILD.json"
        if provenance.exists():
            target["build_record_sha256"] = sha256(provenance)
        target["slices"] = []
        info = plistlib.loads((framework / "Info.plist").read_bytes())
        for library in sorted(info["AvailableLibraries"], key=lambda s: s["LibraryIdentifier"]):
            binary = framework / library["LibraryIdentifier"] / library["LibraryPath"]
            if binary.suffix == ".framework":
                binary = binary / binary.stem
            symbols = {line.split()[-1] for line in output("xcrun", "nm", "-u", str(binary)).splitlines() if line.split()}
            target["slices"].append({
                "id": library["LibraryIdentifier"], "architectures": library["SupportedArchitectures"],
                "sha256": sha256(binary), "file_type": output("file", "-b", str(binary)).splitlines()[0],
                "required_reason_imports": {category: sorted(symbols & values) for category, values in API_SYMBOLS.items() if symbols & values},
            })
        targets.append(target)
    # Eight added libdovi: libavcodec, libavformat, libavutil,
    # libswresample, dav1d, lcms2, uavs3d, libdovi. The GnuTLS stack left
    # with libavformat's network stack.
    if len(targets) != 8:
        raise ValueError(f"Native target set changed ({len(targets)}); review the inventory before regenerating")
    report = {"scope": "All declared native framework slices, including non-shipped macOS slices. Import presence is not runtime-use proof.",
              "engine": {"version": pin["state"]["version"], "revision": revision},
              "package_sha256": sha256(package / "Package.swift"), "dependencies": targets}
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Recorded {len(targets)} dependencies / {sum(len(t['slices']) for t in targets)} slices in {args.report}")


if __name__ == "__main__":
    main()
