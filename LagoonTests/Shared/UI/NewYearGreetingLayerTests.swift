import QuartzCore
import Testing
import UIKit
@testable import Lagoon

/// The moving greeting's layers, checked against the numbers the still
/// picture is drawn from.
@Suite("New Year greeting in motion")
@MainActor
struct NewYearGreetingLayerTests {
    private nonisolated static let page = CGSize(width: 1920, height: 1080)

    private func greeting(year: Int = 2027, ago: Double = 0, size: CGSize = page) -> NewYearGreetingLayerView {
        let view = NewYearGreetingLayerView(startedAt: Date.now.addingTimeInterval(-ago), year: year)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view
    }

    private func values(_ layer: CALayer?, _ key: String) throws -> [Double] {
        let layer = try #require(layer)
        let animation = try #require(layer.animation(forKey: key) as? CAKeyframeAnimation)
        #expect(animation.duration == Fireworks.duration)
        return try #require(animation.values as? [Double])
    }

    @Test func theGreetingIsSampledFromTheShowsFirstMomentToItsLast() {
        let times = NewYearGreetingLayerView.sampleTimes
        #expect(times.first == 0)
        #expect(times.last == Fireworks.duration)
        #expect(times.count == Int(Fireworks.duration * NewYearGreetingLayerView.samplesPerSecond) + 1)
    }

    @Test func theNumeralsStandSideBySideAboutThePagesMiddleUnderTheLine() throws {
        let view = greeting()
        #expect(view.numeralLayers.count == 4)
        let margin = NewYearGreetingLayerView.margin
        // Each picture carries a margin for its glow, so the numerals
        // themselves touch.
        let frames = view.numeralLayers.map { $0.frame.insetBy(dx: margin, dy: margin) }
        for (leading, trailing) in zip(frames, frames.dropFirst()) {
            #expect(abs(leading.maxX - trailing.minX) < 0.5)
            #expect(abs(leading.midY - trailing.midY) < 0.5)
        }
        let row = frames.reduce(frames[0]) { $0.union($1) }
        #expect(abs(row.midX - Self.page.width / 2) < 0.5)
        let title = try #require(view.titleLayer).frame.insetBy(dx: margin, dy: margin)
        #expect(abs(title.midX - Self.page.width / 2) < 0.5)
        #expect(abs(title.maxY + Metrics.Space.s - row.minY) < 0.5)
        // The pair is about the greeting's middle.
        #expect(abs((title.minY + row.maxY) / 2 - Self.page.height * NewYearGreeting.height) < 0.5)
        // The band of light is held to the numerals.
        let shine = try #require(view.shineLayer)
        #expect(abs(shine.frame.minX - row.minX) < 0.5 && abs(shine.frame.width - row.width) < 0.5)
        #expect(shine.mask?.sublayers?.count == 4)
    }

    @Test func theNumeralsPopInOneAfterAnotherThenTheLineFadesIn() throws {
        let view = greeting()
        let times = NewYearGreetingLayerView.sampleTimes
        var arrivals: [Double] = []
        for (index, layer) in view.numeralLayers.enumerated() {
            #expect(layer.opacity == 0)
            let since = NewYearGreeting.arrival(ofNumeral: index)
            let fade = try values(layer, NewYearGreetingLayerView.fadeKey)
            let pop = try values(layer, NewYearGreetingLayerView.popKey)
            for step in [0, times.count / 6, times.count / 2] {
                #expect(fade[step] == NewYearGreeting.rise(since: since, at: times[step], over: NewYearGreeting.numeralRise))
                #expect(pop[step] == NewYearGreeting.pop(since: since, at: times[step]))
            }
            // Past full size on the way in, then settled at it.
            #expect((pop.max() ?? 0) > 1.05)
            #expect(abs((pop.last ?? 0) - 1) < 0.001)
            arrivals.append(times[fade.firstIndex { $0 > 0 } ?? 0])
        }
        #expect(zip(arrivals, arrivals.dropFirst()).allSatisfy { $1 > $0 })
        let line = try values(view.titleLayer, NewYearGreetingLayerView.fadeKey)
        #expect(times[line.firstIndex { $0 > 0 } ?? 0] > arrivals[0])
        #expect(line.last == 1)
    }

    @Test func theBandOfLightCrossesTheNumeralsThreeTimes() throws {
        let view = greeting()
        let shine = try #require(view.shineLayer)
        let band = try #require(shine.sublayers?.first)
        let cross = try #require(band.animation(forKey: NewYearGreetingLayerView.crossKey) as? CAKeyframeAnimation)
        let points = try #require(cross.values as? [NSValue]).map(\.cgPointValue.x)
        let times = NewYearGreetingLayerView.sampleTimes
        for step in [0, times.count / 5, times.count / 2] {
            let expected = shine.bounds.width * NewYearGreeting.shinePosition(at: times[step])
            #expect(abs(points[step] - expected) < 1e-9)
        }
        // Off to one side between crossings, and across the row in each.
        var crossings = 0
        var crossing = false
        for point in points {
            let over = point > 0 && point < shine.bounds.width
            if over && !crossing { crossings += 1 }
            crossing = over
        }
        #expect(crossings == 3)
        #expect(abs(band.bounds.width - shine.bounds.width * NewYearGreeting.shineWidth) < 0.0001)
    }

    @Test func theStarsTwinkleEachOnItsOwnBeat() throws {
        let view = greeting()
        let times = NewYearGreetingLayerView.sampleTimes
        #expect(view.starLayers.count == NewYearGreeting.stars.count)
        var beats = Set<[Bool]>()
        for (layer, star) in zip(view.starLayers, NewYearGreeting.stars) {
            #expect(layer.opacity == 0 && layer.contents != nil)
            let twinkle = try values(layer, NewYearGreetingLayerView.fadeKey)
            #expect(twinkle[times.count / 2] == NewYearGreeting.brightness(of: star, at: times[times.count / 2]))
            #expect(twinkle.first == 0)
            #expect((twinkle.max() ?? 0) > 0.9)
            beats.insert(twinkle.map { $0 > 0.5 })
        }
        #expect(beats.count == NewYearGreeting.stars.count)
    }

    @Test func theWholeGreetingLeavesWithTheLastSparks() throws {
        let view = greeting()
        let times = NewYearGreetingLayerView.sampleTimes
        let greeting = try #require(view.greetingLayer)
        #expect(greeting.opacity == 0)
        let fade = try values(greeting, NewYearGreetingLayerView.fadeKey)
        #expect(fade.first == 1)
        #expect(fade.last == 0)
        let gone = times[fade.firstIndex { $0 == 0 } ?? 0]
        #expect(abs(gone - NewYearGreeting.leaves) < 0.05)
    }

    /// A year of any length, and a page too narrow for it.
    @Test func numeralsThatWouldNotFitShrinkTogether() throws {
        let roomy = greeting(year: 2027)
        let narrow = greeting(year: 2027, size: CGSize(width: 300, height: 600))
        let margin = NewYearGreetingLayerView.margin
        func row(_ view: NewYearGreetingLayerView) -> CGRect {
            let frames = view.numeralLayers.map { $0.frame.insetBy(dx: margin, dy: margin) }
            return frames.reduce(frames[0]) { $0.union($1) }
        }
        #expect(narrow.numeralLayers.count == 4)
        let room = 300 - Metrics.Space.l * 2
        if row(roomy).width > room {
            // To fit, or to half their size if even that is too wide.
            #expect(row(narrow).width <= max(room + 1, row(roomy).width * 0.52))
            #expect(row(narrow).width >= row(roomy).width * 0.48)
            #expect(row(narrow).height < row(roomy).height)
        }
        // A page with room to spare leaves them at full size.
        let wide = greeting(year: 2027, size: CGSize(width: 3000, height: 1080))
        #expect(abs(row(wide).width - row(roomy).width) < 0.5)
        #expect(greeting(year: 12345).numeralLayers.count == 5)
    }

    /// Coming back from the background rebuilds every layer.
    @Test func aGreetingRebuiltPartwayCarriesOnFromTheSameMoment() throws {
        let view = greeting(ago: 4)
        #expect(abs(CACurrentMediaTime() - view.began - 4) < 0.5)
        func beginTime() throws -> CFTimeInterval {
            let greeting = try #require(view.greetingLayer)
            return try #require(greeting.animation(forKey: NewYearGreetingLayerView.fadeKey)).beginTime
        }
        let before = try beginTime()
        view.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        view.layoutIfNeeded()
        #expect(try beginTime() == before)
        #expect(view.layer.sublayers?.count == 1)
    }

    @Test func aViewWithNoSizeBuildsNothing() {
        let view = NewYearGreetingLayerView(startedAt: .now, year: 2027)
        view.layoutIfNeeded()
        #expect(view.greetingLayer == nil)
        #expect(view.numeralLayers.isEmpty)
    }
}
