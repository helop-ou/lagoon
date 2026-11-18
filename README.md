<p align="center">
  <img src=".github/readme/banner.png" alt="Lagoon, a native Jellyfin client for Apple TV, iPhone and iPad" width="100%">
</p>

<p align="center">
  <img src="https://img.shields.io/badge/tvOS-26-0B1D28?logo=apple&logoColor=white" alt="tvOS 26">
  <img src="https://img.shields.io/badge/iOS-26-0B1D28?logo=apple&logoColor=white" alt="iOS 26">
  <img src="https://img.shields.io/badge/Jellyfin-10.8%2B-0D4A57?logo=jellyfin&logoColor=white" alt="Jellyfin 10.8+">
  <a href="LICENSE"><img src="https://img.shields.io/badge/licence-MPL--2.0-0D4A57" alt="MPL-2.0"></a>
  <a href="FAQ.md#was-ai-used-in-this-project"><img src="https://img.shields.io/badge/AI-assisted-0D4A57" alt="AI-assisted"></a>
  <a href="https://github.com/helop-ou/lagoon/actions/workflows/tests.yml"><img src="https://github.com/helop-ou/lagoon/actions/workflows/tests.yml/badge.svg" alt="Tests"></a>
</p>

<p align="center">
  <a href="https://apps.apple.com/app/lagoon-for-jellyfin/id6801882873"><img src="https://img.shields.io/badge/Download_on_the-App_Store-2ED4C7?style=for-the-badge&logo=apple&logoColor=0B1D28&labelColor=E9F1F2" alt="Download on the App Store"></a>
  <a href="https://testflight.apple.com/join/PwjnXuAt"><img src="https://img.shields.io/badge/Apple_TV_beta-TestFlight-0B1D28?style=for-the-badge&logo=apple&logoColor=2ED4C7" alt="Apple TV beta on TestFlight"></a>
  <a href="https://lagoon.helop.dev"><img src="https://img.shields.io/badge/lagoon.helop.dev-0B1D28?style=for-the-badge&logo=safari&logoColor=2ED4C7" alt="lagoon.helop.dev"></a>
</p>

<p align="center">
  <img src=".github/readme/screens/tvos-movie-detail.webp" width="49%" alt="Movie detail page">
  <img src=".github/readme/screens/tvos-library.webp" width="49%" alt="Library">
  <img src=".github/readme/screens/tvos-player.webp" width="49%" alt="Player with its buttons and timeline">
  <img src=".github/readme/screens/tvos-watch-together.webp" width="49%" alt="Watch Together">
</p>

## Features

- **Sign in** by address, without a scheme or port, with a password or Quick Connect, or pick a server found on your network
- **Profiles** for every Jellyfin user on a shared device, on one server or several, with sessions kept in the keychain
- **Home and Discover** with featured banners and native rows you can reorder or hide, no Home Screen Sections plugin needed (although it is supported)
- **Library** of Movies and Shows with sorting and filters, remembered per account
- **Detail pages** with seasons, an episode rail, resume points, trailers and a page for everyone in the cast and crew
- **Collections and playlists** that play straight through, like episodes
- **Playback** that plays the file directly when it can and asks the server to transcode when it can't, with Dolby Vision, HDR10+ and Atmos ([codec support](docs/codec-support.md))
- **A player of its own** with Skip Intro, Skip Credits and Up Next, Night Mode and Dialogue Boost, playback speed and Picture in Picture
- **Subtitles** as text, styled ASS, images or closed captions, with a search that runs on your server
- **Search** across your library and Seerr
- **Seerr**, if you connect it, to browse and request what is not in your library yet
- **SyncPlay** to watch together with friends, family, enemies or loved ones
- **Downloads** for offline playback on iPhone and iPad
- **Themes**: Lagoon, Baby Pink, Spooky and Winter, with seasonal ones that arrive by themselves
- **iPhone Duo** layouts that keep clear of the fold
- **Top Shelf** with what you are watching, on the Apple TV Home Screen
- **Servers behind an access proxy**, such as Cloudflare Access, Authelia or Authentik
- **Liquid Glass** on tvOS 26, dark on both platforms

## More

- [FAQ](FAQ.md): why another client, AI use, formats, Jellyfin versions, telemetry
- [Contributing](CONTRIBUTING.md): building, tests and the public demo server
- [Documentation](docs/README.md): architecture, design, Jellyfin API, playback and release
- [Security](SECURITY.md) reports go privately by email, and taking part means keeping to the [Code of Conduct](CODE_OF_CONDUCT.md)

## Licence

Lagoon's code is [MPL-2.0](LICENSE). The name and brand artwork are not part
of that grant, see [TRADEMARKS.md](TRADEMARKS.md). The native libraries carry
their own licences, in [`Lagoon/Resources/Licenses`](Lagoon/Resources/Licenses)
and in the app under Settings → About → Acknowledgements.
