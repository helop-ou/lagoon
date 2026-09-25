import Foundation
import LagoonEngine
import Observation

/// The player's two timed decisions, skipping an intro or recap and rolling
/// into the next episode, driven by the engine's clock rather than a view
/// body so they keep working with the phone locked or in Picture in Picture.
///
/// The overlays only draw this, so the pill and Select cannot disagree.
/// `SkipSegmentPolicy` and `NextUpPolicy` decide where; this decides when,
/// and remembers what the viewer already answered.
@Observable
@MainActor
final class PlaybackAutomation {
    /// The segment the playhead is inside. Nil when none, already handled, or
    /// suppressed.
    private(set) var activeSegment: MediaSegment?
    /// Timing shared by the pending skip and the pill's visible progress.
    private(set) var skipTiming: PlaybackCountdown?
    private(set) var showsNextUp = false
    private(set) var isCountingDown = false
    /// Timing shared by the pending handoff and the card's visible progress.
    private(set) var nextUpTiming: PlaybackCountdown?
    private(set) var nextUpCardStart: Double?
    /// The panel and an open scrub own the remote; a prompt must not change
    /// what Select does underneath them. Set by the player view.
    var isSuppressed = false {
        didSet { if oldValue != isSuppressed { evaluate() } }
    }
    /// The countdown runs on wall time, so it can come due mid-stall. A skip due
    /// now waits: seeking would throw away the buffer the stall is waiting on.
    var isBuffering = false {
        didSet {
            if oldValue != isBuffering, !isBuffering { commitDeferredSkip() }
        }
    }
    /// A skip that came due while buffering, owed once the picture moves.
    private var deferredSkip: MediaSegment?

    /// What Back on the Up Next card said. Outlives the card, so the end of
    /// the file keeps the answer.
    enum NextUpAnswer: Equatable {
        case none
        /// In Automatic mode, before the file's last seconds: the viewer is
        /// watching the credits and still expects the next episode. The card
        /// returns for the final countdown.
        case notYet
        /// Back during the final countdown, or in card mode: this episode is
        /// the last one.
        case stay
    }
    private(set) var nextUpAnswer: NextUpAnswer = .none

    @ObservationIgnored var onSkip: ((MediaSegment) -> Void)?
    @ObservationIgnored var onPlayNext: (() -> Void)?

    private var segments: [MediaSegment] = []
    private var hasNextUp = false
    private var duration: Double = 0
    private var position: Double = 0
    /// Nothing is decided before the engine reports a position. A new item
    /// starts at a phantom zero, and a recap covering zero would otherwise arm,
    /// and on a slow open fire, before the clock ticks.
    private var hasPosition = false
    /// Segments already acted on or waved away, so a committed skip does not
    /// re-arm when the playhead lands.
    private var handledSegmentIDs: Set<String> = []
    private var skipCountdown: Task<Void, Never>?
    private var nextUpCountdown: Task<Void, Never>?
    private let defaults: UserDefaults
    private let countdown: Duration

    /// `countdown` is how long both fills run; tests shorten it.
    init(
        defaults: UserDefaults = .standard,
        countdown: Duration = .seconds(SkipMode.autoDelaySeconds)
    ) {
        self.defaults = defaults
        self.countdown = countdown
    }

    var skipMode: SkipMode {
        defaults.string(forKey: SkipMode.defaultsKey).flatMap(SkipMode.init) ?? .autoDelay
    }

    var autoplayMode: AutoplayMode {
        defaults.string(forKey: AutoplayMode.defaultsKey).flatMap(AutoplayMode.init) ?? .autoDelay
    }

    var autoplaysOnFinish: Bool {
        autoplayMode == .autoDelay && nextUpAnswer != .stay && hasNextUp
    }

    /// Closing or handing off: no countdown may act on a gone engine.
    func invalidate() {
        cancelSkipCountdown()
        cancelNextUpCountdown()
        onSkip = nil
        onPlayNext = nil
    }

    // MARK: - Inputs

    /// A "no" belongs to the episode it was said during, not the rest of the
    /// binge.
    func beginItem(segments: [MediaSegment]) {
        self.segments = segments
        handledSegmentIDs.removeAll()
        nextUpAnswer = .none
        position = 0
        duration = 0
        hasPosition = false
        cancelSkipCountdown()
        cancelNextUpCountdown()
        activeSegment = nil
        showsNextUp = false
        nextUpCardStart = nil
        evaluate()
    }

    func setNextUpAvailable(_ available: Bool) {
        guard hasNextUp != available else { return }
        hasNextUp = available
        evaluate()
    }

    /// The engine's clock. Duration arrives only once the streams are known.
    func tick(position: Double, duration: Double) {
        self.position = position
        self.duration = duration
        hasPosition = true
        evaluate()
    }

    // MARK: - Answers

    /// A skip the clock asked for. Held while the engine refills. Select and a
    /// tap go straight through `skip`.
    private func commitTimedSkip(_ segment: MediaSegment) {
        guard !isBuffering else {
            deferredSkip = segment
            return
        }
        skip(segment)
    }

    /// The picture is moving again. Skip only while the playhead is still inside
    /// the segment: past its end, seeking would drag the viewer back through
    /// what they have watched.
    private func commitDeferredSkip() {
        guard let segment = deferredSkip else { return }
        deferredSkip = nil
        guard !isSuppressed, activeSegment?.id == segment.id, position < segment.end else {
            evaluate()
            return
        }
        skip(segment)
    }

    func skip(_ segment: MediaSegment) {
        // Mark before seeking, or landing near the end re-arms the segment.
        handledSegmentIDs.insert(segment.id)
        cancelSkipCountdown()
        onSkip?(segment)
        evaluate()
    }

    /// Back on the pill means "no", with or without a countdown. Returns
    /// whether a pill was up.
    @discardableResult
    func dismissSkip() -> Bool {
        guard let segment = activeSegment, skipMode != .instant else { return false }
        handledSegmentIDs.insert(segment.id)
        cancelSkipCountdown()
        evaluate()
        return true
    }

    func playNext() {
        // Cancel the task but keep the timing: the card stays up while the
        // successor is prepared, and an emptied bar would read as the offer being
        // withdrawn.
        nextUpCountdown?.cancel()
        nextUpCountdown = nil
        onPlayNext?()
    }

    /// Back on the card. In Automatic mode the first one means "not yet",
    /// unless the final countdown is already running; after that, and in card
    /// mode, it means "stay". Returns whether the card was up.
    @discardableResult
    func dismissNextUp() -> Bool {
        guard showsNextUp else { return false }
        let finalStart = NextUpPolicy.finalCountdownStart(duration: duration)
        let isBeforeFinalCountdown = finalStart.map { position < $0 } ?? false
        nextUpAnswer = autoplayMode == .autoDelay && nextUpAnswer == .none && isBeforeFinalCountdown
            ? .notYet
            : .stay
        cancelNextUpCountdown()
        evaluate()
        return true
    }

    // MARK: - Evaluation

    private var outroStart: Double? {
        segments.first { $0.kind == .outro }?.start
    }

    private func evaluate() {
        evaluateSkip()
        evaluateNextUp()
    }

    private func evaluateSkip() {
        let segment: MediaSegment? = isSuppressed || !hasPosition
            ? nil
            : SkipSegmentPolicy.activeSegment(in: segments, at: position, handled: handledSegmentIDs)
        guard segment?.id != activeSegment?.id else { return }
        activeSegment = segment
        cancelSkipCountdown()
        guard let segment else { return }
        // Arms once per segment, as the playhead crosses into it.
        switch skipMode {
        case .instant:
            commitTimedSkip(segment)
        case .autoDelay:
            let timing = PlaybackCountdown(duration: countdown)
            skipTiming = timing
            skipCountdown = Task { [weak self] in
                try? await Task.sleep(until: timing.deadline, clock: .continuous)
                guard let self, !Task.isCancelled, self.activeSegment?.id == segment.id else { return }
                self.commitTimedSkip(segment)
            }
        case .button:
            break
        }
    }

    private func evaluateNextUp() {
        let offeredStart = NextUpPolicy.cardStart(
            hasEpisode: hasNextUp,
            autoplayMode: autoplayMode,
            duration: duration,
            outroStart: outroStart
        )
        // "Not yet" moves the card, countdown and all, to the file's last
        // seconds.
        let cardStart: Double?
        let countdownStart: Double?
        if nextUpAnswer == .notYet, let offeredStart,
           let finalStart = NextUpPolicy.finalCountdownStart(duration: duration) {
            cardStart = max(offeredStart, finalStart)
            countdownStart = cardStart
        } else {
            cardStart = offeredStart
            countdownStart = NextUpPolicy.countdownStart(
                cardStart: offeredStart,
                outroStart: outroStart,
                duration: duration
            )
        }
        nextUpCardStart = cardStart
        let shows: Bool
        if let cardStart, hasPosition, !isSuppressed, nextUpAnswer != .stay {
            shows = position >= cardStart
        } else {
            shows = false
        }
        showsNextUp = shows
        let counting = shows && autoplayMode == .autoDelay
            && countdownStart.map { position >= $0 } == true
        guard counting != isCountingDown else { return }
        isCountingDown = counting
        cancelNextUpCountdown()
        guard counting else { return }
        let timing = PlaybackCountdown(duration: countdown)
        nextUpTiming = timing
        nextUpCountdown = Task { [weak self] in
            try? await Task.sleep(until: timing.deadline, clock: .continuous)
            guard let self, !Task.isCancelled, self.isCountingDown else { return }
            self.playNext()
        }
    }

    private func cancelSkipCountdown() {
        skipCountdown?.cancel()
        skipCountdown = nil
        skipTiming = nil
        deferredSkip = nil
    }

    private func cancelNextUpCountdown() {
        nextUpCountdown?.cancel()
        nextUpCountdown = nil
        nextUpTiming = nil
    }
}
