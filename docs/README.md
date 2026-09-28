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
  experiments on a specific build; the code may have moved on.

Generated files. Each script takes `--check` to fail on drift instead of
writing:

| File | Generated from | By |
| --- | --- | --- |
| [Codec support](codec-support.md) | `DeviceProfile.everything`, the envelope the app sends Jellyfin, so it cannot overstate direct play | [`generate-codec-support.sh`](../scripts/generate-codec-support.sh) |
| [CHANGELOG.md](../CHANGELOG.md) | `Changelog.swift`, the source of truth for About and release bodies (`--notes <build>` prints one build) | [`generate-changelog.sh`](../scripts/generate-changelog.sh) |
| The website's `app-facts.json` | The declared version and `DeviceProfile`. The site's prose, Jellyfin floor and availability stay hand-written there | [`generate-site-facts.sh`](../scripts/generate-site-facts.sh) |
| [Native dependency inventory](reference/native-dependency-inventory.json) | The resolved engine checkout; regenerate whenever the engine pin moves (no `--check`) | [`inventory-native-dependencies.py`](../scripts/inventory-native-dependencies.py) |

## Keeping this clean

- Update the guide that owns a contract when you change it. Give each rule one
  home and link to it from elsewhere.
- Long technical investigations go in `reference/`.
- Validation evidence (revision, environment, result, what is owed) belongs
  where the work is tracked, not in a guide. Unresolved release gates go in
  [Release](release.md#public-release).
- [Changelog.swift](../Lagoon/Features/Settings/Changelog.swift) owns release
  history, and website copy lives in the `lagoon-website` repository. Neither
  needs a copy here.
