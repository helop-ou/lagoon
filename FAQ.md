# FAQ

### Why another client?

Fair question, and I understand. It is also why I am not advertising Lagoon
anywhere (also because I'm quite bad at marketing).

I built it for myself and for the people using my own Jellyfin server, who
kept telling me there was nothing that just worked unless they paid for
Infuse. The second reason is the engine: the sample-buffer player underneath
Lagoon took most of the effort here, and I would rather it existed as
something others can build on than not exist at all.

### Was AI used in this project?

Yes, Claude and Codex. I review and test everything they write, and every change goes through me
and through an internal TestFlight build before it reaches anyone else. I am a
full-time senior SWE and my time outside work is limited and without AI this project
would've taken me quite a while longer to get it ready for a release.

### How is this better than other clients?

For a specific need you already have covered, probably it is not. Lagoon aims
to be simple enough that you can point a non-techy friend at it, have them
sign in, and have it play, ideally without the server re-encoding anything.

There are some very good clients out there and I won't be here, trying to
advertise that my client is better than the other ones.

### What formats are supported?

[**Codec support**](docs/codec-support.md) has the full table: containers,
video and audio codecs, subtitle formats, and the conditions attached to each.

It is generated from the capability profile the app sends the server, so it is
accurate by construction rather than by me remembering to update it.

I won't throw in promises that this will play anything and will never transcode, but 
I do try to have as wide as a support for most stuff as possible.

### Which Jellyfin versions does it work with?

Uses Jellyfin's user-scoped HTTP API, which Jellyfin 10.8 and later expose, so
Lagoon works against 10.8 through current. Jellyfin 10.11.11, 12.0.0 and 12.1 have been tested thoroughly.

### Does it work offline?

On iPhone and iPad, yes. Films and episodes can be downloaded and played back.
Whether your account may download is decided by your Jellyfin
server, not by Lagoon.

### Does it work with Jellyseerr?

Yes, optionally. Connect it and requests and discovery appear alongside your
library. Without it, Lagoon works exactly as before.

### Does it have any telemetry?

In a sense, yes, it has a custom Sentry diagnostic chain built-in.
The reason for that is because reporting issues is always the point that has the most
friction, and I wanted to have something that would automatically send some basic info to me if
any issues are detected. The Sentry info is completely anonymous though, no info about your server,
connection, or anything like that is ever sent to me (you can check the code). It is also possible to turn
it off completely in settings.

### Why target tvOS and iOS 26?

Because most iOS devices are kept up to date and since I made the project mostly for me,
I don't know anyone who uses OS versions older than those.

This is not set in stone and may change in the future, although I doubt I will be supporting anything older
than 26 proactively.
