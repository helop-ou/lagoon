#if !os(tvOS)
import SwiftUI

/// The native form treatment shared by the touch settings categories.
///
/// Pickers open as menus on the row, like the TV's `TVSettingsMenuPicker`.
/// A pushed page per choice is kept for lists too long for a menu, such as
/// `SettingsLanguagePickers`.
struct TouchSettingsPage<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        ThemedForm { content }
            .pickerStyle(.menu)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
#endif
