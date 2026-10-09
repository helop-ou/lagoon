import Foundation
import Libass
import Libavutil
import Libdav1d
import lcms2
import Testing
@testable import Lagoon

/// Every bundled licence resolves, every binary target the engine links has
/// an entry, and the trademark notice names the marks it disclaims.
@Suite("Acknowledgements", .serialized)
struct AcknowledgementsTests {
    @Test func everyComponentsLicenseTextResolvesAndNamesItsCopyrightHolder() throws {
        for component in Acknowledgements.components {
            let text = try #require(
                Acknowledgements.licenseText(for: component),
                "No bundled licence text for \(component.id); add Lagoon/Resources/Licenses/\(component.licenseFile).txt"
            )
            #expect(
                text.count > 500,
                "Licence text for \(component.id) is suspiciously short (\(text.count) characters)"
            )
            let distinctiveWord = component.copyright
                .split(whereSeparator: { !$0.isLetter })
                .first { $0.count > 3 && $0 != "Copyright" }
            let word = try #require(
                distinctiveWord,
                "Could not find a distinctive word in the copyright string for \(component.id): \(component.copyright)"
            )
            #expect(
                text.contains(word),
                "Licence text for \(component.id) does not mention '\(word)' from its copyright string"
            )
        }
    }

    @Test func componentIdsAreUniqueAndNonEmptyAndSourceURLsAreHTTPS() {
        var seen = Set<String>()
        for component in Acknowledgements.components {
            #expect(!component.id.isEmpty)
            #expect(!seen.contains(component.id), "Duplicate component id: \(component.id)")
            seen.insert(component.id)
            #expect(
                component.sourceURL.scheme == "https",
                "\(component.id) sourceURL is not https: \(component.sourceURL)"
            )
        }
    }

    /// Reads the native inventory, not a sibling engine checkout: the
    /// inventory is generated from the engine `Package.resolved` pins, so a
    /// newer engine on disk cannot pass or fail this build.
    @Test func binaryTargetsCoverExactlyWhatThePinnedEngineDeclares() throws {
        struct Resolved: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { let revision: String }
                let identity: String
                let state: State
            }
            let pins: [Pin]
        }
        struct Inventory: Decodable {
            struct Engine: Decodable { let revision: String }
            struct Dependency: Decodable { let name: String }
            let engine: Engine
            let dependencies: [Dependency]
        }
        // LagoonTests/Settings/AcknowledgementsTests.swift -> repo root
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let resolved = try JSONDecoder().decode(Resolved.self, from: Data(contentsOf: repoRoot.appending(
            path: "Lagoon.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )))
        let inventory = try JSONDecoder().decode(Inventory.self, from: Data(contentsOf: repoRoot.appending(
            path: "docs/reference/native-dependency-inventory.json"
        )))
        let pinned = try #require(resolved.pins.first { $0.identity == "lagoon-engine" })
        try #require(
            inventory.engine.revision == pinned.state.revision,
            "The native inventory records engine \(inventory.engine.revision), but the pin is \(pinned.state.revision). Regenerate it with scripts/inventory-native-dependencies.py."
        )

        let declaredTargets = Set(inventory.dependencies.map(\.name))
        #expect(!declaredTargets.isEmpty, "The native inventory lists no binary targets")

        let coveredTargets = Set(Acknowledgements.components.flatMap(\.binaryTargets))

        #expect(
            coveredTargets == declaredTargets,
            """
            Acknowledgements.components binaryTargets do not match the pinned engine's.
            Declared: \(declaredTargets.sorted())
            Covered: \(coveredTargets.sorted())
            Missing: \(declaredTargets.subtracting(coveredTargets).sorted())
            Extra: \(coveredTargets.subtracting(declaredTargets).sorted())
            """
        )
    }

    /// An engine bump can move a library under an entry naming the old release.
    @Test func versionsMatchTheLinkedLibraries() throws {
        func entry(_ id: String) throws -> ThirdPartyComponent {
            try #require(Acknowledgements.components.first { $0.id == id })
        }
        #expect(try entry("ffmpeg").version == String(cString: av_version_info()))
        // dav1d reports `git describe`, e.g. "1.5.4-0-g54706fc": zero commits
        // past the tag. The release is the part before the first hyphen.
        let dav1d = String(cString: dav1d_version()).split(separator: "-").first.map(String.init)
        #expect(try entry("dav1d").version == dav1d)
        let lcms = Int(cmsGetEncodedCMMversion())
        #expect(try entry("lcms2").version == "\(lcms / 1000).\(lcms % 1000 / 10)")
        // libass packs its version as hex digits, 0.17.5 as 0x01705000.
        let ass = String(format: "%08x", ass_library_version())
        let digits = Array(ass)
        let libass = "\(Int(String(digits[0]))!).\(Int(String(digits[1...2]))!).\(Int(String(digits[3...4]))!)"
        #expect(try entry("libass").version == libass, "linked libass reports \(ass)")
    }

    @Test func trademarkNoticeNamesJellyfinAndApple() {
        #expect(Acknowledgements.trademarkNotice.contains("Jellyfin"))
        #expect(Acknowledgements.trademarkNotice.contains("Apple"))
    }

    @Test func displayAddressStripsSchemeAndTrailingSlash() {
        let url = URL(string: "https://lagoon.helop.dev/privacy/")!
        #expect(LegalDestinations.displayAddress(url) == "lagoon.helop.dev/privacy")
    }
}
