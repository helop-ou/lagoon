import Foundation
import UIKit

/// Optional tester-facing sampling. Tasks keep only weak engine references;
/// observations are read here and published as low-frequency HUD snapshots.
/// The independent incident monitor owns automatic diagnostic reporting.
@MainActor
final class PlaybackDiagnosticsSampler {
    struct HUDContext {
        let cache: PlaybackCacheMetrics?
        let handoffMilliseconds: Double?
        let fallbackLines: [String]
    }

    private var decodeTraceTask: Task<Void, Never>?
    private var hudTask: Task<Void, Never>?
    /// Supplied by the controller so the decode trace can print the cache's
    /// fill progress next to the engine counters (HEL-160).
    var cacheMetrics: (() -> PlaybackCacheMetrics?)?

    deinit {
        decodeTraceTask?.cancel()
        hudTask?.cancel()
    }

    func stop() {
        decodeTraceTask?.cancel()
        decodeTraceTask = nil
        hudTask?.cancel()
        hudTask = nil
    }

    /// A console time series of the software decode path, every two seconds
    /// (HEL-137).
    ///
    /// The HUD shows the same numbers, but a HUD reading is one glance at one
    /// moment, and the question this ticket is stuck on is a *curve*: cost per
    /// frame climbs from 31 ms to past the 41.7 ms budget within half a
    /// minute, and whether the queue depth and footprint move with it is what
    /// separates memory pressure from heat from scene complexity. Reading that
    /// off a television by eye loses exactly the correlation that matters.
    ///
    /// `devicectl ... --console` streams this from a real Apple TV, where the
    /// unified log is out of reach. Off unless `-debug.decodeTrace YES`.
    func startTrace(
        engine: SampleBufferPlayerEngine,
        onExitRequested: @escaping @MainActor () -> Void
    ) {
        decodeTraceTask?.cancel()
        guard UserDefaults.standard.bool(forKey: "debug.decodeTrace") else { return }
        decodeTraceTask = Task { [weak engine] in
            let cpuTrace = ProcessCPUTrace()
            let pumpPing = PumpPing()
            // HEL-148 soak hooks: a hands-off pause/resume and a hands-off
            // exit at fixed media-time positions, each off (0) unless set.
            // Read once so a value that changes mid-soak (it shouldn't)
            // can't retrigger either one.
            let soakPauseAtSeconds = UserDefaults.standard.double(forKey: "debug.soakPauseAtSeconds")
            let soakExitAtSeconds = UserDefaults.standard.double(forKey: "debug.soakExitAtSeconds")
            var didSoakPause = false
            var didSoakExit = false
            while !Task.isCancelled {
                // HEL-148 soak diagnostic: overshoot past the requested 2 s
                // sleep is time the main actor was unavailable to resume
                // this task — this loop runs on the main actor because it
                // was created inside `PlaybackController`, a `@MainActor`
                // type.
                let sleepStart = ContinuousClock.now
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                let mainLateMs = max(0, ms(ContinuousClock.now - sleepStart) - 2_000)
                guard !Task.isCancelled, let engine else { return }
                // Whether frames take the direct-display path or are being
                // composited with UI — readable here with the HUD off, which
                // the HUD itself never could be (HEL-137).
                engine.refreshVideoPerformanceMetrics()
                let performance = engine.videoPerformance
                let memory = MemorySnapshot.current()
                let depths = engine.queueDepths
                // Last tick's completed pump-queue ping; the one fired below
                // lands in time for the next tick to read.
                let lastPumpMs = pumpPing.lastMs
                let thermalName: String
                switch ProcessInfo.processInfo.thermalState {
                case .nominal: thermalName = "nominal"
                case .fair: thermalName = "fair"
                case .serious: thermalName = "serious"
                case .critical: thermalName = "critical"
                @unknown default: thermalName = "unknown"
                }
                // The renderer-side audio signal (HEL-123) rides on the same
                // line, so a device console can correlate it with position
                // and the queues without the HUD or the accessibility probe.
                var trace = "DecodeTrace"
                    + String(format: " position=%.2f", engine.timePosition)
                    + " video=\(engine.videoQueueCountDiagnostic)/\(engine.maximumVideoBacklogDiagnostic)/\(engine.videoQueueHardLimitDiagnostic)"
                    + " intake=\(engine.videoIntakeCountDiagnostic)/\(engine.maximumVideoIntakeDiagnostic)"
                    + " audio=\(depths.audio)"
                    + String(format: " lead=%.3f", engine.audioDeliveryLeadSeconds)
                    + " ready=\(engine.audioRendererReadyForPlayback ? 1 : 0)"
                    + " buffering=\(engine.isBuffering ? 1 : 0)"
                    + " aDry=\(engine.audioStarvationCount)"
                    + String(format: " footprintMB=%.1f availableMB=%.1f",
                        memory.footprintMB, memory.availableMB)
                    + " stalls=\(engine.stallCount) audioStalls=\(engine.audioStallCount)"
                    + " reprimes=\(engine.stallReprimeCount)"
                    + " shown=\(performance?.totalFrames ?? -1)"
                    + " opt=\(performance?.optimizedCompositingFrames ?? -1)"
                    + " dropped=\(performance?.droppedFrames ?? -1)"
                    + " swdec=\"\(engine.softwareDecodeBenchField ?? "n/a")\""
                    // HEL-148 soak diagnostics: main-actor scheduling
                    // latency, pump-queue ping, the 10 Hz tick summary,
                    // subtitle cue count, renderer observer count, thermal
                    // state — everything the 100-minute soak needs to show
                    // whether the engine degrades over a long film.
                    + String(format: " mainLateMs=%.0f pumpMs=%.1f", mainLateMs, lastPumpMs)
                    + " \(engine.drainMainTickDiagnostic())"
                    + " cues=\(engine.subtitleCueCountDiagnostic)"
                    + " observers=\(engine.rendererObserverCountDiagnostic)"
                    + " thermal=\(thermalName)"
                #if os(tvOS)
                // Whether the display actually matched the content: a
                // 60 Hz SDR mode left in place makes the compositor
                // cadence-convert and tone-map every HDR frame, which is
                // the standing suspect for the composited-path drops.
                trace += " display=\"\(DisplayModeMatcher.statusDescription)"
                    + " · \(DisplayModeMatcher.maximumFramesPerSecond.map(String.init) ?? "?") Hz\""
                #endif
                #if DEBUG
                trace += " audioHeld=\(engine.audioDeliverySuspendedForDiagnostics ? 1 : 0)"
                    + " deliveryHeld=\(engine.demuxDeliverySuspendedForDiagnostics ? 1 : 0)"
                #endif
                // HEL-160: the cache's fill progress on the same line, so a
                // console run can read the fill rate against position.
                if let cache = cacheMetrics?() {
                    trace += String(
                        format: " cacheMB=%.1f aheadMB=%.1f netMB=%.1f dupMB=%.1f shared=%d req=%d",
                        Double(cache.cachedBytes) / 1_048_576,
                        Double(cache.cachedBytesAheadOfPlayhead) / 1_048_576,
                        Double(cache.networkBytes) / 1_048_576,
                        Double(cache.duplicateNetworkBytes) / 1_048_576,
                        cache.sharedFetchCount,
                        cache.requestCount
                    )
                }
                print(trace)
                print(cpuTrace.tick())
                engine.measurePumpQueueLatency { duration in
                    Task { @MainActor in pumpPing.lastMs = ms(duration) }
                }

                if soakPauseAtSeconds > 0, !didSoakPause,
                   engine.timePosition >= soakPauseAtSeconds, !engine.isPaused {
                    didSoakPause = true
                    let pauseStart = ContinuousClock.now
                    engine.pause()
                    print(String(
                        format: "SoakPause position=%.2f pauseCallMs=%.1f",
                        engine.timePosition, ms(ContinuousClock.now - pauseStart)
                    ))
                    do {
                        try await Task.sleep(for: .seconds(5))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    let resumeStart = ContinuousClock.now
                    engine.play()
                    print(String(
                        format: "SoakResume position=%.2f playCallMs=%.1f",
                        engine.timePosition, ms(ContinuousClock.now - resumeStart)
                    ))
                }
                if soakExitAtSeconds > 0, !didSoakExit, engine.timePosition >= soakExitAtSeconds {
                    didSoakExit = true
                    onExitRequested()
                    print(String(format: "SoakExit requested position=%.2f", engine.timePosition))
                }
            }
        }
    }

    // MARK: Playback HUD (Settings → Debug → Playback HUD; ships in all
    // builds so TestFlight sessions can diagnose playback too)

    func startHUD(
        source: MediaSource,
        method: PlayMethod,
        engine: SampleBufferPlayerEngine,
        context: @escaping @MainActor () -> HUDContext?,
        publish: @escaping @MainActor ([String]) -> Void
    ) {
        hudTask?.cancel()
        guard UserDefaults.standard.bool(forKey: "debug.playbackHUD") else { return }

        var negotiated = [
            "Method: \(method.rawValue)"
                + (method == .transcode ? " (\(source.transcodingSubProtocol ?? "?"))" : ""),
        ]
        var sourceLine = "Source: \(source.container ?? "?")"
        if let bitrate = source.bitrate {
            sourceLine += " · \(Self.mbps(bitrate))"
        }
        negotiated.append(sourceLine)
        if let video = source.mediaStreams?.first(where: { $0.type == "Video" }) {
            var line = "Video:  \(video.codec ?? "?")"
            if let profile = video.profile { line += " \(profile.lowercased())" }
            if let range = video.videoRangeType { line += " · \(range)" }
            if let width = video.width, let height = video.height { line += " · \(width)×\(height)" }
            negotiated.append(line)
            if let width = video.width, let height = video.height {
                let bitDepth = video.bitDepth ?? (video.videoRangeType == "SDR" ? 8 : 10)
                let frameMB = Double(DecodedFrameMemory.bytesPer420Frame(
                    width: width,
                    height: height,
                    bitDepth: bitDepth
                )) / 1_048_576
                let hardQueueMB = Double(DecodedFrameMemory.queuedBytes(
                    width: width,
                    height: height,
                    bitDepth: bitDepth,
                    frames: DemuxBackpressurePolicy.videoHardLimit(videoIsDecoded: true)
                )) / 1_048_576
                negotiated.append(String(
                    format: "Surface: %.1f MB/frame · %.0f MB app hard queue",
                    frameMB,
                    hardQueueMB
                ))
            }
        }
        let audioStreams = source.mediaStreams?.filter { $0.type == "Audio" } ?? []
        if let audio = audioStreams.first(where: { $0.isDefault == true }) ?? audioStreams.first {
            var line = "Audio:  \(audio.codec ?? "?")"
            if let channels = audio.channels { line += " · \(channels)ch" }
            negotiated.append(line)
        }

        publish(negotiated)
        hudTask = Task { [weak engine] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled, let engine, let context = context() else { return }
                engine.refreshVideoPerformanceMetrics()
                var live = Self.liveHUDLines(
                    for: engine,
                    cache: context.cache
                )
                if let milliseconds = context.handoffMilliseconds {
                    live.insert(String(format: "Handoff: %.0f ms to ready", milliseconds), at: 0)
                }
                publish(negotiated + live + context.fallbackLines)
            }
        }
    }

    private static func liveHUDLines(
        for engine: SampleBufferPlayerEngine,
        cache: PlaybackCacheMetrics?
    ) -> [String] {
        var lines: [String] = []
        if let size = engine.videoSize {
            lines.append("Playing: \(Int(size.width))×\(Int(size.height))")
        } else {
            lines.append("Playing: not ready · \(engine.isBuffering ? "buffering" : "…")")
        }
        if let audio = engine.audioDiagnostic {
            lines.append("Track:   \(audio)")
        }
        if engine.duration > 0 {
            lines.append("Time:    \(Int(engine.timePosition))/\(Int(engine.duration)) s")
        }
        let depths = engine.queueDepths
        // App-side count/seconds explain demux backpressure. `lead` is the
        // separate renderer-side starvation signal: media already handed to
        // AVFoundation beyond the clock, which stays positive after Lagoon's
        // own queue drains to zero (HEL-123). `+cur/peak` is compressed video
        // parked in the intake, past the decoded limit, waiting for the
        // demuxer to reach it again (HEL-124).
        lines.append(String(
            format: "Queues:  V %d/%d/%d +%d/%d · A %d/%d (%.1fs) · lead %.2fs ready%d · stalls %d (%d audio) · reprime %d · aDry %d · aGaps %d",
            engine.videoQueueCountDiagnostic,
            engine.maximumVideoBacklogDiagnostic,
            engine.videoQueueHardLimitDiagnostic,
            engine.videoIntakeCountDiagnostic,
            engine.maximumVideoIntakeDiagnostic,
            depths.audio,
            engine.audioCushionTarget,
            engine.audioBufferedSeconds,
            engine.audioDeliveryLeadSeconds,
            engine.audioRendererReadyForPlayback ? 1 : 0,
            engine.stallCount,
            engine.audioStallCount,
            engine.stallReprimeCount,
            engine.audioStarvationCount,
            engine.audioTimingGapCount
        ))
        #if DEBUG
        if engine.audioDeliverySuspendedForDiagnostics
            || engine.demuxDeliverySuspendedForDiagnostics {
            lines.append(
                "Fault: audio \(engine.audioDeliverySuspendedForDiagnostics ? "held" : "live")"
                    + " · delivery \(engine.demuxDeliverySuspendedForDiagnostics ? "held" : "live")"
            )
        }
        #endif
        // Audio thrown away in the demuxer, which no other counter can show:
        // dropped packets never reach the renderer, so aGaps above reads 0
        // through exactly the failure this line exists to catch.
        if let drops = engine.audioPacketDropInfo {
            lines.append("AudDrop: \(drops)")
        }
        // Only once something has actually been rebuilt. A renderer that
        // failed and was replaced leaves no other trace — playback simply
        // carries on, which is the point (HEL-101).
        if engine.audioRendererRecoveryCount > 0 || engine.mediaServicesResetRecoveryCount > 0 {
            lines.append(
                "Recovery: audio ×\(engine.audioRendererRecoveryCount) · service ×\(engine.mediaServicesResetRecoveryCount)"
            )
        }
        if let cache {
            if let fraction = cache.bufferedFraction,
               let contentLength = cache.contentLength {
                lines.append(String(
                    format: "Buffer:  %.1f/%.1f MB · %.0f%% prefix · %d ranges · %d playhead fills",
                    Double(cache.cachedBytes) / 1_048_576,
                    Double(contentLength) / 1_048_576,
                    fraction * 100,
                    cache.bufferedRanges.count,
                    cache.playheadPrefetchCount
                ))
            }
            lines.append(String(
                format: "Cache:   %.1f/%.0f MB · %.0f%% hit · %d req · %.0fms avg · %d res · %d evict",
                Double(cache.cachedBytes) / 1_048_576,
                Double(cache.capacityBytes) / 1_048_576,
                cache.hitRate * 100,
                cache.requestCount,
                cache.averageRequestMilliseconds,
                cache.resourceCount,
                cache.evictionCount
            ))
            // HEL-160: the cushion the fill scheduler is protecting, and what
            // overtaking a prefetch cost or saved.
            lines.append(String(
                format: "Ahead:   %.1f MB cached past the playhead · %.1f MB duplicate · %d shared fetches",
                Double(cache.cachedBytesAheadOfPlayhead) / 1_048_576,
                Double(cache.duplicateNetworkBytes) / 1_048_576,
                cache.sharedFetchCount
            ))
        }
        if let videoTiming = engine.videoTimingDiagnostic {
            lines.append("Vtime:   \(videoTiming)")
        }
        // Where the software path's frame budget goes, split three ways so a
        // slow one can be attributed rather than guessed at (HEL-137). Each
        // percentage is a share of one core on its own queue; they overlap,
        // so they are not meant to sum.
        if let software = engine.softwareDecodeDiagnostic {
            lines.append("SWdec:   \(software)")
        }
        if let dovi = engine.dolbyVisionRewriteInfo {
            lines.append("DoVi P7: \(dovi)")
        }
        #if os(tvOS)
        // Every gate between the request and the glass. Lagoon always asks;
        // the system's Match Content setting remains the user's authority.
        if let request = engine.displayMatchRequest {
            lines.append(String(
                format: "Display: request %.3f Hz · %@",
                Double(request.frameRate),
                DisplayModeMatcher.statusDescription
            ))
        }
        #endif
        if let bench = engine.benchStatus {
            lines.append("Bench:   \(bench)")
        }
        let memory = MemorySnapshot.current()
        var memoryLine = String(format: "Memory:  %.0f MB", memory.footprintMB)
        if memory.availableBytes > 0 {
            memoryLine += String(format: " · %.0f MB free", memory.availableMB)
        }
        lines.append(memoryLine)
        if let metrics = engine.videoPerformance {
            lines.append(
                "Frames:  \(metrics.droppedFrames) dropped / \(metrics.totalFrames)"
                    + (metrics.corruptedFrames > 0 ? " · \(metrics.corruptedFrames) corrupt" : "")
                    + " · opt \(metrics.optimizedCompositingFrames)"
                    + String(format: " · delay %.0fms", metrics.accumulatedFrameDelay * 1000)
            )
        }
        return lines
    }

    private static func mbps(_ bitsPerSecond: Int) -> String {
        String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
    }
}

/// HEL-148 soak diagnostic: holds the DecodeTrace loop's pump-queue ping
/// result. A box rather than a local var because the callback that fills it
/// runs on the main actor a tick later than the print that reads it.
@MainActor
private final class PumpPing {
    var lastMs: Double = -1
}

private func ms(_ duration: Duration) -> Double {
    Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
}
