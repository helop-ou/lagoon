import Foundation

/// One attempt's track selection: the ordinals the engine starts on, and
/// what recording the viewer's later choices needs.
///
/// Built per attempt and dropped with it, because every input (streams,
/// server defaults, the carry, remembered choices) describes one item on one
/// rung. Precedence, lowest first: automatic selection, the choice carried
/// from the previous episode, the choice remembered for the show, then the
/// bench hook.
nonisolated struct PlaybackTrackPlan {
    /// A track choice carried into the next episode, by description rather
    /// than ordinal: an extra track on one episode would shift every ordinal
    /// below it.
    struct Carry: Equatable {
        var audioLanguage: String?
        /// The file's title, not Jellyfin's display title, which reads the
        /// same on every untagged track and would match the first.
        var audioTitle: String?
        var subtitleLanguage: String?
        /// Jellyfin's display title, unlike audio: it names the forced and
        /// SDH flags, which tell same-language subtitle tracks apart.
        var subtitleDisplayTitle: String?
        /// Subtitles turned off is carried too, or the next episode
        /// reinstates the server default.
        var subtitlesOff: Bool
    }

    /// What a viewer's choice does to the remembered one.
    enum MemoryUpdate<Choice> {
        case remember(Choice)
        case forget
    }

    /// Embedded audio, in engine order.
    let audioStreams: [MediaStream]
    /// Embedded subtitles, then external ones, as the engine lists them.
    /// Subtitle search appends to it mid-play.
    private(set) var subtitleStreams: [MediaStream]
    let initialAudioOrdinal: Int?
    /// 0 is the engine's "no subtitles".
    let initialSubtitleOrdinal: Int?
    /// What automatic selection alone chose. A viewer landing back on it
    /// drops the remembered override.
    let automaticAudioOrdinal: Int?
    let automaticSubtitleOrdinal: Int?
    /// The show or film both choices are remembered under.
    let memoryScope: String
    /// The layouts the scope was resolved against. Held, not re-read when
    /// recording, so a start that fails partway cannot pair a new scope
    /// with old streams. The subtitle layout excludes searched tracks.
    let audioLayout: [AudioLayoutStream]
    let subtitleLayout: [SubtitleLayoutStream]

    /// `embeddedSubtitles` and `externalSubtitles` must be in engine order,
    /// and an external track the engine cannot open must be left out of
    /// both, or every later ordinal names the wrong track.
    init(
        audio: [MediaStream],
        embeddedSubtitles: [MediaStream],
        externalSubtitles: [MediaStream],
        serverDefaultAudioIndex: Int?,
        serverDefaultSubtitleIndex: Int?,
        settings: TrackSelectionSettings,
        originalLanguage: String?,
        captionDisplay: SystemCaptionDisplay,
        memoryScope: String,
        carry: Carry?,
        rememberedAudio: RememberedAudioChoice?,
        rememberedSubtitle: RememberedSubtitleChoice?,
        benchSubtitleLanguage: String? = nil
    ) {
        audioStreams = audio
        let subtitles = embeddedSubtitles + externalSubtitles
        subtitleStreams = subtitles
        self.memoryScope = memoryScope
        audioLayout = audio.map(Self.audioLayoutStream)
        subtitleLayout = subtitles.map(Self.subtitleLayoutStream)

        // Jellyfin names its default by stream index; the engine counts a
        // 1-based ordinal per kind.
        let serverDefaultAudio = serverDefaultAudioIndex.flatMap { index in
            audio.firstIndex { $0.index == index }.map { $0 + 1 }
        }
        var audioOrdinal = TrackSelectionPolicy.audioOrdinal(
            mode: settings.audioMode,
            candidates: audio.map(Self.selectionCandidate),
            serverDefault: serverDefaultAudio,
            preferredLanguages: settings.preferredAudioLanguages,
            originalLanguage: originalLanguage
        )
        automaticAudioOrdinal = audioOrdinal
        if let carry,
           let carried = AudioTrackMemoryPolicy.descriptiveOrdinal(
               matchingLanguage: carry.audioLanguage,
               title: carry.audioTitle,
               in: audioLayout
           ) {
            audioOrdinal = carried
        }
        // While it still matches a track here.
        if let rememberedAudio,
           let remembered = AudioTrackMemoryPolicy.ordinal(for: rememberedAudio, in: audioLayout) {
            audioOrdinal = remembered
        }
        initialAudioOrdinal = audioOrdinal

        var serverDefaultSubtitle: Int?
        if let index = serverDefaultSubtitleIndex {
            if let position = embeddedSubtitles.firstIndex(where: { $0.index == index }) {
                serverDefaultSubtitle = position + 1
            } else if let position = externalSubtitles.firstIndex(where: { $0.index == index }) {
                serverDefaultSubtitle = embeddedSubtitles.count + position + 1
            }
        }
        // Against the audio that will actually play, carry and memory
        // included.
        let selectedAudioLanguage = audioOrdinal.flatMap { ordinal in
            audio.indices.contains(ordinal - 1) ? audio[ordinal - 1].language : nil
        }
        let automaticSubtitle = TrackSelectionPolicy.subtitleOrdinal(
            mode: settings.subtitleMode,
            candidates: subtitles.map(Self.selectionCandidate),
            serverDefault: serverDefaultSubtitle,
            preferredLanguages: settings.preferredSubtitleLanguages,
            selectedAudioLanguage: selectedAudioLanguage,
            captionDisplay: captionDisplay
        )
        automaticSubtitleOrdinal = automaticSubtitle
        // A carry that finds no match falls back to the viewer's own mode,
        // as audio does, never to the server's default.
        var subtitleOrdinal = automaticSubtitle
        if let carry {
            if carry.subtitlesOff {
                subtitleOrdinal = SubtitleTrackMemoryPolicy.offOrdinal
            } else if let carried = Self.carriedSubtitleOrdinal(
                language: carry.subtitleLanguage,
                displayTitle: carry.subtitleDisplayTitle,
                in: subtitles
            ) {
                subtitleOrdinal = carried
            }
        }
        // While it still matches a track here or says none.
        if let rememberedSubtitle,
           let remembered = SubtitleTrackMemoryPolicy.ordinal(for: rememberedSubtitle, in: subtitleLayout) {
            subtitleOrdinal = remembered
        }
        // Bench hook: a forced language, so scripted runs always have cues
        // to count. "off" is explicit, or the system caption setting may
        // turn a track on.
        if let benchSubtitleLanguage, !benchSubtitleLanguage.isEmpty {
            if benchSubtitleLanguage == "off" {
                subtitleOrdinal = SubtitleTrackMemoryPolicy.offOrdinal
            } else if let ordinal = Self.carriedSubtitleOrdinal(
                language: benchSubtitleLanguage,
                displayTitle: nil,
                in: subtitles
            ) {
                subtitleOrdinal = ordinal
            }
        }
        initialSubtitleOrdinal = subtitleOrdinal
    }

    /// A subtitle track found by search, which the engine appends after
    /// every other.
    mutating func appendSearchedSubtitle(_ stream: MediaStream) {
        subtitleStreams.append(stream)
    }

    /// What to carry into the next episode, from the engine's live selection.
    /// No subtitle selected means off.
    func carry(selectedAudio: Int?, selectedSubtitle: Int?) -> Carry {
        let audio = selectedAudio.flatMap { Self.stream(at: $0, in: audioStreams) }
        let subtitle = selectedSubtitle.flatMap { Self.stream(at: $0, in: subtitleStreams) }
        return Carry(
            audioLanguage: audio?.language,
            audioTitle: audio?.title,
            subtitleLanguage: subtitle?.language,
            subtitleDisplayTitle: subtitle?.displayTitle,
            subtitlesOff: selectedSubtitle == nil
        )
    }

    /// What the viewer's audio pick does to the remembered choice, or nil
    /// when it cannot be recorded.
    ///
    /// Engine ordinals count delivered tracks and the layout counts source
    /// tracks. On remux or transcode they can differ, and then nothing is
    /// recorded.
    func audioMemoryUpdate(
        selected ordinal: Int,
        engineTrackCount: Int
    ) -> MemoryUpdate<RememberedAudioChoice>? {
        guard audioLayout.indices.contains(ordinal - 1),
              engineTrackCount == audioLayout.count else { return nil }
        switch AudioTrackMemoryPolicy.outcome(chosen: ordinal, automatic: automaticAudioOrdinal) {
        case .forget:
            return .forget
        case .remember(let ordinal):
            let stream = audioLayout[ordinal - 1]
            return .remember(RememberedAudioChoice(
                language: stream.language,
                title: stream.title,
                ordinal: ordinal,
                layout: AudioTrackMemoryPolicy.fingerprint(of: audioLayout)
            ))
        }
    }

    /// What the viewer's subtitle pick does to the remembered choice, or
    /// nil when it cannot be recorded. `selected` nil is off, a real choice.
    ///
    /// Search appends tracks mid-play, so the engine may list more than the
    /// layout. The prefix still lines up, and an appended track is not
    /// remembered.
    func subtitleMemoryUpdate(
        selected: Int?,
        engineTrackCount: Int
    ) -> MemoryUpdate<RememberedSubtitleChoice>? {
        guard engineTrackCount >= subtitleLayout.count else { return nil }
        let off = SubtitleTrackMemoryPolicy.offOrdinal
        let ordinal = selected ?? off
        guard ordinal == off || subtitleLayout.indices.contains(ordinal - 1) else { return nil }
        switch SubtitleTrackMemoryPolicy.outcome(chosen: ordinal, automatic: automaticSubtitleOrdinal) {
        case .forget:
            return .forget
        case .remember(let ordinal):
            let stream = ordinal == off ? nil : subtitleLayout[ordinal - 1]
            return .remember(RememberedSubtitleChoice(
                isOff: ordinal == off,
                language: stream?.language,
                title: stream?.title,
                ordinal: ordinal,
                layout: SubtitleTrackMemoryPolicy.fingerprint(of: subtitleLayout)
            ))
        }
    }

    /// Engine ordinals are 1-based and count per kind.
    private static func stream(at ordinal: Int, in streams: [MediaStream]) -> MediaStream? {
        streams.indices.contains(ordinal - 1) ? streams[ordinal - 1] : nil
    }

    /// Language and display title together, then the first track in the
    /// language: titles vary per episode.
    private static func carriedSubtitleOrdinal(
        language: String?,
        displayTitle: String?,
        in streams: [MediaStream]
    ) -> Int? {
        guard language != nil || displayTitle != nil else { return nil }
        if let exact = streams.firstIndex(where: {
            $0.language == language && $0.displayTitle == displayTitle
        }) {
            return exact + 1
        }
        guard let language else { return nil }
        return streams.firstIndex { $0.language == language }.map { $0 + 1 }
    }

    static func selectionCandidate(_ stream: MediaStream) -> TrackSelectionCandidate {
        TrackSelectionCandidate(
            language: stream.language,
            isDefault: stream.isDefault == true,
            isOriginal: stream.isOriginal == true,
            isForced: stream.isForced == true,
            isHearingImpaired: stream.isHearingImpaired == true,
            isTitledForced: TrackSelectionPolicy.titleNamesForcedTrack(stream.title)
        )
    }

    private static func audioLayoutStream(_ stream: MediaStream) -> AudioLayoutStream {
        AudioLayoutStream(
            codec: stream.codec,
            channels: stream.channels,
            language: stream.language,
            title: stream.title,
            isDefault: stream.isDefault == true
        )
    }

    private static func subtitleLayoutStream(_ stream: MediaStream) -> SubtitleLayoutStream {
        SubtitleLayoutStream(
            language: stream.language,
            title: stream.title,
            isForced: stream.isForced == true,
            isHearingImpaired: stream.isHearingImpaired == true,
            isExternal: stream.isExternal == true,
            isDefault: stream.isDefault == true
        )
    }
}
