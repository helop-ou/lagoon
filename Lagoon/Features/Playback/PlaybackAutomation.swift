import Foundation
import Observation

/// The player's two timed decisions — skipping an intro or recap (HEL-63)
/// and rolling into the next episode (HEL-66) — driven by the engine's
/// clock instead of a view body, so they keep working with the phone
/// locked or the player minimised into Picture in Picture (HEL-176).
///
/// The overlays draw from this and nothing else: the pill and Select
/// cannot disagree because there is one answer. `SkipSegmentPolicy` and
/// `NextUpPolicy` decide *where*; this decides *when*, and remembers what
/// the viewer already answered.
@Observable
@MainActor
final class PlaybackAutomation {
    /// The skippable segment the playhead is inside. Nil when there is
    /// none, when it was already handled, and while suppressed.
    private(set) var activeSegment: MediaSegment?
    /// 0…1, drives the pill's fill; 1 while the countdown runs.
    private(set) var skipFill: Double = 0
    /// The Up Next card is due and not waved away.
    private(set) var showsNextUp = false
    /// The card's countdown is running.
    private(set) var isCountingDown = false
    /// 0…1, drives the card's fill; 1 while the countdown runs.
    private(set) var nextUpFill: Double = 0
    /// Where the card is due, for the regression probe.
    private(set) var nextUpCardStart: Double?
    /// The panel and an open scrub own the screen and the remote, and a
    /// prompt that quietly rewrites what Select does underneath them would
    /// be a trap. Set by the player view.
    var isSuppressed = false {
        didSet { if oldValue != isSuppressed { evaluate() } }
    }
    /// Back was pressed on the Up Next card. Outlives the card itself: the
    /// episode still has its credits to run, and the end of the file must
    /// not undo the answer that was already given.
    private(set) var nextUpDismissed = false

    /// Where a committed skip lands the playhead.
    @ObservationIgnored var onSkip: ((MediaSegment) -> Void)?
    /// The next episode was asked for, by the countdown or the viewer.
    @ObservationIgnored var onPlayNext: (() -> Void)?

    private(set) var identity = ""
    private var segments: [MediaSegment] = []
    private var hasNextUp = false
    private var duration: Double = 0
    private var position: Double = 0
    /// Segments already acted on or waved away, so a committed skip (or a
    /// "no thanks") does not re-arm the moment the playhead lands.
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

    /// Whether the end of the file should roll into the next episode on
    /// its own: only when the countdown mode is on and nobody said no.
    var autoplaysOnFinish: Bool {
        autoplayMode == .autoDelay && !nextUpDismissed && hasNextUp
    }

    /// The player is closing or handing off: a countdown must not wake
    /// up and act on an engine that is gone.
    func invalidate() {
        cancelSkipCountdown()
        cancelNextUpCountdown()
        onSkip = nil
        onPlayNext = nil
    }

    // MARK: - Inputs

    /// A new item starts with a clean slate: a "no" belongs to the episode
    /// it was said during, not to the rest of the binge.
    func beginItem(identity: String, segments: [MediaSegment]) {
        self.identity = identity
        self.segments = segments
        handledSegmentIDs.removeAll()
        nextUpDismissed = false
        position = 0
        duration = 0
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

    /// The engine's clock. Duration rides along because it is known only
    /// once the streams are, and the card is placed against it.
    func tick(position: Double, duration: Double) {
        self.position = position
        self.duration = duration
        evaluate()
    }

    // MARK: - Answers

    /// Commits the skip, by the countdown, a tap, or Select.
    func skip(_ segment: MediaSegment) {
        // Marked before seeking: landing near the end would otherwise put
        // the playhead back inside the segment and re-arm the whole thing.
        handledSegmentIDs.insert(segment.id)
        cancelSkipCountdown()
        onSkip?(segment)
        evaluate()
    }

    /// Back during the skip countdown means "no" — the one mode with a
    /// pending action to call off. Returns whether there was one.
    @discardableResult
    func dismissSkip() -> Bool {
        guard let segment = activeSegment, skipMode == .autoDelay else { return false }
        handledSegmentIDs.insert(segment.id)
        cancelSkipCountdown()
        evaluate()
        return true
    }

    /// Starts the next episode now, by the countdown, a tap, or Select.
    func playNext() {
        cancelNextUpCountdown()
        onPlayNext?()
    }

    /// Back on the card during its countdown. Same rule as the skip pill:
    /// only where something is pending. Returns whether there was.
    @discardableResult
    func dismissNextUp() -> Bool {
        guard showsNextUp, autoplayMode == .autoDelay else { return false }
        nextUpDismissed = true
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
        let segment: MediaSegment? = isSuppressed
            ? nil
            : SkipSegmentPolicy.activeSegment(in: segments, at: position, handled: handledSegmentIDs)
        guard segment?.id != activeSegment?.id else { return }
        activeSegment = segment
        cancelSkipCountdown()
        guard let segment else { return }
        // Arms as the playhead crosses into a segment, once per segment.
        switch skipMode {
        case .instant:
            skip(segment)
        case .autoDelay:
            skipFill = 1
            skipCountdown = Task { [weak self, countdown] in
                try? await Task.sleep(for: countdown)
                guard let self, !Task.isCancelled, self.activeSegment?.id == segment.id else { return }
                self.skip(segment)
            }
        case .button:
            break
        }
    }

    private func evaluateNextUp() {
        let cardStart = NextUpPolicy.cardStart(
            hasEpisode: hasNextUp,
            autoplayMode: autoplayMode,
            duration: duration,
            outroStart: outroStart
        )
        let countdownStart = NextUpPolicy.countdownStart(
            cardStart: cardStart,
            outroStart: outroStart,
            duration: duration
        )
        nextUpCardStart = cardStart
        let shows: Bool
        if let cardStart, !isSuppressed, !nextUpDismissed {
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
        // Arms as the playhead crosses into the countdown window, once.
        nextUpFill = 1
        nextUpCountdown = Task { [weak self, countdown] in
            try? await Task.sleep(for: countdown)
            guard let self, !Task.isCancelled, self.isCountingDown else { return }
            self.playNext()
        }
    }

    private func cancelSkipCountdown() {
        skipCountdown?.cancel()
        skipCountdown = nil
        skipFill = 0
    }

    private func cancelNextUpCountdown() {
        nextUpCountdown?.cancel()
        nextUpCountdown = nil
        nextUpFill = 0
    }
}
