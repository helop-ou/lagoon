import QuartzCore
import Testing
import UIKit
@testable import Lagoon

/// The moving show's layers, checked against the numbers the still picture
/// is drawn from.
@Suite("New Year fireworks in motion")
@MainActor
struct FireworksLayerTests {
    private static let page = CGSize(width: 1920, height: 1080)
    private static let tints: [UIColor] = [.cyan, .red, .yellow, .white]

    /// A show that began `ago` seconds back, laid out at once.
    private func show(began ago: Double = 0, size: CGSize = page) -> FireworksLayerView {
        let view = FireworksLayerView(startedAt: Date.now.addingTimeInterval(-ago), tints: Self.tints)
        view.frame = CGRect(origin: .zero, size: size)
        view.layoutIfNeeded()
        return view
    }

    private func flight(of layer: CALayer) throws -> (group: CAAnimationGroup, parts: [String: CAKeyframeAnimation]) {
        let group = try #require(layer.animation(forKey: FireworksLayerView.flyKey) as? CAAnimationGroup)
        let parts = (group.animations ?? []).compactMap { $0 as? CAKeyframeAnimation }
        return (group, Dictionary(uniqueKeysWithValues: parts.map { ($0.keyPath ?? "", $0) }))
    }

    @Test func thePageDimsAsTheShowStartsAndClearsAsItEnds() throws {
        let view = show()
        let scrim = try #require(view.scrimLayer)
        #expect(scrim.opacity == 0)
        let dim = try #require(scrim.animation(forKey: FireworksLayerView.dimKey) as? CAKeyframeAnimation)
        #expect(dim.values as? [Double] == [0, Fireworks.scrim, Fireworks.scrim, 0])
        #expect(dim.duration == Fireworks.duration)
        #expect(dim.keyTimes?.count == 4)
    }

    /// Fifteen hundred sparks are never all alive at once.
    @Test func onlyAShellAboutToFlyHasItsLayers() {
        let shells = FireworksFrame.shells
        let fresh = show()
        #expect(fresh.shellLayers.isEmpty)
        let partway = show(began: 4)
        let expected = shells.indices.filter { index in
            let shell = shells[index]
            return shell.launch - FireworksLayerView.lead <= 4.2
                && shell.launch + Fireworks.climb + shell.kind.burn > 3.8
        }
        #expect(!partway.shellLayers.isEmpty)
        #expect(Set(partway.shellLayers.keys).isSubset(of: Set(expected)))
        #expect(partway.shellLayers.count < shells.count / 2)
        // Whatever burnt out before it was built never is.
        let late = show(began: Fireworks.duration + 1)
        #expect(late.shellLayers.isEmpty)
    }

    @Test func aShellIsARocketAFlashAndOneStreakASpark() throws {
        let view = show()
        for index in [0, 5, 12, 20] {
            view.addShell(index)
            let shell = FireworksFrame.shells[index]
            let layers = try #require(view.shellLayers[index]?.sublayers)
            #expect(layers.count == 2 + shell.sparks.count)
            #expect(layers.allSatisfy { $0.contents != nil && !($0 is CAShapeLayer) })
            // Out of sight whenever its own animation is not running.
            #expect(layers.allSatisfy { $0.opacity == 0 })
        }
    }

    @Test func theRocketClimbsFromTheGroundToWhereItsShellBursts() throws {
        let view = show()
        view.addShell(3)
        let shell = FireworksFrame.shells[3]
        let rocket = try #require(view.shellLayers[3]?.sublayers?.first)
        let (group, parts) = try flight(of: rocket)
        let start = view.layer.convertTime(view.began, from: nil)
        #expect(abs(group.beginTime - start - shell.launch) < 1e-9)
        #expect(group.duration == Fireworks.climb)
        let points = try #require(parts["position"]?.values as? [NSValue]).map(\.cgPointValue)
        // Its leading edge is half the picture's height above its head.
        let half = FireworksLayerView.streakHeight / 2
        let ground = Fireworks.rocketPoint(of: shell, aged: 0, in: Self.page)
        let apex = Fireworks.rocketPoint(of: shell, aged: Fireworks.climb, in: Self.page)
        #expect(abs((points.first?.y ?? 0) - (ground.y - half)) < 0.0001)
        #expect(abs((points.last?.y ?? 0) - (apex.y - half)) < 0.0001)
        #expect(points.allSatisfy { abs($0.x - ground.x) < 0.0001 })
        #expect(ground.y == Self.page.height)
        // Straight up.
        let turns = try #require(parts["transform.rotation.z"]?.values as? [Double])
        #expect(turns.allSatisfy { abs($0 + .pi / 2) < 0.0001 })
    }

    @Test func everySparkFliesThePathTheStillPictureDrawsItOn() throws {
        let view = show()
        let start = view.layer.convertTime(view.began, from: nil)
        for index in [0, 7, 14] {
            view.addShell(index)
            let shell = FireworksFrame.shells[index]
            let burn = shell.kind.burn
            let layers = try #require(view.shellLayers[index]?.sublayers).dropFirst(2)
            for (layer, spark) in zip(layers, shell.sparks) {
                let (group, parts) = try flight(of: layer)
                #expect(abs(group.beginTime - start - shell.launch - Fireworks.climb) < 1e-9)
                #expect(group.duration == burn)
                let points = try #require(parts["position"]?.values as? [NSValue]).map(\.cgPointValue)
                let steps = points.count - 1
                let widths = try #require(parts["bounds.size.width"]?.values as? [Double])
                #expect(widths.count == points.count)
                for step in [0, steps / 4, steps / 2, steps] {
                    // Laid from where it was a tail's length ago to where it is.
                    let age = Double(step) / Double(steps) * burn
                    let lay = FireworksLayerView.lay(
                        head: Fireworks.point(of: spark, in: shell, aged: age, in: Self.page),
                        tail: Fireworks.point(of: spark, in: shell, aged: age - shell.kind.tail, in: Self.page)
                    )
                    #expect(points[step] == lay.edge)
                    #expect(widths[step] == lay.width)
                }
            }
        }
    }

    @Test func aStreakIsAsLongAsItsTailAndItsHeadKeepsItsShape() {
        let half = FireworksLayerView.streakHeight / 2
        let lay = FireworksLayerView.lay(head: CGPoint(x: 300, y: 200), tail: CGPoint(x: 100, y: 200))
        // Flying to the trailing side: its edge is past its head, for the glow.
        #expect(lay.turn == 0)
        #expect(lay.edge == CGPoint(x: 300 + half, y: 200))
        #expect(abs(lay.width - (FireworksLayerView.streakTail + 200 + half)) < 0.0001)
        let falling = FireworksLayerView.lay(head: CGPoint(x: 100, y: 260), tail: CGPoint(x: 100, y: 200))
        #expect(abs(falling.turn - .pi / 2) < 0.0001)
        #expect(abs(falling.edge.y - (260 + half)) < 0.0001)
        // One that has all but stopped is its head and glow, never squashed.
        let still = FireworksLayerView.lay(head: CGPoint(x: 100, y: 200), tail: CGPoint(x: 100, y: 200))
        #expect(still.width > FireworksLayerView.streakTail + FireworksLayerView.streakHeight)
        #expect(still.turn == -.pi / 2)
    }

    @Test func aStreakNeverTurnsTheLongWayRound() throws {
        let view = show()
        view.addShell(0)
        let layers = try #require(view.shellLayers[0]?.sublayers).dropFirst(2)
        for layer in layers {
            let turns = try #require(try flight(of: layer).parts["transform.rotation.z"]?.values as? [Double])
            #expect(zip(turns, turns.dropFirst()).allSatisfy { abs($1 - $0) <= .pi })
        }
    }

    @Test func aDyingSparkBlinksOnItsOwnBeat() throws {
        let view = show()
        view.addShell(0)
        let shell = FireworksFrame.shells[0]
        let layers = try #require(view.shellLayers[0]?.sublayers).dropFirst(2)
        var patterns = Set<[Bool]>()
        for layer in layers {
            let glow = try #require(try flight(of: layer).parts["opacity"])
            // Held for each blink, not faded between them.
            #expect(glow.calculationMode == .discrete)
            let values = try #require(glow.values as? [Double])
            #expect(values.count == Int((shell.kind.burn * FireworksLayerView.blinksPerSecond).rounded()))
            // Steady until it starts to glitter, then on or off.
            let steady = values.prefix(Int(Double(values.count) * Fireworks.glitterFrom) - 1)
            #expect(steady.allSatisfy { $0 > 0.8 })
            #expect(values.allSatisfy { $0 >= 0 && $0 <= 1 })
            patterns.insert(values.suffix(values.count / 3).map { $0 > 0 })
        }
        #expect(patterns.count > layers.count / 2)
        #expect(patterns.contains { $0.contains(false) && $0.contains(true) })
    }

    @Test func theFlashSwellsAndFadesWhereTheShellBursts() throws {
        let view = show()
        view.addShell(2)
        let shell = FireworksFrame.shells[2]
        let flash = try #require(view.shellLayers[2]?.sublayers?.dropFirst().first)
        #expect(flash.position == CGPoint(x: shell.lane * Self.page.width, y: shell.apex * Self.page.height))
        let group = try #require(flash.animation(forKey: FireworksLayerView.flyKey) as? CAAnimationGroup)
        #expect(group.duration == Fireworks.flashTime)
        let parts = (group.animations ?? []).compactMap { $0 as? CAKeyframeAnimation }
        let swell = try #require(parts.first { $0.keyPath == "transform.scale" }?.values as? [Double])
        let fade = try #require(parts.first { $0.keyPath == "opacity" }?.values as? [Double])
        #expect(zip(swell, swell.dropFirst()).allSatisfy { $1 > $0 })
        #expect(abs((swell.last ?? 0) - 1) < 0.001)
        #expect(swell.count == 9 && fade.count == 9)
        #expect((fade.first ?? 0) > 0.99)
        #expect(zip(fade, fade.dropFirst()).allSatisfy { $1 < $0 })
    }

    /// Coming back from the background rebuilds every layer.
    @Test func aShowRebuiltPartwayCarriesOnFromTheSameMoment() throws {
        let view = show(began: 4)
        #expect(abs(CACurrentMediaTime() - view.began - 4) < 0.5)
        let index = try #require(view.shellLayers.keys.min())
        func beginTime() throws -> CFTimeInterval {
            let rocket = try #require(view.shellLayers[index]?.sublayers?.first)
            return try flight(of: rocket).group.beginTime
        }
        let before = try beginTime()
        view.frame = CGRect(x: 0, y: 0, width: 1280, height: 720)
        view.layoutIfNeeded()
        #expect(try beginTime() == before)
    }

    @Test func aViewWithNoSizeBuildsNothing() {
        let view = FireworksLayerView(startedAt: .now, tints: Self.tints)
        view.layoutIfNeeded()
        #expect(view.shellLayers.isEmpty)
        #expect(view.scrimLayer == nil)
    }
}
