#!/usr/bin/env python3
"""Capture what Lagoon's diagnostic reporter would send to Sentry (HEL-159).

Runs a local endpoint that accepts Sentry envelopes and writes each one to
disk, split into its event JSON and history attachment, so the exact bytes
that would leave a device can be read. Point a Debug build at it:

    scripts/diagnostics-capture-server.py --port 8765 --out /tmp/lagoon-diagnostics
    xcrun simctl launch <udid> ee.helop.lagoon \
        -diagnostics.reportingEnabled YES \
        -diagnostics.sentryDSN http://key@127.0.0.1:8765/1 \
        -debug.regressionFailFirstDelivery delivery

`--status 429` answers every envelope with a rate limit (and the
`X-Sentry-Rate-Limits` header) to exercise the transport's backoff; `--status
500` exercises the retry path. Nothing here talks to Sentry.
"""

import argparse
import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer


def split_envelope(body: bytes):
    """Yields (header, payload) pairs from an envelope body."""
    lines = body.split(b"\n")
    envelope_header = json.loads(lines[0])
    index = 1
    items = []
    while index < len(lines) and lines[index]:
        item_header = json.loads(lines[index])
        length = item_header.get("length")
        # Payloads are written on their own line; length is authoritative.
        payload = lines[index + 1][:length] if length is not None else lines[index + 1]
        items.append((item_header, payload))
        index += 2
    return envelope_header, items


class Handler(BaseHTTPRequestHandler):
    out_dir = "."
    status = 200

    def do_POST(self):  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        stamp = time.strftime("%Y%m%d-%H%M%S") + f"-{int(time.time() * 1000) % 1000:03d}"
        base = os.path.join(self.out_dir, stamp)
        with open(base + ".envelope", "wb") as raw:
            raw.write(body)
        summary = {
            "path": self.path,
            "auth": self.headers.get("X-Sentry-Auth"),
            "content_type": self.headers.get("Content-Type"),
            "user_agent": self.headers.get("User-Agent"),
            "bytes": len(body),
        }
        try:
            header, items = split_envelope(body)
            summary["event_id"] = header.get("event_id")
            for item_header, payload in items:
                kind = item_header.get("type")
                name = item_header.get("filename", kind)
                with open(f"{base}.{name if kind == 'attachment' else 'event.json'}", "wb") as part:
                    part.write(payload)
                if kind == "event":
                    event = json.loads(payload)
                    summary["fingerprint"] = event.get("fingerprint")
                    summary["level"] = event.get("level")
                    summary["release"] = event.get("release")
        except Exception as error:  # noqa: BLE001
            summary["parse_error"] = str(error)
        print(json.dumps(summary), flush=True)
        self.send_response(self.status)
        if self.status == 429:
            self.send_header("X-Sentry-Rate-Limits", "60:error;default:organization")
            self.send_header("Retry-After", "60")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, *_):
        return


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--out", default="/tmp/lagoon-diagnostics")
    parser.add_argument("--status", type=int, default=200, help="HTTP status to answer with (200, 429, 500)")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    Handler.out_dir = args.out
    Handler.status = args.status
    print(f"capturing envelopes on http://127.0.0.1:{args.port} into {args.out} (status {args.status})", flush=True)
    HTTPServer(("127.0.0.1", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
