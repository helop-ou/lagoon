import SwiftUI

#if DEBUG
/// A single-point, fully transparent accessibility element that the UI
/// regression suite reads by identifier and value. Never visible, never
/// hit-testable, and never part of tvOS focus: a screen that needs the value
/// on an already-focusable element (see `PlayerRegressionValue`) attaches the
/// identifier there instead of mounting one of these beside it.
struct RegressionProbe: View {
    let label: String
    let identifier: String
    let value: String

    var body: some View {
        Text(label)
            .font(.system(size: 1))
            .foregroundStyle(.clear)
            .frame(width: 1, height: 1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityValue(value)
            .accessibilityIdentifier(identifier)
            .allowsHitTesting(false)
    }
}
#endif
