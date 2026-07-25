import DuckHuntCore
import Observation
import QuartzCore
import UIKit

@MainActor
@Observable
final class GameSession {
    private(set) var renderSnapshot = GameSnapshot.empty
    private(set) var phase: GamePhase = .ready
    private(set) var score = 0
    private(set) var remainingSeconds = Int(GameConfiguration.standard.duration)
    private(set) var isFaceTracked = false
    private(set) var isTargetLocked = false
    @ObservationIgnored var onFinished: ((Int) -> Void)?

    @ObservationIgnored private var engine = GameEngine()
    @ObservationIgnored private var viewport = Size2D(width: 1, height: 1)
    @ObservationIgnored private var latestTracking = NormalizedTracking.unavailable
    @ObservationIgnored private var horizontalFilter = OneEuroFilter()
    @ObservationIgnored private var verticalFilter = OneEuroFilter()
    private let displayLink = DisplayLinkDriver()

    init() {
        displayLink.onFrame = { [weak self] timestamp in
            self?.advance(at: timestamp)
        }
    }

    func receive(_ frame: FaceTrackingFrame, predictedGaze: Point2D?) {
        guard frame.status == .tracked, let predictedGaze else {
            latestTracking = .unavailable
            horizontalFilter.reset()
            verticalFilter.reset()
            return
        }

        latestTracking = NormalizedTracking(
            gaze: NormalizedPoint(
                x: horizontalFilter.filter(predictedGaze.x, at: frame.timestamp),
                y: verticalFilter.filter(predictedGaze.y, at: frame.timestamp)
            ),
            leftEye: frame.leftEye,
            rightEye: frame.rightEye,
            mouthOpenness: frame.jawOpen,
            isFaceTracked: true
        )
    }

    func start(in size: CGSize) {
        latestTracking = .unavailable
        horizontalFilter.reset()
        verticalFilter.reset()
        viewport = Size2D(width: size.width, height: size.height)
        let now = CACurrentMediaTime()
        engine.start(at: now, in: viewport)
        publish(engine.snapshot)
        displayLink.start()
    }

    func updateViewport(_ size: CGSize) {
        viewport = Size2D(width: size.width, height: size.height)
    }

    func pause() {
        latestTracking = .unavailable
        horizontalFilter.reset()
        verticalFilter.reset()
        displayLink.stop()
    }

    func resume() {
        guard phase == .playing else { return }
        let now = CACurrentMediaTime()
        engine.resume(at: now)
        displayLink.start()
    }

    func stop() {
        displayLink.stop()
    }

    private func advance(at timestamp: TimeInterval) {
        let tracking = TrackingInput(
            gaze: latestTracking.gaze?.point(in: viewport),
            leftEye: latestTracking.leftEye?.point(in: viewport),
            rightEye: latestTracking.rightEye?.point(in: viewport),
            mouthOpenness: latestTracking.mouthOpenness,
            isFaceTracked: latestTracking.isFaceTracked
        )
        let previousPhase = phase
        engine.update(at: timestamp, in: viewport, tracking: tracking)
        let snapshot = engine.snapshot
        publish(snapshot)

        if previousPhase != .finished, snapshot.phase == .finished {
            displayLink.stop()
            onFinished?(snapshot.score)
        }
    }

    private func publish(_ snapshot: GameSnapshot) {
        renderSnapshot = snapshot
        if phase != snapshot.phase {
            phase = snapshot.phase
        }
        if score != snapshot.score {
            score = snapshot.score
        }
        let seconds = Int(ceil(snapshot.timeRemaining))
        if remainingSeconds != seconds {
            remainingSeconds = seconds
        }
        if isFaceTracked != snapshot.isFaceTracked {
            isFaceTracked = snapshot.isFaceTracked
        }
        if isTargetLocked != snapshot.isTargetLocked {
            isTargetLocked = snapshot.isTargetLocked
        }
    }
}

private struct NormalizedTracking {
    let gaze: NormalizedPoint?
    let leftEye: NormalizedPoint?
    let rightEye: NormalizedPoint?
    let mouthOpenness: Double
    let isFaceTracked: Bool

    static let unavailable = NormalizedTracking(
        gaze: nil,
        leftEye: nil,
        rightEye: nil,
        mouthOpenness: 0,
        isFaceTracked: false
    )
}

@MainActor
private final class DisplayLinkDriver: NSObject {
    var onFrame: ((TimeInterval) -> Void)?
    private var displayLink: CADisplayLink?

    func start() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkFired(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 60,
            maximum: 60,
            preferred: 60
        )
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    @objc
    private func displayLinkFired(_ displayLink: CADisplayLink) {
        onFrame?(displayLink.targetTimestamp)
    }
}
