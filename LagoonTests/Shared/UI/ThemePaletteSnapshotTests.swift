import SwiftUI
import Testing
import UIKit
@testable import Lagoon

/// Every theme's picker entry and the colours behind it, so a palette change
/// shows up as a picture in review. Built from the palettes directly: the
/// shared theme store is global and other suites render in parallel.
@Suite("Theme palette snapshots", .serialized)
@MainActor
struct ThemePaletteSnapshotTests {
    @Test func everyThemeShowsItsPalette() async throws {
        let board = VStack(alignment: .leading, spacing: Metrics.Space.xl) {
            ForEach(AppTheme.allCases) { theme in
                VStack(alignment: .leading, spacing: Metrics.Space.s) {
                    HStack(spacing: Metrics.Space.m) {
                        ThemeSwatch(palette: theme.palette)
                        VStack(alignment: .leading, spacing: Metrics.Space.hair) {
                            Text(theme.title)
                            Text(theme.settingsDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    roles(theme.palette)
                }
            }
        }
        .padding(Metrics.Space.l)

        try await Snapshot.verify(board, named: "theme-palettes", size: Self.size)
    }

    private static var size: CGSize {
        #if os(tvOS)
        CGSize(width: 1400, height: 400)
        #else
        CGSize(width: 402, height: 420)
        #endif
    }

    /// Background, rows, ground, glow, controls and accent, left to right.
    private func roles(_ palette: ThemePalette) -> some View {
        let colors: [Color] = [
            palette.background,
            palette.surface ?? Color(white: 0.11),
            palette.ground,
            palette.glowDepth,
            palette.controlTint ?? .white,
            palette.accent,
        ]
        return HStack(spacing: 0) {
            ForEach(colors.indices, id: \.self) { colors[$0] }
        }
        .frame(height: Metrics.Space.xl)
        .clipShape(.rect(cornerRadius: Metrics.Space.s))
        .overlay(RoundedRectangle(cornerRadius: Metrics.Space.s).strokeBorder(.white.opacity(0.15)))
    }
}
