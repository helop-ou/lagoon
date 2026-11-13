import LagoonEngine

/// The stages the app fails at on its own. The engine names only its own.
/// Reports are grouped by these strings, so a rename splits an issue in two.
nonisolated extension PlaybackFailureDetail.Stage {
    /// The server was asked what it can deliver.
    static let negotiate = Self(rawValue: "negotiate")
    /// An engine was made for the answer and asked to start.
    static let start = Self(rawValue: "start")
    /// The engine failed without saying where.
    static let unknown = Self(rawValue: "unknown")
}
