import Foundation
import Observation

/// When repeated stalls earn the viewer an offer of a lower quality. Pure,
/// so a test can walk it through a session. The offer is the viewer's
/// choice, never a step down the ladder: stalls say nothing about the
/// samples (docs/playback.md).
nonisolated struct PlaybackQualityOfferPolicy: Equatable, Sendable {
    /// As the frequent-stall incident: three stalls inside a minute.
    static let window: TimeInterval = 60
    static let stallCount = 3

    private var stalls: [TimeInterval] = []
    /// Offered once per item, whatever the answer.
    private(set) var hasOffered = false

    /// A stall began. True when this one should bring up the offer.
    mutating func recordStall(at now: TimeInterval) -> Bool {
        guard !hasOffered else { return false }
        stalls.append(now)
        stalls.removeAll { $0 <= now - Self.window }
        guard stalls.count >= Self.stallCount else { return false }
        hasOffered = true
        return true
    }
}

/// The offer as the player draws it. The controller decides when it is up
/// and what accepting does.
@Observable
@MainActor
final class PlaybackQualityOffer {
    /// How long an unanswered offer stays up before it reads as "no".
    static let visibleSeconds: Double = 20

    private(set) var isVisible = false

    @ObservationIgnored var onAccept: (() -> Void)?
    @ObservationIgnored private var expiry: Task<Void, Never>?

    func present() {
        isVisible = true
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.visibleSeconds))
            guard !Task.isCancelled else { return }
            self?.withdraw()
        }
    }

    /// Select, or a tap on Lower Quality.
    func accept() {
        guard isVisible else { return }
        withdraw()
        onAccept?()
    }

    /// Back, or Keep Quality. False when there was nothing to dismiss, so
    /// Back can go on to its next meaning.
    @discardableResult
    func dismiss() -> Bool {
        guard isVisible else { return false }
        withdraw()
        return true
    }

    func withdraw() {
        expiry?.cancel()
        expiry = nil
        isVisible = false
    }
}
