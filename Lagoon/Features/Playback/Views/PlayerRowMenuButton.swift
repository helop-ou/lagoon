import LagoonEngine
import SwiftUI
import UIKit

/// What the player's UIKit menu buttons tell it: which one has
/// focus and whether its menu is up. Their focus lives outside SwiftUI's
/// `FocusState`, and an open system menu takes focus out of the view tree,
/// so without this the player read both as the row being left.
@Observable
@MainActor
final class PlayerRowMenus {
    private(set) var focusedID: String?
    private(set) var isPresented = false
    @ObservationIgnored private var buttons: [String: WeakButton] = [:]

    private struct WeakButton {
        weak var button: UIButton?
    }

    var isActive: Bool { focusedID != nil || isPresented }

    /// The button a focus update should land on, read by the hosting
    /// controller's `preferredFocusEnvironments` for that one update.
    /// `UIFocusSystem.requestFocusUpdate(to:)` alone was ignored while the
    /// video surface held focus.
    static weak var pendingFocus: UIFocusEnvironment?

    fileprivate func register(_ button: UIButton, id: String) {
        buttons[id] = WeakButton(button: button)
    }

    fileprivate func focusChanged(id: String, isFocused: Bool) {
        if isFocused {
            focusedID = id
        } else if focusedID == id {
            focusedID = nil
        }
    }

    fileprivate func presentationChanged(_ presented: Bool) {
        isPresented = presented
    }

    /// Moves focus onto a menu button. False when it is not on screen.
    @discardableResult
    func focus(_ id: String) -> Bool {
        guard let button = buttons[id]?.button, button.window != nil else { return false }
        var responder = button.next
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard let controller = responder as? UIViewController else { return false }
        Self.pendingFocus = button
        controller.setNeedsFocusUpdate()
        controller.updateFocusIfNeeded()
        Self.pendingFocus = nil
        return true
    }
}

/// A glass row button whose menu is a UIKit `UIMenu`, the way a custom
/// player gets the system menu. SwiftUI's `Menu` presents too, but on an
/// Apple TV its highlight flickered all through playback. The menu here is
/// replaced only when `menuKey` changes.
struct PlayerRowMenuButton: UIViewRepresentable {
    let id: String
    let title: String
    let systemImage: String
    let accessibilityIdentifier: String
    let menuKey: String
    let menus: PlayerRowMenus
    let makeMenu: () -> UIMenu
    let onMoveDown: () -> Void

    func makeUIView(context: Context) -> RowMenuUIButton {
        #if os(tvOS)
        var configuration = UIButton.Configuration.glass()
        configuration.cornerStyle = .capsule
        #else
        // The toolbar draws the glass around its items, and its own
        // buttons' symbols are body-sized, large scale.
        var configuration = UIButton.Configuration.plain()
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .body, scale: .large)
        configuration.baseForegroundColor = .label
        #endif
        configuration.image = UIImage(systemName: systemImage)
        let button = RowMenuUIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = title
        button.accessibilityIdentifier = accessibilityIdentifier
        button.menu = makeMenu()
        context.coordinator.menuKey = menuKey
        menus.register(button, id: id)
        apply(to: button, context: context)
        return button
    }

    func updateUIView(_ button: RowMenuUIButton, context: Context) {
        apply(to: button, context: context)
        guard context.coordinator.menuKey != menuKey else { return }
        context.coordinator.menuKey = menuKey
        button.menu = makeMenu()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Its own size: without it a toolbar stretched it across the free space.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RowMenuUIButton, context: Context) -> CGSize? {
        uiView.intrinsicContentSize
    }

    final class Coordinator {
        var menuKey: String?
    }

    private func apply(to button: RowMenuUIButton, context: Context) {
        // SwiftUI's `disabled` does not reach a UIKit view by itself.
        button.isEnabled = context.environment.isEnabled
        let menus = menus
        let id = id
        button.onFocusChange = { isFocused in menus.focusChanged(id: id, isFocused: isFocused) }
        button.onPresentationChange = { presented in menus.presentationChanged(presented) }
        button.onMoveDown = onMoveDown
    }
}

final class RowMenuUIButton: UIButton {
    var onFocusChange: ((Bool) -> Void)?
    var onPresentationChange: ((Bool) -> Void)?
    var onMoveDown: (() -> Void)?

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        if context.nextFocusedItem === self {
            onFocusChange?(true)
        } else if context.previouslyFocusedItem === self {
            onFocusChange?(false)
        }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willDisplayMenuFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willDisplayMenuFor: configuration, animator: animator)
        onPresentationChange?(true)
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction,
        willEndFor configuration: UIContextMenuConfiguration,
        animator: (any UIContextMenuInteractionAnimating)?
    ) {
        super.contextMenuInteraction(interaction, willEndFor: configuration, animator: animator)
        onPresentationChange?(false)
    }

    /// Down leaves the row for the surface, as from the SwiftUI buttons.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if isFocused, presses.contains(where: { $0.type == .downArrow }) {
            onMoveDown?()
            return
        }
        super.pressesBegan(presses, with: event)
    }
}

/// What the player's menu buttons hold, as system menus.
enum PlayerRowMenuContent {
    /// Night Mode and Dialogue Boost as toggles, then the channel limit as
    /// an inline choice.
    static func soundMenu(_ options: PlayerSoundOptions) -> UIMenu {
        let shaping = options.shaping
        let limits = AudioChannelLimit.allCases.map { limit in
            UIAction(title: limit.title, state: options.channelLimit == limit ? .on : .off) { _ in
                options.setChannelLimit(limit)
            }
        }
        return UIMenu(children: [
            UIAction(title: String(localized: "Night Mode"), state: shaping.nightMode ? .on : .off) { _ in
                options.setNightMode(!shaping.nightMode)
            },
            UIAction(title: String(localized: "Dialogue Boost"), state: shaping.dialogueBoost ? .on : .off) { _ in
                options.setDialogueBoost(!shaping.dialogueBoost)
            },
            UIMenu(title: String(localized: "Channel Limit"), options: .displayInline, children: limits),
        ])
    }

    /// The season or list under its heading, the playing title checked.
    static func episodeMenu(_ list: PlayerEpisodeList, onPlay: @escaping (PlayerEpisodeList.Row) -> Void) -> UIMenu {
        let rows = list.rows.map { row in
            UIAction(title: row.title, subtitle: row.detail, state: row.isCurrent ? .on : .off) { _ in
                guard !row.isCurrent else { return }
                onPlay(row)
            }
        }
        return UIMenu(title: list.heading ?? "", options: .displayInline, children: rows)
    }

    /// What the sound menu shows. A presented menu replaced with the same
    /// content still redraws, so it is replaced only when this changes.
    static func soundMenuKey(_ options: PlayerSoundOptions) -> String {
        "\(options.shaping.nightMode)|\(options.shaping.dialogueBoost)|\(options.channelLimit.rawValue)"
    }

    static func episodeMenuKey(_ list: PlayerEpisodeList) -> String {
        ([list.heading ?? ""] + list.rows.map { "\($0.index):\($0.title):\($0.isCurrent)" })
            .joined(separator: "|")
    }
}
