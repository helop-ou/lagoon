import CoreText
import Foundation
import LagoonEngine
import MediaAccessibility
import Observation
import SwiftUI
import UIKit

nonisolated enum MissingSubtitleMode: String, Codable, CaseIterable, Identifiable {
    case off
    case ask
    case automaticSearch

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: String(localized: "Off")
        case .ask: String(localized: "Ask When Missing")
        case .automaticSearch: String(localized: "Automatically Search")
        }
    }
}

nonisolated enum SubtitleTextSize: String, Codable, CaseIterable, Identifiable {
    case small
    case medium
    case large
    case extraLarge

    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        case .extraLarge: String(localized: "Extra Large")
        }
    }

    var scale: CGFloat {
        switch self {
        case .small: 0.82
        case .medium: 1
        case .large: 1.25
        case .extraLarge: 1.55
        }
    }
}

nonisolated enum SubtitleEdgeStyle: String, Codable, CaseIterable, Identifiable {
    case none
    case shadow
    case outline

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .shadow: String(localized: "Shadow")
        case .outline: String(localized: "Outline")
        }
    }
}

nonisolated enum SubtitleBackground: String, Codable, CaseIterable, Identifiable {
    case none
    case light
    case medium
    case dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: String(localized: "None")
        case .light: String(localized: "Light")
        case .medium: String(localized: "Medium")
        case .dark: String(localized: "Dark")
        }
    }

    var opacity: Double {
        switch self {
        case .none: 0
        case .light: 0.25
        case .medium: 0.5
        case .dark: 0.8
        }
    }
}

nonisolated enum SubtitleVerticalPosition: String, Codable, CaseIterable, Identifiable {
    case low
    case standard
    case high

    var id: String { rawValue }
    var title: String {
        switch self {
        case .low: String(localized: "Low")
        case .standard: String(localized: "Standard")
        case .high: String(localized: "High")
        }
    }
}

nonisolated struct SubtitlePreferenceValues: Codable, Equatable {
    var followsSystemAppearance = true
    var textSize: SubtitleTextSize = .medium
    var edgeStyle: SubtitleEdgeStyle = .shadow
    var background: SubtitleBackground = .light
    var verticalPosition: SubtitleVerticalPosition = .standard
    /// Lagoon's choices first. Apple's caption languages are appended at read
    /// time so Settings.app changes still apply.
    var languageOverrides: [String] = []
    var missingMode: MissingSubtitleMode = .ask
}

struct SubtitleRenderStyle {
    let font: Font
    let foregroundColor: Color
    let edgeColor: Color
    let backgroundColor: Color
    let backgroundOpacity: Double
    let edgeStyle: SubtitleEdgeStyle
    let bottomPadding: CGFloat

    static let fallback = SubtitleRenderStyle(
        font: .title3.weight(.medium),
        foregroundColor: .white,
        edgeColor: .black.opacity(0.95),
        backgroundColor: .black,
        backgroundOpacity: 0.35,
        edgeStyle: .shadow,
        bottomPadding: Metrics.screenGutter
    )
}

/// Per-account subtitle preferences plus the live bridge to Apple's caption
/// appearance and ordered caption-language settings.
@MainActor
@Observable
final class SubtitlePreferencesStore {
    private(set) var accountID: String?
    var values = SubtitlePreferenceValues() {
        didSet { persist() }
    }
    /// Incremented when the app becomes active so a changed system caption
    /// profile immediately invalidates SwiftUI's computed render style.
    private(set) var systemRevision = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func configure(accountID: String?) {
        guard self.accountID != accountID else { return }
        self.accountID = accountID
        guard let accountID,
              let data = defaults.data(forKey: Self.key(accountID)),
              let decoded = try? JSONDecoder().decode(SubtitlePreferenceValues.self, from: data) else {
            values = SubtitlePreferenceValues()
            return
        }
        values = decoded
    }

    func resetAppearanceToSystem() {
        values.followsSystemAppearance = true
    }

    func refreshSystemAppearance() {
        systemRevision &+= 1
    }

    private var languageOrder: LanguagePreferenceOrder {
        LanguagePreferenceOrder(
            overrides: values.languageOverrides,
            system: Self.systemCaptionLanguages
        )
    }

    var preferredLanguages: [String] {
        languageOrder.preferred
    }

    var primaryLanguage: String? {
        languageOrder.primary
    }

    var fallbackLanguage: String? {
        languageOrder.fallback
    }

    func setPrimaryLanguage(_ language: String?) {
        values.languageOverrides = languageOrder.settingPrimary(language)
    }

    func setFallbackLanguage(_ language: String?) {
        values.languageOverrides = languageOrder.settingFallback(language)
    }

    var renderStyle: SubtitleRenderStyle {
        _ = systemRevision
        return values.followsSystemAppearance ? systemRenderStyle : customRenderStyle
    }

    /// The same look for the engine to draw into the frames, where Picture
    /// in Picture shows them.
    var burnedInStyle: BurnedInSubtitleStyle {
        guard values.followsSystemAppearance else {
            return Self.burnedInStyle(
                text: CGColor(gray: 1, alpha: 1),
                background: CGColor(gray: 0, alpha: 1),
                backgroundOpacity: values.background.opacity,
                edge: values.edgeStyle,
                scale: values.textSize.scale,
                fontName: nil
            )
        }
        var behavior = MACaptionAppearanceBehavior.useValue
        let foreground = MACaptionAppearanceCopyForegroundColor(.user, &behavior).takeRetainedValue()
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(.user, &behavior)
        let background = MACaptionAppearanceCopyBackgroundColor(.user, &behavior).takeRetainedValue()
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(.user, &behavior)
        let relativeSize = MACaptionAppearanceGetRelativeCharacterSize(.user, &behavior)
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(.user, &behavior, .default).takeRetainedValue()
        let edge: SubtitleEdgeStyle = switch MACaptionAppearanceGetTextEdgeStyle(.user, &behavior) {
        case .none: .none
        case .uniform: .outline
        default: .shadow
        }
        return Self.burnedInStyle(
            text: foreground.copy(alpha: CGFloat(foregroundOpacity)) ?? foreground,
            background: background,
            backgroundOpacity: backgroundOpacity,
            edge: edge,
            scale: max(relativeSize > 4 ? relativeSize / 100 : relativeSize, 0.5),
            fontName: CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String
        )
    }

    /// Text height as a share of the picture at the default size: about a
    /// line in eighteen, as subtitles usually sit.
    nonisolated static let burnedInRelativeSize = 0.055

    nonisolated static func burnedInStyle(
        text: CGColor,
        background: CGColor,
        backgroundOpacity: Double,
        edge: SubtitleEdgeStyle,
        scale: Double,
        fontName: String?
    ) -> BurnedInSubtitleStyle {
        let burnedInEdge: BurnedInSubtitleStyle.Edge = switch edge {
        case .none: .none
        case .shadow: .dropShadow
        case .outline: .outline
        }
        return BurnedInSubtitleStyle(
            textColor: subtitleColor(text),
            edgeColor: SubtitleTextColor(red: 0, green: 0, blue: 0, alpha: 242),
            edge: burnedInEdge,
            backgroundColor: subtitleColor(background, opacity: backgroundOpacity),
            relativeSize: burnedInRelativeSize * scale,
            fontName: fontName
        )
    }

    /// sRGB bytes, with `opacity` multiplied into the colour's own alpha.
    nonisolated static func subtitleColor(_ color: CGColor, opacity: Double = 1) -> SubtitleTextColor {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let converted = color.converted(to: sRGB, intent: .defaultIntent, options: nil) ?? color
        let components = converted.components ?? [1, 1, 1, 1]
        func byte(_ value: CGFloat) -> UInt8 { UInt8(clamping: Int((min(max(value, 0), 1) * 255).rounded())) }
        let rgb = components.count >= 3 ? Array(components.prefix(3)) : Array(repeating: components.first ?? 1, count: 3)
        return SubtitleTextColor(
            red: byte(rgb[0]),
            green: byte(rgb[1]),
            blue: byte(rgb[2]),
            alpha: byte(converted.alpha * CGFloat(opacity))
        )
    }

    static var systemCaptionLanguages: [String] {
        let selected = MACaptionAppearanceCopySelectedLanguages(.user).takeRetainedValue() as? [String] ?? []
        return deduplicated((selected + Locale.preferredLanguages).compactMap(normalizedLanguage))
    }

    static var commonLanguageChoices: [String] {
        deduplicated(systemCaptionLanguages + [
            "en", "et", "es", "de", "fr", "it", "pt", "fi", "sv",
            "nb", "da", "nl", "pl", "ru", "uk", "ja", "ko", "zh",
        ])
    }

    static var allLanguageChoices: [String] {
        deduplicated(
            commonLanguageChoices
                + Locale.LanguageCode.isoLanguageCodes.map(\.identifier)
        ).sorted {
            displayName(for: $0).localizedStandardCompare(displayName(for: $1)) == .orderedAscending
        }
    }

    static func displayName(for language: String?) -> String {
        guard let language else { return String(localized: "None") }
        return Locale.current.localizedString(forIdentifier: language)
            ?? Locale.current.localizedString(forLanguageCode: language)
            ?? language.uppercased()
    }

    nonisolated static func normalizedLanguage(_ identifier: String) -> String? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.replacingOccurrences(of: "_", with: "-")
        let base = normalized.split(separator: "-", maxSplits: 1).first.map(String.init) ?? normalized
        if let twoLetter = JellyfinSubtitleLanguageCode.twoLetter(for: base) {
            return twoLetter
        }
        let locale = Locale(identifier: normalized)
        return locale.language.languageCode?.identifier.lowercased()
    }

    nonisolated static func deduplicated(_ languages: [String]) -> [String] {
        var seen: Set<String> = []
        return languages.compactMap { normalizedLanguage($0) }.filter { seen.insert($0).inserted }
    }

    private var customRenderStyle: SubtitleRenderStyle {
        SubtitleRenderStyle(
            font: .system(size: Self.baseFontSize * values.textSize.scale, weight: .medium),
            foregroundColor: .white,
            edgeColor: .black.opacity(0.95),
            backgroundColor: .black,
            backgroundOpacity: values.background.opacity,
            edgeStyle: values.edgeStyle,
            bottomPadding: bottomPadding
        )
    }

    /// The caption font itself. By name, the system font (".SFUI-Medium")
    /// does not open, and CoreText drew the subtitles in Times.
    nonisolated static func uiFont(_ font: CTFont) -> UIFont {
        font as UIFont
    }

    private var systemRenderStyle: SubtitleRenderStyle {
        var behavior = MACaptionAppearanceBehavior.useValue
        let foreground = MACaptionAppearanceCopyForegroundColor(.user, &behavior).takeRetainedValue()
        let foregroundOpacity = MACaptionAppearanceGetForegroundOpacity(.user, &behavior)
        let background = MACaptionAppearanceCopyBackgroundColor(.user, &behavior).takeRetainedValue()
        let backgroundOpacity = MACaptionAppearanceGetBackgroundOpacity(.user, &behavior)
        let relativeSize = MACaptionAppearanceGetRelativeCharacterSize(.user, &behavior)
        let scale = relativeSize > 4 ? relativeSize / 100 : relativeSize
        let descriptor = MACaptionAppearanceCopyFontDescriptorForStyle(.user, &behavior, .default)
            .takeRetainedValue()
        let ctFont = CTFontCreateWithFontDescriptor(
            descriptor,
            max(Self.baseFontSize * max(scale, 0.5), 1),
            nil
        )
        let uiFont = Self.uiFont(ctFont)
        let edge: SubtitleEdgeStyle = switch MACaptionAppearanceGetTextEdgeStyle(.user, &behavior) {
        case .none: .none
        case .uniform: .outline
        default: .shadow
        }
        return SubtitleRenderStyle(
            font: Font(uiFont),
            foregroundColor: Color(cgColor: foreground).opacity(foregroundOpacity),
            edgeColor: .black.opacity(0.95),
            backgroundColor: Color(cgColor: background),
            backgroundOpacity: backgroundOpacity,
            edgeStyle: edge,
            bottomPadding: bottomPadding
        )
    }

    private var bottomPadding: CGFloat {
        #if os(tvOS)
        switch values.verticalPosition {
        case .low: 70
        case .standard: 130
        case .high: 210
        }
        #else
        switch values.verticalPosition {
        case .low: 24
        case .standard: 54
        case .high: 100
        }
        #endif
    }

    private static var baseFontSize: CGFloat {
        #if os(tvOS)
        38
        #else
        22
        #endif
    }

    private func persist() {
        guard let accountID,
              let data = try? JSONEncoder().encode(values) else { return }
        defaults.set(data, forKey: Self.key(accountID))
    }

    private static func key(_ accountID: String) -> String {
        "subtitles.preferences.\(accountID)"
    }
}

private struct SubtitleEdgeModifier: ViewModifier {
    let style: SubtitleEdgeStyle
    let color: Color

    func body(content: Content) -> some View {
        switch style {
        case .none:
            content
        case .shadow:
            content.shadow(color: color, radius: 3, y: 1)
        case .outline:
            content
                .shadow(color: color, radius: 0, x: 1.5)
                .shadow(color: color, radius: 0, x: -1.5)
                .shadow(color: color, radius: 0, y: 1.5)
                .shadow(color: color, radius: 0, y: -1.5)
        }
    }
}

extension View {
    func subtitleEdge(_ style: SubtitleEdgeStyle, color: Color) -> some View {
        modifier(SubtitleEdgeModifier(style: style, color: color))
    }
}
