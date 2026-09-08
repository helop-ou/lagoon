#!/usr/bin/env python3
"""Exercise Lagoon's actual FFmpeg binaries on disposable iOS/tvOS simulators.

Requires Xcode, ffmpeg, openssl, and Python's cryptography package. Creates a
temporary CA, installs it ONLY in newly created simulators, and deletes those
simulators on exit. No real credentials or external test servers are used.
Build/test logs and xcresults remain in --work (or a new temporary directory).
"""
import argparse
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import os
from pathlib import Path
import plistlib
import socket
import ssl
import subprocess
import tempfile
import threading
from urllib.parse import urlsplit

from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

ROOT = Path(__file__).resolve().parents[1]


def run(args, **kwargs):
    return subprocess.check_output([str(arg) for arg in args], text=True, **kwargs).strip()


class Fixtures:
    def __init__(self, work):
        self.work = work
        self.servers = []
        self.requests = []
        # Names of servers reached only by following a redirect issued by a
        # different origin (never as a fixture's own direct target) — see
        # violations().
        self.redirect_targets = set()
        self.cases = []
        self.roots()
        run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "sine=frequency=440:duration=1",
             "-c:a", "aac", "-f", "mpegts", work / "segment.ts"])
        self.media = (work / "segment.ts").read_bytes()
        self.key = b"0123456789abcdef"
        run(["openssl", "enc", "-aes-128-cbc", "-K", self.key.hex(), "-iv", "00" * 16,
             "-in", work / "segment.ts", "-out", work / "encrypted.ts"])
        self.encrypted = (work / "encrypted.ts").read_bytes()
        self.urls = {name: self.server(name) for name in ("valid", "self-signed", "expired", "wrong-host", "http")}
        for enforce in (False, True):
            for name, base in self.urls.items():
                self.case(f"direct-{name}-{'policy' if enforce else 'default'}", base + "/body", name in ("valid", "http"), enforce=enforce)
        for name in ("valid", "self-signed", "expired", "wrong-host"):
            self.case(f"redirect-{name}", self.urls["valid"] + f"/redirect/{name}", name == "valid")
        for kind in ("variant", "segment", "later-segment", "key"):
            for name in ("valid", "self-signed", "expired", "wrong-host"):
                self.case(f"hls-{kind}-{name}", self.urls["valid"] + f"/hls/{kind}/{name}/master.m3u8", name == "valid", hls=True)
        for name in ("reconnect-valid", "reconnect-invalid"):
            self.case(name, self.server(name) + "/reconnect", name == "reconnect-valid", reconnect=True)
        self.control = self.server("control")

    def roots(self):
        now = datetime.now(timezone.utc)
        self.ca_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "Lagoon disposable TLS test CA")])
        self.ca = (x509.CertificateBuilder().subject_name(ca_name).issuer_name(ca_name)
                   .public_key(self.ca_key.public_key()).serial_number(x509.random_serial_number())
                   .not_valid_before(now - timedelta(days=1)).not_valid_after(now + timedelta(days=7))
                   .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                   .add_extension(x509.KeyUsage(False, False, False, False, False, True, True, False, False), critical=True)
                   .sign(self.ca_key, hashes.SHA256()))
        (self.work / "ca.pem").write_bytes(self.ca.public_bytes(serialization.Encoding.PEM))
        self.contexts = {}
        for name in ("valid", "self-signed", "expired", "wrong-host"):
            key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
            subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
            san = [x509.DNSName("wrong.invalid")] if name == "wrong-host" else [x509.DNSName("localhost"), x509.IPAddress(ipaddress.ip_address("127.0.0.1"))]
            certificate = (x509.CertificateBuilder().subject_name(subject)
                           .issuer_name(subject if name == "self-signed" else self.ca.subject)
                           .public_key(key.public_key()).serial_number(x509.random_serial_number())
                           .not_valid_before(now - timedelta(days=3))
                           .not_valid_after(now - timedelta(days=1) if name == "expired" else now + timedelta(days=2))
                           .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
                           .add_extension(x509.SubjectAlternativeName(san), critical=False)
                           .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                           .sign(key if name == "self-signed" else self.ca_key, hashes.SHA256()))
            cert_path, key_path = self.work / f"{name}.pem", self.work / f"{name}.key"
            cert_path.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
            key_path.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8, serialization.NoEncryption()))
            key_path.chmod(0o600)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert_path, key_path)
            self.contexts[name] = context

    def case(self, name, url, allowed, hls=False, enforce=True, reconnect=False):
        self.cases.append(dict(name=name, url=url + "?api_key=synthetic-tls-test-token", allowed=allowed,
                               hls=hls, enforce=enforce, reconnect=reconnect))

    def server(self, name):
        owner = self

        class Server(ThreadingHTTPServer):
            daemon_threads = True
            handshakes = 0
            reads = 0

            def get_request(self):
                connection, address = super().get_request()
                connection.settimeout(10)
                self.handshakes += 1
                cert = "valid" if name.startswith("reconnect-") else name
                if name == "reconnect-invalid" and self.handshakes > 1:
                    cert = "self-signed"
                if cert in owner.contexts:
                    try:
                        connection = owner.contexts[cert].wrap_socket(connection, server_side=True)
                    except Exception:
                        connection.close()
                        raise
                return connection, address

            def handle_error(self, request, client_address):
                pass  # Expected EOF/reset after FFmpeg rejects the peer.

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                pass

            def do_GET(self):
                path = urlsplit(self.path).path
                owner.requests.append(dict(
                    server=name, path=self.path, authorization=self.headers.get("Authorization")
                ))
                self.server.reads += 1
                if path == "/fixtures":
                    return self.send(json.dumps(owner.cases).encode(), "application/json")
                if path == "/report":
                    return self.send(json.dumps(owner.violations()).encode(), "application/json")
                if path.startswith("/redirect/"):
                    target_name = path.split("/")[-1]
                    if target_name != name:
                        owner.redirect_targets.add(target_name)
                    self.send_response(302)
                    # Trust, not token placement, is what the redirect cases
                    # exercise: Lagoon's own credential now travels as a
                    # header scoped to its issuing origin (see
                    # MediaRequestAuthorization), so a redirect target never
                    # needs the legacy query token to be reachable.
                    self.send_header("Location", owner.urls[target_name] + "/body")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                if path == "/reconnect":
                    start = int(self.headers.get("Range", "bytes=0-").split("=")[1].split("-")[0])
                    self.send_response(206 if start else 200)
                    self.send_header("Content-Length", str(65_536 - start))
                    self.send_header("Accept-Ranges", "bytes")
                    if start:
                        self.send_header("Content-Range", f"bytes {start}-65535/65536")
                    self.end_headers()
                    self.wfile.write(b"x" * (8192 if self.server.reads == 1 else 65_536 - start))
                    self.wfile.flush()
                    self.connection.shutdown(socket.SHUT_RDWR)
                    self.close_connection = True
                    return
                if path.startswith("/hls/"):
                    _, _, kind, cert, file = path.split("/")
                    good, child = owner.urls["valid"], owner.urls[cert]
                    # The synthetic token rides only on same-origin children: the
                    # app must strip it into a header there, which the log guard
                    # proves. Children on other origins are trust probes, and a
                    # token in their URL would only show up in CFNetwork's own
                    # failure log, which is not the app's leak.
                    def credential(base, separator="?"):
                        return f"{separator}api_key=synthetic-tls-test-token" if base == good else ""
                    if file == "master.m3u8":
                        base = child if kind == "variant" else good
                        body = f"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=128000\n{base}/hls/{kind}/{cert}/variant.m3u8{credential(base)}\n"
                    elif file == "variant.m3u8":
                        body = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:0\n"
                        if kind == "key":
                            body += f'#EXT-X-KEY:METHOD=AES-128,URI="{child}/key.bin{credential(child)}",IV=0x' + "00" * 16 + "\n"
                        media = "encrypted.ts" if kind == "key" else "segment.ts"
                        # Three segments exercise native persistent connection
                        # reuse and rejection after playback has already begun.
                        for index in range(3):
                            base = child if kind == "segment" or (kind == "later-segment" and index == 2) else good
                            body += f"#EXTINF:1.0,\n{base}/{media}?segment={index}{credential(base, "&")}\n"
                        body += "#EXT-X-ENDLIST\n"
                    else:
                        return self.send(b"missing", code=404)
                    return self.send(body.encode(), "application/vnd.apple.mpegurl")
                if path == "/segment.ts":
                    return self.send(owner.media, "video/mp2t")
                if path == "/encrypted.ts":
                    return self.send(owner.encrypted, "video/mp2t")
                if path == "/key.bin":
                    return self.send(owner.key)
                self.send(b"TLS test response")

            def send(self, body, content_type="application/octet-stream", code=200):
                self.send_response(code)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        server = Server(("127.0.0.1", 0), Handler)
        self.servers.append((name, server))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        scheme = "http" if name in ("http", "control") else "https"
        return f"{scheme}://127.0.0.1:{server.server_port}"

    def violations(self):
        invalid = [r for r in self.requests if r["server"] in ("self-signed", "expired", "wrong-host")]
        reconnect = [r for r in self.requests if r["server"] == "reconnect-invalid"]
        # A request that only exists because a different origin redirected
        # it here must not still carry that origin's credential header —
        # MediaRequestAuthorization's redirect delegate is what is supposed
        # to strip it.
        leaked_header = [
            r for r in self.requests if r["server"] in self.redirect_targets and r.get("authorization")
        ]
        return [f'{r["server"]}: {r["path"]}' for r in invalid + reconnect[1:]] + [
            f'{r["server"]}: {r["path"]} kept the Authorization header across a cross-origin redirect'
            for r in leaked_header
        ]

    def close(self):
        (self.work / "requests.json").write_text(json.dumps(self.requests, indent=2) + "\n")
        for _, server in self.servers:
            server.shutdown()
            server.server_close()


def inject_environment(node, base):
    count = 0
    if isinstance(node, dict):
        if "TestBundlePath" in node:
            node.setdefault("EnvironmentVariables", {})["LAGOON_TLS_FIXTURES"] = base
            count += 1
        for value in node.values():
            count += inject_environment(value, base)
    elif isinstance(node, list):
        for value in node:
            count += inject_environment(value, base)
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--platforms", nargs="+", choices=("iOS", "tvOS"), default=["iOS", "tvOS"])
    parser.add_argument("--all-unit-tests", action="store_true")
    args = parser.parse_args()
    work = (args.work or Path(tempfile.mkdtemp(prefix="lagoon-tls-tests-"))).resolve()
    work.mkdir(parents=True, exist_ok=True)
    runtimes = json.loads(run(["xcrun", "simctl", "list", "runtimes", "-j"]))["runtimes"]
    for platform in args.platforms:
        directory = work / platform / datetime.now().strftime("%Y%m%d-%H%M%S")
        directory.mkdir(parents=True, exist_ok=True)
        fixtures = Fixtures(directory)
        device = None
        try:
            runtime = max((r for r in runtimes if r["isAvailable"] and r["platform"] == platform),
                          key=lambda r: tuple(map(int, r["version"].split("."))))
            device_type = next(t["identifier"] for t in runtime["supportedDeviceTypes"]
                               if t["productFamily"] == ("iPhone" if platform == "iOS" else "Apple TV"))
            device = run(["xcrun", "simctl", "create", f"Lagoon TLS {platform}", device_type, runtime["identifier"]])
            run(["xcrun", "simctl", "boot", device])
            run(["xcrun", "simctl", "bootstatus", device, "-b"])
            run(["xcrun", "simctl", "keychain", device, "add-root-cert", directory / "ca.pem"])
            destination = f"platform={platform} Simulator,id={device}"
            derived = work / platform / "DerivedData"
            print(f"Building {platform}; logs: {directory}", flush=True)
            with (directory / "build.log").open("w") as log:
                subprocess.run(["xcodebuild", "build-for-testing", "-scheme", "Lagoon", "-destination", destination,
                                "-derivedDataPath", str(derived)], cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            xctestrun = next((derived / "Build/Products").glob("Lagoon_Lagoon_*.xctestrun"))
            spec = plistlib.loads(xctestrun.read_bytes())
            if not inject_environment(spec, fixtures.control):
                raise RuntimeError("Could not find test target environment in xctestrun")
            xctestrun.write_bytes(plistlib.dumps(spec))
            print(f"Testing {platform}: {len(fixtures.cases)} transport cases", flush=True)
            command = ["xcodebuild", "test-without-building", "-xctestrun", str(xctestrun), "-destination", destination,
                       "-parallel-testing-enabled", "NO", "-resultBundlePath", str(directory / "TLS.xcresult")]
            if not args.all_unit_tests:
                command += ["-only-testing:LagoonTests/FFmpegTransportTests"]
            with (directory / "test.log").open("w") as log:
                subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, check=True)
            # Catch an accidentally skipped integration test even if XCTest succeeds.
            if not any(urlsplit(r["path"]).path == "/report" for r in fixtures.requests):
                raise RuntimeError("The TLS matrix did not run (fixture environment missing)")
            if fixtures.violations():
                raise RuntimeError(f"Invalid peers received HTTP requests: {fixtures.violations()}")
            if "synthetic-tls-test-token" in (directory / "test.log").read_text():
                raise RuntimeError("A native diagnostic exposed the synthetic query token")
            print(f"Passed {platform}: certificate matrix and no requests to invalid peers", flush=True)
        finally:
            fixtures.close()
            if device:
                subprocess.run(["xcrun", "simctl", "shutdown", device], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                run(["xcrun", "simctl", "delete", device])


if __name__ == "__main__":
    main()
