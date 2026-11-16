import Foundation

/// The first sign-in's setup, one topic a step, in the order they are shown.
nonisolated enum SetupStep: Int, CaseIterable, Identifiable {
    case look
    case languages
    case subtitleLook
    case reports

    var id: Int { rawValue }

    var next: SetupStep? { SetupStep(rawValue: rawValue + 1) }
    var previous: SetupStep? { SetupStep(rawValue: rawValue - 1) }

    /// "Step 2 of 4".
    var position: String {
        String(localized: "Step \(rawValue + 1) of \(Self.allCases.count)")
    }

    var title: String {
        switch self {
        case .look: String(localized: "Choose a Look")
        case .languages: String(localized: "Sound and Subtitles")
        case .subtitleLook: String(localized: "How Subtitles Look")
        case .reports: String(localized: "Help Improve Lagoon")
        }
    }

    var message: String {
        switch self {
        case .look:
            String(localized: "You can change all of this later in Settings.")
        case .languages:
            String(localized: "What a title starts with.")
        case .subtitleLook:
            String(localized: "The system's caption style, or Lagoon's own.")
        case .reports:
            String(localized: "Reports never say who you are or what you watch.")
        }
    }
}
