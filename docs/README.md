# Documentation

Start with [Coding standards](standards.md), then read the guide for the area
you are changing. The six guides below describe how the code works today.

| Guide | Use it for |
| --- | --- |
| [Architecture](architecture.md) | Ownership, project layout, navigation, and refactoring priorities |
| [Design system](design-system.md) | Shared components, tokens, focus, accessibility, and artwork |
| [Jellyfin API](jellyfin-api.md) | Authentication, endpoints, wire formats, and server compatibility |
| [Playback](playback.md) | Negotiation, the delivery ladder, lifecycle ownership, controls, and regression checks |
| [Release](release.md) | Build numbers, changelog, licence, TestFlight, website, and release gates |
| [Roadmap](roadmap.md) | Remaining product work and device acceptance |

## Supporting material

Playback's engine is a separate package in its own repository, and its
internals are documented there: [the engine
guide](https://github.com/helop-ou/lagoon-engine/blob/main/docs/engine.md) and
its [engineering
notes](https://github.com/helop-ou/lagoon-engine/blob/main/docs/reference/README.md).
What stays here is what Lagoon negotiates, presents and reports.

`reference/` holds the longer engineering notes behind the guides:
[playback](reference/playback/README.md),
[architecture](reference/architecture.md),
[design](reference/design-system.md) and [regression
lane](reference/regression-lane.md). Read them for the reasoning and the
measurements behind a particular implementation. Some describe experiments on
a specific build, and the code may have moved on since.

[Codec support](codec-support.md) is generated from `DeviceProfile.everything`
by [the codec script](../scripts/generate-codec-support.sh), so the published
table is the same envelope the app sends Jellyfin and cannot overstate what
direct plays. Run it with `--check` to fail on drift rather than ship it.

The [native dependency inventory](reference/native-dependency-inventory.json)
is generated. Regenerate it with [the inventory
script](../scripts/inventory-native-dependencies.py), pointed at the resolved
engine checkout, whenever the engine pin moves.

[CHANGELOG.md](../CHANGELOG.md) is generated from `Changelog.swift` by [the
changelog script](../scripts/generate-changelog.sh), which also prints one
build's notes for a release body. The in-app changelog stays the source of
truth, so what a release says and what About shows cannot diverge. Run it with
`--check` to fail on drift.

The website's `app-facts.json` is generated too, by [the site-facts
script](../scripts/generate-site-facts.sh), from the declared version and
`DeviceProfile`. The site lives in its own repository and used to restate what
Lagoon plays by hand, which is how it came to promise formats the app had
changed underneath it. Prose, the Jellyfin floor and availability stay written
there; the version, build and format rows come from here. `--check` fails on
drift.

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
