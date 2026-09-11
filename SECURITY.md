# Security policy

## Supported versions

Lagoon ships as a single moving build. Only the most recent build distributed
through TestFlight, and the current App Store release once there is one, is
supported. Fixes land in the next build rather than in patches to older ones.
Settings → About shows the version and build you are running.

## Reporting a vulnerability

Please report privately rather than opening an issue, and give the fix a
chance to ship before describing the problem publicly.

- Email **security@helop.ee**.
- Include the app version and build, the platform and OS version, the device
  or simulator, what an attacker could achieve, and the steps to reproduce it.
- Say whether you want credit in the release notes, and under what name.

There is no bug bounty. This is a small project maintained by one person, so
expect an acknowledgement within about a week, an assessment of severity and
scope after that, and a note when the fix is in a distributed build. If you
have not heard back in two weeks, send a reminder.

## What Lagoon talks to

Lagoon is a client for servers you run. It connects to:

- your Jellyfin server, with credentials you enter, stored in the keychain;
- your Seerr server, if you configure one, for discovery and requests;
- Sentry, for automatic diagnostic reports about playback and request
  failures.

Diagnostic reporting can be turned off in Settings → Advanced → Send
Diagnostic Reports, and off means off: nothing is sent or queued, and
anything still waiting to be sent is discarded. The
reports carry build, device class, format and failure facts, and never account
identifiers, media titles or item identifiers, server addresses, credentials,
request or response bodies, search terms, or subtitle text.
[The diagnostics reference](docs/reference/playback/diagnostics.md) lists every
field that can be sent and every field that cannot.

There is no Lagoon account, no analytics beyond those reports, and no other
network destination. Vulnerabilities in Jellyfin, Jellyseerr or Overseerr
themselves belong to those projects; report them there.
