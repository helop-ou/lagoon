import SwiftUI

#if os(iOS)
extension VerticalAlignment {
    /// The Resume pill's centre, so the circles sit level with the pill and
    /// not with the pill-and-caption block.
    private enum DetailPillCenter: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat {
            context[VerticalAlignment.center]
        }
    }
    static let detailPillCenter = VerticalAlignment(DetailPillCenter.self)
}

/// Wide (regular-width iPad, laid out like the TV) or compact touch layout.
enum DetailLayout {
    static func usesLeadingColumn(_ horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && horizontalSizeClass == .regular
    }

    /// A landscape phone: title, actions and Play share one row.
    static func usesLandscapeRow(
        _ horizontalSizeClass: UserInterfaceSizeClass?,
        _ verticalSizeClass: UserInterfaceSizeClass?
    ) -> Bool {
        !usesLeadingColumn(horizontalSizeClass) && verticalSizeClass == .compact
    }

    static func titleAlignment(
        _ horizontalSizeClass: UserInterfaceSizeClass?,
        _ verticalSizeClass: UserInterfaceSizeClass?
    ) -> HorizontalAlignment {
        usesLeadingColumn(horizontalSizeClass) || usesLandscapeRow(horizontalSizeClass, verticalSizeClass)
            ? .leading
            : .center
    }
}
#endif

/// A detail page's actions, shared by film, series and Seerr pages.
///
/// - tvOS and regular-width iPad: one row, primary first so it takes first
///   focus, accessory beneath.
/// - Landscape phone: secondary, accessory, then primary on one line,
///   aligned on `detailPillCenter`.
/// - Portrait phone: primary alone and wide, secondary in a centred row
///   beneath that wraps when it cannot fit, accessory below that.
///
/// The accessory is the series page's season picker.
struct DetailActionLayout<Primary: View, Secondary: View, Accessory: View>: View {
    @ViewBuilder let primary: Primary
    @ViewBuilder let secondary: Secondary
    @ViewBuilder let accessory: Accessory

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #endif

    init(
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary,
        @ViewBuilder accessory: () -> Accessory = { EmptyView() }
    ) {
        self.primary = primary()
        self.secondary = secondary()
        self.accessory = accessory()
    }

    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: Metrics.Space.l) {
            HStack(spacing: Metrics.detailActionSpacing) {
                primary
                secondary
            }
            accessory
        }
        #else
        if DetailLayout.usesLeadingColumn(horizontalSizeClass) {
            VStack(alignment: .leading, spacing: Metrics.Space.l) {
                AdaptiveActionStack(spacing: Metrics.detailActionSpacing) {
                    primary
                    secondary
                }
                accessory
            }
        } else if DetailLayout.usesLandscapeRow(horizontalSizeClass, verticalSizeClass) {
            // A plain row: when tight, the title art gives way instead of
            // the accessory wrapping.
            HStack(alignment: .detailPillCenter, spacing: Metrics.detailActionSpacing) {
                secondary
                accessory
                    .fixedSize()
                primary
            }
        } else {
            // The circles wrap rather than fold into a column, and the
            // accessory takes a line of its own beneath them.
            VStack(spacing: Metrics.Space.m) {
                primary
                MetadataFlowLayout(spacing: Metrics.detailActionSpacing, alignment: .center) {
                    secondary
                }
                accessory
            }
        }
        #endif
    }
}

extension View {
    /// The label of a detail page's hero action (Play, Resume, Request...).
    func detailPrimaryLabel() -> some View {
        modifier(DetailPrimaryLabelModifier())
    }

    func detailPrimaryButton() -> some View {
        #if os(iOS)
        buttonStyle(.glass)
            .controlSize(.extraLarge)
        #else
        buttonStyle(.glass)
        #endif
    }
}

private struct DetailPrimaryLabelModifier: ViewModifier {
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    /// Uncapped in the wide iPad row.
    private var maxWidth: CGFloat? {
        if DetailLayout.usesLeadingColumn(horizontalSizeClass) { return nil }
        return DetailLayout.usesLandscapeRow(horizontalSizeClass, verticalSizeClass)
            ? Metrics.detailLandscapePlayButtonMaxWidth
            : Metrics.detailPlayButtonMaxWidth
    }
    #endif

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .font(.title3.weight(.semibold))
            // A squeezed Label stacks its icon over its text.
            .fixedSize()
            .frame(maxWidth: maxWidth)
            .padding(.vertical, Metrics.Space.xs)
        #else
        content
        #endif
    }
}
