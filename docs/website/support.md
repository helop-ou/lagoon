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

Subtitle availability depends on the media and your configured provider. Direct
OpenSubtitles uses its own account and provider allowances, separate from your
Jellyfin login. Include the exact provider error when reporting a problem. Update
this section if direct OpenSubtitles is excluded from public 1.0.

## Sharing a report

Describe what you did, what you expected and what happened. Reproduction steps
using media you have permission to share are useful. Remove passwords, access
tokens, cookies, API keys, private server URLs and personal library details from
screenshots and logs before sending them. Do not send an administrator account.

The final page must provide the monitored contact and link to the approved
privacy policy. A public support URL must work without a Jellyfin login.
