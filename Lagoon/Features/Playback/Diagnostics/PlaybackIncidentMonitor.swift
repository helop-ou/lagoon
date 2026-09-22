import Foundation
import LagoonEngine
#if canImport(UIKit)
import UIKit
#endif

/// Detects playback that stopped without anyone saying so.
///
/// The engine handles a dry queue itself (`isBuffering`). This catches two
/// cases while the engine thinks it is playing: the playhead has not moved
/// for `threshold` seconds, or it moves but no frame has been presented,
/// which is a frozen picture over running audio. Pure so the thresholds can
/// be pinned.
nonisolated struct PlaybackFreezeDetector: Equatable, Sendable {
    struct Sample: Equatable, Sendable {
        var position: Double
        var isPaused: Bool
        var isBuffering: Bool
        var rate: Double
        var duration: Double
        var isFinished: Bool
        var isAppActive: Bool
        var secondsSinceSeek: Double?
        /// The renderer's frame count (displayed plus dropped), nil until read.
        var framesPresented: Int? = nil
    }

    enum Kind: String, Equatable, Sendable {
        case playhead
        case picture
    }

    enum Verdict: Equatable, Sendable {
        case idle
        case watching(seconds: Double)
        /// Reported once per freeze; progress resets it.
        case frozen(seconds: Double, kind: Kind)
    }

    static let threshold: Double = 8
    static let positionTolerance: Double = 0.05
    /// The last moments belong to the finish observer.
    static let endGuard: Double = 2
    /// A seek repositions optimistically and then refills; give it time.
    static let seekSettle: Double = 3

    private(set) var lastPosition: Double?
    private(set) var stalledSince: TimeInterval?
    private(set) var reported = false
    private(set) var lastFrames: Int?
    private(set) var pictureStalledSince: TimeInterval?
    private(set) var pictureReported = false

    static func expectsProgress(_ sample: Sample) -> Bool {
        guard !sample.isPaused, !sample.isBuffering, sample.rate > 0,
              !sample.isFinished, sample.isAppActive else { return false }
        if let since = sample.secondsSinceSeek, since < seekSettle { return false }
        if sample.duration > 0, sample.duration - sample.position <= endGuard { return false }
        return true
    }

    mutating func observe(_ sample: Sample, at now: TimeInterval) -> Verdict {
        guard Self.expectsProgress(sample) else {
            lastPosition = nil
            stalledSince = nil
            reported = false
            lastFrames = nil
            pictureStalledSince = nil
            pictureReported = false
            return .idle
        }
        if let lastPosition, abs(sample.position - lastPosition) <= Self.positionTolerance {
            let since = stalledSince ?? now
            stalledSince = since
            let elapsed = now - since
            if elapsed >= Self.threshold, !reported {
                reported = true
                return .frozen(seconds: elapsed, kind: .playhead)
            }
            return .watching(seconds: elapsed)
        }
        lastPosition = sample.position
        stalledSince = now
        reported = false
        guard let frames = sample.framesPresented else { return .idle }
        if let lastFrames, frames <= lastFrames {
            let since = pictureStalledSince ?? now
            pictureStalledSince = since
            let elapsed = now - since
            if elapsed >= Self.threshold, !pictureReported {
                pictureReported = true
                return .frozen(seconds: elapsed, kind: .picture)
            }
            return .watching(seconds: elapsed)
        }
        lastFrames = frames
        pictureStalledSince = now
        pictureReported = false
        return .idle
    }
}

/// When a session that ended without an error still deserves a report.
/// Thresholds are documented in docs/reference/playback/diagnostics.md;
/// change both together.
nonisolated enum PlaybackDegradationPolicy {
    struct Counters: Equatable, Sendable {
        var playedSeconds: Double = 0
        var droppedFrames = 0
        var totalFrames = 0
        var corruptedFrames = 0
        var stalls = 0
        var reprimes = 0
        var audioStarvation = 0
        var frozen = 0
        var rendererRecoveries = 0
    }

    static let minimumPlayedSeconds: Double = 30
    static let droppedFramesMinimum = 60
    static let droppedFramesRatio = 0.005
    static let stallsMinimum = 3
    static let reprimesMinimum = 1
    static let audioStarvationMinimum = 5

    /// Why a session is degraded, sorted so the fingerprint is stable. Empty for
    /// a healthy or too-short session. Freezes and renderer recoveries have their
    /// own incidents.
    static func reasons(for counters: Counters, sampledWholeAttempt: Bool = true) -> [String] {
        // Engine totals cover the whole attempt, so a partial window cannot be
        // compared fairly.
        guard sampledWholeAttempt, counters.playedSeconds >= minimumPlayedSeconds else { return [] }
        var reasons: [String] = []
        if counters.droppedFrames >= droppedFramesMinimum, counters.totalFrames > 0,
           Double(counters.droppedFrames) / Double(counters.totalFrames) >= droppedFramesRatio {
            reasons.append("droppedFrames")
        }
        if counters.stalls >= stallsMinimum { reasons.append("stalls") }
        if counters.reprimes >= reprimesMinimum { reasons.append("reprimes") }
        if counters.audioStarvation >= audioStarvationMinimum { reasons.append("audioStarvation") }
        return reasons.sorted()
    }
}

/// Reports on one playback attempt after another: what the item is, how it
/// is delivered, and what happened. Owns the sampling task and the freeze
/// detector; the controller calls in at start, ready, failure, handoff and
/// stop.
@MainActor
final class PlaybackIncidentMonitor {
    static let sampleInterval: Duration = .seconds(2)
    /// Every n-th tick writes a `playback.sample` event; the freeze check
    /// runs on every tick.
    static let sampleEveryTicks = 3
    /// Stalls within this many seconds of each other count as frequent.
    static let frequentStallWindow: Double = 60
    static let frequentStallCount = 3

    private(set) var attempt = ""
    private var facts: [String: DiagnosticValue] = [:]
    private var attemptStartedAt: TimeInterval?
    private var readyAt: TimeInterval?
    private var sampleTask: Task<Void, Never>?
    private weak var samplingEngine: DiagnosableEngine?
    private var preferenceObserver: NSObjectProtocol?
    private var freeze = PlaybackFreezeDetector()
    private var counters = PlaybackDegradationPolicy.Counters()
    private var lastSampleAt: TimeInterval?
    private var tick = 0
    private var stallUptimes: [TimeInterval] = []
    private var lastStallCount = 0
    private var frequentStallsReported = false
    private var attemptEnded = true
    /// Degradation is only assessed after uninterrupted sampling of the
    /// attempt.
    private(set) var sampledWholeAttempt = false
    /// A fallback whose report waits for the next rung's verdict: `recovered`,
    /// failed, or abandoned.
    private var pendingFallback: PendingFallback?
    private let hub: DiagnosticsHub
    private let notificationCenter: NotificationCenter
    private let sleep: @MainActor (Duration) async throws -> Void

    private struct PendingFallback {
        var variant: [String]
        var fields: [String: DiagnosticValue]
        var failedAt: TimeInterval
    }

    init(
        hub: DiagnosticsHub = Diagnostics.shared,
        notificationCenter: NotificationCenter = .default,
        sleep: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.hub = hub
        self.notificationCenter = notificationCenter
        self.sleep = sleep
        // Keep listening while opted out, so this attempt can resume sampling
        // without polling or retaining its engine.
        preferenceObserver = notificationCenter.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: nil
        ) { [weak self, hub] _ in
            let observedAt = ProcessInfo.processInfo.systemUptime
            let enabled = hub.isReportingEnabled
            Task { @MainActor [weak self] in
                guard let self else { return }
                // Preserve an observed opt-out even if re-enabled before this runs. A
                // queued change from the outgoing attempt must not reset its successor.
                if !enabled, let startedAt = self.attemptStartedAt, observedAt >= startedAt {
                    self.sampledWholeAttempt = false
                    self.endSampling()
                }
                self.updateSamplingPreference()
            }
        }
    }

    isolated deinit {
        sampleTask?.cancel()
        if let preferenceObserver {
            notificationCenter.removeObserver(preferenceObserver)
        }
    }

    /// A new attempt with a fresh random token. Called after negotiation, before
    /// the engine exists.
    func beginAttempt(
        delivery: PlaybackDelivery,
        method: PlayMethod,
        source: MediaSource,
        cached: Bool,
        disc: Bool,
        resumeSeconds: Double
    ) {
        endSampling()
        samplingEngine = nil
        attempt = String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).lowercased()
        attemptStartedAt = ProcessInfo.processInfo.systemUptime
        readyAt = nil
        freeze = PlaybackFreezeDetector()
        counters = PlaybackDegradationPolicy.Counters()
        lastSampleAt = nil
        tick = 0
        stallUptimes = []
        lastStallCount = 0
        frequentStallsReported = false
        attemptEnded = false
        sampledWholeAttempt = hub.isReportingEnabled
        facts = Self.facts(delivery: delivery, method: method, source: source, cached: cached, disc: disc)
        var fields = facts
        fields["position"] = .double(resumeSeconds.rounded(toPlaces: 1))
        fields["network"] = .string(Self.networkName)
        hub.record(.playbackStart, fields)
        publishAmbientFields()
    }

    /// Fields every incident inherits until the attempt ends, including ones the
    /// engine reports itself.
    private func publishAmbientFields() {
        var ambient = facts
        ambient["attempt"] = .string(attempt)
        hub.setAmbientFields(ambient)
    }

    /// Nothing negotiated or the engine never started. `stage` says how
    /// far it got.
    func startFailed(_ error: Error, delivery: PlaybackDelivery, stage: PlaybackFailureDetail.Stage) {
        resolvePendingFallback(outcome: "failed")
        let detail = Self.detail(for: error, stage: stage)
        var fields = incidentFields(extra: detail.fields)
        fields["delivery"] = .string(delivery.rawValue)
        if let status = Self.httpStatus(of: error) {
            fields["httpStatus"] = .int(status)
        }
        hub.record(.playbackFailure, fields)
        hub.report(.playbackStartFailed, level: .error, variant: detail.fingerprint, fields: fields)
        attemptEnded = true
        endSampling()
        samplingEngine = nil
        hub.setAmbientFields([:])
    }

    /// The engine presented its first frames. Starts sampling.
    func playbackReady(engine: DiagnosableEngine) {
        let now = ProcessInfo.processInfo.systemUptime
        readyAt = now
        var fields: [String: DiagnosticValue] = ["attempt": .string(attempt)]
        if let attemptStartedAt {
            fields["elapsedMs"] = .double(((now - attemptStartedAt) * 1_000).rounded())
        }
        fields["videoPath"] = DiagnosticSchema.token(engine.videoOutputPathDiagnostic) ?? .string("unknown")
        fields["audioPath"] = DiagnosticSchema.token(engine.audioOutputPathDiagnostic) ?? .string("unknown")
        facts["videoPath"] = fields["videoPath"]
        facts["audioPath"] = fields["audioPath"]
        publishAmbientFields()
        hub.record(.playbackReady, fields)
        resolvePendingFallback(outcome: "recovered")
        endSampling()
        samplingEngine = engine
        updateSamplingPreference()
    }

    /// `next` is the rung the ladder tries next, nil when it is spent.
    func engineFailed(_ failure: PlaybackEngineFailure, delivery: PlaybackDelivery, next: PlaybackDelivery?, engine: DiagnosableEngine?) {
        let detail = failure.detail ?? PlaybackFailureDetail(stage: .unknown)
        var fields = incidentFields(extra: detail.fields)
        fields["cause"] = .string(failure.cause == .undecodable ? "undecodable" : "delivery")
        fields["delivery"] = .string(delivery.rawValue)
        fields["from"] = .string(delivery.rawValue)
        if let engine {
            fields.merge(Self.pipelineFields(engine)) { _, new in new }
        }
        var variant = [failure.cause == .undecodable ? "undecodable" : "delivery"] + detail.fingerprint
        if fields["sinceTrackSwitchMs"] != nil {
            variant.append("afterTrackSwitch")
        }
        hub.record(.playbackFailure, fields)
        // A failure during a pending fallback is its verdict; report that first.
        resolvePendingFallback(outcome: "failed")
        if let next {
            fields["to"] = .string(next.rawValue)
            fields["outcome"] = .string("fallback")
            hub.record(.playbackFallback, fields)
            pendingFallback = PendingFallback(variant: variant, fields: fields, failedAt: ProcessInfo.processInfo.systemUptime)
        } else {
            fields["outcome"] = .string("exhausted")
            hub.report(.playbackFailed, level: .error, variant: variant, fields: fields)
        }
    }

    /// `elapsedMs` runs from the failure to the verdict.
    private func resolvePendingFallback(outcome: String) {
        guard let pending = pendingFallback else { return }
        pendingFallback = nil
        var fields = pending.fields
        fields["outcome"] = .string(outcome)
        fields["elapsedMs"] = .double(((ProcessInfo.processInfo.systemUptime - pending.failedAt) * 1_000).rounded())
        hub.report(.playbackFallback, level: outcome == "recovered" ? .warning : .error, variant: pending.variant, fields: fields)
    }

    func handoffBegan() {
        hub.record(.playbackHandoffBegin, ["attempt": .string(attempt)])
    }

    func handoffFinished(outcome: String, milliseconds: Double) {
        var fields: [String: DiagnosticValue] = [
            "attempt": .string(attempt),
            "elapsedMs": .double(milliseconds.rounded()),
        ]
        if DiagnosticSchema.outcomeChoices.contains(outcome) {
            fields["outcome"] = .string(outcome)
        }
        hub.record(.playbackHandoffEnd, fields)
        if outcome == "failed" {
            hub.report(.playbackHandoffFailed, level: .error, fields: incidentFields(extra: fields))
        }
    }

    /// Evaluates the session counters once and stops sampling. Safe to call
    /// more than once.
    func endAttempt(engine: DiagnosableEngine?, outcome: String) {
        guard !attemptEnded else { return }
        attemptEnded = true
        // A fallback's outgoing engine ends here too, but its successor owes the
        // verdict. Any other end abandons the fallback.
        if outcome != "fallback" {
            resolvePendingFallback(outcome: "cancelled")
        }
        if hub.isReportingEnabled, let engine {
            accumulate(engine: engine, at: ProcessInfo.processInfo.systemUptime)
        }
        endSampling()
        samplingEngine = nil
        var fields = incidentFields(extra: countersFields)
        if DiagnosticSchema.outcomeChoices.contains(outcome) {
            fields["outcome"] = .string(outcome)
        }
        if let engine {
            fields["position"] = .double(engine.timePosition.rounded(toPlaces: 1))
        }
        hub.record(.playbackStop, fields)
        defer { hub.setAmbientFields([:]) }
        let reasons = PlaybackDegradationPolicy.reasons(for: counters, sampledWholeAttempt: sampledWholeAttempt)
        guard !reasons.isEmpty, outcome != "failed" else { return }
        fields["degradation"] = .string(reasons.joined(separator: ","))
        hub.report(.playbackDegraded, level: .warning, variant: reasons, fields: fields)
    }

    // MARK: - Sampling

    private func updateSamplingPreference() {
        guard hub.isReportingEnabled else {
            sampledWholeAttempt = false
            endSampling()
            return
        }
        guard !attemptEnded, sampleTask == nil, let engine = samplingEngine else { return }
        beginSampling(engine: engine)
    }

    private func beginSampling(engine: DiagnosableEngine) {
        // Off means off: no tick at all.
        guard hub.isReportingEnabled else { return }
        // Reset the window after an opt-out interval, which is not a freeze,
        // played time or stalls.
        freeze = PlaybackFreezeDetector()
        tick = 0
        stallUptimes = []
        lastSampleAt = ProcessInfo.processInfo.systemUptime
        lastStallCount = engine.stallCount
        sampleTask = Task { [weak self, weak engine, sleep] in
            while !Task.isCancelled {
                do {
                    try await sleep(Self.sampleInterval)
                } catch {
                    return
                }
                // Cancellation may race a completed sleep. Never sample an ended attempt.
                guard !Task.isCancelled, let self, let engine else { return }
                guard self.hub.isReportingEnabled else {
                    self.sampledWholeAttempt = false
                    self.endSampling()
                    return
                }
                self.sample(engine: engine)
            }
        }
    }

    private func endSampling() {
        sampleTask?.cancel()
        sampleTask = nil
        lastSampleAt = nil
    }

    private func sample(engine: DiagnosableEngine) {
        let now = ProcessInfo.processInfo.systemUptime
        tick += 1
        accumulate(engine: engine, at: now)
        engine.refreshVideoPerformanceMetrics()

        let verdict = freeze.observe(PlaybackFreezeDetector.Sample(
            position: engine.timePosition,
            isPaused: engine.isPaused,
            isBuffering: engine.isBuffering,
            rate: engine.rate,
            duration: engine.duration,
            isFinished: engine.duration > 0 && engine.timePosition >= engine.duration - 0.5,
            isAppActive: Self.isAppActive,
            secondsSinceSeek: hub.millisecondsSince(.playbackSeek).map { $0 / 1_000 },
            framesPresented: engine.videoPerformance?.totalFrames
        ), at: now)
        if case .frozen(let seconds, let kind) = verdict {
            counters.frozen += 1
            var fields = incidentFields(extra: Self.pipelineFields(engine))
            fields["frozenSeconds"] = .double(seconds.rounded(toPlaces: 1))
            fields["frozenCount"] = .int(counters.frozen)
            hub.report(.playbackFrozen, level: .error, variant: [kind.rawValue], fields: fields)
        }

        // Stalls the engine recovered from, so a run of them becomes one report.
        let stalls = engine.stallCount
        if stalls > lastStallCount {
            stallUptimes.append(contentsOf: repeatElement(now, count: stalls - lastStallCount))
            lastStallCount = stalls
            stallUptimes.removeAll { $0 < now - Self.frequentStallWindow }
            if stallUptimes.count >= Self.frequentStallCount, !frequentStallsReported {
                frequentStallsReported = true
                var fields = incidentFields(extra: Self.pipelineFields(engine))
                fields["stalls"] = .int(stalls)
                hub.report(.playbackStall, level: .warning, variant: ["frequent"], fields: fields)
            }
        }

        if tick % Self.sampleEveryTicks == 0 {
            var fields = Self.pipelineFields(engine)
            fields["attempt"] = .string(attempt)
            hub.record(.playbackSample, fields)
        }
    }

    /// Advances the session counters from the engine's session-scoped
    /// values and the wall clock while playing.
    private func accumulate(engine: DiagnosableEngine, at now: TimeInterval) {
        if let lastSampleAt, !engine.isPaused, !engine.isBuffering {
            counters.playedSeconds += max(now - lastSampleAt, 0)
        }
        lastSampleAt = now
        if let performance = engine.videoPerformance {
            counters.droppedFrames = performance.droppedFrames
            counters.totalFrames = performance.totalFrames
            counters.corruptedFrames = performance.corruptedFrames
        }
        counters.stalls = engine.stallCount
        counters.reprimes = engine.stallReprimeCount
        counters.audioStarvation = engine.audioStarvationCount
        counters.rendererRecoveries = engine.audioRendererRecoveryCount + engine.mediaServicesResetRecoveryCount
    }

    private var countersFields: [String: DiagnosticValue] {
        [
            "playedSeconds": .double(counters.playedSeconds.rounded(toPlaces: 1)),
            "dropped": .int(counters.droppedFrames),
            "frames": .int(counters.totalFrames),
            "corrupted": .int(counters.corruptedFrames),
            "stalls": .int(counters.stalls),
            "reprimes": .int(counters.reprimes),
            "audioStarvation": .int(counters.audioStarvation),
            "frozenCount": .int(counters.frozen),
            "rendererRecoveries": .int(counters.rendererRecoveries),
        ]
    }

    /// The facts, the attempt, and how long ago the viewer last seeked or
    /// switched a track, merged with `extra`.
    private func incidentFields(extra: [String: DiagnosticValue]) -> [String: DiagnosticValue] {
        var fields = facts
        // Negotiation failures precede the attempt; the schema rejects an empty
        // token.
        if !attempt.isEmpty {
            fields["attempt"] = .string(attempt)
        }
        if let since = hub.millisecondsSince(.playbackSeek), since < 30_000 {
            fields["sinceSeekMs"] = .double(since.rounded())
        }
        if let since = hub.millisecondsSince(.playbackTrack), since < 30_000 {
            fields["sinceTrackSwitchMs"] = .double(since.rounded())
        }
        if let readyAt {
            fields["playedSeconds"] = .double((ProcessInfo.processInfo.systemUptime - readyAt).rounded(toPlaces: 1))
        }
        fields.merge(extra) { _, new in new }
        return fields
    }

    // MARK: - Field builders

    static func facts(
        delivery: PlaybackDelivery,
        method: PlayMethod,
        source: MediaSource,
        cached: Bool,
        disc: Bool
    ) -> [String: DiagnosticValue] {
        var fields: [String: DiagnosticValue] = [
            "delivery": .string(delivery.rawValue),
            "method": .string(method.rawValue),
            "cached": .bool(cached),
            "disc": .bool(disc),
        ]
        if let container = DiagnosticSchema.token(source.container?.lowercased()) {
            fields["container"] = container
        }
        if let bitrate = source.bitrate { fields["bitrate"] = .int(bitrate) }
        if let ticks = source.runTimeTicks {
            fields["durationSeconds"] = .double(Ticks.seconds(ticks).rounded())
        }
        if let video = source.mediaStreams?.first(where: { $0.type == "Video" }) {
            if let codec = DiagnosticSchema.token(video.codec?.lowercased()) { fields["videoCodec"] = codec }
            if let profile = DiagnosticSchema.token(video.profile?.replacingOccurrences(of: " ", with: "")) {
                fields["videoProfile"] = profile
            }
            if let range = DiagnosticSchema.token(video.videoRangeType) { fields["videoRange"] = range }
            if let width = video.width { fields["width"] = .int(width) }
            if let height = video.height { fields["height"] = .int(height) }
            if let bitDepth = video.bitDepth { fields["bitDepth"] = .int(bitDepth) }
            if let frameRate = video.realFrameRate, frameRate.isFinite {
                fields["frameRate"] = .double(frameRate.rounded(toPlaces: 3))
            }
        }
        let audioStreams = source.mediaStreams?.filter { $0.type == "Audio" } ?? []
        if let audio = audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first {
            if let codec = DiagnosticSchema.token(audio.codec?.lowercased()) { fields["audioCodec"] = codec }
            if let channels = audio.channels { fields["audioChannels"] = .int(channels) }
        }
        return fields
    }

    /// What the pipeline looks like right now: cheap reads only.
    static func pipelineFields(_ engine: DiagnosableEngine) -> [String: DiagnosticValue] {
        let memory = MemorySnapshot.current()
        var fields: [String: DiagnosticValue] = [
            "position": .double(engine.timePosition.rounded(toPlaces: 1)),
            "rate": .double(engine.rate),
            "paused": .bool(engine.isPaused),
            "buffering": .bool(engine.isBuffering),
            "videoQueued": .int(engine.videoQueueCountDiagnostic),
            "audioQueued": .int(engine.queueDepths.audio),
            "videoIntake": .int(engine.videoIntakeCountDiagnostic),
            "audioLead": .double(engine.audioDeliveryLeadSeconds.rounded(toPlaces: 2)),
            "stalls": .int(engine.stallCount),
            "audioStalls": .int(engine.audioStallCount),
            "audioStarvation": .int(engine.audioStarvationCount),
            "reprimes": .int(engine.stallReprimeCount),
            "idleRequests": .int(engine.idleRequestCallbacks),
            "startPointDrops": .int(engine.videoStartPointDropDiagnostic),
            "memoryMB": .double(memory.footprintMB.rounded(toPlaces: 1)),
            "availableMB": .double(memory.availableMB.rounded(toPlaces: 1)),
            "thermal": .string(DiagnosticsProcessObserver.thermalName(ProcessInfo.processInfo.thermalState)),
            "appState": .string(appStateName),
        ]
        if let refused = engine.refusedSampleMsDiagnostic {
            fields["refusedSampleMs"] = .int(refused)
        }
        if let performance = engine.videoPerformance {
            fields["dropped"] = .int(performance.droppedFrames)
            fields["corrupted"] = .int(performance.corruptedFrames)
            fields["frames"] = .int(performance.totalFrames)
            fields["frameDelay"] = .double(performance.accumulatedFrameDelay.rounded(toPlaces: 3))
        }
        return fields
    }

    static func detail(for error: Error, stage: PlaybackFailureDetail.Stage) -> PlaybackFailureDetail {
        if let jellyfin = error as? JellyfinError {
            switch jellyfin {
            case .server(let status, _):
                return PlaybackFailureDetail(stage: stage, domain: "JellyfinError.server", code: status)
            case .unplayable:
                return PlaybackFailureDetail(stage: stage, domain: "JellyfinError.unplayable")
            case .notConfigured, .invalidServerURL:
                return PlaybackFailureDetail(stage: stage, domain: "JellyfinError.configuration")
            case .unauthorized, .sessionExpired:
                return PlaybackFailureDetail(stage: stage, domain: "JellyfinError.session")
            }
        }
        if error is PlaybackStartError {
            return PlaybackFailureDetail(stage: .start, domain: "PlaybackStartError")
        }
        return PlaybackFailureDetail(stage: stage, error: error)
    }

    static func httpStatus(of error: Error) -> Int? {
        if case .server(let status, _)? = error as? JellyfinError { return status }
        return nil
    }

    private static var networkName: String {
        let cost = NetworkPathObserver.shared.current
        if cost.isConstrained { return "constrained" }
        if cost.isExpensive { return "expensive" }
        return "unrestricted"
    }

    private static var isAppActive: Bool {
        #if canImport(UIKit)
        UIApplication.shared.applicationState == .active
        #else
        true
        #endif
    }

    private static var appStateName: String {
        #if canImport(UIKit)
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "active"
        }
        #else
        "active"
        #endif
    }
}
