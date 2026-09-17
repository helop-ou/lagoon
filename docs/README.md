# Documentation

Start with [Coding standards](standards.md), then read the guide for the area
you are changing. The six guides below describe how the code works today.

| Guide | Use it for |
| --- | --- |
| [Architecture](architecture.md) | Ownership, project layout, navigation, and refactoring priorities |
| [Design system](design-system.md) | Shared components, tokens, focus, accessibility, and artwork |
| [Jellyfin API](jellyfin-api.md) | Authentication, endpoints, wire formats, and server compatibility |
| [Playback](playback.md) | Engine boundaries, lifecycle, transport, controls, and regression checks |
| [Release](release.md) | Build numbers, changelog, licence, TestFlight, website, and release gates |
| [Roadmap](roadmap.md) | Remaining product work and device acceptance |

## Supporting material

`reference/` holds the longer engineering notes behind the guides:
[playback](reference/playback/README.md),
[architecture](reference/architecture.md),
[design](reference/design-system.md) and
[regression lane](reference/regression-lane.md). Read them for the reasoning
and the measurements behind a particular implementation. Some describe
experiments on a specific build, and the code may have moved on since.

The [native dependency inventory](reference/native-dependency-inventory.json)
is generated. Regenerate it with
[the inventory script](../scripts/inventory-native-dependencies.py) whenever
the linked artifacts change.

## Keeping this clean

Update the guide that owns a contract when you change it. Give each rule one
home and link to it from anywhere else it matters. Long technical
investigations go in `reference/`.

Validation evidence — the revision, the environment, the result, and what is
still owed — belongs wherever the work is tracked, not appended to a guide as
a session transcript. Unresolved release gates go in
[Release](release.md#public-release).

[Changelog.swift](../Lagoon/Features/Settings/Changelog.swift) owns release
history, and published website copy lives in the separate `lagoon-website`
repository. Neither needs a second copy here.
