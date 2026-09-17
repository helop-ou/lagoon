#!/usr/bin/env python3
"""Validate Lagoon's required-reason privacy resources in an app or archive.

This is a packaging check, not Apple's Organizer privacy report or an App
Privacy/legal approval. HEL-143 records the inventory.
"""
import argparse
import json
from pathlib import Path
import plistlib
import sys

ROOT = Path(__file__).resolve().parents[1]
REASONS = {
    "NSPrivacyAccessedAPICategoryUserDefaults": {"CA92.1", "1C8F.1"},
    "NSPrivacyAccessedAPICategoryFileTimestamp": {"C617.1"},
    "NSPrivacyAccessedAPICategoryDiskSpace": {"E174.1"},
    "NSPrivacyAccessedAPICategorySystemBootTime": {"35F9.1"},
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read(path):
    with path.open("rb") as stream:
        return plistlib.load(stream)


def manifest(bundle, source, expected):
    path = bundle / "PrivacyInfo.xcprivacy"
    value = read(path)
    require(value == read(source), f"{path}: archived manifest differs from the reviewed source")
    require(value.get("NSPrivacyTracking") is False, f"{path}: unexpected tracking declaration")
    require(value.get("NSPrivacyTrackingDomains") == [], f"{path}: unexpected tracking domains")
    entries = value.get("NSPrivacyAccessedAPITypes")
    require(isinstance(entries, list), f"{path}: missing API array")
    actual = {}
    for entry in entries:
        category = entry["NSPrivacyAccessedAPIType"]
        reasons = entry["NSPrivacyAccessedAPITypeReasons"]
        require(category not in actual, f"{path}: duplicate category {category}")
        require(isinstance(reasons, list) and all(isinstance(r, str) for r in reasons), f"{path}: invalid reasons")
        require(len(reasons) == len(set(reasons)), f"{path}: duplicate reasons")
        actual[category] = set(reasons)
    require(actual == expected, f"{path}: API reasons differ from the inventory")
    return {"bundle": bundle.name, "required_reasons": {k: sorted(v) for k, v in actual.items()},
            "collected_data_declared": "NSPrivacyCollectedDataTypes" in value}


def validate(path):
    if path.suffix == ".xcarchive":
        apps = list((path / "Products/Applications").glob("*.app"))
        require(len(apps) == 1, "Archive must contain exactly one application")
        path = apps[0]
    require(path.suffix == ".app" and path.is_dir(), "Expected an .app or .xcarchive directory")
    info = read(path / "Info.plist")
    require(info.get("CFBundleIdentifier") == "ee.helop.lagoon", "Unexpected app identity")
    platform = info.get("DTPlatformName")
    require(platform in {"iphoneos", "iphonesimulator", "appletvos", "appletvsimulator"}, "Unsupported app platform")
    if platform.startswith("iphone"):
        purpose = info.get("NSLocalNetworkUsageDescription")
        require(isinstance(purpose, str) and bool(purpose.strip()), "Missing iOS local-network purpose text")
    ats = info.get("NSAppTransportSecurity", {})
    require(ats.get("NSAllowsLocalNetworking") is True, "Local-network ATS exception missing")
    require(not any(ats.get(k) for k in ["NSAllowsArbitraryLoads", "NSAllowsArbitraryLoadsForMedia", "NSAllowsArbitraryLoadsInWebContent"]),
            "Unexpected broad ATS exception")
    manifests = [manifest(path, ROOT / "Lagoon/PrivacyInfo.xcprivacy", REASONS)]
    extensions = list((path / "PlugIns").glob("*.appex"))
    require(len(extensions) == (1 if platform.startswith("appletv") else 0), "Unexpected app extension set")
    for extension in extensions:
        ext_info = read(extension / "Info.plist")
        require(ext_info.get("CFBundleIdentifier") == "ee.helop.lagoon.topshelf", "Unexpected extension identity")
        for key in ["CFBundleShortVersionString", "CFBundleVersion"]:
            require(ext_info.get(key) == info.get(key), f"App/extension {key} mismatch")
        manifests.append(manifest(extension, ROOT / "LagoonTopShelf/PrivacyInfo.xcprivacy", {}))
    return {"scope": "Required-reason resources and basic bundle consistency only",
            "platform": platform, "version": info["CFBundleShortVersionString"], "build": info["CFBundleVersion"],
            "manifests": manifests,
            "remaining_release_checks": ["App Privacy and service retention decisions", "Organizer privacy report and signed archive validation",
                                         "Physical iPhone/iPad permission acceptance", "Licensing, encryption and public website"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("product", type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    try:
        report = validate(args.product)
    except (OSError, ValueError, KeyError, TypeError, plistlib.InvalidFileException) as error:
        print(f"Privacy packaging validation failed: {error}", file=sys.stderr)
        return 1
    output = json.dumps(report, indent=2) + "\n"
    if args.report:
        args.report.write_text(output)
    print(output, end="")
    return 0


if __name__ == "__main__":
    sys.exit(main())
