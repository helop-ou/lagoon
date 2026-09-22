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
