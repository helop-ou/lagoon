# Name and brand assets

Lagoon's source code is licensed under the Mozilla Public License 2.0, in
[LICENSE](LICENSE). This file describes the one thing that licence does not
give you.

**The Lagoon name, the wordmark, the jellyfish mark, the app icon and the
other brand artwork are not part of the grant.** MPL-2.0 covers every file in
a repository by default, so this is an explicit carve-out. It applies to the
PNG and PDF assets tracked here, to `Assets.xcassets` and to the brand asset
sources in `art/`, which are kept in a separate repository and are not
published.

## What you may do

Fork the code, build it, change it and ship it, under the terms in LICENSE.
Nothing here narrows those terms for the source.

## What to change first

Give your fork its own name and its own artwork before you distribute it. A
build that calls itself Lagoon and wears Lagoon's jellyfish is one that people
will report bugs about to this project, which is the practical reason for the
carve-out as much as the legal one.

Renaming means the display name, the icon and image assets, and the bundle
identifiers. [CONTRIBUTING.md](CONTRIBUTING.md) describes the identifiers you
need to change for a device build in any case.

## What stays true

Say where it came from. That is the whole ask: MPL-2.0 already requires the
licence notice to travel with the files it covers, and this project's interest
is attribution rather than getting changes back.

Referring to Lagoon by name to say what your fork is based on, or to discuss
or review the project, is normal nominative use and needs no permission.

## The native libraries are separate

The FFmpeg, dav1d, uavs3d, lcms2 and libdovi binaries Lagoon links carry their
own licences, which this file and LICENSE do not alter. Their texts are in
[`Lagoon/Resources/Licenses`](Lagoon/Resources/Licenses), and the app lists
them under Settings → About → Acknowledgements.

Copyright © Helop OÜ. Lagoon is a project of Helop OÜ.
