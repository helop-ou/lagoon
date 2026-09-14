import SwiftUI

/// Tabs shared by the live player's slide-down panel and the Debug component
/// gallery. Keeping this outside `CustomPlayerView` ensures the gallery is a
/// preview of production UI rather than a separately maintained imitation.
enum PlayerPanelTab: CaseIterable, Hashable {
    case info
    case video
    case audio
    case subtitles
    case together

    var title: String {
        switch self {
        case .info: String(localized: "Info")
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .subtitles: String(localized: "Subtitles")
        case .together: String(localized: "Together")
        }
    }

    /// The tabs actually on offer. Together exists only while a group
    /// does, and every place that walks the tabs — the strip, the tvOS
    /// left/right grammar — must walk *this* rather than `allCases`, or
    /// arrowing right lands on a tab that is not drawn (HEL-172).
    static func offered(inGroup: Bool) -> [PlayerPanelTab] {
        inGroup ? allCases : allCases.filter { $0 != .together }
    }
}

/// What the Together tab draws (HEL-172).
///
/// A value rather than the store: the panel host is `Equatable` so the
/// playback clock cannot walk its tabs and track rows, and that boundary
/// only works if everything it shows can be compared.
nonisolated struct PlayerTogetherState: Equatable, Sendable {
    let groupName: String
    let participants: [String]
    let state: SyncPlayGroupState
    /// This member has taken itself out of the group's readiness
    /// accounting: it is started with everyone else and no longer holds
    /// them up when it is behind.
    let ignoresWait: Bool

    var stateTitle: String { SyncPlayStateCopy.title(for: state) }
}

/// The panel keeps using the live player's focus namespace so opening and
/// closing it can hand focus back to the video surface without a dead frame.
enum PlayerControlFocus: Hashable {
    case surface
    case tab(PlayerPanelTab)
    case track(String)
}

/// The real Info · Video · Audio · Subtitles panel used during playback,
/// with a fifth Together tab while a Watch Together group owns the session.
/// Values and actions are injected so Debug settings can exercise the same
/// focusable controls with representative data and harmless local state.
struct PlayerControlPanel: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Binding var selectedTab: PlayerPanelTab
    let focus: FocusState<PlayerControlFocus?>.Binding
    let info: PlayerItemInfo
    let audioTracks: [PlayerTrack]
    let subtitleTracks: [PlayerTrack]
    let audioDelay: Double
    let playbackRate: Double
    var subtitleSearch: SubtitleSearchCoordinator? = nil
    var subtitleLoadState: SubtitleLoadState = .idle
    var onRetrySubtitleLoad: (() -> Void)? = nil
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var onTogglePictureInPicture: (() -> Void)? = nil
    /// Nil outside a group, which is also what hides the Together tab.
    var together: PlayerTogetherState? = nil
    var onLeaveGroup: (() -> Void)? = nil
    var onSetIgnoreWait: ((Bool) -> Void)? = nil
    let onSelectAudioTrack: (Int?) -> Void
    let onSelectSubtitleTrack: (Int?) -> Void
    let onSetAudioDelay: (Double) -> Void
    let onSetPlaybackRate: (Double) -> Void
    var onDismiss: (() -> Void)? = nil

    private static var togetherIgnoreWaitID: String { "together-ignore-wait" }
    private static var togetherLeaveID: String { "together-leave" }
    private static var subtitleOffID: String { "subtitle-off" }
    private static var subtitleSearchID: String { "subtitle-search" }
    private static var subtitleSearchCloseID: String { "subtitle-search-close" }
    private static var subtitleResultPrefix: String { "subtitle-result-" }
    /// Room a focused track row needs before its ScrollView clips it.
    private var rowFocusInset: CGFloat { 20 }
    /// A track row at rest; the card sizes itself from this plus the gap.
    private var trackRowHeight: CGFloat { 62 }
    /// Keep large libraries scrollable without letting the sheet dominate
    /// the video behind it.
    private var trackListMaxHeight: CGFloat { 360 }
    /// A result row at rest: its title over the provider/format detail line,
    /// measured in the panel rather than guessed, so a capped list ends on a
    /// row boundary instead of a clipped sliver.
    private var resultRowHeight: CGFloat { 99 }
    /// Results are the whole tab while browsing, not a strip above the track
    /// list, so they take considerably more of the sheet than tracks do: five
    /// rows and their focus insets, which is what fits above the safe area.
    private var resultListMaxHeight: CGFloat {
        #if os(tvOS)
        583
        #else
        320
        #endif
    }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            Form {
                Section { tabBar }
                Section { tabContent }
            }
            .navigationTitle("Playback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "xmark", role: .close) { onDismiss?() }
                        .accessibilityIdentifier("player.panel.close")
                }
            }
        }
        #else
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
        // Both edges of the subtitle mode switch remove the row focus is
        // sitting on, so focus has to be placed deliberately or tvOS drops it
        // somewhere arbitrary in the card.
        .onChange(of: subtitleSearch?.isBrowsingResults) { _, isBrowsing in
            moveFocusForSubtitleBrowsing(isBrowsing)
        }
        #endif
    }

    #if os(tvOS)
    /// Leaving the browser lands on the track that was just downloaded, and
    /// otherwise back on Search — the control the viewer opened it from.
    /// Entering it moves the same press onto Done, which takes Search's place.
    private func moveFocusForSubtitleBrowsing(_ isBrowsing: Bool?) {
        guard let isBrowsing, case .track(let id)? = focus.wrappedValue else { return }
        let target: PlayerControlFocus?
        if isBrowsing {
            target = id == Self.subtitleSearchID ? .track(Self.subtitleSearchCloseID) : nil
        } else if id == Self.subtitleSearchCloseID || id.hasPrefix(Self.subtitleResultPrefix) {
            if subtitleSearch?.phase == .downloaded,
               let selected = subtitleTracks.first(where: \.isSelected) {
                target = .track(selected.id)
            } else {
                target = .track(Self.subtitleSearchID)
            }
        } else {
            target = nil
        }
        guard let target else { return }
        // The control being claimed is created by this same update and is not
        // in the focus system yet, so an immediate assignment is dropped and
        // tvOS parks focus back on the tab bar. Claim it on the next turn.
        Task { focus.wrappedValue = target }
    }
    #endif

    // Native buttons only: the system's focused lozenge IS the Infuse
    // white-pill look — never draw custom focus chrome around it. The
    // active tab keeps bold text once focus moves down into the card.
    @ViewBuilder
    private var tabBar: some View {
        #if os(iOS)
        if dynamicTypeSize.isAccessibilitySize {
            tabPicker.pickerStyle(.menu)
        } else {
            tabPicker.pickerStyle(.segmented)
        }
        #else
        HStack(spacing: Metrics.Space.m) {
            ForEach(tabs, id: \.self) { tab in
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
        #endif
    }

    private var tabs: [PlayerPanelTab] { PlayerPanelTab.offered(inGroup: together != nil) }

    private var tabPicker: some View {
        Picker("Options", selection: $selectedTab) {
            ForEach(tabs, id: \.self) { tab in
                Text(tab.title).tag(tab)
                    .accessibilityIdentifier("player.tab.\(String(describing: tab))")
            }
        }
        .accessibilityIdentifier("player.panel.tabs")
    }

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .info: infoCard
        case .video: videoCard
        case .audio: audioCard
        case .subtitles: subtitleCard
        case .together: togetherCard
        }
    }

    /// Who is in the room, what the room is doing, and the two decisions
    /// that belong to this member alone: whether to hold everyone up, and
    /// whether to stay (HEL-172). Everything about *playback* is the
    /// group's and is not offered here.
    @ViewBuilder
    private var togetherCard: some View {
        if let together {
            VStack(alignment: .leading, spacing: Metrics.Space.l) {
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text(together.groupName)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(together.stateTitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("player.together.group")

                cardHeader("In the Group")
                ForEach(together.participants, id: \.self) { participant in
                    Label(participant, systemImage: "person.fill")
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                togetherOptions(together)
            }
        }
    }

    @ViewBuilder
    private func togetherOptions(_ together: PlayerTogetherState) -> some View {
        let ignoresWait = Binding(
            get: { together.ignoresWait },
            set: { onSetIgnoreWait?($0) }
        )

        Toggle("Ignore Waiting", isOn: ignoresWait)
            #if os(tvOS)
            .focused(focus, equals: .track(Self.togetherIgnoreWaitID))
            #endif
            .accessibilityIdentifier("player.together.ignoreWait")

        Text("On, this device is started with the others and no longer holds them up when it falls behind.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

        Button {
            onLeaveGroup?()
        } label: {
            Label("Leave Group", systemImage: "rectangle.portrait.and.arrow.right")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(tvOS)
        .focused(focus, equals: .track(Self.togetherLeaveID))
        #else
        // Several controls share this Form row; an automatic button would
        // also fire its neighbour.
        .buttonStyle(.borderless)
        #endif
        .accessibilityIdentifier("player.together.leave")
    }

    private var tabCard: some View {
        tabContent
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

    @ViewBuilder
    private var infoCard: some View {
        #if os(iOS)
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            Text(combinedTitle)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            if let overview = info.overview {
                Text(overview)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !info.facts.isEmpty {
                Text(info.facts.joined(separator: " · "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AdaptiveActionStack {
                if let onTogglePictureInPicture {
                    Button(action: onTogglePictureInPicture) {
                        Label(
                            isPictureInPictureActive ? "Stop Picture in Picture" : "Picture in Picture",
                            systemImage: isPictureInPictureActive ? "pip.exit" : "pip.enter"
                        )
                    }
                    .buttonStyle(.glass)
                    .labelStyle(.titleAndIcon)
                    .fixedSize(horizontal: false, vertical: true)
                    .disabled(!isPictureInPicturePossible && !isPictureInPictureActive)
                    .accessibilityIdentifier("player.pictureInPicture")
                }
                AirPlayRoutePicker()
                    .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                    .accessibilityLabel("AirPlay")
            }
        }
        #else
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
        #endif
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
            #if os(iOS)
            Stepper {
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text("Audio Delay")
                    Text(String(format: "%+.1f s", audioDelay))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } onIncrement: {
                onSetAudioDelay(audioDelay + 0.1)
            } onDecrement: {
                onSetAudioDelay(audioDelay - 0.1)
            }
            .accessibilityValue(String(format: "%.1f seconds", audioDelay))
            .accessibilityIdentifier("player.audioDelay")
            #else
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
            #endif
        }
    }

    /// The same split the Audio tab uses: what is playing on the left, the
    /// options for it on the right. Speed is a short, fixed set of values, so
    /// its options are a row rather than a column — six stacked rows made the
    /// card taller than the sheet needed to be, for six numbers.
    private var videoCard: some View {
        #if os(tvOS)
        HStack(alignment: .top, spacing: Metrics.Space.xl) {
            videoTrack
                .frame(
                    width: PlayerPanelMetrics.videoTrackColumnWidth,
                    alignment: .topLeading
                )
                .padding(.trailing, Metrics.Space.l)
                // Same content-sized overlay as the Audio tab: a standalone
                // vertical Divider would take the sheet's full proposed
                // height.
                .overlay(alignment: .trailing) {
                    Divider()
                }

            // Takes whatever the track column leaves rather than a width of
            // its own, and declares itself a focus section. The Audio tab does
            // not need to: its left column is a list of focusable rows, so
            // there is always something directly under the tab. This card's
            // left column is a summary line, so without the section Down from
            // the tab finds nothing below it and focus never enters the card.
            videoOptions
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .focusSection()
        }
        #else
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            videoTrack
            videoOptions
        }
        #endif
    }

    private var videoTrack: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            cardHeader("Track")
            HStack(spacing: Metrics.Space.s) {
                Image(systemName: "checkmark")
                    .font(.caption.bold())
                Text(info.videoSummary ?? String(localized: "Unknown video track"))
                    .font(.callout)
            }
        }
    }

    /// Shaped exactly like the Audio tab's delay row — label, value, a pair
    /// of steppers — because it is the same kind of control: one value from a
    /// short ordered scale. Six selectable options made the card either tall
    /// (stacked) or wide (a row), and neither earned the space for something
    /// that is almost always left at 1×.
    private var videoOptions: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            cardHeader("Options")
            #if os(iOS)
            Stepper {
                VStack(alignment: .leading, spacing: Metrics.Space.xs) {
                    Text("Playback Speed")
                    Text(PlaybackRatePolicy.title(playbackRate))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } onIncrement: {
                onSetPlaybackRate(PlaybackRatePolicy.stepped(from: playbackRate, by: 1))
            } onDecrement: {
                onSetPlaybackRate(PlaybackRatePolicy.stepped(from: playbackRate, by: -1))
            }
            .accessibilityValue(String(format: "%.2f times normal speed", playbackRate))
            .accessibilityIdentifier("player.playbackRate")
            #else
            HStack(spacing: Metrics.Space.m) {
                Text("Playback Speed")
                    .font(.callout)
                    .fixedSize()
                    .layoutPriority(1)
                Spacer()
                Button {
                    onSetPlaybackRate(PlaybackRatePolicy.stepped(from: playbackRate, by: -1))
                } label: {
                    Image(systemName: "minus")
                }
                .accessibilityIdentifier("player.playbackRate.decrease")
                Text(PlaybackRatePolicy.title(playbackRate))
                    .font(.callout.monospacedDigit())
                    // Dimmed at the default, exactly as a zero delay is: it
                    // says "nothing to see here" without hiding the value.
                    .foregroundStyle(playbackRate == 1 ? .secondary : .primary)
                    .fixedSize()
                    .layoutPriority(1)
                    .accessibilityIdentifier("player.playbackRate.value")
                Button {
                    onSetPlaybackRate(PlaybackRatePolicy.stepped(from: playbackRate, by: 1))
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("player.playbackRate.increase")
            }
            #endif
        }
    }

    /// The tab is either choosing a track or browsing search results, never
    /// both. Stacking results above the tracks gave the candidates two visible
    /// rows and left no way back to a track list they were now burying
    /// (HEL-150).
    private var subtitleCard: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            if let subtitleSearch, subtitleSearch.isBrowsingResults {
                subtitleResultsBrowser(subtitleSearch)
            } else {
                subtitleTrackChooser
            }
        }
    }

    @ViewBuilder
    private var subtitleTrackChooser: some View {
        subtitleLoadStatus
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
                .focused(focus, equals: .track(Self.subtitleSearchID))
                .accessibilityIdentifier("player.subtitleSearch")

                subtitleLanguageMenu(subtitleSearch)
            }

            // Only the phases that outlive the browser reach this: what a
            // finished download did, or why one could not start.
            subtitleSearchStatus(subtitleSearch)

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

    /// Done takes the Search button's place, so the press that opened the
    /// browser is also the press that leaves it. Menu does the same thing one
    /// level up, exactly as it closes the panel before it would exit playback.
    @ViewBuilder
    private func subtitleResultsBrowser(_ search: SubtitleSearchCoordinator) -> some View {
        cardHeader("Subtitle Results")

        #if os(tvOS)
        HStack(spacing: Metrics.Space.m) {
            subtitleResultsCloseButton(search)
                .frame(maxWidth: .infinity)
            subtitleLanguageMenu(search)
                .frame(maxWidth: .infinity)
        }
        #else
        subtitleResultsCloseButton(search)
        subtitleLanguageMenu(search)
        #endif

        subtitleSearchStatus(search)

        if !search.results.isEmpty {
            Text(String(localized: "From your Jellyfin server · saved to the library"))
                .font(.caption)
                .foregroundStyle(.secondary)

            subtitleResultList(search)
        }
    }

    private func subtitleResultsCloseButton(_ search: SubtitleSearchCoordinator) -> some View {
        Button {
            search.closeResults()
        } label: {
            Label("Done", systemImage: "xmark")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .focused(focus, equals: .track(Self.subtitleSearchCloseID))
        .accessibilityIdentifier("player.subtitleSearch.close")
        #if os(iOS)
        // Multiple controls share this Form row; an automatic button would
        // also fire the neighbouring one.
        .buttonStyle(.borderless)
        #endif
    }

    private func subtitleLanguageMenu(_ search: SubtitleSearchCoordinator) -> some View {
        Menu {
            Button("Preferred Languages") {
                search.selectLanguage(nil)
            }
            ForEach(search.languageChoices, id: \.self) { language in
                Button(SubtitlePreferencesStore.displayName(for: language)) {
                    search.selectLanguage(language)
                }
            }
        } label: {
            HStack(spacing: Metrics.Space.m) {
                Label(search.selectedLanguageTitle, systemImage: "globe")
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.bold())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .disabled(search.phase.isBusy)
        .focused(focus, equals: .track("subtitle-search-language"))
        .accessibilityIdentifier("player.subtitleSearch.language")
    }

    private func subtitleResultList(_ search: SubtitleSearchCoordinator) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Space.m) {
                ForEach(search.results) { result in
                    Button {
                        search.startDownload(result)
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
                            if search.phase == .downloading(result.id) {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.down.circle")
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .disabled(search.phase.isBusy)
                    .focused(focus, equals: .track("\(Self.subtitleResultPrefix)\(result.id)"))
                    .accessibilityIdentifier("player.subtitleResult.\(result.id)")
                    #if os(iOS)
                    .buttonStyle(.borderless)
                    #endif
                }
            }
            .padding(.horizontal, rowFocusInset)
            .padding(.vertical, rowFocusInset)
        }
        .padding(.horizontal, -rowFocusInset)
        .frame(
            maxHeight: min(
                CGFloat(search.results.count) * (resultRowHeight + Metrics.Space.m) + rowFocusInset * 2,
                resultListMaxHeight
            )
        )
    }

    @ViewBuilder
    private var subtitleLoadStatus: some View {
        switch subtitleLoadState {
        case .idle:
            EmptyView()
        case .loading(_, let title):
            HStack(spacing: Metrics.Space.m) {
                ProgressView()
                Text("Loading \(title)…")
                    .foregroundStyle(.secondary)
            }
            .accessibilityIdentifier("player.subtitleLoad.loading")
        case .failed(_, let title, let message):
            VStack(alignment: .leading, spacing: Metrics.Space.m) {
                Label("Couldn't load \(title)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("player.subtitleLoad.error")
                if let onRetrySubtitleLoad {
                    Button(action: onRetrySubtitleLoad) {
                        Text("Retry Subtitle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                        .focused(focus, equals: .track("subtitle-retry"))
                        .accessibilityIdentifier("player.subtitleLoad.retry")
                        #if os(iOS)
                        // Multiple controls share this Form row. An automatic
                        // button can also activate the adjacent Search action.
                        .buttonStyle(.borderless)
                        #endif
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
        #if os(iOS)
        VStack(alignment: .leading, spacing: Metrics.Space.s) {
            cardHeader("Tracks")
            ForEach(rows, id: \.id) { row in
                Button {
                    onSelect(row.id)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.Space.s) {
                        Text(row.name)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: Metrics.Space.s)
                        if row.selected { Image(systemName: "checkmark") }
                    }
                    .frame(minHeight: Metrics.touchTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityAddTraits(row.selected ? [.isSelected] : [])
                .accessibilityIdentifier("player.track.\(row.id)")
            }
        }
        #else
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
        #endif
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
    /// The video track summary is one line; the speeds take the rest.
    static let videoTrackColumnWidth: CGFloat = 560
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
    @PlayerEngineRef var engine: any PlayerEngine
    @Binding var selectedTab: PlayerPanelTab
    let focus: FocusState<PlayerControlFocus?>.Binding
    let info: PlayerItemInfo
    var subtitleSearch: SubtitleSearchCoordinator? = nil
    var isPictureInPicturePossible = false
    var isPictureInPictureActive = false
    var onTogglePictureInPicture: (() -> Void)? = nil
    var together: PlayerTogetherState? = nil
    var onLeaveGroup: (() -> Void)? = nil
    var onSetIgnoreWait: ((Bool) -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.engine === rhs.engine
            && lhs.info == rhs.info
            && lhs.subtitleSearch === rhs.subtitleSearch
            && lhs.isPictureInPicturePossible == rhs.isPictureInPicturePossible
            && lhs.isPictureInPictureActive == rhs.isPictureInPictureActive
            // Somebody joining or leaving has to reach the Together tab,
            // so the group's state is part of this boundary rather than
            // something it filters out.
            && lhs.together == rhs.together
    }

    var body: some View {
        PlayerControlPanel(
            selectedTab: $selectedTab,
            focus: focus,
            info: info,
            audioTracks: engine.audioTracks,
            subtitleTracks: engine.subtitleTracks,
            audioDelay: engine.audioDelay,
            playbackRate: engine.rate,
            subtitleSearch: subtitleSearch,
            subtitleLoadState: engine.subtitleLoadState,
            onRetrySubtitleLoad: engine.retrySubtitleLoad,
            isPictureInPicturePossible: isPictureInPicturePossible,
            isPictureInPictureActive: isPictureInPictureActive,
            onTogglePictureInPicture: onTogglePictureInPicture,
            together: together,
            onLeaveGroup: onLeaveGroup,
            onSetIgnoreWait: onSetIgnoreWait,
            onSelectAudioTrack: engine.selectAudioTrack,
            onSelectSubtitleTrack: { id in
                subtitleSearch?.cancelDownload()
                engine.selectSubtitleTrack(id: id)
            },
            onSetAudioDelay: engine.setAudioDelay,
            onSetPlaybackRate: engine.setRate,
            onDismiss: onDismiss
        )
    }
}
