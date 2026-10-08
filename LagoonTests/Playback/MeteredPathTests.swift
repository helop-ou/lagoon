import Foundation
import Testing
@testable import Lagoon

@Suite("Metered path cap")
struct MeteredPathTests {
    private let cellular = NetworkPathCost(isExpensive: true, isConstrained: false)
    private let lowData = NetworkPathCost(isExpensive: false, isConstrained: true)

    @Test func onlyAMeteredPathIsCapped() {
        #expect(MeteredPathPolicy.applies(cost: .unrestricted, allowFullQuality: false) == false)
        #expect(MeteredPathPolicy.applies(cost: cellular, allowFullQuality: false))
        #expect(MeteredPathPolicy.applies(cost: lowData, allowFullQuality: false))
    }

    /// The viewer's override wins, because Apple can report that a path is
    /// expensive but never that it is slow.
    @Test func theOverrideRestoresFullQuality() {
        #expect(MeteredPathPolicy.maxStreamingBitrate(
            unrestricted: 120_000_000,
            cost: cellular,
            allowFullQuality: true
        ) == 120_000_000)
        #expect(MeteredPathPolicy.maxStreamingBitrate(
            unrestricted: 120_000_000,
            cost: cellular,
            allowFullQuality: false
        ) == MeteredPathPolicy.maxBitrate)
    }

    /// Never raises a lower ceiling, such as the transcode rung's.
    @Test func theCapOnlyEverLowers() {
        #expect(MeteredPathPolicy.maxStreamingBitrate(
            unrestricted: 1_000_000,
            cost: cellular,
            allowFullQuality: false
        ) == 1_000_000)
    }

    /// The server checks the static ceiling before offering the original
    /// file, so it must come down too, and the picture with it.
    @Test func theStaticCeilingComesDownToo() {
        let capped = DeviceProfile.cappedForMeteredPath(
            DeviceProfile.everything,
            cost: cellular,
            allowFullQuality: false
        )
        #expect(capped.maxStreamingBitrate == MeteredPathPolicy.maxBitrate)
        #expect(capped.maxStaticBitrate == MeteredPathPolicy.maxBitrate)
        let hevc = capped.codecProfiles.first { $0.codec == "hevc" }?.conditions ?? []
        #expect(hevc.first { $0.property == "Width" }?.value == String(MeteredPathPolicy.maxWidth))
        #expect(hevc.first { $0.property == "Height" }?.value == String(MeteredPathPolicy.maxHeight))
    }

    @Test func anOrdinaryPathIsUntouched() {
        for (cost, allowFullQuality) in [(NetworkPathCost.unrestricted, false), (cellular, true)] {
            let same = DeviceProfile.cappedForMeteredPath(
                DeviceProfile.everything,
                cost: cost,
                allowFullQuality: allowFullQuality
            )
            #expect(same.maxStreamingBitrate == DeviceProfile.everything.maxStreamingBitrate)
            #expect(same.maxStaticBitrate == DeviceProfile.everything.maxStaticBitrate)
            #expect(same.codecProfiles.map(\.conditions.count)
                == DeviceProfile.everything.codecProfiles.map(\.conditions.count))
        }
    }

    /// The tighter bound wins, or a 1080p fallback bound would undo a
    /// metered 720p cap.
    @Test func twoGeometryBoundsResolveToTheTighter() {
        let hd = DeviceProfile.boundedTo(
            DeviceProfile.everything.codecProfiles.first { $0.codec == "hevc" }!,
            width: 1920,
            height: 1080
        )
        let both = DeviceProfile.boundedTo(hd, width: 1280, height: 720)
        let widths = both.conditions.filter { $0.property == "Width" }
        let heights = both.conditions.filter { $0.property == "Height" }
        #expect(widths.count == 1)
        #expect(heights.count == 1)
        #expect(widths.first?.value == "1280")
        #expect(heights.first?.value == "720")
        // In either order.
        let reversed = DeviceProfile.boundedTo(
            DeviceProfile.boundedTo(
                DeviceProfile.everything.codecProfiles.first { $0.codec == "hevc" }!,
                width: 1280,
                height: 720
            ),
            width: 1920,
            height: 1080
        )
        #expect(reversed.conditions.first { $0.property == "Width" }?.value == "1280")
    }
}
