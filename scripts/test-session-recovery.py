#!/usr/bin/env python3
"""Run session recovery, account privacy, or server setup UI checks on fresh simulators."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def run(arguments):
    return subprocess.check_output([str(a) for a in arguments], cwd=ROOT, text=True).strip()


def environment(node, url):
    if isinstance(node, dict):
        if "TestBundlePath" in node:
            node.setdefault("EnvironmentVariables", {})["LAGOON_SESSION_FIXTURE"] = url
        for value in node.values():
            environment(value, url)
    elif isinstance(node, list):
        for value in node:
            environment(value, url)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--platforms", nargs="+", choices=("iOS", "tvOS"), default=["iOS", "tvOS"])
    journeys = parser.add_mutually_exclusive_group()
    journeys.add_argument("--account-privacy", action="store_true", help="Run the remembered-account picker privacy journey")
    journeys.add_argument("--local-network", action="store_true", help="Run iOS denial guidance and retry with a simulated path diagnosis")
    journeys.add_argument("--server-address", action="store_true", help="Run proxy setup and HTTP disclosure checks")
    journeys.add_argument("--subtitle-downloads", action="store_true", help="Run subtitle failure, retry, and oversized download checks during playback")
    args = parser.parse_args()
    if args.local_network:
        args.platforms = ["iOS"]  # tvOS does not implement local-network privacy.
    work = (args.work or Path(tempfile.mkdtemp(prefix="lagoon-session-tests-"))).resolve()
    directory = work / datetime.now().strftime("%Y%m%d-%H%M%S")
    directory.mkdir(parents=True)
    fixture_command = [sys.executable, str(ROOT / "scripts/jellyfin-regression-fixture.py"),
                       "--work", str(directory / "fixture")]
    if args.server_address:
        fixture_command += ["--base-path", "/services/jellyfin", "--base-path", "/services/seerr"]
    if args.subtitle_downloads:
        fixture_command += ["--subtitle-downloads"]
    fixture = subprocess.Popen(fixture_command, stdout=subprocess.PIPE, text=True)
    try:
        url = fixture.stdout.readline().strip()
        if not url.startswith("http://127.0.0.1:"):
            raise RuntimeError("Synthetic fixture did not start")
        runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "-j"]))["runtimes"]
        for platform_index, platform in enumerate(args.platforms):
            device = None
            results = directory / platform
            results.mkdir()
            try:
                runtime = max((r for r in runtimes if r["isAvailable"] and r["platform"] == platform),
                              key=lambda r: tuple(map(int, r["version"].split("."))))
                device_type = next(t["identifier"] for t in runtime["supportedDeviceTypes"]
                                   if t["productFamily"] == ("iPhone" if platform == "iOS" else "Apple TV"))
                device = run(["xcrun", "simctl", "create", f"Lagoon session {platform}", device_type, runtime["identifier"]])
                run(["xcrun", "simctl", "boot", device])
                run(["xcrun", "simctl", "bootstatus", device, "-b"])
                destination = f"platform={platform} Simulator,id={device}"
                derived = work / platform / "DerivedData"
                command = ["xcodebuild", "build-for-testing", "-scheme", "LagoonHardwareRegression",
                           "-destination", destination, "-derivedDataPath", str(derived)]
                if platform == "iOS":
                    # The existing UI target otherwise contains tvOS-only
                    # remote tests. Keep its checked-in platform scope intact.
                    command += ["SUPPORTED_PLATFORMS=iphonesimulator", "SDKROOT=iphonesimulator",
                                "TARGETED_DEVICE_FAMILY=1,2", "IPHONEOS_DEPLOYMENT_TARGET=26.0",
                                "EXCLUDED_SOURCE_FILE_NAMES=PlayerRegressionUITests.swift ServerSyncUITests.swift LibraryBrowseUITests.swift"]
                print(f"Building {platform}; logs: {results}", flush=True)
                with (results / "build.log").open("w") as log:
                    subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
                spec_path = next((derived / "Build/Products").glob("LagoonHardwareRegression_*.xctestrun"))
                spec = plistlib.loads(spec_path.read_bytes())
                environment(spec, url)
                spec_path.write_bytes(plistlib.dumps(spec))
                suite = "SubtitleDownloadUITests" if args.subtitle_downloads else "ServerAddressUITests" if args.server_address else "LocalNetworkUITests" if args.local_network else "AccountPrivacyUITests" if args.account_privacy else "SessionExpiryUITests"
                command = ["xcodebuild", "test-without-building", "-xctestrun", str(spec_path),
                           "-destination", destination, "-parallel-testing-enabled", "NO",
                           f"-only-testing:LagoonUITests/{suite}", "-resultBundlePath", str(results / "Recovery.xcresult")]
                with (results / "test.log").open("w") as log:
                    subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
                expected = 1 if args.account_privacy or args.local_network or args.server_address or args.subtitle_downloads else 2
                if f"Executed {expected} test" not in (results / "test.log").read_text():
                    raise RuntimeError("The selected UI cases did not execute")
                # Each case resets the fixture; the final case must complete
                # reauthentication, not merely return a passing skip result.
                state = json.loads((directory / "fixture/requests.json").read_text())
                if not (args.account_privacy or args.local_network or args.server_address or args.subtitle_downloads) and (state["generation"] != 2 or not state["revoked"]):
                    raise RuntimeError("Recovery cases were skipped or did not revoke and replace a token")
                if args.account_privacy and state["generation"] != 2 * (platform_index + 1):
                    raise RuntimeError("The privacy journey did not authenticate both synthetic accounts")
                if args.local_network and (state["drop_connections"] or not any(r["path"] == "/QuickConnect/Enabled" for r in state["requests"])):
                    raise RuntimeError("The local-network journey did not recover to sign-in")
                if args.server_address:
                    paths = {r["path"] for r in state["requests"]}
                    required = {"/services/jellyfin/System/Info/Public", "/services/jellyfin/Users/AuthenticateByName",
                                "/services/seerr/api/v1/status", "/services/seerr/api/v1/settings/public"}
                    if state["generation"] != 1 or not required.issubset(paths):
                        raise RuntimeError("The server-address journey did not complete both proxy connections")
                if args.subtitle_downloads:
                    paths = [r["path"] for r in state["requests"]]
                    if not state["subtitle_recovered"] or paths.count("/Subtitles/retry.vtt") != 2 or \
                            "/Subtitles/working.vtt" not in paths or "/Subtitles/oversized.vtt" not in paths:
                        raise RuntimeError("The subtitle journey did not load, retry, and reject the oversized file")
                    if any("/RemoteSearch/Subtitles/" in path for path in paths):
                        raise RuntimeError("Retrying an existing track unexpectedly started a provider search")
                (results / "requests.json").write_text(json.dumps(state, indent=2))
                run(["xcrun", "xcresulttool", "export", "attachments", "--path", results / "Recovery.xcresult",
                     "--output-path", results / "screenshots"])
                journey = "subtitle failure, retry, and decompressed byte limit" if args.subtitle_downloads else "proxy setup and HTTP disclosure" if args.server_address else "simulated denial guidance and retry to sign-in" if args.local_network else "account picker and search isolation" if args.account_privacy else "direct/HLS playback, revocation, sign-in and resumed playback"
                print(f"Passed {platform}: {journey}", flush=True)
            finally:
                if device:
                    subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    run(["xcrun", "simctl", "delete", device])
    finally:
        fixture.terminate()
        fixture.wait(timeout=10)


if __name__ == "__main__":
    main()
