import QuartzCore
import Testing
import UIKit
@testable import Lagoon

/// The moving flight's layers, checked against the numbers the still picture
/// is drawn from.
@Suite("Santa's sleigh in motion")
@MainActor
struct SantaFlightLayerTests {
    private nonisolated static let page = CGSize(width: 1920, height: 1080)

    private func flight(startedAt: Date = .now, size: CGSize = page) -> SantaFlightLayerView {
        let view = SantaFlightLayerView(startedAt: startedAt)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view
    }

    @Test func thePathIsSampledFromOneEdgeOfThePageToTheOther() {
        let times = SantaFlightLayerView.sampleTimes
        #expect(times.first == 0)
        #expect(times.last == SantaFlight.crossing)
        #expect(times.count == Int(SantaFlight.crossing * SantaFlightLayerView.samplesPerSecond) + 1)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 > $0 })
    }

    @Test func everyFigureFollowsThePathTheStillPictureDrawsItOn() throws {
        let view = flight()
        let times = SantaFlightLayerView.sampleTimes
        #expect(view.memberLayers.count == SantaFlight.team.count)
        for (layer, member) in zip(view.memberLayers, SantaFlight.team) {
            let move = try #require(layer.animation(forKey: SantaFlightLayerView.moveKey) as? CAKeyframeAnimation)
            let lean = try #require(layer.animation(forKey: SantaFlightLayerView.leanKey) as? CAKeyframeAnimation)
            #expect(move.duration == SantaFlight.crossing)
            #expect(lean.duration == SantaFlight.crossing)
            let points = try #require(move.values as? [NSValue]).map(\.cgPointValue)
            let turns = try #require(lean.values as? [Double])
            #expect(points.count == times.count)
            for index in [0, times.count / 3, times.count - 1] {
                let placement = SantaFlight.placement(of: member, at: times[index], in: Self.page)
                #expect(points[index] == placement.center)
                #expect(turns[index] == placement.turn)
            }
            // It rests off the page, where the flight leaves it.
            #expect(layer.position.x > Self.page.width)
        }
        // The sleigh is over the reindeer, as it is drawn.
        #expect(view.memberLayers.last?.sublayers?.count == 1)
    }

    @Test func everyLegSwingsOnceAStrideAndNoTwoReindeerRunInStep() throws {
        let view = flight()
        // Six reindeer, four legs each, in two pieces.
        #expect(view.legLayers.count == 6 * 4 * 2)
        var offsets = Set<Double>()
        for leg in view.legLayers {
            let swing = try #require(leg.animation(forKey: SantaFlightLayerView.gallopKey) as? CABasicAnimation)
            #expect(swing.duration == 1 / SantaFlight.gallop / 2)
            #expect(swing.autoreverses)
            #expect(swing.repeatCount == .infinity)
            #expect(swing.fromValue != nil && swing.toValue != nil)
            #expect(swing.timeOffset >= 0 && swing.timeOffset < 1 / SantaFlight.gallop)
            offsets.insert((swing.timeOffset * 1000).rounded())
        }
        #expect(offsets.count == 6)
    }

    @Test func theReinsFollowTheTeamFromEdgeToEdge() throws {
        let view = flight()
        let reins = try #require(view.reinsLayer)
        let follow = try #require(reins.animation(forKey: SantaFlightLayerView.reinsKey) as? CAKeyframeAnimation)
        let times = SantaFlightLayerView.sampleTimes
        #expect(follow.values?.count == times.count)
        #expect(follow.duration == SantaFlight.crossing)
        let first = try #require(follow.values?.first)
        #expect((first as! CGPath).boundingBox == SantaFlight.reins(at: 0, in: Self.page).cgPath.boundingBox)
        #expect(reins.fillColor == nil)
    }

    @Test func everyMoteWaitsForItsMomentAndIsGoneWhenItHasBurntOut() throws {
        let view = flight()
        let start = view.layer.convertTime(view.began, from: nil)
        #expect(view.moteLayers.count == SantaFlight.dust.count)
        for (layer, mote) in zip(view.moteLayers, SantaFlight.dust) {
            // Out of sight whenever its own animation is not running.
            #expect(layer.opacity == 0)
            let life = try #require(layer.animation(forKey: SantaFlightLayerView.driftKey) as? CAAnimationGroup)
            #expect(abs(life.beginTime - start - mote.born) < 1e-9)
            #expect(life.duration == mote.life)
            let fall = try #require(life.animations?.first as? CAKeyframeAnimation)
            let points = try #require(fall.values as? [NSValue]).map(\.cgPointValue)
            // It falls.
            #expect((points.last?.y ?? 0) > (points.first?.y ?? 0))
            #expect(life.animations?.count == (mote.isStar ? 4 : 3))
        }
    }

    @Test func thePageDimsAsTheSleighArrivesAndClearsWithTheLastDust() throws {
        let view = flight()
        let scrim = try #require(view.scrimLayer)
        #expect(scrim.opacity == 0)
        let dim = try #require(scrim.animation(forKey: SantaFlightLayerView.dimKey) as? CAKeyframeAnimation)
        #expect(dim.values as? [Double] == [0, SantaFlight.scrim, SantaFlight.scrim, 0])
        #expect(dim.duration == SantaFlight.duration)
        #expect(dim.keyTimes?.count == 4)
    }

    /// Coming back from the background rebuilds every layer.
    @Test func aFlightRebuiltPartwayCarriesOnFromTheSameMoment() throws {
        let view = flight(startedAt: Date.now.addingTimeInterval(-5))
        #expect(abs(CACurrentMediaTime() - view.began - 5) < 0.5)
        func beginTime() throws -> CFTimeInterval {
            let layer = try #require(view.memberLayers.first)
            return try #require(layer.animation(forKey: SantaFlightLayerView.moveKey)).beginTime
        }
        let before = try beginTime()
        view.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        view.layoutIfNeeded()
        #expect(try beginTime() == before)
        #expect(view.memberLayers.count == SantaFlight.team.count)
        #expect(view.layer.sublayers?.count == 1 + SantaFlight.dust.count + SantaFlight.team.count + 1)
    }

    @Test func aViewWithNoSizeBuildsNothing() {
        let view = SantaFlightLayerView(startedAt: .now)
        view.layoutIfNeeded()
        #expect(view.memberLayers.isEmpty)
        #expect(view.moteLayers.isEmpty)
        #expect(view.scrimLayer == nil)
    }
}
