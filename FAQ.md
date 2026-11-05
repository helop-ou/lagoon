# FAQ

### Why another client?

In my defense, I started working on this before the big wave of different Jellyfin clients started coming out.
It is also why I don't really advertise this project anywhere. There is also this really bad (but also kind of justified)
backlash against using AI at all to develop projects amongst the Jellyfin community. I get it, but people have a hard time differentiating
between vibecoded slop, and AI assisted projects, where the developer actually knows about architecture themselves.
I'm not going to be here and say that this is the best client ever, or I am the smartest developer ever, I don't know everything,
I am not the smartest, but I do want to learn and develop myself as a person and as a developer.

### Will this be free? Will there be a supporter plan?

Yes it will be free forever, and no I don't plan on implementing a supporter plan and paywalling icons, or anything else.
I honestly don't care much about donations themselves, I don't need them at the moment (I have a full-time job, well atleast I have a full time job at the time of writing this,
idk what the tech CEO-s cook up next). This is completely a passion project of mine and while I do really like other clients (Infuse, Neptune come to mind and they're really an inspiration),
I have always kind of disliked the idea of subscription based solutions, I know they're needed from a business standpoint, but Jellyfin itself is open source and free, and I feel like it should
keep being like that. That is to say, I am not throwing any shade against Infuse or Neptune, or any other clients, I really respect them and personally am supporting Infuse & Neptune with a yearly subscription just to show my appreciation to those developers.

TLDR is that this app and entire project will be free, and open source forever.

### Was AI used in this project?

Yes, Claude and Codex. I review and test everything they write, and every change goes through me
and through an internal TestFlight build before it reaches anyone else. I am a
full-time senior SWE and my time outside work is limited and without AI this project
would've taken me quite a while longer to get it ready for a release. AI is part of the
software development workflow nowadays and that's okay, we just need to slow down at times
so we don't get caught up in shipping half-baked features since the velocity is so big with AI.

### How is this better than other clients?

For a specific need that you already have covered with any other client? Probably not.
The idea of this project is to be something that I can fully control and support, so I
don't have to spend time diagnosing other clients issues when some of my friends and family encounter them with
other clients (instead I can spend time diagnosing my own code and client).
Again, I'm not trying to advertise this as the best Jellyfin client ever
it will have bugs, it will have issues and wonky UX at times (I have never been that great with UX, I'm learning to get better at it tho).

### Why not other platforms?

Probably in the future I will expand on to other platforms aswell, the thing is that I am very much a firm believer of native
solutions. That means that if I want to support a specific platform, I will have to start learning that platform's native solutions
and actually develop a proper native app for it.
I find wrapping frameworks like react-native or flutter to be a bit too complicated and a hassle to support long-term and
I as a user have always appreciated proper native apps on all platforms.

### What about LiveTV?

It's something that I plan on adding, but in the future, I want to get it right and it's personally not something
that's high on my priority list at the moment. I have been focusing getting the player and current features of the client right,
then I will move on to actually implementing proper livetv support amongst other things.

### What formats are supported?

[**Codec support**](docs/codec-support.md) has the full table: containers,
video and audio codecs, subtitle formats.

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

Because most iOS devices are kept up to date and since I made the project mostly for me and my friends and family,
I don't know anyone who uses OS versions older than those. 

This is not set in stone and may change in the future, although I doubt I will be supporting anything older
than 26 proactively.
