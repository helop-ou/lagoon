#!/usr/bin/env python3
"""Loopback-only Jellyfin fixture for direct/HLS playback and session revocation.

Requires an installed ffmpeg CLI to generate synthetic test media; invokes no
compiler. Run with --work /tmp/lagoon-fixture. The printed URL can be passed to
SessionExpiryUITests through LAGOON_SESSION_FIXTURE. No real accounts are used.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import parse_qs, urlsplit


def media(directory):
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", "90", "-c:v", "libx264", "-preset", "ultrafast", "-g", "48",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-movflags", "+faststart",
        str(directory / "movie.mp4"),
    ], check=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(directory / "movie.mp4"),
        "-c", "copy", "-f", "hls", "-hls_time", "2", "-hls_list_size", "0",
        "-hls_segment_type", "fmp4", "-hls_playlist_type", "vod", str(directory / "variant.m3u8"),
    ], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    args = parser.parse_args()
    directory = args.work.resolve()
    media(directory)
    lock = Lock()
    state = {"mode": "direct", "generation": 0, "revoked": [], "requests": [], "drop_connections": False}
    user = {"Id": "fixture-user", "Name": "Fixture viewer"}
    movie = {"Id": "fixture", "Name": "Session fixture movie", "Type": "Movie", "MediaType": "Video",
             "RunTimeTicks": 900_000_000, "UserData": {"Played": False, "PlaybackPositionTicks": 0},
             "Chapters": [], "Trickplay": {}, "Genres": []}
    empty = {"Items": [], "TotalRecordCount": 0}

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def reply(self, body, status=200, kind="application/json", headers=None):
            if not isinstance(body, bytes):
                body = json.dumps(body).encode()
            self.send_response(status)
            self.send_header("Content-Type", kind)
            self.send_header("Content-Length", str(len(body)))
            for key, value in (headers or {}).items():
                self.send_header(key, value)
            self.end_headers()
            try:
                self.wfile.write(body)
            except (BrokenPipeError, ConnectionResetError):
                pass  # Cancellation is part of session-expiry testing.

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.body = json.loads(body) if body else {}
            self.do_GET()

        def do_GET(self):
            parsed = urlsplit(self.path)
            path, query = parsed.path, parse_qs(parsed.query)
            match = re.search(r'Token="([^"]+)"', self.headers.get("Authorization", ""))
            token = match.group(1) if match else query.get("ApiKey", [""])[0]
            with lock:
                if path == "/__fixture/reset":
                    state.update(mode=query.get("mode", ["direct"])[0], generation=0, revoked=[], requests=[], drop_connections=False)
                    return self.reply({"ok": True})
                if path == "/__fixture/connectivity":
                    state["drop_connections"] = query.get("drop", ["0"])[0] == "1"
                    return self.reply({"ok": True})
                if path == "/__fixture/revoke":
                    state["revoked"].append(f"synthetic-session-{state['generation']}")
                    return self.reply({"ok": True})
                if path == "/__fixture/state":
                    return self.reply(state)
                state["requests"].append({"path": path, "revoked": token in state["revoked"]})
                (directory / "requests.json").write_text(json.dumps(state, indent=2))
                if path in ("/api/v1/status", "/api/v1/settings/public"):
                    if state["drop_connections"]:
                        self.close_connection = True
                        return
                    return self.reply({"version": "3.0.0"} if path.endswith("/status") else
                                      {"initialized": True, "mediaServerType": 2, "mediaServerLogin": False})
                if path == "/System/Info/Public":
                    if state["drop_connections"]:
                        self.close_connection = True
                        return
                    return self.reply({"ServerName": "Lagoon session fixture", "Id": "fixture", "Version": "10.11.0"})
                if path == "/QuickConnect/Enabled":
                    return self.reply(False)
                if path == "/Users/AuthenticateByName":
                    state["generation"] += 1
                    username = getattr(self, "body", {}).get("Username", user["Name"])
                    identity = {"Id": {"Privacy A": "privacy-a", "Privacy B": "privacy-b"}.get(username, user["Id"]),
                                "Name": username}
                    return self.reply({"AccessToken": f"synthetic-session-{state['generation']}", "User": identity})
                if not token or token in state["revoked"]:
                    return self.reply({"error": "Session expired"}, status=401)
                mode = state["mode"]
            if path == "/Users/Me":
                return self.reply(user)
            if path.endswith("/Views"):
                return self.reply({"Items": [{"Id": "library", "Name": "Movies", "Type": "CollectionFolder",
                                              "CollectionType": "movies"}], "TotalRecordCount": 1})
            if path.endswith("/PlaybackInfo"):
                source = {"Id": "source", "Container": "mp4", "RunTimeTicks": movie["RunTimeTicks"],
                          "Size": (directory / "movie.mp4").stat().st_size, "SupportsDirectPlay": mode == "direct",
                          "SupportsDirectStream": False, "SupportsTranscoding": True,
                          "TranscodingUrl": f"/media/master.m3u8?ApiKey={token}", "TranscodingSubProtocol": "hls",
                          "DefaultAudioStreamIndex": 1,
                          "MediaStreams": [{"Type": "Video", "Codec": "h264", "Index": 0,
                                            "Width": 320, "Height": 180, "RealFrameRate": 24},
                                           {"Type": "Audio", "Codec": "aac", "Index": 1, "Channels": 2}]}
                return self.reply({"MediaSources": [source], "PlaySessionId": "fixture-play"})
            if path.endswith("/Items/fixture"):
                return self.reply(movie)
            if path.endswith("/Items/Latest"):
                return self.reply([movie])
            if path.endswith("/Items"):
                types = query.get("IncludeItemTypes", ["Movie"])[0].split(",")
                return self.reply({"Items": [movie] if "Movie" in types else [], "TotalRecordCount": 1})
            if path.startswith("/Sessions/"):
                return self.reply({})
            if path.endswith("/Resume") or path.startswith(("/Shows/", "/MediaSegments/")):
                return self.reply(empty)
            if path == "/media/master.m3u8":
                return self.reply(f"#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1500000,CODECS=\"avc1.42c00c,mp4a.40.2\"\nvariant.m3u8?ApiKey={token}\n".encode(),
                                  kind="application/vnd.apple.mpegurl")
            if path == "/media/variant.m3u8":
                playlist = (directory / "variant.m3u8").read_text()
                playlist = re.sub(r'URI="([^"]+)"', rf'URI="\1?ApiKey={token}"', playlist)
                playlist = "\n".join(f"{line}?ApiKey={token}" if line and not line.startswith("#") else line
                                     for line in playlist.splitlines()) + "\n"
                return self.reply(playlist.encode(), kind="application/vnd.apple.mpegurl")
            name = "movie.mp4" if path == "/Videos/fixture/stream" else path.removeprefix("/media/")
            if name in {"movie.mp4", "init.mp4"} or re.fullmatch(r"variant\d+\.m4s", name):
                file = directory / name
                if file.is_file():
                    body = file.read_bytes()
                    headers = {"Accept-Ranges": "bytes"}
                    byte_range = re.fullmatch(r"bytes=(\d+)-(\d*)", self.headers.get("Range", ""))
                    if byte_range:
                        start = int(byte_range[1])
                        end = min(int(byte_range[2]) if byte_range[2] else len(body) - 1, len(body) - 1)
                        if start > end:
                            return self.reply(b"", 416, headers={"Content-Range": f"bytes */{len(body)}"})
                        headers["Content-Range"] = f"bytes {start}-{end}/{len(body)}"
                        return self.reply(body[start:end + 1], 206, "video/mp4", headers)
                    return self.reply(body, kind="video/mp4", headers=headers)
            self.reply({}, 404)

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    url = f"http://127.0.0.1:{server.server_port}"
    (directory / "server.json").write_text(json.dumps({"url": url}))
    print(url, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
