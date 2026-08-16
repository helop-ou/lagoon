import AVFAudio
import AVFoundation
import CoreMedia
import Foundation

/// HEL-48 M1: the Lagoon playback engine — libavformat demux into
/// compressed CMSampleBuffers rendered by AVSampleBufferDisplayLayer /
/// AVSampleBufferAudioRenderer under an AVSampleBufferRenderSynchronizer.
/// The system does the decoding, color management, and audio output, which
/// is the whole point of this architecture (see HEL-48).
///
/// M1 coverage: h264/hevc video, aac/ac3/eac3 audio (`canPlay` gates
/// routing; everything else stays on mpv). No subtitles yet.
///
/// Threading: state and transport commands live on the main actor; the
/// demux loop runs on a dedicated serial queue, feeding two thread-safe
/// sample-buffer queues that the renderers' data pumps drain.
@Observable
final class SampleBufferPlayerEngine: PlayerEngine {
    private(set) var timePosition: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPaused = false
    private(set) var isBuffering = true
    private(set) var videoSize: CGSize?
    private(set) var audioTracks: [PlayerTrack] = []
    let subtitleTracks: [PlayerTrack] = []

    @ObservationIgnored var onFinished: (() -> Void)?
    @ObservationIgnored var onError: ((String) -> Void)?

    // MARK: Cross-thread state

    @ObservationIgnored nonisolated private let demuxer = FFmpegDemuxer()
    @ObservationIgnored nonisolated private let videoQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let audioQueue = SampleBufferQueue()
    @ObservationIgnored nonisolated private let demuxQueue = DispatchQueue(label: "ee.helop.lagoon.demux", qos: .userInitiated)
    @ObservationIgnored nonisolated private let pumpQueue = DispatchQueue(label: "ee.helop.lagoon.pump", qos: .userInitiated)

    // Written on main, read on the demux loop (or vice versa) — all simple
    // value types behind one lock.
    @ObservationIgnored nonisolated private let shared = SharedState()

    @ObservationIgnored nonisolated(unsafe) private var videoRenderer: AVSampleBufferVideoRenderer?
    @ObservationIgnored nonisolated(unsafe) private var audioRenderer: AVSampleBufferAudioRenderer?
    @ObservationIgnored private let synchronizer = AVSampleBufferRenderSynchronizer()
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var didFinish = false

    @ObservationIgnored private var pendingURL: URL?
    @ObservationIgnored private var pendingStartSeconds: Double = 0

    /// Codecs the M1 pipeline can wrap. Files outside this envelope route
    /// to mpv instead (see PlaybackController).
    nonisolated static func canPlay(source: MediaSource) -> Bool {
        let streams = source.mediaStreams ?? []
        guard let video = streams.first(where: { $0.type == "Video" }),
              let videoCodec = video.codec?.lowercased(),
              ["h264", "hevc"].contains(videoCodec) else { return false }
        let audioCodecs = streams.filter { $0.type == "Audio" }.compactMap { $0.codec?.lowercased() }
        // Every audio track must be wrappable so the track picker stays honest.
        return audioCodecs.allSatisfy { ["aac", "ac3", "eac3"].contains($0) }
    }

    func prepare(url: URL, startSeconds: Double, initialAudioOrdinal: Int?) {
        pendingURL = url
        pendingStartSeconds = startSeconds
        shared.withLock { $0.initialAudioOrdinal = initialAudioOrdinal }
    }

    func attach(displayLayer: AVSampleBufferDisplayLayer) {
        guard videoRenderer == nil, let url = pendingURL else { return }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)

        let video = displayLayer.sampleBufferRenderer
        let audio = AVSampleBufferAudioRenderer()
        videoRenderer = video
        audioRenderer = audio
        synchronizer.addRenderer(video)
        synchronizer.addRenderer(audio)

        video.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            self?.pumpVideo()
        }
        audio.requestMediaDataWhenReady(on: pumpQueue) { [weak self] in
            self?.pumpAudio()
        }

        timeObserver = synchronizer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            self?.observeTime(time)
        }

        shared.withLock { $0.pendingSeekSeconds = max(pendingStartSeconds, 0) }
        let startURL = url
        demuxQueue.async { [weak self] in
            self?.runDemuxLoop(url: startURL)
        }
    }

    // MARK: - Transport (PlayerEngine)

    func togglePause() {
        if synchronizer.rate > 0 {
            synchronizer.rate = 0
            isPaused = true
        } else {
            synchronizer.rate = 1
            isPaused = false
        }
    }

    func seek(by seconds: Double) {
        seek(to: timePosition + seconds)
    }

    func selectAudioTrack(id: Int?) {
        guard let id, id - 1 < audioTracks.count else { return }
        shared.withLock { $0.selectedAudioOrdinal = id }
        audioTracks = audioTracks.map {
            PlayerTrack(engineID: $0.engineID, kind: .audio, displayName: $0.displayName, isSelected: $0.engineID == id)
        }
        // Cleanest gapless-ish switch in M1: re-run the demux from the
        // current position with the new stream selected.
        seek(to: timePosition)
    }

    func selectSubtitleTrack(id: Int?) {
        // M1 has no subtitle path yet (M5).
    }

    func shutdown() {
        shared.withLock { $0.cancelled = true }
        if let timeObserver {
            synchronizer.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        synchronizer.rate = 0
        videoRenderer?.stopRequestingMediaData()
        audioRenderer?.stopRequestingMediaData()
        videoRenderer?.flush()
        audioRenderer?.flush()
        videoQueue.reset()
        audioQueue.reset()
    }

    // MARK: - Seeking

    private func seek(to target: Double) {
        let clamped = max(0, duration > 0 ? min(target, duration - 1) : target)
        isBuffering = true
        synchronizer.rate = 0
        videoRenderer?.flush()
        audioRenderer?.flush()
        videoQueue.reset()
        audioQueue.reset()
        shared.withLock { $0.pendingSeekSeconds = clamped }
    }

    /// Demux primed after open/seek — start (or reposition, if paused) at
    /// the target position.
    private func beginPlayback(at seconds: Double) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        timePosition = seconds
        isBuffering = false
        synchronizer.setRate(isPaused ? 0 : 1, time: time)
        kickPumps()
    }

    private func observeTime(_ time: CMTime) {
        let seconds = time.seconds
        guard seconds.isFinite else { return }
        if abs(seconds - timePosition) >= 0.25 {
            timePosition = seconds
        }
        if !didFinish, duration > 0, seconds >= duration - 0.4,
           videoQueue.isFinished, audioQueue.isFinished,
           videoQueue.count == 0 {
            didFinish = true
            onFinished?()
        }
    }

    private func publishStreams(duration: Double, videoSize: CGSize, tracks: [PlayerTrack]) {
        self.duration = duration
        self.videoSize = videoSize
        audioTracks = tracks
    }

    // MARK: - Demux loop (demux queue only)

    nonisolated private func runDemuxLoop(url: URL) {
        do {
            try demuxer.open(url: url.absoluteString)
        } catch {
            let message = (error as? DemuxError)?.errorDescription ?? "The stream could not be opened."
            Task { @MainActor in self.onError?(message) }
            return
        }

        // Ordinals are 1-based positions in the demuxed audio list — the
        // same convention the server-default mapping uses.
        let initialOrdinal = shared.withLock { state -> Int in
            if state.selectedAudioOrdinal == 0 {
                state.selectedAudioOrdinal = initialAudioOrdinalSnapshot() ?? 1
            }
            return state.selectedAudioOrdinal
        }
        applyAudioSelection(ordinal: initialOrdinal)

        let streams = demuxer.audioStreams
        let demuxedDuration = demuxer.durationSeconds
        let size = videoDimensions()
        let tracks = streams.enumerated().map { offset, stream in
            PlayerTrack(
                engineID: offset + 1,
                kind: .audio,
                displayName: Self.trackName(for: stream),
                isSelected: offset + 1 == initialOrdinal
            )
        }
        Task { @MainActor in
            self.publishStreams(duration: demuxedDuration, videoSize: size, tracks: tracks)
        }

        while !shared.withLock({ $0.cancelled }) {
            if let target = shared.withLock({ state -> Double? in
                defer { state.pendingSeekSeconds = nil }
                return state.pendingSeekSeconds
            }) {
                videoQueue.reset()
                audioQueue.reset()
                applyAudioSelection(ordinal: shared.withLock { $0.selectedAudioOrdinal })
                if target > 0.5 {
                    demuxer.seek(toSeconds: target)
                }
                primeAndStart(at: target)
                continue
            }

            if videoQueue.isFinished {
                // EOF reached; idle until a seek arrives or we shut down.
                Thread.sleep(forTimeInterval: 0.1)
                continue
            }
            if videoQueue.count > 90, audioQueue.count > 180 {
                Thread.sleep(forTimeInterval: 0.03)
                continue
            }
            step()
        }
        demuxer.close()
    }

    /// One av_read_frame worth of work; routes to the queues.
    nonisolated private func step() {
        switch demuxer.readNext() {
        case .video(let buffer):
            videoQueue.enqueue(buffer)
            kickPumps()
        case .audio(let buffer, let streamIndex):
            if streamIndex == selectedAudioStreamIndex() {
                audioQueue.enqueue(buffer)
                kickPumps()
            }
        case .skipped:
            break
        case .endOfFile:
            videoQueue.markFinished()
            audioQueue.markFinished()
        case .failed(let message):
            videoQueue.markFinished()
            audioQueue.markFinished()
            Task { @MainActor in self.onError?("Playback failed in the Lagoon engine (\(message)).") }
            shared.withLock { $0.cancelled = true }
        }
    }

    /// Fill the queues enough that playback can start cleanly, then hand
    /// control back to the main actor to run the clock.
    nonisolated private func primeAndStart(at target: Double) {
        while videoQueue.count < 12, !videoQueue.isFinished, !shared.withLock({ $0.cancelled }) {
            if shared.withLock({ $0.pendingSeekSeconds != nil }) { return }
            step()
        }
        Task { @MainActor in self.beginPlayback(at: target) }
    }

    nonisolated private func applyAudioSelection(ordinal: Int) {
        let streams = demuxer.audioStreams
        guard !streams.isEmpty else { return }
        let index = min(max(ordinal - 1, 0), streams.count - 1)
        let streamIndex = streams[index].streamIndex
        shared.withLock { $0.selectedAudioStreamIndex = streamIndex }
        demuxer.selectAudio(streamIndex: streamIndex)
    }

    nonisolated private func selectedAudioStreamIndex() -> Int32 {
        shared.withLock { $0.selectedAudioStreamIndex }
    }

    nonisolated private func initialAudioOrdinalSnapshot() -> Int? {
        shared.withLock { $0.initialAudioOrdinal }
    }

    nonisolated private func videoDimensions() -> CGSize {
        // Format description dimensions come straight from codec parameters.
        guard let description = demuxer.videoStream?.formatDescription else { return .zero }
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        return CGSize(width: CGFloat(dimensions.width), height: CGFloat(dimensions.height))
    }

    nonisolated private static func trackName(for stream: DemuxedStream) -> String {
        let language = stream.language.flatMap {
            Locale.current.localizedString(forLanguageCode: $0) ?? $0.uppercased()
        }
        var detail = stream.title
        if detail == nil {
            var facts = stream.codecName.uppercased()
            if stream.channels > 0 {
                facts += " · \(stream.channels)ch"
            }
            detail = facts
        }
        let name = [language, detail].compactMap(\.self).joined(separator: " · ")
        return name.isEmpty ? "Track \(stream.streamIndex)" : name
    }

    // MARK: - Renderer pumps (pump queue only)

    nonisolated private func kickPumps() {
        pumpQueue.async { [weak self] in
            self?.pumpVideo()
            self?.pumpAudio()
        }
    }

    nonisolated private func pumpVideo() {
        guard let renderer = videoRenderer else { return }
        while renderer.isReadyForMoreMediaData, let buffer = videoQueue.dequeue() {
            renderer.enqueue(buffer)
        }
    }

    nonisolated private func pumpAudio() {
        guard let renderer = audioRenderer else { return }
        while renderer.isReadyForMoreMediaData, let buffer = audioQueue.dequeue() {
            renderer.enqueue(buffer)
        }
    }
}

// MARK: - Support types

/// Mutable state crossed between the main actor, demux loop, and pumps —
/// tiny value types behind one lock.
nonisolated private final class SharedState: @unchecked Sendable {
    struct State {
        var cancelled = false
        var pendingSeekSeconds: Double?
        var selectedAudioOrdinal = 0
        var selectedAudioStreamIndex: Int32 = -1
        var initialAudioOrdinal: Int?
    }

    private let lock = NSLock()
    private var state = State()

    func withLock<T>(_ body: (inout State) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&state)
    }
}

/// Thread-safe FIFO of ready-to-enqueue sample buffers.
nonisolated final class SampleBufferQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [CMSampleBuffer] = []
    private var finished = false

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.count
    }

    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return finished
    }

    func enqueue(_ buffer: CMSampleBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
    }

    func dequeue() -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }
        return buffers.isEmpty ? nil : buffers.removeFirst()
    }

    func markFinished() {
        lock.lock()
        finished = true
        lock.unlock()
    }

    func reset() {
        lock.lock()
        buffers.removeAll()
        finished = false
        lock.unlock()
    }
}
