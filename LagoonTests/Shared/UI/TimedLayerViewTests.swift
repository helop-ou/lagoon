import Testing
import UIKit
@testable import Lagoon

/// What every moving surprise leans on: when its layers are laid out again,
/// and when their animations begin.
@Suite("A view of timed layers")
@MainActor
struct TimedLayerViewTests {
    private final class Probe: TimedLayerView {
        private(set) var builds = 0
        private(set) var dot: CALayer?

        override func forgetLayers() {
            dot = nil
        }

        var dims = false

        override func addLayers() {
            builds += 1
            if dims { addScrim(strength: 0.6, fadeIn: 1, fadeOut: 2, over: 8) }
            let dot = CALayer()
            animate(dot, "opacity", [0.0, 1.0, 0.0], over: 6, key: "fade")
            layer.addSublayer(dot)
            self.dot = dot
        }
    }

    private func probe(ago: TimeInterval = 0, size: CGSize = CGSize(width: 400, height: 300)) -> Probe {
        let view = Probe(startedAt: Date.now.addingTimeInterval(-ago))
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view
    }

    @Test func itLaysItsLayersOutOnceItHasRoom() {
        let view = probe()
        #expect(view.builds == 1)
        #expect(view.layer.sublayers?.count == 1)
        #expect(!view.isUserInteractionEnabled)
    }

    @Test func aNewSizeLaysThemOutAgainAndTheSameSizeDoesNot() {
        let view = probe()
        view.setNeedsLayout()
        view.layoutIfNeeded()
        #expect(view.builds == 1)
        view.frame.size = CGSize(width: 800, height: 300)
        view.layoutIfNeeded()
        #expect(view.builds == 2)
        // The earlier build's layers are gone, not added to.
        #expect(view.layer.sublayers?.count == 1)
    }

    @Test func withNoRoomItKeepsNothing() {
        let view = probe()
        let first = view.dot
        #expect(first != nil)
        view.frame.size = .zero
        view.layoutIfNeeded()
        #expect(view.builds == 1)
        #expect(view.dot == nil)
        #expect(view.layer.sublayers?.isEmpty ?? true)
        #expect(first?.superlayer == nil)
    }

    @Test func comingBackToTheFrontLaysThemOutAgain() {
        let view = probe()
        NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        #expect(view.builds == 2)
    }

    @Test func itsAnimationsBeginWhenItDid() throws {
        let view = probe(ago: 4)
        #expect(abs(CACurrentMediaTime() - view.began - 4) < 0.5)
        let dot = try #require(view.dot)
        let fade = try #require(dot.animation(forKey: "fade") as? CAKeyframeAnimation)
        #expect(fade.keyPath == "opacity")
        #expect(fade.values as? [Double] == [0, 1, 0])
        #expect(fade.duration == 6)
        #expect(fade.calculationMode == .linear)
        #expect(fade.beginTime == view.layer.convertTime(view.began, from: nil))
        #expect(fade.beginTime != 0)
        // One laid out again later carries on from the same moment.
        view.rebuild()
        let again = try #require(view.dot?.animation(forKey: "fade") as? CAKeyframeAnimation)
        #expect(again.beginTime == fade.beginTime)
    }

    /// The page dims as the picture arrives and clears as it leaves.
    @Test func itsScrimDimsOverTheFadeInAndClearsOverTheFadeOut() throws {
        let view = probe(ago: 3)
        #expect(view.scrimLayer == nil)
        view.dims = true
        view.rebuild()
        let scrim = try #require(view.scrimLayer)
        #expect(scrim.frame == view.bounds)
        #expect(scrim.opacity == 0)
        let dim = try #require(scrim.animation(forKey: TimedLayerView.dimKey) as? CAKeyframeAnimation)
        #expect(dim.keyPath == "opacity")
        #expect(dim.values as? [Double] == [0, 0.6, 0.6, 0])
        #expect(dim.keyTimes == [0, 0.125, 0.75, 1])
        #expect(dim.duration == 8)
        #expect(dim.beginTime == view.layer.convertTime(view.began, from: nil))
        // Laid out again, there is still one.
        view.rebuild()
        #expect(view.layer.sublayers?.filter { $0.backgroundColor != nil }.count == 1)
        view.frame.size = .zero
        view.layoutIfNeeded()
        #expect(view.scrimLayer == nil)
    }
}
