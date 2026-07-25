import Testing
@testable import DuckHuntCore

@Suite("Duck Hunt engine")
struct GameEngineTests {
    private let viewport = Size2D(width: 390, height: 844)

    @Test("A round lasts thirty seconds of active display time")
    func roundDuration() {
        var engine = GameEngine(seed: 1)
        engine.start(at: 0, in: viewport)

        var timestamp = 0.0
        while engine.snapshot.phase == .playing {
            timestamp += 1.0 / 60.0
            engine.update(at: timestamp, in: viewport, tracking: .unavailable)
        }

        #expect(timestamp >= 30)
        #expect(timestamp < 30.1)
        #expect(engine.snapshot.timeRemaining == 0)
    }

    @Test("An open mouth fires once until it closes past the rearm threshold")
    func mouthHysteresis() {
        var configuration = GameConfiguration()
        configuration.minimumSpawnInterval = 100
        configuration.maximumSpawnInterval = 100
        configuration.fireCooldown = 0.10
        var engine = GameEngine(configuration: configuration, seed: 2)
        engine.start(at: 0, in: viewport)

        engine.update(at: 0.10, in: viewport, tracking: tracking(mouth: 0.02))
        engine.update(at: 0.35, in: viewport, tracking: tracking(mouth: 0.20))
        #expect(engine.snapshot.shotsFired == 1)

        engine.update(at: 0.70, in: viewport, tracking: tracking(mouth: 0.20))
        #expect(engine.snapshot.shotsFired == 1)

        engine.update(at: 0.80, in: viewport, tracking: tracking(mouth: 0.02))
        engine.update(at: 1.10, in: viewport, tracking: tracking(mouth: 0.20))
        #expect(engine.snapshot.shotsFired == 2)
    }

    @Test("A shot at a duck removes it and awards points")
    func hitScores() throws {
        var configuration = GameConfiguration()
        configuration.minimumSpawnInterval = 100
        configuration.maximumSpawnInterval = 100
        var engine = GameEngine(configuration: configuration, seed: 3)
        engine.start(at: 0, in: viewport)
        let duck = try #require(engine.snapshot.ducks.first)

        let aim = Point2D(x: max(duck.center.x, 0), y: duck.center.y)
        engine.update(
            at: 0.25,
            in: viewport,
            tracking: tracking(gaze: aim, mouth: 0.20)
        )

        #expect(engine.snapshot.score == configuration.pointsPerDuck)
        #expect(engine.snapshot.ducks.isEmpty)
        #expect(engine.snapshot.bursts.count == 1)
        #expect(engine.snapshot.lasers.count == 2)
    }

    @Test("Tracking loss cannot fire a laser")
    func trackingLossDoesNotFire() {
        var engine = GameEngine(seed: 4)
        engine.start(at: 0, in: viewport)
        let unavailable = TrackingInput(
            gaze: Point2D(x: 100, y: 100),
            leftEye: nil,
            rightEye: nil,
            mouthOpenness: 1,
            isFaceTracked: false
        )

        engine.update(at: 0.5, in: viewport, tracking: unavailable)

        #expect(engine.snapshot.shotsFired == 0)
        #expect(engine.snapshot.lasers.isEmpty)
        #expect(!engine.snapshot.isFaceTracked)
    }

    @Test("Resuming a paused round resets frame timing")
    func resumeDoesNotConsumePause() {
        var engine = GameEngine(seed: 5)
        engine.start(at: 0, in: viewport)
        engine.update(at: 1.0 / 60.0, in: viewport, tracking: .unavailable)

        engine.resume(at: 500)
        engine.update(at: 500, in: viewport, tracking: .unavailable)

        #expect(engine.snapshot.timeRemaining > 29.98)
        #expect(engine.snapshot.phase == .playing)
    }

    private func tracking(
        gaze: Point2D = Point2D(x: 195, y: 422),
        mouth: Double
    ) -> TrackingInput {
        TrackingInput(
            gaze: gaze,
            leftEye: Point2D(x: 175, y: 280),
            rightEye: Point2D(x: 215, y: 280),
            mouthOpenness: mouth,
            isFaceTracked: true
        )
    }
}

@Suite("One Euro gaze filter")
struct OneEuroFilterTests {
    @Test("Fast eye movement is not smoothed into a long fixed-alpha tail")
    func fastResponse() {
        var filter = OneEuroFilter()
        _ = filter.filter(0.5, at: 0)

        var output = 0.5
        for index in 1 ... 5 {
            output = filter.filter(0, at: Double(index) / 60)
        }

        #expect(output < 0.20)
    }

    @Test("Stationary alternating noise is attenuated")
    func stationaryJitter() {
        var filter = OneEuroFilter()
        var outputs: [Double] = []

        for index in 0 ..< 90 {
            let input = 0.5 + (index.isMultiple(of: 2) ? -0.002 : 0.002)
            let output = filter.filter(input, at: Double(index) / 60)
            if index >= 30 {
                outputs.append(output)
            }
        }

        let spread = (outputs.max() ?? 0) - (outputs.min() ?? 0)
        #expect(spread < 0.002)
    }
}
