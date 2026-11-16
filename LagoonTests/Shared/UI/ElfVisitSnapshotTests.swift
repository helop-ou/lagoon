import SwiftUI
import Testing
@testable import Lagoon

/// The elf on its rope over a winter page's background: red cap, pointed
/// ears, green tunic, and one hand off the rope to wave.
@Suite("Elf visit snapshots", .serialized)
@MainActor
struct ElfVisitSnapshotTests {
    @Test func theElfWavesFromTheEndOfItsRope() async throws {
        let pose = try #require(ElfVisit.pose(at: ElfVisit.stillMoment))
        try await Snapshot.verify(
            ElfFrame(pose: pose, depth: 0.6).background(AppTheme.winter.palette.background),
            named: "elf-waving", size: ElfFrame.size, tolerance: Self.tolerance
        )
    }

    /// The cap's bobble is a sliver of the picture.
    private static let tolerance = 0.0005

    /// Both hands on the rope, and turned to face the other way.
    @Test func theElfClimbsBackFacingTheOtherSide() async throws {
        let pose = try #require(ElfVisit.pose(at: ElfVisit.descent + ElfVisit.stay + 1.5))
        try await Snapshot.verify(
            ElfFrame(pose: pose, depth: 0.6, isMirrored: true).background(AppTheme.winter.palette.background),
            named: "elf-climbing", size: ElfFrame.size, tolerance: Self.tolerance
        )
    }
}
