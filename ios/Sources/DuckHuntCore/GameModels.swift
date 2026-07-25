import Foundation

/// The lifecycle state of a Duck Hunt round.
public enum GamePhase: Equatable, Sendable {
    case ready
    case playing
    case finished
}

/// A duck currently moving through the play field.
public struct Duck: Identifiable, Sendable {
    public let id: Int
    public var center: Point2D
    public let radius: Double
    public let facesRight: Bool
    public var wingPhase: Double

    var horizontalSpeed: Double
    var bobOffset: Double
}

/// A short-lived laser beam drawn after the player fires.
public struct LaserBeam: Identifiable, Sendable {
    public let id: Int
    public let origin: Point2D
    public let target: Point2D
    public let bornAt: Double
    public let duration: Double
}

/// A short-lived impact effect drawn after a duck is hit.
public struct ImpactBurst: Identifiable, Sendable {
    public let id: Int
    public let center: Point2D
    public let bornAt: Double
    public let duration: Double
}

/// One frame of face-tracking information consumed by the game engine.
public struct TrackingInput: Sendable {
    public var gaze: Point2D?
    public var leftEye: Point2D?
    public var rightEye: Point2D?
    public var mouthOpenness: Double
    public var isFaceTracked: Bool

    public init(
        gaze: Point2D?,
        leftEye: Point2D?,
        rightEye: Point2D?,
        mouthOpenness: Double,
        isFaceTracked: Bool
    ) {
        self.gaze = gaze
        self.leftEye = leftEye
        self.rightEye = rightEye
        self.mouthOpenness = mouthOpenness
        self.isFaceTracked = isFaceTracked
    }

    public static let unavailable = TrackingInput(
        gaze: nil,
        leftEye: nil,
        rightEye: nil,
        mouthOpenness: 0,
        isFaceTracked: false
    )
}

/// An immutable render snapshot of the current round.
public struct GameSnapshot: Sendable {
    public let phase: GamePhase
    public let score: Int
    public let timeRemaining: Double
    public let elapsedTime: Double
    public let aim: Point2D
    public let isFaceTracked: Bool
    public let isTargetLocked: Bool
    public let shotsFired: Int
    public let ducks: [Duck]
    public let lasers: [LaserBeam]
    public let bursts: [ImpactBurst]

    public static let empty = GameSnapshot(
        phase: .ready,
        score: 0,
        timeRemaining: GameConfiguration.standard.duration,
        elapsedTime: 0,
        aim: .zero,
        isFaceTracked: false,
        isTargetLocked: false,
        shotsFired: 0,
        ducks: [],
        lasers: [],
        bursts: []
    )
}

/// Tunable rules for one Duck Hunt round.
public struct GameConfiguration: Sendable {
    public var duration: Double
    public var pointsPerDuck: Int
    public var mouthFireThreshold: Double
    public var mouthRearmThreshold: Double
    public var fireCooldown: Double
    public var laserLifetime: Double
    public var burstLifetime: Double
    public var minimumSpawnInterval: Double
    public var maximumSpawnInterval: Double
    public var minimumDuckSpeed: Double
    public var maximumDuckSpeed: Double
    public var maximumFrameDelta: Double

    public init(
        duration: Double = 30,
        pointsPerDuck: Int = 100,
        mouthFireThreshold: Double = 0.09,
        mouthRearmThreshold: Double = 0.055,
        fireCooldown: Double = 0.22,
        laserLifetime: Double = 0.13,
        burstLifetime: Double = 0.32,
        minimumSpawnInterval: Double = 0.42,
        maximumSpawnInterval: Double = 1.10,
        minimumDuckSpeed: Double = 90,
        maximumDuckSpeed: Double = 260,
        maximumFrameDelta: Double = 1.0 / 15.0
    ) {
        self.duration = duration
        self.pointsPerDuck = pointsPerDuck
        self.mouthFireThreshold = mouthFireThreshold
        self.mouthRearmThreshold = mouthRearmThreshold
        self.fireCooldown = fireCooldown
        self.laserLifetime = laserLifetime
        self.burstLifetime = burstLifetime
        self.minimumSpawnInterval = minimumSpawnInterval
        self.maximumSpawnInterval = maximumSpawnInterval
        self.minimumDuckSpeed = minimumDuckSpeed
        self.maximumDuckSpeed = maximumDuckSpeed
        self.maximumFrameDelta = maximumFrameDelta
    }

    public static let standard = GameConfiguration()
}
