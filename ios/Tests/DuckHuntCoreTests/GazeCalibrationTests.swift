import Foundation
import Testing
@testable import DuckHuntCore

@Suite("Native gaze calibration")
struct GazeCalibrationTests {
    private static let edgeTargets = [
        Point2D(x: 0, y: 0),
        Point2D(x: 1, y: 0),
        Point2D(x: 1, y: 1),
        Point2D(x: 0, y: 1),
        Point2D(x: 0.5, y: 0.5),
    ]

    @Test("Visible inset dots teach the full normalized display range")
    func anchorLabelsReachDisplayEdges() {
        let anchors = GazeCalibration.standardAnchors
        let taughtTargets = Set(anchors.map(\.expectedGaze))

        #expect(taughtTargets.contains(Point2D(x: 0, y: 0)))
        #expect(taughtTargets.contains(Point2D(x: 1, y: 1)))
        #expect(anchors.allSatisfy { (0 ... 1).contains($0.displayPoint.x) })
        #expect(anchors.allSatisfy { (0 ... 1).contains($0.displayPoint.y) })
    }

    @Test("Robust fitting rejects isolated outliers and reaches corners", arguments: edgeTargets)
    func predictsFullRange(target: Point2D) throws {
        let model = try fittedModel()
        let prediction = model.predict(rawSample(for: target))

        #expect(abs(prediction.x - target.x) < 0.035)
        #expect(abs(prediction.y - target.y) < 0.035)
    }

    @Test("Too few unique targets cannot produce a model")
    func rejectsInsufficientCoverage() {
        var calibrator = GazeCalibrator()
        for anchor in GazeCalibration.standardAnchors.prefix(7) {
            for _ in 0 ..< 12 {
                calibrator.add(rawSample(for: anchor.expectedGaze), for: anchor)
            }
        }

        #expect(calibrator.fit() == nil)
    }

    @Test("Identical tracking data cannot explain the calibration grid")
    func rejectsDegenerateInput() {
        var calibrator = GazeCalibrator()
        for anchor in GazeCalibration.standardAnchors {
            for _ in 0 ..< 12 {
                calibrator.add(RawGazeSample(horizontal: 0.01, vertical: -0.02), for: anchor)
            }
        }

        #expect(calibrator.fit() == nil)
    }

    @Test("A persisted model round-trips without changing predictions")
    func modelPersistence() throws {
        let model = try fittedModel()
        let data = try JSONEncoder().encode(model)
        let decoded = try JSONDecoder().decode(GazeModel.self, from: data)
        let sample = RawGazeSample(horizontal: 0.037, vertical: -0.026)
        let expected = model.predict(sample)
        let actual = decoded.predict(sample)

        #expect(decoded.isValid)
        #expect(abs(actual.x - expected.x) < 1e-12)
        #expect(abs(actual.y - expected.y) < 1e-12)
    }

    @Test("Malformed persisted coefficients fail closed")
    func invalidPersistedModel() throws {
        let json = """
        {
          "version": 1,
          "horizontalWeights": [0.5],
          "verticalWeights": [0.5],
          "featureMeans": [0],
          "featureScales": [1]
        }
        """
        let model = try JSONDecoder().decode(GazeModel.self, from: Data(json.utf8))

        #expect(!model.isValid)
        #expect(model.predict(RawGazeSample(horizontal: 1, vertical: 1)) == Point2D(x: 0.5, y: 0.5))
    }

    private func fittedModel() throws -> GazeModel {
        var calibrator = GazeCalibrator()
        for (anchorIndex, anchor) in GazeCalibration.standardAnchors.enumerated() {
            let baseline = rawSample(for: anchor.expectedGaze)
            for sampleIndex in 0 ..< 30 {
                let pattern = Double((sampleIndex * 7 + anchorIndex * 3) % 11 - 5)
                let jitter = pattern * 0.000_18
                let isOutlier = sampleIndex == 4 || sampleIndex == 19
                calibrator.add(
                    RawGazeSample(
                        horizontal: baseline.horizontal + jitter + (isOutlier ? 0.35 : 0),
                        vertical: baseline.vertical - jitter + (isOutlier ? -0.30 : 0)
                    ),
                    for: anchor
                )
            }
        }
        return try #require(calibrator.fit())
    }

    private func rawSample(for target: Point2D) -> RawGazeSample {
        let x = target.x - 0.5
        let y = target.y - 0.5
        return RawGazeSample(
            horizontal: x * 0.18 + y * 0.012,
            vertical: y * 0.15 - x * 0.009
        )
    }
}
