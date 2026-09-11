import Foundation

/// One third-party component Lagoon ships, as shown under Settings → About →
/// Acknowledgements and from the sign-in screen (HEL-143, audit A06).
///
/// Curated by hand, like the changelog: each entry names the exact version
/// and source the shipped binaries were built from, the licence that governs
/// them, and where the licence text lives in the bundle. Adding a native
/// dependency means adding an entry here and its licence text under
/// `Resources/Licenses`; `AcknowledgementsTests` checks that every binary
/// target in `Packages/LagoonFFmpeg/Package.swift` is covered.
nonisolated struct ThirdPartyComponent: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    /// One sentence on what the component does inside Lagoon.
    let summary: String
    /// The licence as a viewer would say it, e.g. "GNU LGPL 2.1 or later".
    let licenseName: String
    let copyright: String
    /// The exact upstream tag or release the shipped build came from.
    let sourceURL: URL
    /// Provenance the viewer may care about: built by this repository, or
    /// prebuilt by whom, from what.
    let notes: String?
    /// Resource name without extension under `Resources/Licenses`.
    let licenseFile: String
    /// The `Packages/LagoonFFmpeg/Package.swift` binary targets this entry covers.
    let binaryTargets: [String]
}

nonisolated enum Acknowledgements {
    /// In display order: the media engine's libraries first, then the
    /// smaller pieces they pull in.
    static let components: [ThirdPartyComponent] = [
        ThirdPartyComponent(
            id: "ffmpeg",
            name: "FFmpeg",
            version: "8.1.2",
            summary: "Reads the container and decodes audio and video the hardware cannot.",
            licenseName: "GNU LGPL 2.1 or later and 3.0 or later",
            copyright: "Copyright (c) 2000-2026 the FFmpeg developers",
            sourceURL: URL(string: "https://github.com/FFmpeg/FFmpeg/tree/n8.1.2")!,
            notes: "libavformat is built by this repository from the same release with its network stack compiled out (scripts/build-ffmpeg-format.py, HEL-142); libavcodec, libavutil and libswresample are MPVKit's 1.0.0 prebuilt slices of the same FFmpeg release. The build enables no GPL or nonfree components. Two licence versions apply: the repository-built libavformat is configured without --enable-version3 and is LGPL 2.1 or later, while the three MPVKit slices keep upstream's version3 election and are LGPL 3.0 or later, so the bundled notice prints both texts.",
            licenseFile: "ffmpeg",
            binaryTargets: ["Libavcodec", "Libavformat", "Libavutil", "Libswresample"]
        ),
        ThirdPartyComponent(
            id: "dav1d",
            name: "dav1d",
            version: "1.5.4",
            summary: "Decodes AV1 video in software, built with its arm64 assembly.",
            licenseName: "BSD 2-Clause",
            copyright: "Copyright © 2018-2025, VideoLAN and dav1d authors",
            sourceURL: URL(string: "https://code.videolan.org/videolan/dav1d/-/tags/1.5.4")!,
            notes: "Built by this repository (scripts/build-dav1d.sh, HEL-137) from the same dav1d release MPVKit uses, with the arm64 assembly kept.",
            licenseFile: "dav1d",
            binaryTargets: ["Libdav1d"]
        ),
        ThirdPartyComponent(
            id: "lcms2",
            name: "Little-CMS",
            version: "2.17",
            summary: "Colour management used by FFmpeg's filters.",
            licenseName: "MIT",
            copyright: "Copyright (c) 2023 Marti Maria Saguer",
            sourceURL: URL(string: "https://github.com/mm2/Little-CMS/tree/lcms2.17")!,
            notes: "Prebuilt by MPVKit's lcms2-build release 2.17.0.",
            licenseFile: "lcms2",
            binaryTargets: ["lcms2"]
        ),
        ThirdPartyComponent(
            id: "uavs3d",
            name: "uavs3d",
            version: "1.2.1-fix",
            summary: "Decodes AVS3 video.",
            licenseName: "BSD 3-Clause",
            copyright: "Copyright (c) 2018-2022 Peking University Shenzhen Graduate School, Peng Cheng Laboratory, and Guangdong Bohua UHD Innovation Corporation",
            sourceURL: URL(string: "https://github.com/mpvkit/libuavs3d-build/releases/tag/1.2.1-fix")!,
            notes: "Prebuilt by MPVKit's libuavs3d-build release \"1.2.1-fix\", which points at the upstream uavs3d repository (https://github.com/uavs3/uavs3d) rather than a signed upstream tag.",
            licenseFile: "uavs3d",
            binaryTargets: ["Libuavs3d"]
        ),
        ThirdPartyComponent(
            id: "libdovi",
            name: "libdovi",
            version: "3.4.0",
            summary: "Rewrites Dolby Vision profile 7 metadata to profile 8.1 so Apple TV can display it.",
            licenseName: "MIT",
            copyright: "Copyright (c) 2026 quietvoid",
            sourceURL: URL(string: "https://github.com/quietvoid/dovi_tool/tree/libdovi-3.4.0")!,
            notes: "Vendored prebuilt from superuser404notfound/LibDovi at tag 2.1.0 (HEL-145; details and per-slice hashes in Packages/LagoonFFmpeg/Artifacts/Libdovi.README.md). dovi_tool is dual-licensed MIT OR Apache-2.0 upstream; Lagoon uses it under the MIT option. LibDovi's own packaging carries a separate MIT notice that does not replace the one bundled here.",
            licenseFile: "libdovi",
            binaryTargets: ["Libdovi"]
        ),
    ]

    /// Names used in the app that belong to other projects.
    static let trademarkNotice: String = """
    Jellyfin is a trademark of the Jellyfin project. Seerr, Jellyseerr and \
    Overseerr are trademarks of their respective projects. Apple, Apple TV, \
    iPhone and iPad are trademarks of Apple Inc. Lagoon is an independent \
    client and is not affiliated with, endorsed by, or sponsored by any of \
    these projects or companies.
    """

    /// The full licence text for a component, from the bundle; nil only if
    /// the resource is missing, which the unit tests treat as a failure.
    static func licenseText(for component: ThirdPartyComponent) -> String? {
        guard let url = Bundle.main.url(
            forResource: component.licenseFile,
            withExtension: "txt",
            subdirectory: "Licenses"
        ) ?? Bundle.main.url(forResource: component.licenseFile, withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
