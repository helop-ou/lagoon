# Documentation

Start with [Coding standards](standards.md), then read the guide for the area
you are changing. The guides describe the code as it is today.

| Guide | Use it for |
| --- | --- |
| [Architecture](architecture.md) | Ownership, project layout, navigation, and refactoring priorities |
| [Design system](design-system.md) | Shared components, tokens, focus, accessibility, and artwork |
| [Jellyfin API](jellyfin-api.md) | Authentication, endpoints, wire formats, and server compatibility |
| [Playback](playback.md) | Negotiation, the delivery ladder, lifecycle ownership, controls, and regression checks |
| [Release](release.md) | Build numbers, changelog, licence, TestFlight, website, and release gates |

## Supporting material

- **The engine** is a separate package with its own docs: [the engine
  guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md)
  and its [engineering
  notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/README.md).
  This repository documents what Lagoon negotiates, presents and reports.
- **`reference/`** holds the reasoning and measurements behind the guides:
  [playback](reference/playback/README.md),
  [architecture](reference/architecture.md), [design](reference/design-system.md)
  and the [regression lane](reference/regression-lane.md). Some describe
  experiments on a specific build, and the code may have moved on.

Generated files. A test that finds one out of date fails and rewrites it,
ready to commit:

| File | Generated from | By |
| --- | --- | --- |
| [Codec support](codec-support.md) | `DeviceProfile.everything`, the envelope the app sends Jellyfin, so it cannot overstate direct play | `CodecSupportDocTests` |
| The website's `app-facts.json` | The declared version and `DeviceProfile`. The site's prose, Jellyfin floor and availability stay hand-written there | `SiteFactsDocTests`, with `lagoon-website` beside this checkout |
| [Native dependency inventory](reference/native-dependency-inventory.json) | The resolved engine checkout. Regenerate whenever the engine pin moves (no `--check`) | [`inventory-native-dependencies.py`](../scripts/inventory-native-dependencies.py) |

## Keeping this clean

- Update the guide that owns a contract when you change it. Give each rule one
  home and link to it from elsewhere.
- Long technical investigations go in `reference/`.
- Validation evidence (revision, environment, result, what is owed) belongs
  where the work is tracked, not in a guide. Unresolved release gates go in
  [Release](release.md#public-release).
- [CHANGELOG.md](../CHANGELOG.md) owns release history, and website copy
  lives in the `lagoon-website` repository. Neither needs a copy here.
