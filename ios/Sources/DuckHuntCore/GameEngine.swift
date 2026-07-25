import Foundation

/// Deterministic, display-framework-independent Duck Hunt simulation.
public struct GameEngine: Sendable {
    private let configuration: GameConfiguration
    private var random: SplitMix64
    private var ducks: [Duck] = []
    private var lasers: [LaserBeam] = []
    private var bursts: [ImpactBurst] = []
    private var phase: GamePhase = .ready
    private var score = 0
    private var shotsFired = 0
    private var aim = Point2D.zero
    private var isFaceTracked = false
    private var hitRadius = 18.0
    private var elapsedTime = 0.0
    private var lastTimestamp: Double?
    private var nextSpawnTime = 0.0
    private var lastFireTime = -Double.infinity
    private var mouthIsArmed = true
    private var nextEntityID = 0

    public init(
        configuration: GameConfiguration = .standard,
        seed: UInt64 = 0x4455_434B_4855_4E54
    ) {
        self.configuration = configuration
        self.random = SplitMix64(seed: seed)
    }

    /// Starts a fresh round and discards every entity from the previous round.
    public mutating func start(at timestamp: Double, in viewport: Size2D) {
        ducks.removeAll(keepingCapacity: true)
        lasers.removeAll(keepingCapacity: true)
        bursts.removeAll(keepingCapacity: true)
        phase = .playing
        score = 0
        shotsFired = 0
        aim = Point2D(x: viewport.width / 2, y: viewport.height / 2)
        isFaceTracked = false
        hitRadius = min(viewport.width, viewport.height) * 0.075
        elapsedTime = 0
        lastTimestamp = timestamp
        nextSpawnTime = 0
        lastFireTime = -Double.infinity
        mouthIsArmed = true
        spawnDuck(in: viewport)
        scheduleNextSpawn()
    }

    /// Resets frame timing after a paused round without changing game state.
    public mutating func resume(at timestamp: Double) {
        guard phase == .playing else { return }
        lastTimestamp = timestamp
    }

    /// Advances the simulation by one display frame.
    ///
    /// Large timestamp gaps are clamped, so suspending and resuming the app does not
    /// consume the round or launch entities through the display.
    public mutating func update(
        at timestamp: Double,
        in viewport: Size2D,
        tracking: TrackingInput
    ) {
        guard phase == .playing else { return }

        let deltaTime: Double
        if let lastTimestamp {
            deltaTime = min(max(timestamp - lastTimestamp, 0), configuration.maximumFrameDelta)
        } else {
            deltaTime = 0
        }
        self.lastTimestamp = timestamp
        elapsedTime += deltaTime
        hitRadius = min(viewport.width, viewport.height) * 0.075

        updateDucks(deltaTime: deltaTime, in: viewport)
        removeExpiredEffects()

        if elapsedTime >= configuration.duration {
            phase = .finished
            isFaceTracked = tracking.isFaceTracked
            return
        }

        if elapsedTime >= nextSpawnTime {
            spawnDuck(in: viewport)
            scheduleNextSpawn()
        }

        updateAimAndFire(from: tracking, in: viewport)
    }

    /// Returns the current immutable render state.
    public var snapshot: GameSnapshot {
        let locked = isFaceTracked && ducks.contains { duck in
            aim.distanceSquared(to: duck.center) <=
                (duck.radius + hitRadius) * (duck.radius + hitRadius)
        }

        return GameSnapshot(
            phase: phase,
            score: score,
            timeRemaining: max(0, configuration.duration - elapsedTime),
            elapsedTime: elapsedTime,
            aim: aim,
            isFaceTracked: isFaceTracked,
            isTargetLocked: locked,
            shotsFired: shotsFired,
            ducks: ducks,
            lasers: lasers,
            bursts: bursts
        )
    }


    private mutating func updateAimAndFire(from tracking: TrackingInput, in viewport: Size2D) {
        isFaceTracked = tracking.isFaceTracked
        guard tracking.isFaceTracked, let gaze = tracking.gaze else {
            mouthIsArmed = false
            return
        }

        aim = gaze.clamped(to: viewport)

        if tracking.mouthOpenness <= configuration.mouthRearmThreshold {
            mouthIsArmed = true
        }

        guard
            mouthIsArmed,
            tracking.mouthOpenness >= configuration.mouthFireThreshold,
            elapsedTime - lastFireTime >= configuration.fireCooldown
        else { return }

        mouthIsArmed = false
        lastFireTime = elapsedTime
        shotsFired += 1

        let fallbackY = viewport.height * 0.30
        let origins = [
            tracking.leftEye ?? Point2D(x: viewport.width * 0.46, y: fallbackY),
            tracking.rightEye ?? Point2D(x: viewport.width * 0.54, y: fallbackY),
        ]
        for origin in origins {
            lasers.append(
                LaserBeam(
                    id: takeEntityID(),
                    origin: origin.clamped(to: viewport),
                    target: aim,
                    bornAt: elapsedTime,
                    duration: configuration.laserLifetime
                )
            )
        }

        guard let hitIndex = ducks.firstIndex(where: { duck in
            aim.distanceSquared(to: duck.center) <= (duck.radius + hitRadius) * (duck.radius + hitRadius)
        }) else { return }

        let hitDuck = ducks.remove(at: hitIndex)
        score += configuration.pointsPerDuck
        bursts.append(
            ImpactBurst(
                id: takeEntityID(),
                center: hitDuck.center,
                bornAt: elapsedTime,
                duration: configuration.burstLifetime
            )
        )
    }

    private mutating func updateDucks(deltaTime: Double, in viewport: Size2D) {
        for index in ducks.indices {
            ducks[index].center.x += ducks[index].horizontalSpeed * deltaTime
            ducks[index].center.y -= ducks[index].bobOffset
            ducks[index].wingPhase += deltaTime * 12
            ducks[index].bobOffset = sin(ducks[index].wingPhase) * ducks[index].radius * 0.18
            ducks[index].center.y += ducks[index].bobOffset
        }

        ducks.removeAll { duck in
            duck.center.x < -duck.radius * 2 ||
                duck.center.x > viewport.width + duck.radius * 2
        }
    }

    private mutating func spawnDuck(in viewport: Size2D) {
        let shortSide = min(viewport.width, viewport.height)
        let radius = min(max(shortSide * 0.045, 16), 34)
        let fliesRight = randomUnit() < 0.5
        let progress = min(max(elapsedTime / configuration.duration, 0), 1)
        let baselineSpeed = configuration.minimumDuckSpeed +
            (configuration.maximumDuckSpeed - configuration.minimumDuckSpeed) * progress
        let speed = baselineSpeed * random(in: 0.88 ... 1.12)
        let minimumY = max(radius * 2, viewport.height * 0.16)
        let maximumY = max(minimumY, viewport.height * 0.70)

        ducks.append(
            Duck(
                id: takeEntityID(),
                center: Point2D(
                    x: fliesRight ? -radius : viewport.width + radius,
                    y: random(in: minimumY ... maximumY)
                ),
                radius: radius,
                facesRight: fliesRight,
                wingPhase: random(in: 0 ... (.pi * 2)),
                horizontalSpeed: fliesRight ? speed : -speed,
                bobOffset: 0
            )
        )
    }

    private mutating func scheduleNextSpawn() {
        let progress = min(max(elapsedTime / configuration.duration, 0), 1)
        let maximumInterval = configuration.maximumSpawnInterval -
            (configuration.maximumSpawnInterval - configuration.minimumSpawnInterval) * progress
        nextSpawnTime = elapsedTime + random(in: configuration.minimumSpawnInterval ... maximumInterval)
    }

    private mutating func removeExpiredEffects() {
        lasers.removeAll { elapsedTime - $0.bornAt > configuration.laserLifetime }
        bursts.removeAll { elapsedTime - $0.bornAt > configuration.burstLifetime }
    }

    private mutating func takeEntityID() -> Int {
        defer { nextEntityID &+= 1 }
        return nextEntityID
    }

    private mutating func random(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * randomUnit()
    }

    private mutating func randomUnit() -> Double {
        Double(random.next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }
}

private struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
