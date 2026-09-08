# Lagoon support — publication draft

Editorial status: domain, support contact and public 1.0 availability remain
undecided. Add a monitored contact route before publishing this page.

## Getting started

Lagoon is a Jellyfin client for iPhone, iPad and Apple TV. You need a Jellyfin
server and permission to access its media. Enter the server's address, including
its port and path if your operator supplied them, then sign in. Lagoon does not
provide a media library or a server account.

## Cannot connect

Check that the same address works in a browser on your network. Confirm that
your server is running and that any required VPN is connected. Include the
correct port and reverse-proxy path. For HTTPS, the certificate must be valid
for the server's hostname and trusted by your device.

On iPhone or iPad, if Lagoon reports denied local-network access, use **Open
Settings**, enable Local Network for Lagoon, return to the app and retry. Keep
the entered address. Apple TV does not have this permission prompt.

If your session expires, sign in again. For an incorrect password or unavailable
account, contact your Jellyfin server operator.

## Playback and subtitles

Include the app version/build from Settings → About, device model, OS version,
server version, and the point where playback fails in a support report. If
possible, include the media container and audio/video codec information. Different
server, network and media configurations can affect playback.

Subtitle search in Lagoon uses your Jellyfin server, not a direct connection
from the app. If subtitle search is unavailable, ask your server administrator
to (a) turn on "Allow subtitle management" for your account in the Jellyfin
dashboard and (b) install and configure a subtitle provider plugin (for
example the official OpenSubtitles plugin). Note that the same setting also
allows uploading subtitles into the library.

## Sharing a report

Describe what you did, what you expected and what happened. Reproduction steps
using media you have permission to share are useful. Remove passwords, access
tokens, cookies, API keys, private server URLs and personal library details from
screenshots and logs before sending them. Do not send an administrator account.

The final page must provide the monitored contact and link to the approved
privacy policy. A public support URL must work without a Jellyfin login.
