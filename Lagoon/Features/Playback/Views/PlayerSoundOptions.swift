import LagoonEngine
import SwiftUI

/// Night Mode, Dialogue Boost and the channel limit, from the player's own
/// sound button. A value with its actions, so the iOS menu and the tvOS list
/// apply a change the same way.
struct PlayerSoundOptions {
    let shaping: AudioShaping
    let setNightMode: (Bool) -> Void
    let setDialogueBoost: (Bool) -> Void
    let setChannelLimit: (AudioChannelLimit) -> Void

    var channelLimit: AudioChannelLimit { AudioChannelLimit(engineLimit: shaping.channelLimit) }

    static let atmosNote: LocalizedStringKey = "While any of these is on, Dolby Atmos plays as surround."
}

#if os(iOS)
/// The toolbar's sound button: a native menu.
struct PlayerSoundMenu: View {
    let options: PlayerSoundOptions

    var body: some View {
        Menu {
            Section {
                Toggle("Night Mode", isOn: Binding(get: { options.shaping.nightMode }, set: options.setNightMode))
                    .accessibilityIdentifier("player.sound.nightMode")
                Toggle("Dialogue Boost", isOn: Binding(get: { options.shaping.dialogueBoost }, set: options.setDialogueBoost))
                    .accessibilityIdentifier("player.sound.dialogueBoost")
                Picker("Channel Limit", selection: Binding(get: { options.channelLimit }, set: options.setChannelLimit)) {
                    ForEach(AudioChannelLimit.allCases) { limit in
                        Text(limit.title).tag(limit)
                    }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("player.sound.channelLimit")
            } header: {
                Text(PlayerSoundOptions.atmosNote)
            }
        } label: {
            Label("Sound", systemImage: "speaker.wave.2")
        }
        .accessibilityIdentifier("player.sound")
    }
}
#endif

#if os(tvOS)
/// The tvOS sound list, above the control row. Ordinary buttons: a SwiftUI
/// `Menu` never presents inside the player's full-screen cover.
struct PlayerSoundList: View {
    let options: PlayerSoundOptions
    let focus: FocusState<PlayerControlFocus?>.Binding

    static let nightModeID = "sound-night-mode"
    static let dialogueBoostID = "sound-dialogue-boost"

    static func limitID(_ limit: AudioChannelLimit) -> String {
        "sound-limit-\(limit.rawValue)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Space.m) {
            row(
                "Night Mode",
                isOn: options.shaping.nightMode,
                id: Self.nightModeID,
                identifier: "player.sound.nightMode"
            ) {
                options.setNightMode(!options.shaping.nightMode)
            }
            row(
                "Dialogue Boost",
                isOn: options.shaping.dialogueBoost,
                id: Self.dialogueBoostID,
                identifier: "player.sound.dialogueBoost"
            ) {
                options.setDialogueBoost(!options.shaping.dialogueBoost)
            }
            Text("Channel Limit")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, Metrics.Space.s)
            ForEach(AudioChannelLimit.allCases) { limit in
                row(
                    LocalizedStringKey(limit.title),
                    isOn: options.channelLimit == limit,
                    id: Self.limitID(limit),
                    identifier: "player.sound.channelLimit.\(limit.rawValue)"
                ) {
                    options.setChannelLimit(limit)
                }
            }
            Text(PlayerSoundOptions.atmosNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Metrics.Space.xl)
        .frame(width: SoundListMetrics.width, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Metrics.panelCornerRadius))
        .focusSection()
        .accessibilityIdentifier("player.sound.list")
    }

    private func row(
        _ title: LocalizedStringKey,
        isOn: Bool,
        id: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TVCheckmarkToggleLabel(title: title, isOn: isOn)
        }
        .focused(focus, equals: .sound(id))
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityIdentifier(identifier)
    }
}

/// The tvOS buttons above the scrubber: previous, sound and next. Focus comes
/// here with Up from the surface while the transport is up, and Down sends
/// it back, so the surface keeps the arrows for scrubbing.
struct PlayerTVControlRow: View {
    let episodes: PlayerEpisodeButtons?
    let focus: FocusState<PlayerControlFocus?>.Binding
    let onPrevious: () -> Void
    let onToggleSound: () -> Void
    let onNext: () -> Void

    static let previousID = "previous"
    static let soundID = "sound"
    static let nextID = "next"

    var body: some View {
        HStack(spacing: Metrics.Space.l) {
            if episodes?.hasPrevious == true {
                Button("Previous", systemImage: "backward.end.fill", action: onPrevious)
                    .focused(focus, equals: .control(Self.previousID))
                    .accessibilityIdentifier("player.previous")
            }
            Button("Sound", systemImage: "speaker.wave.2", action: onToggleSound)
                .focused(focus, equals: .control(Self.soundID))
                .accessibilityIdentifier("player.sound")
            if episodes?.hasNext == true {
                Button("Next", systemImage: "forward.end.fill", action: onNext)
                    .focused(focus, equals: .control(Self.nextID))
                    .accessibilityIdentifier("player.next")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .focusSection()
    }
}

private enum SoundListMetrics {
    static let width: CGFloat = 560
}
#endif
