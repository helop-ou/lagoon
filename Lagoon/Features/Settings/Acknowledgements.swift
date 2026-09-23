import Foundation
import LagoonEngine

/// One third-party component Lagoon ships, curated by hand. A new native
/// dependency needs an entry here and its licence under `Resources/Licenses`;
/// `AcknowledgementsTests` checks every engine binary target is covered.
nonisolated struct ThirdPartyComponent: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let version: String
    /// One sentence on what the component does inside Lagoon.
    let summary: String
    /// The licence as a viewer would say it, e.g. "GNU LGPL 2.1 or later".
    let licenseName: String
    let copyright: String
    /// Where the shipped build's source can be had: the exact upstream tag or
    /// release, or for a patched build the engine release carrying it.
    let sourceURL: URL
    /// Built by this repository, or prebuilt by whom, from what.
    let notes: String?
    /// Resource name without extension under `Resources/Licenses`.
    let licenseFile: String
    /// The engine package's `Package.swift` binary targets this entry covers.
    let binaryTargets: [String]
}

nonisolated enum Acknowledgements {
    /// In display order.
    static let components: [ThirdPartyComponent] = [
        ThirdPartyComponent(
            id: "ffmpeg",
            name: "FFmpeg",
            version: "8.1.2",
            summary: "Reads the container and decodes audio and video the hardware cannot.",
            licenseName: "GNU LGPL 2.1 or later",
            copyright: "Copyright (c) 2000-2026 the FFmpeg developers",
            // Patched, so upstream's tag is not the corresponding source; the
            // engine release carries upstream's tarball, the patch and the
            // build script together.
            sourceURL: URL(string: "https://github.com/helop-ou/lagoon-engine/releases/tag/\(EngineVersion.current)")!,
            notes: "All four libraries are built by lagoon-engine \(EngineVersion.current) from FFmpeg 8.1.2 in one configuration, with the network stack compiled out and one patch so HLS works without it (scripts/build-ffmpeg.py). The build enables no GPL, nonfree or version 3 components. The engine release linked here carries the complete source. This software is based in part on the work of the Independent JPEG Group.",
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
            notes: "Built by lagoon-engine \(EngineVersion.current) from this release, with the arm64 assembly kept (scripts/build-dav1d.sh).",
            licenseFile: "dav1d",
            binaryTargets: ["Libdav1d"]
        ),
        ThirdPartyComponent(
            id: "lcms2",
            name: "Little-CMS",
            version: "2.17",
            summary: "Colour management FFmpeg uses for embedded ICC profiles.",
            licenseName: "MIT",
            copyright: "Copyright (c) 2023 Marti Maria Saguer",
            sourceURL: URL(string: "https://github.com/mm2/Little-CMS/tree/lcms2.17")!,
            notes: "Built by lagoon-engine \(EngineVersion.current) from this release, without the GPL-3.0 fast_float and threaded plugins (scripts/build-lcms2.sh).",
            licenseFile: "lcms2",
            binaryTargets: ["lcms2"]
        ),
        ThirdPartyComponent(
            id: "uavs3d",
            name: "uavs3d",
            version: "1.2 (0e20d2c)",
            summary: "Decodes AVS3 video.",
            licenseName: "BSD 3-Clause",
            copyright: "Copyright (c) 2018-2022 Peking University Shenzhen Graduate School, Peng Cheng Laboratory, and Guangdong Bohua UHD Innovation Corporation",
            sourceURL: URL(string: "https://github.com/uavs3/uavs3d/tree/0e20d2c291853f196c68922a264bcd8471d75b68")!,
            notes: "Built by lagoon-engine \(EngineVersion.current) from the upstream repository at this commit; uavs3d has not tagged a release since 1.2 (scripts/build-uavs3d.sh).",
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
            notes: "Vendored prebuilt in lagoon-engine \(EngineVersion.current) from superuser404notfound/LibDovi at tag 2.1.0 (details and per-slice hashes in its Artifacts/Libdovi.README.md). The dolby_vision crate is MIT-licensed; the Rust crates and standard library linked with it are listed in its notice. LibDovi's own packaging carries a separate MIT notice that does not replace the one bundled here.",
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

    /// nil only if the resource is missing, which the unit tests fail on.
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
