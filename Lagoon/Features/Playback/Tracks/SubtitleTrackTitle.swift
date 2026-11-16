import Foundation
import LagoonEngine

extension PlayerTrack {
    /// The subtitle menu's name for the track, with what tells tracks in one
    /// language apart.
    nonisolated var subtitleMenuTitle: String {
        // Captions are for the hard of hearing by definition, so no SDH tag.
        if engineID == Self.closedCaptionsEngineID {
            return String(localized: "Closed Captions")
        }
        var labels = [displayName]
        if source == .downloaded {
            labels.append(String(localized: "Downloaded"))
        } else if source == .external {
            labels.append(String(localized: "External"))
        }
        if isForced { labels.append(String(localized: "Forced")) }
        if isHearingImpaired { labels.append(String(localized: "SDH")) }
        return labels.joined(separator: " · ")
    }
}
