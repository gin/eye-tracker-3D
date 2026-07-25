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
    private(set) var calibrationAttempt = 0
    private(set) var scores: [ScoreRecord] = ScoreStore.load()
    private(set) var latestRank: Int?
    let gameSession = GameSession()

    @ObservationIgnored private var gazeModel: GazeModel?
    @ObservationIgnored private var calibrator = GazeCalibrator()

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

        if
            destination == .calibration,
            isCapturingCalibration,
            let sample = frame.rawGaze
        {
            calibrator.add(sample, for: currentCalibrationAnchor)
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
        isCapturingCalibration = false
        calibrationAttempt &+= 1
        destination = .calibration
    }

    func cancelCalibration() {
        guard gazeModel != nil else { return }
        isCapturingCalibration = false
        calibrationError = nil
        destination = .home
    }

    func retryCalibration() {
        calibrator = GazeCalibrator()
        calibrationIndex = 0
        calibrationError = nil
        isCapturingCalibration = false
        calibrationAttempt &+= 1
    }

    func performCalibration() async {
        guard destination == .calibration, calibrationError == nil else { return }
        calibrator = GazeCalibrator()
        calibrationIndex = 0
        isCapturingCalibration = false
        defer { isCapturingCalibration = false }

        for index in GazeCalibration.standardAnchors.indices {
            guard !Task.isCancelled, destination == .calibration else { return }
            calibrationIndex = index

            guard await waitForTrackedFace() else { return }
            guard await sleep(milliseconds: 700) else { return }

            let anchor = GazeCalibration.standardAnchors[index]
            let startingCount = calibrator.sampleCount(for: anchor)
            isCapturingCalibration = true
            while calibrator.sampleCount(for: anchor) - startingCount < 18 {
                guard !Task.isCancelled, destination == .calibration else { return }
                if trackingStatus != .tracked {
                    isCapturingCalibration = false
                    guard await waitForTrackedFace() else { return }
                    guard await sleep(milliseconds: 700) else { return }
                    isCapturingCalibration = true
                }
                guard await sleep(milliseconds: 25) else { return }
            }
            isCapturingCalibration = false
        }

        guard let model = calibrator.fit() else {
            calibrationError = "Calibration was inconsistent. Keep your head still and follow each dot with only your eyes."
            return
        }

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

    private func sleep(milliseconds: Int64) async -> Bool {
        do {
            try await Task.sleep(for: .milliseconds(milliseconds))
            return true
        } catch {
            return false
        }
    }
}
