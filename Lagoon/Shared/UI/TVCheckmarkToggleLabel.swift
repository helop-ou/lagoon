import SwiftUI

#if os(tvOS)
/// The label of a tvOS checkmark toggle: title on the left, a circle that
/// fills with a checkmark on the right.
struct TVCheckmarkToggleLabel: View {
    let title: LocalizedStringKey
    let isOn: Bool

    var body: some View {
        HStack(spacing: Metrics.Space.xl) {
            Text(title)
            Spacer(minLength: Metrics.Space.xl)
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .stateGlyph(isOn: isOn)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#endif
