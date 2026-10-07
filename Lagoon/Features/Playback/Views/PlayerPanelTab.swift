import Foundation

/// Shared with the Debug gallery so it previews production UI.
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

    /// Walk this, never `allCases`, or arrowing right can land on the
    /// undrawn Together tab.
    static func offered(inGroup: Bool) -> [PlayerPanelTab] {
        inGroup ? allCases : allCases.filter { $0 != .together }
    }
}
