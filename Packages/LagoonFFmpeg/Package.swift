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
            targets: ["_LagoonFFmpeg"]
        ),
    ],
    targets: [
        .target(
            name: "_LagoonFFmpeg",
            dependencies: [
                "Libavcodec", "Libavformat", "Libavutil", "Libswresample",
                "gmp", "nettle", "hogweed", "gnutls",
                "Libdav1d", "Libuavs3d", "lcms2",
            ],
            path: "Sources/_LagoonFFmpeg",
            linkerSettings: [
                .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("CoreFoundation"),
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
        .binaryTarget(
            name: "Libavcodec",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.0.0/Libavcodec.xcframework.zip",
            checksum: "136e432919a8a7b5b80155c68e9dc91b0ef3ae6623970b87bb8bd96a452543cf"
        ),
        .binaryTarget(
            name: "Libavformat",
            url: "https://github.com/mpvkit/MPVKit/releases/download/1.0.0/Libavformat.xcframework.zip",
            checksum: "2afb601375929640e743e7bdaa6c4a88e2b582a07e1c5f2dc95cc7f5b26a0810"
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
        .binaryTarget(
            name: "Libdav1d",
            url: "https://github.com/mpvkit/libdav1d-build/releases/download/1.5.3/Libdav1d.xcframework.zip",
            checksum: "d1a32ae6a1f0193e9f05c44c9176844af7f6d2a58cb33843f6f1b8dfd9224083"
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
