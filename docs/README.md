# Documentation

Read [Coding standards](standards.md) for Apple/Swift guidance and Lagoon's
conventions, then the guide for the area you are changing. These six area
guides describe the current code and workflow.

| Guide | Use it for |
| --- | --- |
| [Architecture](architecture.md) | Ownership, project layout, navigation, and refactoring priorities |
| [Design system](design-system.md) | Shared components, tokens, focus, accessibility, and artwork |
| [Jellyfin API](jellyfin-api.md) | Authentication, endpoints, wire formats, and server compatibility |
| [Playback](playback.md) | Engine boundaries, lifecycle, transport, controls, and regression checks |
| [Release](release.md) | Build numbers, changelog, TestFlight, website integration, and public release gates |
| [Roadmap](roadmap.md) | Remaining product work and device acceptance |

## Supporting material

- `reference/` holds detailed [playback](reference/playback/README.md),
  [architecture](reference/architecture.md), and
  [design](reference/design-system.md) engineering notes. Read these for the
  reasoning and measurements behind a particular implementation. Dated
  experiments can describe code that was subsequently replaced.
- [The archive](archive/README.md) indexes ticket audits, validation records,
  the transport spike, and superseded website drafts. An archived check proves
  only what its recorded revision, device, and fixture exercised.
- [Native dependency inventory](reference/native-dependency-inventory.json)
  is generated evidence. Regenerate it when the linked artifacts change using
  [the inventory script](../scripts/inventory-native-dependencies.py).

## Keeping this clean

Update the relevant guide when behavior or ownership changes. Keep one home
for each instruction and link to it from the other guides. Put long technical
investigations in `reference/` and dated validation evidence in `archive/`,
including the revision, environment, result, and remaining acceptance work.
Add the record to the archive index instead of appending a session transcript
to a guide. Keep unresolved release gates in [Release](release.md#public-release).

Jira owns live ticket status. [Changelog.swift](../Lagoon/Models/Changelog.swift)
owns release history. Published website copy belongs to the separate
`lagoon-website` repository. None of those needs a second running history here.
