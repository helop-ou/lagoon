#!/usr/bin/env python3
"""Loopback-only Jellyfin fixture for direct/HLS playback and session revocation.

Requires an installed ffmpeg CLI to generate synthetic test media; invokes no
compiler. Run with --work /tmp/lagoon-fixture. The printed URL can be passed to
SessionExpiryUITests through LAGOON_SESSION_FIXTURE. No real accounts are used.
"""
import argparse
import gzip
import json
from pathlib import Path
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from threading import Lock
from urllib.parse import parse_qs, urlsplit


def media(directory, duration, embedded_subtitles=False):
    directory.mkdir(parents=True, exist_ok=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
        "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
        "-t", str(duration), "-c:v", "libx264", "-preset", "ultrafast", "-g", "48",
        "-pix_fmt", "yuv420p", "-c:a", "aac", "-ac", "2", "-movflags", "+faststart",
        str(directory / "movie.mp4"),
    ], check=True)
    if embedded_subtitles:
        # A real embedded track, so the engine lists it from the container
        # rather than from anything the fixture claims in PlaybackInfo.
        def stamp(seconds):
            return f"{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d},000"

        (directory / "embedded.srt").write_text("\n\n".join(
            f"{n + 1}\n{stamp(n * 10)} --> {stamp(n * 10 + 9)}\nEmbedded caption {n + 1}"
            for n in range(duration // 10)) + "\n")
        subprocess.run([
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-y",
            "-i", str(directory / "movie.mp4"), "-i", str(directory / "embedded.srt"),
            "-map", "0:v", "-map", "0:a", "-map", "1:s", "-c", "copy", "-c:s", "srt",
            "-metadata:s:s:0", "language=eng", "-metadata:s:s:0", "title=Embedded English",
            str(directory / "movie.mkv"),
        ], check=True)
    subprocess.run([
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", str(directory / "movie.mp4"),
        "-c", "copy", "-f", "hls", "-hls_time", "2", "-hls_list_size", "0",
        "-hls_segment_type", "fmp4", "-hls_playlist_type", "vod", str(directory / "variant.m3u8"),
    ], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--base-path", action="append", default=[],
                        help="Require one of these proxy prefixes for API requests (repeatable; fixture controls remain at root)")
    parser.add_argument("--subtitle-downloads", action="store_true", help="Expose working, failing, and oversized external subtitle tracks")
    parser.add_argument("--subtitle-provider", action="store_true",
                        help="Expose a provider search, an embedded track, and the sidecar the download attaches")
    args = parser.parse_args()
    if any(not p.startswith("/") or p.endswith("/") or "?" in p or "#" in p for p in args.base_path):
        parser.error("Base paths must start with / and have no trailing slash, query, or fragment")
    directory = args.work.resolve()
    duration = 300 if args.subtitle_downloads or args.subtitle_provider else 90
    media(directory, duration, embedded_subtitles=args.subtitle_provider)
    lock = Lock()
    state = {"mode": "direct", "generation": 0, "revoked": [], "requests": [], "drop_connections": False, "subtitle_recovered": False,
             "uploaded": False, "searches": 0, "downloads": 0}
    user = {"Id": "fixture-user", "Name": "Fixture viewer",
            "Policy": {"EnableSubtitleManagement": True, "IsAdministrator": False}}
    movie = {"Id": "fixture", "Name": "Session fixture movie", "Type": "Movie", "MediaType": "Video",
             "RunTimeTicks": duration * 10_000_000, "UserData": {"Played": False, "PlaybackPositionTicks": 0},
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
                    state.update(mode=query.get("mode", ["direct"])[0], generation=0, revoked=[], requests=[], drop_connections=False, subtitle_recovered=False, uploaded=False, searches=0, downloads=0)
                    return self.reply({"ok": True})
                if path == "/__fixture/connectivity":
                    state["drop_connections"] = query.get("drop", ["0"])[0] == "1"
                    return self.reply({"ok": True})
                if path == "/__fixture/revoke":
                    state["revoked"].append(f"synthetic-session-{state['generation']}")
                    return self.reply({"ok": True})
                if path == "/__fixture/subtitle-recover":
                    state["subtitle_recovered"] = True
                    return self.reply({"ok": True})
                if path == "/__fixture/state":
                    return self.reply(state)
                state["requests"].append({"path": path, "revoked": token in state["revoked"]})
                (directory / "requests.json").write_text(json.dumps(state, indent=2))
                if args.base_path:
                    prefix = next((p for p in sorted(args.base_path, key=len, reverse=True)
                                   if path.startswith(p + "/")), None)
                    if prefix is None:
                        return self.reply({"error": "Missing proxy base path"}, 404)
                    path = path.removeprefix(prefix)
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
                recovered = state["subtitle_recovered"]
            if args.subtitle_downloads and path.startswith("/Subtitles/"):
                if path == "/Subtitles/retry.vtt" and not recovered:
                    return self.reply({"error": "Synthetic subtitle failure"}, 500)
                if path == "/Subtitles/oversized.vtt":
                    # Small on the wire, too large after URLSession expands it.
                    return self.reply(gzip.compress(b"x" * (8 * 1024 * 1024 + 1)), kind="text/vtt",
                                      headers={"Content-Encoding": "gzip"})
                text = "Recovered captions" if path.endswith("retry.vtt") else "Working captions"
                return self.reply(f"WEBVTT\n\n00:00:00.000 --> 00:05:00.000\n{text}\n".encode(), kind="text/vtt")
            if args.subtitle_provider:
                # The provider search, the provider file, and the upload that
                # attaches it to the item — the three calls a real download
                # makes (HEL-151).
                if re.fullmatch(r"/Items/fixture/RemoteSearch/Subtitles/[a-z]{2,3}", path):
                    with lock:
                        state["searches"] += 1
                    return self.reply([{
                        "Id": "provider-candidate", "Name": "Provider English",
                        "ThreeLetterISOLanguageName": "eng", "ProviderName": "Synthetic",
                        "Format": "vtt", "DownloadCount": 42, "IsHashMatch": True,
                        "HearingImpaired": False, "IsForced": False,
                    }])
                if path == "/Providers/Subtitles/Subtitles/provider-candidate":
                    with lock:
                        state["downloads"] += 1
                    return self.reply(
                        b"WEBVTT\n\n00:00:00.000 --> 00:05:00.000\nDownloaded captions\n",
                        kind="text/vtt")
                if path == "/Videos/fixture/Subtitles":
                    with lock:
                        state["uploaded"] = True
                    return self.reply(b"", 204)
                if path == "/Subtitles/downloaded.vtt":
                    return self.reply(
                        b"WEBVTT\n\n00:00:00.000 --> 00:05:00.000\nDownloaded captions\n",
                        kind="text/vtt")
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
                if args.subtitle_provider:
                    source["Container"] = "mkv"
                    source["Size"] = (directory / "movie.mkv").stat().st_size
                    source["MediaStreams"].append(
                        {"Type": "Subtitle", "Codec": "subrip", "Index": 2, "Language": "eng",
                         "DisplayTitle": "English - SUBRIP", "IsExternal": False,
                         "IsTextSubtitleStream": True, "DeliveryMethod": "Embed"})
                    with lock:
                        uploaded = state["uploaded"]
                    if uploaded:
                        # Jellyfin renumbers a source's streams when a sidecar
                        # is attached: the new external stream takes index 0
                        # and everything already in the container moves up.
                        for stream in source["MediaStreams"]:
                            stream["Index"] += 1
                        source["MediaStreams"].insert(0, {
                            "Type": "Subtitle", "Codec": "webvtt", "Index": 0, "Language": "eng",
                            "DisplayTitle": "English - WEBVTT - External", "IsExternal": True,
                            "IsTextSubtitleStream": True, "DeliveryMethod": "External",
                            "DeliveryUrl": "/Subtitles/downloaded.vtt"})
                        source["DefaultAudioStreamIndex"] = 2
                if args.subtitle_downloads:
                    source["DefaultSubtitleStreamIndex"] = 2
                    source["MediaStreams"] += [
                        {"Type": "Subtitle", "Codec": "webvtt", "Index": index, "Language": "eng",
                         "DisplayTitle": title, "IsExternal": True, "DeliveryMethod": "External",
                         "DeliveryUrl": f"/Subtitles/{name}.vtt"}
                        for index, name, title in [(2, "working", "Working track"), (3, "retry", "Retry track"),
                                                   (4, "oversized", "Oversized track")]]
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
            stream_name = "movie.mkv" if args.subtitle_provider else "movie.mp4"
            name = stream_name if path == "/Videos/fixture/stream" else path.removeprefix("/media/")
            if name in {"movie.mp4", "movie.mkv", "init.mp4"} or re.fullmatch(r"variant\d+\.m4s", name):
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
