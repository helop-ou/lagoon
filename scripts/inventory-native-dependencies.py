#!/usr/bin/env python3
"""Record pinned native artifacts, slice hashes, binary formats and API imports.

Run after package resolution; this inspects files without invoking a compiler.
Undefined imports are an inventory aid, not proof of runtime use or a complete
license/source audit. The output deliberately preserves that distinction.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = ROOT / "Packages/LagoonFFmpeg"
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
    return subprocess.check_output(args, text=True, stderr=subprocess.PIPE).strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifacts", type=Path, required=True, help="DerivedData/SourcePackages/artifacts")
    parser.add_argument("--report", type=Path, required=True)
    args = parser.parse_args()
    targets = []
    for match in re.finditer(r'\.binaryTarget\(\s*name:\s*"([^"]+)"(.*?)\n\s*\)', (PACKAGE / "Package.swift").read_text(), re.S):
        name, declaration = match.groups()
        target = {"name": name}
        for field in ["url", "checksum", "path"]:
            value = re.search(rf'\b{field}:\s*"([^"]+)"', declaration)
            if value:
                target[field] = value.group(1)
        if "path" in target:
            framework = PACKAGE / target["path"]
        else:
            candidates = list(args.artifacts.rglob(f"{name}.xcframework"))
            if len(candidates) != 1:
                raise ValueError(f"Expected one resolved {name}.xcframework, found {len(candidates)}")
            framework = candidates[0]
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
    # Seven since the transport spike: libavcodec, libavformat, libavutil,
    # libswresample, dav1d, lcms2, uavs3d. The GnuTLS stack left with
    # libavformat's network stack.
    if len(targets) != 7:
        raise ValueError(f"Native target set changed ({len(targets)}); review the inventory before regenerating")
    report = {"scope": "All declared native framework slices, including non-shipped macOS slices. Import presence is not runtime-use proof.",
              "package_sha256": sha256(PACKAGE / "Package.swift"), "dependencies": targets}
    args.report.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Recorded {len(targets)} dependencies / {sum(len(t['slices']) for t in targets)} slices in {args.report}")


if __name__ == "__main__":
    main()
