import QuartzCore
import Testing
import UIKit
@testable import Lagoon

/// The moving elf's layers, checked against the numbers the still picture is
/// drawn from.
@Suite("Elf visit in motion")
@MainActor
struct ElfVisitLayerTests {
    private func visit(depth: Double = 0.7, mirrored: Bool = false, ago: Double = 0) -> ElfVisitLayerView {
        let view = ElfVisitLayerView(depth: depth, isMirrored: mirrored, arrived: Date.now.addingTimeInterval(-ago))
        view.frame = CGRect(origin: .zero, size: ElfFrame.size)
        view.layoutIfNeeded()
        return view
    }

    private func keyframes(_ layer: CALayer?, _ key: String) throws -> CAKeyframeAnimation {
        let layer = try #require(layer)
        return try #require(layer.animation(forKey: key) as? CAKeyframeAnimation)
    }

    @Test func theVisitIsSampledFromItsFirstMomentToItsLast() {
        let samples = ElfVisitLayerView.samples
        #expect(samples.count == Int((ElfVisit.duration * ElfVisitLayerView.samplesPerSecond).rounded()) + 1)
        #expect(samples.first?.time == 0)
        #expect(abs((samples.last?.time ?? 0) - ElfVisit.duration) < 0.001)
        #expect(zip(samples, samples.dropFirst()).allSatisfy { $1.time > $0.time })
    }

    @Test func theElfSlidesDownItsRopeToTheDepthItWasGiven() throws {
        let view = visit(depth: 0.7)
        let samples = ElfVisitLayerView.samples
        let slide = try keyframes(view.elfLayer, ElfVisitLayerView.slideKey)
        #expect(slide.duration == ElfVisit.duration)
        let points = try #require(slide.values as? [NSValue]).map(\.cgPointValue)
        #expect(points.count == samples.count)
        for index in [0, samples.count / 4, samples.count / 2, samples.count - 1] {
            let grip = ElfVisit.grip(of: samples[index].pose, depth: 0.7)
            #expect(abs(points[index].y - (grip - ElfVisit.knot)) < 1e-9)
            #expect(points[index].x == 0)
        }
        // At the rope's end, its hand is as far down the page as its depth
        // says, give or take the bounce as the rope takes it.
        let lowest = points.map(\.y).max() ?? 0
        #expect(abs(lowest + ElfVisit.knot - 0.7 * Metrics.elfDrop) < Metrics.elfSize * 0.08)
        #expect(abs(points[samples.count / 2].y + ElfVisit.knot - 0.7 * Metrics.elfDrop) < 1e-9)
        // Outside the visit it rests out of sight above the page.
        let resting = try #require(view.elfLayer).position.y + ElfVisit.knot
        #expect(resting + ElfGeometry.bottom * ElfVisit.unit < 0)
    }

    @Test func theRopeLeansFromItsKnotToCarryTheSway() throws {
        let view = visit(depth: 0.9)
        let rope = try #require(view.ropeLayer)
        #expect(rope.position == CGPoint(x: ElfFrame.size.width / 2, y: ElfVisit.knot))
        let lean = try keyframes(rope, ElfVisitLayerView.leanKey)
        let turns = try #require(lean.values as? [Double])
        let samples = ElfVisitLayerView.samples
        for index in [0, samples.count / 3, samples.count / 2] {
            #expect(abs(turns[index] - ElfVisit.lean(of: samples[index].pose, depth: 0.9)) < 1e-12)
        }
        #expect((turns.max() ?? 0) > 0 && (turns.min() ?? 0) < 0)
        // The lean never carries it further than the room its frame leaves.
        for (turn, sample) in zip(turns, samples) {
            let rope = ElfVisit.grip(of: sample.pose, depth: 0.9) - ElfVisit.knot
            #expect(abs(sin(turn)) * max(rope, Metrics.elfSize) <= Metrics.elfSize * 0.1001)
        }
    }

    @Test func theLegsTurnAboutTheirHipsAgainstEachOther() throws {
        let view = visit()
        #expect(view.legLayers.count == 2)
        let samples = ElfVisitLayerView.samples
        var turns: [[Double]] = []
        for (leg, side) in zip(view.legLayers, [-1.0, 1.0]) {
            let hip = ElfGeometry.restingLeg(side: side).hip
            #expect(abs(leg.position.x - hip.x) < 0.0001 && abs(leg.position.y - hip.y) < 0.0001)
            #expect(leg.contents != nil)
            let kick = try keyframes(leg, ElfVisitLayerView.kickKey)
            let values = try #require(kick.values as? [Double])
            let expected = ElfGeometry.legTurn(side: side, kick: samples[samples.count / 5].pose.kick)
            #expect(abs(values[samples.count / 5] - expected) < 1e-12)
            turns.append(values)
        }
        #expect(zip(turns[0], turns[1]).allSatisfy { abs($0 + $1) < 0.0001 })
        #expect((turns[0].max() ?? 0) > 0.1)
    }

    @Test func theFreeArmLeavesTheRopeOnlyToWave() throws {
        let view = visit()
        let samples = ElfVisitLayerView.samples
        let hand = try keyframes(view.handLayer, ElfVisitLayerView.waveKey)
        let points = try #require(hand.values as? [NSValue]).map(\.cgPointValue)
        let arm = try keyframes(view.armLayer, ElfVisitLayerView.waveKey)
        #expect(arm.values?.count == samples.count)
        for (point, sample) in zip(points, samples) where sample.pose.raise == 0 {
            #expect(point == ElfGeometry.upperHand)
        }
        let raised = zip(points, samples).filter { $0.1.pose.raise == 1 }.map(\.0)
        #expect(!raised.isEmpty)
        #expect(raised.allSatisfy { $0.x > ElfGeometry.rightShoulder.x + 15 })
        #expect((raised.map(\.x).max() ?? 0) - (raised.map(\.x).min() ?? 0) > 6)
        #expect(view.armLayer?.fillColor == nil)
    }

    @Test func itTurnsToFaceTheOtherWayWhenAsked() throws {
        let facing = try #require(visit(mirrored: false).elfLayer).affineTransform()
        let turned = try #require(visit(mirrored: true).elfLayer).affineTransform()
        #expect(facing.a == ElfVisit.unit && facing.d == ElfVisit.unit)
        #expect(turned.a == -ElfVisit.unit && turned.d == ElfVisit.unit)
    }

    /// Coming back from the background rebuilds every layer.
    @Test func aVisitRebuiltPartwayCarriesOnFromTheSameMoment() throws {
        let view = visit(ago: 5)
        #expect(abs(CACurrentMediaTime() - view.began - 5) < 0.5)
        let before = try keyframes(view.elfLayer, ElfVisitLayerView.slideKey).beginTime
        view.frame = CGRect(x: 0, y: 0, width: ElfFrame.size.width + 20, height: ElfFrame.size.height)
        view.layoutIfNeeded()
        #expect(try keyframes(view.elfLayer, ElfVisitLayerView.slideKey).beginTime == before)
        #expect(view.layer.sublayers?.count == 1)
    }

    @Test func aViewWithNoSizeBuildsNothing() {
        let view = ElfVisitLayerView(depth: 1, isMirrored: false, arrived: .now)
        view.layoutIfNeeded()
        #expect(view.elfLayer == nil)
        #expect(view.legLayers.isEmpty)
    }
}
