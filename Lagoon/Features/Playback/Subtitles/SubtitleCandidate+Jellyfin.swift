import Foundation
import LagoonEngine

/// Turns a Jellyfin remote-subtitle result into the engine's shape. The
/// engine treats `providerID` as opaque; only this file knows it is
/// Jellyfin's.
nonisolated extension SubtitleCandidate {
    init(_ info: RemoteSubtitleInfo) {
        self.init(
            id: "jellyfin:" + info.id,
            providerID: info.id,
            name: info.name,
            language: info.threeLetterISOLanguageName,
            providerName: info.providerName,
            format: info.format,
            downloadCount: info.downloadCount,
            isHashMatch: info.isHashMatch == true,
            isHearingImpaired: info.hearingImpaired == true,
            isForced: info.isForced == true,
            isMachineTranslated: info.machineTranslated == true,
            isAITranslated: info.aiTranslated == true
        )
    }
}

nonisolated extension MediaStream {
    /// How the controller sees a downloaded candidate before Jellyfin has a
    /// stream for it: external, with no index or delivery URL yet.
    static func externalSubtitle(describing candidate: SubtitleCandidate) -> MediaStream {
        MediaStream(
            type: "Subtitle",
            codec: candidate.format,
            displayTitle: candidate.name,
            title: candidate.name,
            language: candidate.language,
            index: nil,
            isDefault: nil,
            isOriginal: nil,
            isExternal: true,
            isForced: candidate.isForced,
            isHearingImpaired: candidate.isHearingImpaired,
            deliveryUrl: nil,
            profile: nil,
            videoRangeType: nil,
            channels: nil,
            width: nil,
            height: nil,
            bitDepth: nil,
            bitRate: nil,
            realFrameRate: nil
        )
    }
}
