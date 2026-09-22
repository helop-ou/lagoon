import Foundation
import LagoonEngine

/// Turns a Jellyfin remote-subtitle result into the engine's own shape.
///
/// The engine used to take the wire DTO directly, which put a Jellyfin type
/// inside the subtitle pipeline. It now takes `providerID` as an opaque
/// string and hands it back untouched, so this is the only place that knows
/// the identifier came from Jellyfin.
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
