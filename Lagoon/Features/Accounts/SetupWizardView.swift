import SwiftUI

/// The first sign-in's setup: one topic a step, each with its default
/// already chosen, so Continue alone reaches Home. Every choice is the
/// setting its page in Settings changes, saved as it is made.
struct SetupWizardView: View {
    @Environment(SessionStore.self) private var session
    @State private var step = SetupStep.look
    @State private var subtitlePreferences = SubtitlePreferencesStore()
    @State private var trackPreferences = TrackPreferencesStore()
    #if os(tvOS)
    private enum Control { case advance }
    @FocusState private var focus: Control?
    #endif

    var body: some View {
        ZStack {
            GroundBackground()
            JellyfishSwimLayer()

            #if os(iOS)
            OnboardingColumn {
                heading
                content
                advanceButton
                    .buttonStyle(.glass)
                    .controlSize(.extraLarge)
                    .font(.title3.weight(.semibold))
                secondaryButton
                    .buttonStyle(.glass)
            }
            #else
            ScrollView {
                VStack(spacing: Metrics.Space.l) {
                    heading
                        .padding(.bottom, Metrics.Space.l)
                    content
                    advanceButton
                        .buttonStyle(.glass)
                        .focused($focus, equals: .advance)
                        .padding(.top, Metrics.Space.xl)
                    secondaryButton
                        .buttonStyle(.glass)
                }
                .frame(maxWidth: Metrics.readableWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, Metrics.screenGutter)
                .padding(.vertical, Metrics.Space.section)
            }
            .scrollClipDisabled()
            // Continue first, so Select alone walks through the defaults.
            .defaultFocus($focus, .advance)
            .onChange(of: step) { focus = .advance }
            .onExitCommand(perform: exitCommand)
            #endif
        }
        .task(id: session.activeAccount?.id) {
            subtitlePreferences.configure(accountID: session.activeAccount?.id)
            trackPreferences.configure(accountID: session.activeAccount?.id)
        }
    }

    private var heading: some View {
        VStack(spacing: Metrics.Space.m) {
            LagoonLockup(layout: .horizontal, symbolHeight: Metrics.lockupHeaderSymbolHeight)
            Text(step.position)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("setup.position")
            Text(step.title)
                .font(.largeTitle.bold())
                .accessibilityIdentifier("setup.title")
            Text(step.message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .look:
            SetupLookStepView()
        case .languages:
            SetupLanguagesStepView(trackPreferences: trackPreferences, subtitlePreferences: subtitlePreferences)
        case .subtitleLook:
            SetupSubtitleLookStepView(subtitlePreferences: subtitlePreferences)
        case .reports:
            SetupReportsStepView()
        }
    }

    private var advanceButton: some View {
        Button(action: advance) {
            Text(step.next == nil ? "Done" : "Continue")
                .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("setup.continue")
    }

    /// Out of the setup from its first step, back a step from the others.
    @ViewBuilder
    private var secondaryButton: some View {
        if step.previous == nil {
            Button("Skip Setup") { session.finishSetup() }
                .accessibilityIdentifier("setup.skip")
        } else {
            Button("Back", action: goBack)
                .accessibilityIdentifier("setup.back")
        }
    }

    private func advance() {
        guard let next = step.next else {
            session.finishSetup()
            return
        }
        withAnimation(.easeInOut(duration: Motion.standard)) { step = next }
    }

    private func goBack() {
        guard let previous = step.previous else { return }
        withAnimation(.easeInOut(duration: Motion.standard)) { step = previous }
    }

    #if os(tvOS)
    /// Menu goes back a step. On the first step it is left to the system.
    private var exitCommand: (() -> Void)? {
        step.previous == nil ? nil : { goBack() }
    }
    #endif
}

// MARK: - Steps

/// The theme, and whether the seasons change it.
struct SetupLookStepView: View {
    var store = ThemeStore.shared

    private var theme: Binding<AppTheme> {
        Binding(
            get: { store.theme },
            set: { theme in
                withAnimation(.easeInOut(duration: Motion.crossfade)) { store.select(theme) }
            }
        )
    }

    private var followsSeasons: Binding<Bool> {
        Binding(
            get: { store.followsSeasons },
            set: { follows in
                withAnimation(.easeInOut(duration: Motion.crossfade)) { store.setFollowsSeasons(follows) }
            }
        )
    }

    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            SetupGroup {
                #if os(iOS)
                ForEach(AppTheme.allCases) { option in
                    Button {
                        theme.wrappedValue = option
                    } label: {
                        HStack(spacing: Metrics.Space.m) {
                            ThemeSwatch(palette: option.palette)
                            Text(option.title)
                                .foregroundStyle(Color.primary)
                            Spacer()
                            if option == store.theme {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(.rect)
                    }
                    .modifier(SetupRow())
                    .accessibilityIdentifier("setup.theme.\(option.rawValue)")
                    .accessibilityAddTraits(option == store.theme ? .isSelected : [])
                }
                #else
                SetupChoiceRow(
                    title: "Theme", identifier: "setup.theme", selection: theme,
                    options: AppTheme.allCases.map { SetupOption(value: $0, title: $0.title) }
                )
                #endif
            }
            SetupGroup {
                SetupToggleRow(title: "Seasonal Themes", identifier: "setup.seasonal", isOn: followsSeasons)
            }
            SetupFootnote(Text("Spooky in October, Winter in December."))
        }
    }
}

/// Which audio and which subtitles a title starts with.
struct SetupLanguagesStepView: View {
    @Bindable var trackPreferences: TrackPreferencesStore
    @Bindable var subtitlePreferences: SubtitlePreferencesStore

    private var audioLanguage: Binding<String?> {
        Binding(
            get: { trackPreferences.primaryAudioLanguage },
            set: { trackPreferences.setPrimaryAudioLanguage($0) }
        )
    }

    private var subtitleLanguage: Binding<String?> {
        Binding(
            get: { subtitlePreferences.primaryLanguage },
            set: { subtitlePreferences.setPrimaryLanguage($0) }
        )
    }

    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            SetupGroup {
                SetupChoiceRow(
                    title: "Audio", identifier: "setup.audio.default",
                    selection: $trackPreferences.values.audioMode,
                    options: AudioDefaultMode.allCases.map { SetupOption(value: $0, title: $0.title) }
                )
                SetupChoiceRow(
                    title: "Audio Language", identifier: "setup.audio.language", selection: audioLanguage,
                    options: Self.languages(including: trackPreferences.primaryAudioLanguage)
                )
            }
            SetupGroup {
                SetupChoiceRow(
                    title: "Subtitles", identifier: "setup.subtitles.default",
                    selection: $trackPreferences.values.subtitleMode,
                    options: SubtitleDefaultMode.allCases.map { SetupOption(value: $0, title: $0.title) }
                )
                SetupChoiceRow(
                    title: "Subtitle Language", identifier: "setup.subtitles.language", selection: subtitleLanguage,
                    options: Self.languages(including: subtitlePreferences.primaryLanguage)
                )
            }
            // The one explanation kept: Smart and System Setting do not say
            // what they do.
            SetupFootnote(Text(trackPreferences.values.subtitleMode.settingsDescription))
        }
    }

    /// The common languages, short enough for a menu, and the one in use
    /// when it is not among them. Settings lists every language.
    static func languages(including current: String?) -> [SetupOption<String?>] {
        var codes = SubtitlePreferencesStore.commonLanguageChoices
        if let current, !codes.contains(current) { codes.insert(current, at: 0) }
        return codes.map { SetupOption(value: Optional($0), title: SubtitlePreferencesStore.displayName(for: $0)) }
    }
}

/// The system's caption style, or Lagoon's own, with a sample line.
struct SetupSubtitleLookStepView: View {
    @Bindable var subtitlePreferences: SubtitlePreferencesStore

    var body: some View {
        let followsSystem = subtitlePreferences.values.followsSystemAppearance
        VStack(spacing: Metrics.Space.l) {
            SubtitleStylePreviewView(style: subtitlePreferences.renderStyle)
                // Its own height: the column would stretch it to fill the page.
                .fixedSize(horizontal: false, vertical: true)
            SetupGroup {
                SetupToggleRow(
                    title: "Use System Caption Style", identifier: "setup.subtitleLook.system",
                    isOn: $subtitlePreferences.values.followsSystemAppearance
                )
                if !followsSystem {
                    SetupChoiceRow(
                        title: "Size", identifier: "setup.subtitleLook.size",
                        selection: $subtitlePreferences.values.textSize,
                        options: SubtitleTextSize.allCases.map { SetupOption(value: $0, title: $0.title) }
                    )
                    SetupChoiceRow(
                        title: "Edge", identifier: "setup.subtitleLook.edge",
                        selection: $subtitlePreferences.values.edgeStyle,
                        options: SubtitleEdgeStyle.allCases.map { SetupOption(value: $0, title: $0.title) }
                    )
                    SetupChoiceRow(
                        title: "Background", identifier: "setup.subtitleLook.background",
                        selection: $subtitlePreferences.values.background,
                        options: SubtitleBackground.allCases.map { SetupOption(value: $0, title: $0.title) }
                    )
                }
            }
        }
    }
}

/// Whether failures are reported to the developer, and what a report holds.
struct SetupReportsStepView: View {
    @AppStorage(DiagnosticsPreference.reportingEnabledKey)
    private var sendsReports = DiagnosticsPreference.defaultReportingEnabled

    var body: some View {
        VStack(spacing: Metrics.Space.l) {
            SetupGroup {
                SetupToggleRow(title: "Send Diagnostic Reports", identifier: "setup.reports", isOn: $sendsReports)
            }
            SetupFootnote(Text("Technical details of a failure only. Settings lists them in full."))
        }
    }
}

// MARK: - Rows

/// One entry of a setup choice.
struct SetupOption<Value: Hashable>: Identifiable {
    let value: Value
    let title: String

    var id: Value { value }
}

/// A group of setup rows: one rounded card on iOS, stacked rows on tvOS.
private struct SetupGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        #if os(iOS)
        OnboardingFieldGroup { content }
        #else
        VStack(spacing: Metrics.Space.s) { content }
        #endif
    }
}

/// One choice out of a few, as the platform's own menu.
private struct SetupChoiceRow<Value: Hashable>: View {
    let title: LocalizedStringKey
    let identifier: String
    @Binding var selection: Value
    let options: [SetupOption<Value>]

    var body: some View {
        #if os(iOS)
        HStack {
            Text(title)
            Spacer()
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.title).tag(option.value)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier(identifier)
        }
        .modifier(SetupRow())
        #else
        TVSettingsMenuPicker(
            title: title, accessibilityIdentifier: identifier, selection: $selection,
            options: options.map { TVSettingsOption(value: $0.value, title: $0.title) }
        )
        // As far in as a toggle row sets itself.
        .padding(.horizontal, Metrics.Space.l)
        #endif
    }
}

private struct SetupToggleRow: View {
    let title: LocalizedStringKey
    let identifier: String
    @Binding var isOn: Bool

    var body: some View {
        #if os(iOS)
        Toggle(title, isOn: $isOn)
            .modifier(SetupRow())
            .accessibilityIdentifier(identifier)
        #else
        TVSettingsToggle(title, isOn: $isOn)
            .accessibilityIdentifier(identifier)
        #endif
    }
}

/// A short line under a group. The setup keeps its words few: Settings has
/// the long explanations.
private struct SetupFootnote: View {
    let text: Text

    init(_ text: Text) {
        self.text = text
    }

    var body: some View {
        text
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#if os(iOS)
/// One row of an `OnboardingFieldGroup` that is not a text field.
private struct SetupRow: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Metrics.Space.l)
            .frame(minHeight: Metrics.onboardingFieldHeight)
    }
}
#endif
