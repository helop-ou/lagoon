#if !os(tvOS)
import SwiftUI

/// The native form treatment shared by the touch settings categories.
struct TouchSettingsPage<Content: View>: View {
    let title: LocalizedStringKey
    let content: Content

    init(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        Form { content }
            .pickerStyle(.navigationLink)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
    }
}
#endif
