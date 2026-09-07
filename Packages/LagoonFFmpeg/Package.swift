// swift-tools-version:5.9

// HEL-48 M6 dependency slimming: Lagoon's sample-buffer engine needs only
// FFmpeg's demux/decode libraries, not the mpv stack MPVKit exists for.
// This package pins the exact binary artifacts from MPVKit's 1.0.0
// release (FFmpeg 8.1.2) plus the static libraries FFmpeg's build was
// configured against — the linker pulls only referenced objects, but the
// archives must be present to resolve them. libmpv, MoltenVK-for-mpv,
// libplacebo, libass and friends stay out of the project entirely.

import PackageDescription

let package = Package(
    name: "LagoonFFmpeg",
    platforms: [.iOS(.v15), .tvOS(.v15)],
    products: [
        .library(
            name: "LagoonFFmpeg",
            targets: ["_LagoonFFmpeg", "LagoonPixelOps"]
        ),
    ],
    targets: [
        .target(
            name: "_LagoonFFmpeg",
            dependencies: [
                "LagoonPixelOps",
                "Libavcodec", "Libavformat", "Libavutil", "Libswresample",
                "gmp", "nettle", "hogweed", "gnutls",
                "Libdav1d", "Libuavs3d", "lcms2",
            ],
            path: "Sources/_LagoonFFmpeg",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
                .linkedFramework("Security"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("Metal"),
                .linkedFramework("VideoToolbox"),
                .linkedLibrary("bz2"),
                .linkedLibrary("iconv"),
                .linkedLibrary("expat"),
                .linkedLibrary("resolv"),
                .linkedLibrary("xml2"),
                .linkedLibrary("z"),
                .linkedLibrary("c++"),
            ]
        ),
        .target(
            name: "LagoonPixelOps",
            path: "Sources/LagoonPixelOps",
            publicHeadersPath: "include",
            cSettings: [
                // Xcode 26 enables coverage for Swift-package targets even
                // when the containing app's Release target disables it.
                // These are the per-pixel hot loops, so make the Release
                // override explicit at the package boundary (HEL-137).
                .unsafeFlags(
                    ["-fno-profile-instr-generate", "-fno-coverage-mapping"],
                    .when(configuration: .release)
                ),
            ]
        ),
        .binaryTarget(
            name: "Libavcodec",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.0.0/Libavcodec.xcframework.zip",
            checksum: "136e432919a8a7b5b80155c68e9dc91b0ef3ae6623970b87bb8bd96a452543cf"
        ),
        .binaryTarget(
            name: "Libavformat",
            // HEL-142: same FFmpeg release, verification enabled by default
            // with Apple system trust for GnuTLS's actual peer chain.
            // Rebuild/provenance: scripts/build-ffmpeg-format.py.
            path: "Artifacts/Libavformat.xcframework"
        ),
        .binaryTarget(
            name: "Libavutil",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.0.0/Libavutil.xcframework.zip",
            checksum: "5dc251c8807c501982edfb0bc9bddfee4148733142d6ebb947738c60fb3bf8d8"
        ),
        .binaryTarget(
            name: "Libswresample",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.0.0/Libswresample.xcframework.zip",
            checksum: "d5c36acf2ff944e15706f4b7bfbf18bb1993ffc5b446c9f67f1aa79de5441f15"
        ),
        .binaryTarget(
            name: "gmp",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gmp.xcframework.zip",
            checksum: "ad33c7a08f4cdcb9924c8f0e6d9a054dad33d7794b97667bf8b6fb2b236ae585"
        ),
        .binaryTarget(
            name: "nettle",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/nettle.xcframework.zip",
            checksum: "0fdf3ebf8bd7b8bc8eee837cf27261cb4c52ae520b6576a2f468656aa1691e02"
        ),
        .binaryTarget(
            name: "hogweed",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/hogweed.xcframework.zip",
            checksum: "25727c9fa67287fa0a4f4722f88bb8be669b23cd7e837e2d00870eb8a25d3f27"
        ),
        .binaryTarget(
            name: "gnutls",
            url: "https://github.com/mpvkit/gnutls-build/releases/download/3.8.11/gnutls.xcframework.zip",
            checksum: "3dbec5809339189bf9679e218c6cff387ebf8fb72745927835afc2678f5c9f4d"
        ),
        // Lagoon also builds dav1d itself (HEL-137). mpvkit's dav1d is
        // compiled with -Denable_asm=false, to silence an Xcode 15 linker
        // warning about assembled objects carrying no platform load command,
        // so every AV1 frame ran dav1d's portable C path: 11.4 fps against
        // the 23.976 a 4K HDR10+ episode needs, on an Apple TV. Same dav1d
        // 1.5.4, same headers, same public API, built by
        // scripts/build-dav1d.sh with the assembly kept and the warning
        // fixed properly by passing -target to the assembler.
        //
        // Vendored rather than fetched: there is nothing upstream to point
        // at, and a URL that has to outlive the app is a worse dependency
        // than five megabytes in the repository.
        .binaryTarget(
            name: "Libdav1d",
            path: "Artifacts/Libdav1d.xcframework"
        ),
        .binaryTarget(
            name: "lcms2",
            url: "https://github.com/mpvkit/lcms2-build/releases/download/2.17.0/lcms2.xcframework.zip",
            checksum: "dc0dce0606f6ab6841a8ec5a6bd4448e2f3ef00661a050460f806c9393dc6982"
        ),
        .binaryTarget(
            name: "Libuavs3d",
            url: "https://github.com/mpvkit/libuavs3d-build/releases/download/1.2.1-fix/Libuavs3d.xcframework.zip",
            checksum: "bd5256081486d16c51c868d755bf70266c424b54c895269580de44ec6707f789"
        ),
    ]
)
