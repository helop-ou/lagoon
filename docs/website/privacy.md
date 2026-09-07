# Lagoon privacy policy — publication draft

Editorial status: not yet a published policy. Before publication, confirm the
publisher/controller identity, contact method, effective date, support/crash-report
retention, service practices and final 1.0 integration scope using the HEL-143
data-flow inventory. These notes should not appear in the published policy.

## Connecting to your services

Lagoon connects to the Jellyfin server you choose. Signing in sends your login
information to that server. Browsing, searching and watching send the requests,
account/device identity and playback progress needed to provide those features.
Your server operator controls the server's accounts, viewing history and logs.

If you connect Seerr, Lagoon sends your authentication and requests to that Seerr
server. Discovery, search and media requests may be associated with your server
account. Artwork shown by Seerr can be downloaded directly from TMDB's image
service, which receives the requested image path and ordinary network information.

The optional direct OpenSubtitles integration connects to OpenSubtitles using its
own API key and account. Searches and downloads can include title identifiers,
language, and a media-file hash and size. This account is separate from your
Jellyfin account. Subtitles supplied through Jellyfin use your Jellyfin server's
configuration instead. The public policy must reflect whether the direct
integration is included in the final release.

## Information stored on your device

Lagoon remembers server/account information and preferences locally. Session
tokens and Seerr cookies use the device Keychain. Lagoon does not persist your
Jellyfin password. Recent searches belong to the selected Jellyfin account.
Media, subtitle and artwork caches support playback and browsing.

On Apple TV, optional Top Shelf content uses a local snapshot and artwork prepared
by the app. The extension has no server credentials and makes no server requests.

Forgetting an account removes its saved Lagoon credentials and account-scoped
local data. This does not delete the account or its history on your Jellyfin or
Seerr server. Contact that server's operator for server-side deletion. Direct
OpenSubtitles has a separate device-wide account and sign-out control.

## Permissions and diagnostics

On iPhone and iPad, local-network access lets Lagoon reach the local servers you
choose. You can change access in Settings. Denying it can prevent local servers
from connecting; Lagoon provides a Settings shortcut and retry.

Lagoon has no advertising or third-party analytics SDK in the reviewed build.
Playback diagnostics are generated locally. If you choose to share diagnostics,
screenshots or a support message, they may reveal server or media information.
Review them before sharing. Final policy copy must describe the publisher's
actual handling of support messages and any Apple crash/TestFlight reports it
receives, including retention and deletion.

## Contact and requests

Publication requires a working privacy contact and the publisher's identity.
No public contact has been selected yet. Server-side data requests should go to
the operator of the service that holds the data; the approved policy must also
explain how to contact Lagoon's publisher about data it receives.
