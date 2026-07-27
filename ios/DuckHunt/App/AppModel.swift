import ARKit
import DuckHuntCore
import Foundation
import Observation

@MainActor
enum AppDestination: Equatable {
    case unsupported
    case calibration
    case home
    case game
}

@MainActor
@Observable
final class AppModel {
    private(set) var destination: AppDestination
    private(set) var trackingStatus: FaceTrackingStatus = .searching
    private(set) var calibrationIndex = 0
    private(set) var isCapturingCalibration = false
    private(set) var calibrationError: String?
    private(set) var calibrationCoaching: String?
    private(set) var calibrationAccuracyMillimetres: Double?
    private(set) var calibrationAttempt = 0
    private(set) var scores: [ScoreRecord] = ScoreStore.load()
    private(set) var latestRank: Int?
    let gameSession = GameSession()

    @ObservationIgnored private var gazeModel: GazeModel?
    @ObservationIgnored private var calibrator = GazeCalibrator()
    /// Resolved once. The device cannot change under a running app, and the lookup reaches
    /// for `sysctl`, which has no business on a 25ms settle poll.
    @ObservationIgnored private let display = PhysicalDisplay.current
    /// Whether the dot on screen has been collecting long enough to be worth a nudge.
    ///
    /// Kept apart from `calibrationCoaching` because a live gate rejection names a
    /// specific, fixable problem and must win, and the per-frame gate would otherwise
    /// wipe the hint 60 times a second.
    @ObservationIgnored private var isCurrentDotSlow = false

    /// The dot animates to its new position over 350ms. Sampling while it travels teaches
    /// the model the journey instead of the destination.
    private static let dotTravelMilliseconds: Int64 = 450
    /// A saccade lands quickly, but the eye keeps drifting onto the target afterwards.
    private static let fixationSettleMilliseconds: Int64 = 400
    private static let capturePollMilliseconds: Int64 = 25
    /// Long enough for a cooperative fixation, short enough that a hopeless dot does not
    /// hold the session hostage.
    private static let captureBudget = Duration.seconds(4)
    private static let maximumCaptureAttempts = 3
    /// How long a dot may collect before the user is offered a hint. Comfortably past a
    /// cooperative fixation, and early enough to be actionable before the budget expires.
    private static let slowDotDelay = Duration.seconds(2)
    /// Deliberately blames the measurement rather than the user: the usual cause is a dim
    /// room, and a dot that needs longer is still a dot that will succeed.
    private static let slowDotCoaching = "Still measuring — a little more light helps, and look right at the dot"

    init() {
        let storedModel = GazeModelStore.load()
        gazeModel = storedModel
        if !ARFaceTrackingConfiguration.isSupported {
            destination = .unsupported
        } else if storedModel == nil {
            destination = .calibration
        } else {
            destination = .home
        }

        gameSession.onFinished = { [weak self] score in
            self?.record(score: score)
        }
    }

    var currentCalibrationAnchor: CalibrationAnchor {
        GazeCalibration.standardAnchors[calibrationIndex]
    }

    var calibrationProgress: Double {
        Double(calibrationIndex + 1) / Double(GazeCalibration.standardAnchors.count)
    }

    var canCancelCalibration: Bool {
        gazeModel != nil
    }

    var trackingMessage: String {
        switch trackingStatus {
        case .searching:
            "Center your face in view"
        case .tracked:
            "Face locked"
        case .failed(let message):
            message
        }
    }

    func receive(_ frame: FaceTrackingFrame) {
        if trackingStatus != frame.status {
            trackingStatus = frame.status
        }

        if destination == .calibration, isCapturingCalibration {
            let rejection = GazeSampleGate.rejection(
                blink: frame.eyeBlink,
                headSpeed: frame.headAngularSpeed,
                viewingDistance: frame.viewingDistance
            )
            let coaching = rejection ?? (isCurrentDotSlow ? Self.slowDotCoaching : nil)
            if calibrationCoaching != coaching {
                calibrationCoaching = coaching
            }
            if rejection == nil, let sample = frame.rawGaze {
                calibrator.add(sample, for: currentCalibrationAnchor)
            }
        }

        if destination == .game, let gazeModel {
            let predictedGaze = frame.rawGaze.map(gazeModel.predict)
            gameSession.receive(frame, predictedGaze: predictedGaze)
        }
    }

    func play() {
        guard gazeModel != nil else {
            beginCalibration()
            return
        }
        latestRank = nil
        destination = .game
    }

    func replay(in size: CGSize) {
        latestRank = nil
        gameSession.start(in: size)
    }

    func goHome() {
        gameSession.stop()
        destination = .home
    }

    func beginCalibration() {
        gameSession.stop()
        calibrator = GazeCalibrator()
        calibrationIndex = 0
        calibrationError = nil
        clearCalibrationCoaching()
        calibrationAccuracyMillimetres = nil
        isCapturingCalibration = false
        calibrationAttempt &+= 1
        destination = .calibration
    }

    func cancelCalibration() {
        guard gazeModel != nil else { return }
        isCapturingCalibration = false
        calibrationError = nil
        clearCalibrationCoaching()
        destination = .home
    }

    func retryCalibration() {
        calibrator = GazeCalibrator()
        calibrationIndex = 0
        calibrationError = nil
        clearCalibrationCoaching()
        calibrationAccuracyMillimetres = nil
        isCapturingCalibration = false
        calibrationAttempt &+= 1
    }

    func performCalibration() async {
        guard destination == .calibration, calibrationError == nil else { return }
        calibrator = GazeCalibrator()
        calibrationIndex = 0
        isCapturingCalibration = false
        clearCalibrationCoaching()
        calibrationAccuracyMillimetres = nil
        defer {
            isCapturingCalibration = false
            clearCalibrationCoaching()
        }

        for index in GazeCalibration.standardAnchors.indices {
            guard !Task.isCancelled, destination == .calibration else { return }
            calibrationIndex = index
            clearCalibrationCoaching()

            let anchor = GazeCalibration.standardAnchors[index]
            attempts: for _ in 0 ..< Self.maximumCaptureAttempts {
                switch await captureAttempt(for: anchor) {
                case .settled:
                    break attempts
                case .expired:
                    // A dot that never resolves into a fixation is dropped instead of
                    // failing the run: fit() weighs the surviving coverage itself, and one
                    // stubborn dot out of thirteen is not worth restarting the session for.
                    calibrator.discardSamples(for: anchor)
                case .aborted:
                    return
                }
            }
        }

        guard let model = calibrator.fit(display: display) else {
            calibrationError = "Calibration could not reach usable accuracy. Try brighter, even lighting, hold the phone at a comfortable arm's length, and look straight at each dot."
            return
        }

        calibrationAccuracyMillimetres = model.validationErrorMillimetres
        GazeModelStore.save(model)
        gazeModel = model
        destination = .home
    }

    func appDidBecomeActive() {
        if destination == .game {
            gameSession.resume()
        }
    }

    func appWillResignActive() {
        trackingStatus = .searching
        if destination == .game {
            gameSession.pause()
        }
    }

    private func record(score: Int) {
        latestRank = ScoreStore.record(score: score, in: &scores)
    }

    /// Drops both sources of coaching, so a hint cannot outlive the dot that raised it.
    private func clearCalibrationCoaching() {
        isCurrentDotSlow = false
        calibrationCoaching = nil
    }

    private func waitForTrackedFace() async -> Bool {
        while trackingStatus != .tracked {
            guard !Task.isCancelled, destination == .calibration else { return false }
            if case .failed(let message) = trackingStatus {
                calibrationError = message
                return false
            }
            guard await sleep(milliseconds: 50) else { return false }
        }
        return true
    }

    /// How one attempt at a single dot ended.
    private enum CaptureOutcome {
        case settled
        case expired
        case aborted
    }

    /// Samples one dot until the standard error of its mean says the eye is genuinely
    /// parked on it.
    private func captureAttempt(for anchor: CalibrationAnchor) async -> CaptureOutcome {
        guard await settleOnDot() else { return .aborted }
        var deadline = ContinuousClock.now.advanced(by: Self.captureBudget)
        var hintDeadline = ContinuousClock.now.advanced(by: Self.slowDotDelay)
        isCapturingCalibration = true
        defer { isCapturingCalibration = false }

        while !calibrator.isSettled(for: anchor, display: display) {
            guard !Task.isCancelled, destination == .calibration else { return .aborted }

            if trackingStatus != .tracked {
                // Samples taken before tracking dropped are kept. If the user came back to
                // a different spot the mean will refuse to pin down, and the attempt
                // expires into a clean retry rather than averaging two fixations.
                isCapturingCalibration = false
                guard await settleOnDot() else { return .aborted }
                deadline = ContinuousClock.now.advanced(by: Self.captureBudget)
                hintDeadline = ContinuousClock.now.advanced(by: Self.slowDotDelay)
                clearCalibrationCoaching()
                isCapturingCalibration = true
            }

            if !isCurrentDotSlow, calibrationCoaching == nil, ContinuousClock.now >= hintDeadline {
                isCurrentDotSlow = true
                calibrationCoaching = Self.slowDotCoaching
            }

            guard ContinuousClock.now < deadline else { return .expired }
            guard await sleep(milliseconds: Self.capturePollMilliseconds) else { return .aborted }
        }
        clearCalibrationCoaching()
        return .settled
    }

    /// Waits for tracking, for the dot to finish moving, and for the eye to land on it.
    private func settleOnDot() async -> Bool {
        guard await waitForTrackedFace() else { return false }
        guard await sleep(milliseconds: Self.dotTravelMilliseconds) else { return false }
        return await sleep(milliseconds: Self.fixationSettleMilliseconds)
    }

    private func sleep(milliseconds: Int64) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return true
        } catch {
            return false
        }
    }
}
