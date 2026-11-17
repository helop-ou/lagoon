import Foundation
import Testing
@testable import Lagoon

@Suite("Elf visit")
struct ElfVisitTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Tallinn")!
        return calendar
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private static let moments = stride(from: 0.0, to: ElfVisit.duration, by: 0.02).map { $0 }

    // MARK: - When

    @Test(arguments: Array(2026...2046))
    func theElvesAreAboutFromTheFirstOfDecemberToBoxingDayEveryYear(year: Int) {
        let calendar = Self.calendar
        #expect(!ElfVisit.isSeason(on: Self.date(year, 11, 30, 23), calendar: calendar))
        #expect(ElfVisit.isSeason(on: Self.date(year, 12, 1, 0), calendar: calendar))
        #expect(ElfVisit.isSeason(on: Self.date(year, 12, 24), calendar: calendar))
        #expect(ElfVisit.isSeason(on: Self.date(year, 12, 26, 23), calendar: calendar))
        #expect(!ElfVisit.isSeason(on: Self.date(year, 12, 27, 0), calendar: calendar))
        // Winter goes on without them.
        #expect(!ElfVisit.isSeason(on: Self.date(year + 1, 1, 3), calendar: calendar))
        #expect(!ElfVisit.isSeason(on: Self.date(year + 1, 7, 1), calendar: calendar))
    }

    @Test func aPagesFirstVisitComesSoonerThanTheOnesAfterIt() {
        var random = SeededGenerator(seed: 12)
        for _ in 0..<40 {
            let first = ElfVisit.plan(isFirst: true, using: &random)
            #expect(ElfVisit.firstWait.contains(first.wait))
            let later = ElfVisit.plan(isFirst: false, using: &random)
            #expect(ElfVisit.wait.contains(later.wait))
            #expect((0...1).contains(later.lane))
            #expect((0.55...1).contains(later.depth))
        }
        #expect(ElfVisit.firstWait.upperBound < ElfVisit.wait.lowerBound)
        // Either side of the page.
        let sides = (0..<40).map { _ in ElfVisit.plan(isFirst: false, using: &random).onLeading }
        #expect(Set(sides).count == 2)
    }

    // MARK: - The visit

    @Test func theElfIsOutOfSightBeforeAndAfterItsVisit() throws {
        #expect(ElfVisit.pose(at: -0.1) == nil)
        #expect(ElfVisit.pose(at: ElfVisit.duration) == nil)
        #expect(try #require(ElfVisit.pose(at: 0)).reach == 0)
        #expect(try #require(ElfVisit.pose(at: ElfVisit.duration - 0.001)).reach < 0.01)
    }

    @Test func itSlidesDownStaysAtTheRopesEndAndClimbsBack() throws {
        let arrives = ElfVisit.descent
        let leaves = ElfVisit.descent + ElfVisit.stay
        var last = 0.0
        for moment in Self.moments where moment < arrives {
            let reach = try #require(ElfVisit.pose(at: moment)).reach
            #expect(reach >= last - 0.03, "at \(moment)")
            last = max(last, reach)
        }
        #expect(last > 0.97)
        for moment in Self.moments where moment >= arrives && moment < leaves {
            #expect(try #require(ElfVisit.pose(at: moment)).reach == 1)
        }
        last = 1
        for moment in Self.moments where moment >= leaves {
            let reach = try #require(ElfVisit.pose(at: moment)).reach
            #expect(reach <= last + 1e-9, "at \(moment)")
            last = reach
        }
    }

    /// A pull, a pause, a pull: not one smooth glide.
    @Test func itClimbsHandOverHand() {
        #expect(ElfVisit.hauled(0) == 0)
        #expect(ElfVisit.hauled(1) == 1)
        #expect(ElfVisit.hauled(2) == 1)
        let steps = stride(from: 0.0, through: 1.0, by: 0.002).map(ElfVisit.hauled)
        #expect(zip(steps, steps.dropFirst()).allSatisfy { $1 >= $0 })
        // It rests once after every pull but the last.
        var rests = 0
        var resting = false
        for (before, after) in zip(steps, steps.dropFirst()) {
            let still = after - before < 1e-9
            if still && !resting { rests += 1 }
            resting = still
        }
        #expect(rests == ElfVisit.pulls)
    }

    @Test func itWavesOnlyOnceItHasArrivedAndBeforeItLeaves() throws {
        let arrives = ElfVisit.descent
        let leaves = ElfVisit.descent + ElfVisit.stay
        for moment in Self.moments where moment < arrives || moment >= leaves {
            #expect(try #require(ElfVisit.pose(at: moment)).raise == 0, "at \(moment)")
        }
        let still = try #require(ElfVisit.pose(at: ElfVisit.stillMoment))
        #expect(still.raise == 1)
        // The hand goes both ways while it is up.
        let waves = try Self.moments.filter { $0 > arrives + 1.6 && $0 < leaves - 2 }
            .map { try #require(ElfVisit.pose(at: $0)).wave }
        #expect((waves.min() ?? 0) < -0.9)
        #expect((waves.max() ?? 0) > 0.9)
    }

    /// The page leaves it a narrow lane.
    @Test func itNeverSwingsFarFromItsRope() throws {
        for moment in Self.moments {
            let pose = try #require(ElfVisit.pose(at: moment))
            #expect(abs(pose.sway) <= 0.1, "at \(moment)")
            #expect(abs(pose.kick) <= 1)
        }
        // Its legs work hardest on the way down and up.
        let hanging = try #require(ElfVisit.pose(at: ElfVisit.descent + 0.19))
        #expect(abs(hanging.kick) <= 0.2)
    }

    // MARK: - The figure

    @Test func theFreeHandLeavesTheRopeToWave() {
        #expect(ElfGeometry.freeHand(raise: 0, wave: 1) == ElfGeometry.upperHand)
        let out = ElfGeometry.freeHand(raise: 1, wave: 0)
        #expect(out.x > ElfGeometry.rightShoulder.x + 15)
        #expect(ElfGeometry.freeHand(raise: 1, wave: 1).x > ElfGeometry.freeHand(raise: 1, wave: -1).x)
        // Inside the room its frame leaves it.
        #expect(ElfGeometry.freeHand(raise: 1, wave: 1).x + ElfGeometry.handRadius <= ElfGeometry.halfWidth)
    }

    /// Where each ankle is once its leg has turned about its hip for `kick`.
    private func ankles(kick: Double) -> [CGPoint] {
        [-1.0, 1.0].map { side in
            let rest = ElfGeometry.restingLeg(side: side)
            let turn = ElfGeometry.legTurn(side: side, kick: kick)
            let offset = CGPoint(x: rest.ankle.x - rest.hip.x, y: rest.ankle.y - rest.hip.y)
            return CGPoint(
                x: rest.hip.x + offset.x * cos(turn) - offset.y * sin(turn),
                y: rest.hip.y + offset.x * sin(turn) + offset.y * cos(turn)
            )
        }
    }

    @Test func theLegsSwingAgainstEachOther() {
        let resting = ankles(kick: 0)
        #expect(resting[0].x == -resting[1].x)
        let kicking = ankles(kick: 1)
        #expect(kicking[0].x < resting[0].x)
        #expect(kicking[1].x > resting[1].x)
        #expect(kicking.allSatisfy { $0.y < ElfGeometry.ropeTail })
    }
}
