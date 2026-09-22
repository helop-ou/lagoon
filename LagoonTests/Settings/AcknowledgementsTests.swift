import Foundation
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

    @Test func binaryTargetsCoverExactlyWhatPackageSwiftDeclares() throws {
        let thisFile = URL(fileURLWithPath: #filePath)
        // LagoonTests/Settings/AcknowledgementsTests.swift -> repo root
        let repoRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // The engine package's manifest declares the native libraries.
        let packageSwiftURL = repoRoot
            .deletingLastPathComponent()
            .appendingPathComponent("lagoon-engine/Package.swift")

        guard let contents = try? String(contentsOf: packageSwiftURL, encoding: .utf8) else {
            Issue.record("Could not read \(packageSwiftURL.path); skipping binary target coverage check")
            return
        }

        let pattern = #"\.binaryTarget\(\s*name:\s*"([^"]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(contents.startIndex..., in: contents)
        let declaredTargets = Set(
            regex.matches(in: contents, range: range).compactMap { match -> String? in
                guard let r = Range(match.range(at: 1), in: contents) else { return nil }
                return String(contents[r])
            }
        )

        #expect(!declaredTargets.isEmpty, "Regex found no .binaryTarget declarations in Package.swift")

        let coveredTargets = Set(Acknowledgements.components.flatMap(\.binaryTargets))

        #expect(
            coveredTargets == declaredTargets,
            """
            Acknowledgements.components binaryTargets do not match Package.swift.
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
