import SwiftUI

/// Tabs shared by the live player's slide-down panel and the Debug component
/// gallery. Keeping this outside `CustomPlayerView` ensures the gallery is a
/// preview of production UI rather than a separately maintained imitation.
enum PlayerPanelTab: CaseIterable, Hashable {
    case info
    case video
    case audio
    case subtitles

    var title: String {
        switch self {
        case .info: String(localized: "Info")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .subtitles: String(localized: "Subtitles")
        }
    }
}

/// The panel keeps using the live player's focus namespace so opening and
/// closing it can hand focus back to the video surface without a dead frame.
enum PlayerControlFocus: Hashable {
    case surface
    /// The transport's speed control. It lives outside the panel, so it is
    /// its own case rather than a `track`.
    case speed
    case tab(PlayerPanelTab)
    case track(String)
}

/// The real Info · Video · Audio · Subtitles panel used during playback.
/// Values and actions are injected so Debug settings can exercise the same
/// focusable controls with representative data and harmless local state.
struct PlayerControlPanel: View {
    @Binding var selectedTab: PlayerPanelTab
    let focus: FocusState<PlayerControlFocus?>.Binding
    let info: PlayerItemInfo
    let audioTracks: [PlayerTrack]
    let subtitleTracks: [PlayerTrack]
    let audioDelay: Double
    var subtitleSearch: SubtitleSearchCoordinator? = nil
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var onTogglePictureInPicture: (() -> Void)? = nil
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void
    let onSetAudioDelay: (Double) -> Void
    var onDismiss: (() -> Void)? = nil

    private static var subtitleOffID: String { "subtitle-off" }
    /// Room a focused track row needs before its ScrollView clips it.
    private var rowFocusInset: CGFloat { 20 }
    /// A track row at rest; the card sizes itself from this plus the gap.
    private var trackRowHeight: CGFloat { 62 }
    /// Keep large libraries scrollable without letting the sheet dominate
    /// the video behind it.
    private var trackListMaxHeight: CGFloat { 360 }

    var body: some View {
        VStack(spacing: Metrics.Space.xl) {
            VStack(spacing: Metrics.Space.l) {
                // Only the sibling glass tabs need shared sampling and
                // blending. Keeping the material sheet and its potentially
                // long track tree outside this specialized container avoids
                // an unnecessary glass-compositing subtree on every tab move.
                GlassEffectContainer(spacing: Metrics.Space.s) {
                    tabBar
                }

                tabCard
            }
            .frame(maxWidth: PlayerPanelMetrics.maxWidth)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, Metrics.screenGutter)

            Spacer()
        }
        .padding(.top, Metrics.railTopPadding)
        .defaultFocus(focus, .tab(selectedTab))
        #if os(iOS)
        .background(
            // Dim + tap-out on iOS; tvOS closes via Menu.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { onDismiss?() }
        )
        #endif
    }

    // Native buttons only: the system's focused lozenge IS the Infuse
    // white-pill look — never draw custom focus chrome around it. The
    // active tab keeps bold text once focus moves down into the card.
    private var tabBar: some View {
        HStack(spacing: Metrics.Space.m) {
            ForEach(PlayerPanelTab.allCases, id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    // Always bold. Selection follows focus here, so the
                    // lozenge already says which tab is active.
                    Text(tab.title)
                        .fontWeight(.bold)
                }
                .buttonStyle(.glass)
                .focused(focus, equals: .tab(tab))
                .accessibilityIdentifier("player.tab.\(String(describing: tab))")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tabCard: some View {
        Group {
            switch selectedTab {
            case .info: infoCard
            case .video: videoCard
            case .audio: audioCard
            case .subtitles: subtitleCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(PlayerPanelMetrics.cardPadding)
        // Native focused controls choose their own label color. Forcing a
        // foreground style here makes their text disappear in the lozenge.
        // Apple reserves Liquid Glass for controls/navigation. This is the
        // content sheet beneath those glass tabs, so tvOS's regular overlay
        // material preserves that hierarchy and adapts for contrast and
        // Reduce Transparency without nesting glass inside glass.
        .background(
            .regularMaterial,
            in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.panelCornerRadius)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }

    private var infoCard: some View {
        HStack(alignment: .top, spacing: Metrics.Space.l) {
            CachedAsyncImage(url: info.posterURL, maxPixelSize: 400) { image in
                image
                    .resizable()
                    // Respect the downloaded artwork's own pixels. The
                    // surrounding frame supplies the poster ratio without
                    // stretching or zoom-cropping the image itself.
                    .scaledToFit()
            } placeholder: {
                Color.white.opacity(0.1)
            }
            .frame(
                width: PlayerPanelMetrics.posterWidth,
                height: PlayerPanelMetrics.posterHeight
            )
            .background(.white.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: Metrics.cardArtRadius))

            VStack(alignment: .leading, spacing: Metrics.Space.s) {
                Text(combinedTitle)
                    .font(.headline)
                if let overview = info.overview {
                    Text(overview)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if !info.facts.isEmpty {
                    Text(info.facts.joined(separator: "   "))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                #if os(iOS)
                if let onTogglePictureInPicture {
                    Button(action: onTogglePictureInPicture) {
                        Label(
                            isPictureInPictureActive ? "Stop Picture in Picture" : "Picture in Picture",
                            systemImage: isPictureInPictureActive ? "pip.exit" : "pip.enter"
                        )
                        .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.glass)
                    .fixedSize()
                    .disabled(!isPictureInPicturePossible && !isPictureInPictureActive)
                    .focused(focus, equals: .track("picture-in-picture"))
                    .accessibilityIdentifier("player.pictureInPicture")
                }
                #endif
            }
            Spacer(minLength: 0)
            #if os(iOS)
            AirPlayRoutePicker()
                .frame(width: 44, height: 44)
                .accessibilityLabel("AirPlay")
            #endif
        }
    }

    private var combinedTitle: String {
        if let subtitle = info.subtitle {
            return "\(info.title) – \(subtitle)"
        }
        return info.title
    }

    private var audioCard: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: Metrics.Space.xl) {
            trackCard(rows: audioTracks.map { ($0.id, $0.displayName, $0.isSelected) }) { rowID in
                onSelectAudioTrack(audioTracks.first(where: { $0.id == rowID })?.engineID)
            }
            // One or two audio tracks should read as a compact list, not a
            // half-screen column. Long libraries still scroll vertically.
            .frame(
                width: PlayerPanelMetrics.audioTrackColumnWidth,
                alignment: .topLeading
            )
            .padding(.trailing, Metrics.Space.l)
            // A standalone vertical Divider greedily accepts the sheet's
            // full proposed height. Keeping it in this content-sized overlay
            // makes the Audio sheet follow its actual rows instead.
            .overlay(alignment: .trailing) {
                Divider()
            }

            audioOptions
                .frame(
                    width: PlayerPanelMetrics.audioOptionsColumnWidth,
                    alignment: .topLeading
                )

            Spacer(minLength: 0)
        }
        #else
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            trackCard(rows: audioTracks.map { ($0.id, $0.displayName, $0.isSelected) }) { rowID in
                onSelectAudioTrack(audioTracks.first(where: { $0.id == rowID })?.engineID)
            }
            audioOptions
        }
        #endif
    }

    private var audioOptions: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            cardHeader("Options")
            HStack(spacing: Metrics.Space.m) {
                Text("Audio Delay")
                    .font(.callout)
                    .fixedSize()
                    .layoutPriority(1)
                Spacer()
                Button {
                    onSetAudioDelay(audioDelay - 0.1)
                } label: {
                    Image(systemName: "minus")
                }
                .accessibilityIdentifier("player.audioDelay.decrease")
                Text(String(format: "%+.1f s", audioDelay))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(audioDelay == 0 ? .secondary : .primary)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityIdentifier("player.audioDelay.value")
                Button {
                    onSetAudioDelay(audioDelay + 0.1)
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("player.audioDelay.increase")
            }
        }
    }

    private var videoCard: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            cardHeader("Track")
            HStack(spacing: Metrics.Space.s) {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                Text(info.videoSummary ?? String(localized: "Unknown video track"))
                    .font(.callout)
            }
        }
    }

    private var subtitleCard: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            if let subtitleSearch {
                cardHeader("Find Subtitles")
                VStack(alignment: .leading, spacing: Metrics.Space.m) {
                    Button {
                        subtitleSearch.startSearch()
                    } label: {
                        Label("Search subtitles…", systemImage: "magnifyingglass")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(subtitleSearch.phase.isBusy)
                    .focused(focus, equals: .track("subtitle-search"))
                    .accessibilityIdentifier("player.subtitleSearch")

                    Menu {
                        Button("Preferred Languages") {
                            subtitleSearch.selectLanguage(nil)
                        }
                        ForEach(subtitleSearch.languageChoices, id: \.self) { language in
                            Button(SubtitlePreferencesStore.displayName(for: language)) {
                                subtitleSearch.selectLanguage(language)
                            }
                        }
                    } label: {
                        HStack(spacing: Metrics.Space.m) {
                            Label(subtitleSearch.selectedLanguageTitle, systemImage: "globe")
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.caption.bold())
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(subtitleSearch.phase.isBusy)
                    .focused(focus, equals: .track("subtitle-search-language"))
                    .accessibilityIdentifier("player.subtitleSearch.language")
                }

                subtitleSearchStatus(subtitleSearch)

                if let source = subtitleSearch.activeSource, !subtitleSearch.results.isEmpty {
                    Text(subtitleSourceCaption(source, search: subtitleSearch))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !subtitleSearch.results.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: Metrics.Space.m) {
                            ForEach(subtitleSearch.results) { result in
                                Button {
                                    subtitleSearch.startDownload(result)
                                } label: {
                                    HStack(spacing: Metrics.Space.m) {
                                        VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                                            Text(result.name ?? String(localized: "Subtitle"))
                                                .lineLimit(1)
                                            Text(subtitleResultDetails(result))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 0)
                                        if subtitleSearch.phase == .downloading(result.id) {
                                            ProgressView()
                                        } else {
                                            Image(systemName: "arrow.down.circle")
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .disabled(subtitleSearch.phase.isBusy)
                                .focused(focus, equals: .track("subtitle-result-\(result.id)"))
                                .accessibilityIdentifier("player.subtitleResult.\(result.id)")
                            }
                        }
                        .padding(.horizontal, rowFocusInset)
                        .padding(.vertical, rowFocusInset)
                    }
                    .padding(.horizontal, -rowFocusInset)
                    .frame(maxHeight: 280)
                }

                Divider()
            }

            // Discovery stays above this potentially very long list. A
            // library with dozens of embedded/external tracks should still
            // reach Find Subtitles with one Down press from the tab bar.
            trackCard(
                rows: [(Self.subtitleOffID, String(localized: "Off"), !subtitleTracks.contains(where: \.isSelected))]
                    + subtitleTracks.map { ($0.id, subtitleTrackName($0), $0.isSelected) }
            ) { rowID in
                if rowID == Self.subtitleOffID {
                    onSelectSubtitleTrack(nil)
                } else {
                    onSelectSubtitleTrack(subtitleTracks.first(where: { $0.id == rowID })?.engineID)
                }
            }
        }
    }

    @ViewBuilder
    private func subtitleSearchStatus(_ search: SubtitleSearchCoordinator) -> some View {
        switch search.phase {
        case .idle:
            EmptyView()
        case .searching:
            HStack {
                ProgressView()
                Text("Searching configured providers…")
                    .foregroundStyle(.secondary)
            }
        case .noProvider:
            Label("No subtitle provider is available on this server.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .notPermitted:
            Label(
                SubtitleDownloadError.notPermitted.localizedDescription,
                systemImage: "lock"
            )
            .foregroundStyle(.secondary)
        case .providerNotConfigured:
            Label(
                OpenSubtitlesError.notConfigured.localizedDescription
                    + String(localized: " Add one in Settings → Subtitles."),
                systemImage: "key"
            )
            .foregroundStyle(.secondary)
        case .noResults:
            Text("No matching subtitles were found.")
                .foregroundStyle(.secondary)
        case .failed(let message):
            Label("Search failed: \(message)", systemImage: "wifi.exclamationmark")
                .foregroundStyle(.secondary)
        case .downloading:
            EmptyView()
        case .downloadFailed(let message):
            Label("Download failed: \(message)", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.secondary)
        case .downloaded:
            Label("Downloaded and selected", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        }
    }

    private func subtitleTrackName(_ track: PlayerTrack) -> String {
        var labels = [track.displayName]
        if track.source == .downloaded {
            labels.append(String(localized: "Downloaded"))
        } else if track.source == .external {
            labels.append(String(localized: "External"))
        }
        if track.isForced { labels.append(String(localized: "Forced")) }
        if track.isHearingImpaired { labels.append(String(localized: "SDH")) }
        return labels.joined(separator: " · ")
    }

    /// Where these results came from, and — for the direct provider — what
    /// is left of today's allowance, since it is small enough to matter.
    private func subtitleSourceCaption(
        _ source: SubtitleSourceKind,
        search: SubtitleSearchCoordinator
    ) -> String {
        switch source {
        case .jellyfin:
            return String(localized: "From your Jellyfin server · saved to the library")
        case .openSubtitles:
            if let remaining = search.providerRemainingDownloads {
                return String(localized: "From OpenSubtitles · this player only · \(remaining) downloads left today")
            }
            return String(localized: "From OpenSubtitles · this player only")
        }
    }

    private func subtitleResultDetails(_ result: SubtitleCandidate) -> String {
        var details: [String] = []
        if let language = result.language {
            details.append(SubtitlePreferencesStore.displayName(for: language))
        }
        if let provider = result.providerName { details.append(provider) }
        if let format = result.format { details.append(format.uppercased()) }
        // An exact-release match is the single most useful thing to know
        // about a result, so it is called out rather than left implicit.
        if result.isHashMatch { details.append(String(localized: "Exact match")) }
        if result.isForced { details.append(String(localized: "Forced")) }
        if result.isHearingImpaired { details.append(String(localized: "SDH")) }
        if result.isAITranslated || result.isMachineTranslated {
            details.append(String(localized: "Machine translated"))
        }
        if let downloads = result.downloadCount { details.append("↓ \(downloads)") }
        return details.joined(separator: " · ")
    }

    private func trackCard(
        rows: [(id: String, name: String, selected: Bool)],
        onSelect: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            cardHeader("Tracks")
            ScrollView {
                // Libraries can legitimately expose dozens of subtitle
                // streams. Keep offscreen buttons out of the focus/layout
                // tree until scrolling approaches them.
                LazyVStack(alignment: .leading, spacing: Metrics.Space.m) {
                    ForEach(rows, id: \.id) { row in
                        Button {
                            onSelect(row.id)
                        } label: {
                            HStack(spacing: Metrics.Space.s) {
                                Image(systemName: "checkmark")
                                    .font(.caption.bold())
                                    .opacity(row.selected ? 1 : 0)
                                Text(row.name)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .focused(focus, equals: .track(row.id))
                        .accessibilityIdentifier("player.track.\(row.id)")
                    }
                }
                .padding(.horizontal, rowFocusInset)
                .padding(.vertical, rowFocusInset)
            }
            .padding(.horizontal, -rowFocusInset)
            .frame(
                maxHeight: min(
                    CGFloat(rows.count) * (trackRowHeight + Metrics.Space.m) + rowFocusInset * 2,
                    trackListMaxHeight
                )
            )
        }
    }

    private func cardHeader(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .textCase(.uppercase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, Metrics.Space.m)
    }
}

private enum PlayerPanelMetrics {
    #if os(tvOS)
    static let maxWidth: CGFloat = 1_440
    static let cardPadding: CGFloat = 24
    static let posterWidth: CGFloat = 112
    static let audioTrackColumnWidth: CGFloat = 720
    static let audioOptionsColumnWidth: CGFloat = 520
    #else
    static let maxWidth: CGFloat = .infinity
    static let cardPadding: CGFloat = 20
    static let posterWidth: CGFloat = 88
    #endif

    static let posterHeight = posterWidth * 1.5
}

/// Observation boundary between the playback clock and the comparatively
/// expensive panel hierarchy. `CustomPlayerView` reads position/buffering
/// several times a second; this host only observes the engine properties the
/// panel actually displays. Equatable identity prevents unrelated parent
/// updates from walking the tabs and track rows again.
struct PlayerControlPanelHost: View, Equatable {
    let engine: any PlayerEngine
    @Binding var selectedTab: PlayerPanelTab
    let focus: FocusState<PlayerControlFocus?>.Binding
    let info: PlayerItemInfo
    var subtitleSearch: SubtitleSearchCoordinator? = nil
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var onTogglePictureInPicture: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine === rhs.engine
            && lhs.info == rhs.info
            && lhs.subtitleSearch === rhs.subtitleSearch
            && lhs.isPictureInPicturePossible == rhs.isPictureInPicturePossible
            && lhs.isPictureInPictureActive == rhs.isPictureInPictureActive
    }

    var body: some View {
        PlayerControlPanel(
            selectedTab: $selectedTab,
            focus: focus,
            info: info,
            audioTracks: engine.audioTracks,
            subtitleTracks: engine.subtitleTracks,
            audioDelay: engine.audioDelay,
            subtitleSearch: subtitleSearch,
            isPictureInPicturePossible: isPictureInPicturePossible,
            isPictureInPictureActive: isPictureInPictureActive,
            onTogglePictureInPicture: onTogglePictureInPicture,
            onSelectAudioTrack: engine.selectAudioTrack,
            onSelectSubtitleTrack: engine.selectSubtitleTrack,
            onSetAudioDelay: engine.setAudioDelay,
            onDismiss: onDismiss
        )
    }
}
