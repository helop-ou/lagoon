import SwiftUI
import Testing
@testable import Lagoon

/// The Legal rows shared by Settings, About and the sign-in About sheet. On
/// Apple TV a row opens a sheet with a code, since nothing there can open a
/// web page.
@Suite("Legal section snapshots", .serialized)
@MainActor
struct LegalSectionSnapshotTests {
    @Test func theSectionListsEveryPublishedDestination() async throws {
        #if os(tvOS)
        try await Snapshot.verify(
            LegalSettingsSection().padding(Metrics.Space.section),
            named: "legal-section",
            size: Metrics.modalPanelSize
        )
        #else
        try await Snapshot.verify(
            ThemedForm { LegalSettingsSection() },
            named: "legal-section",
            size: CGSize(width: 402, height: 420)
        )
        #endif
    }

    #if os(tvOS)
    @Test func theSourceCodeSheetShowsACodeAndTheAddress() async throws {
        let url = try #require(LegalDestinations.sourceCode)
        let address = LegalAddress(id: "settings.about.source", title: "Source Code", url: url)
        // The width the section presents it at, and a television's height.
        try await Snapshot.verify(
            LegalAddressSheet(address: address).frame(width: Metrics.modalPanelSize.width),
            named: "source-code-address",
            size: CGSize(width: Metrics.modalPanelSize.width, height: 1_080)
        )
    }
    #endif
}
