import Foundation

/// Raw, face-relative gaze angles derived from ARKit's look-at point.
public struct RawGazeSample: Sendable {
    public var horizontal: Double
    public var vertical: Double

    public init(horizontal: Double, vertical: Double) {
        self.horizontal = horizontal
        self.vertical = vertical
    }
}

/// One visible calibration location and the full-range gaze coordinate it teaches.
public struct CalibrationAnchor: Hashable, Sendable {
    public let displayPoint: Point2D
    public let expectedGaze: Point2D

    public init(displayPoint: Point2D, expectedGaze: Point2D) {
        self.displayPoint = displayPoint
        self.expectedGaze = expectedGaze
    }
}

/// The ordered calibration path used by the native app.
public enum GazeCalibration {
    /// Edge dots remain comfortably visible while their labels teach exact display edges.
    /// The center is revisited last to expose drift before accepting the model.
    public static let standardAnchors: [CalibrationAnchor] = [
        CalibrationAnchor(displayPoint: Point2D(x: 0.50, y: 0.50), expectedGaze: Point2D(x: 0.50, y: 0.50)),
        CalibrationAnchor(displayPoint: Point2D(x: 0.08, y: 0.10), expectedGaze: Point2D(x: 0.00, y: 0.00)),
        CalibrationAnchor(displayPoint: Point2D(x: 0.50, y: 0.10), expectedGaze: Point2D(x: 0.50, y: 0.00)),
        CalibrationAnchor(displayPoint: Point2D(x: 0.92, y: 0.10), expectedGaze: Point2D(x: 1.00, y: 0.00)),
        CalibrationAnchor(displayPoint: Point2D(x: 0.92, y: 0.50), expectedGaze: Point2D(x: 1.00, y: 0.50)),
        CalibrationAnchor(displayPoint: Point2D(x: 0.92, y: 0.90), expectedGaze: Point2D(x: 1.00, y: 1.00)),
        CalibrationAnchor(displayPoint: Point2D(x: 0.50, y: 0.90), expectedGaze: Point2D(x: 0.50, y: 1.00)),
        CalibrationAnchor(displayPoint: Point2D(x: 0.08, y: 0.90), expectedGaze: Point2D(x: 0.00, y: 1.00)),
        CalibrationAnchor(displayPoint: Point2D(x: 0.08, y: 0.50), expectedGaze: Point2D(x: 0.00, y: 0.50)),
        CalibrationAnchor(displayPoint: Point2D(x: 0.50, y: 0.50), expectedGaze: Point2D(x: 0.50, y: 0.50)),
    ]
}

/// A versioned quadratic mapping from raw ARKit gaze angles to normalized screen space.
public struct GazeModel: Codable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    private let horizontalWeights: [Double]
    private let verticalWeights: [Double]
    private let featureMeans: [Double]
    private let featureScales: [Double]

    init(
        horizontalWeights: [Double],
        verticalWeights: [Double],
        featureMeans: [Double],
        featureScales: [Double]
    ) {
        version = Self.currentVersion
        self.horizontalWeights = horizontalWeights
        self.verticalWeights = verticalWeights
        self.featureMeans = featureMeans
        self.featureScales = featureScales
    }

    /// Whether the decoded model has the expected shape and finite coefficients.
    public var isValid: Bool {
        let vectors = [horizontalWeights, verticalWeights, featureMeans, featureScales]
        return version == Self.currentVersion &&
            vectors.allSatisfy { $0.count == Self.featureCount && $0.allSatisfy(\.isFinite) } &&
            featureScales.allSatisfy { $0 > 0 }
    }

    /// Predicts a normalized screen location, clamped to the full display.
    public func predict(_ sample: RawGazeSample) -> Point2D {
        guard isValid, sample.horizontal.isFinite, sample.vertical.isFinite else {
            return Point2D(x: 0.5, y: 0.5)
        }

        let rawFeatures = Self.features(for: sample)
        let standardizedFeatures = rawFeatures.indices.map { index in
            (rawFeatures[index] - featureMeans[index]) / featureScales[index]
        }
        let horizontal = zip(horizontalWeights, standardizedFeatures).reduce(0) { $0 + $1.0 * $1.1 }
        let vertical = zip(verticalWeights, standardizedFeatures).reduce(0) { $0 + $1.0 * $1.1 }

        return Point2D(
            x: min(max(horizontal, 0), 1),
            y: min(max(vertical, 0), 1)
        )
    }

    fileprivate static let featureCount = 6

    fileprivate static func features(for sample: RawGazeSample) -> [Double] {
        let x = sample.horizontal
        let y = sample.vertical
        return [1, x, y, x * x, y * y, x * y]
    }
}

/// Collects per-target gaze samples and fits a robust, regularized model.
public struct GazeCalibrator: Sendable {
    private static let minimumUniqueTargets = 8
    private static let minimumSamplesPerTarget = 5
    private static let retainedFraction = 0.60
    private static let ridgeLambda = 0.02
    private static let maximumMeanTrainingError = 0.10
    private static let scaleFloors = [1.0, 0.005, 0.005, 0.001, 0.001, 0.001]

    private var samplesByTarget: [Point2D: [RawGazeSample]] = [:]

    public init() {}

    /// Adds a finite sample for one anchor. Invalid tracking frames are ignored.
    public mutating func add(_ sample: RawGazeSample, for anchor: CalibrationAnchor) {
        guard sample.horizontal.isFinite, sample.vertical.isFinite else { return }
        samplesByTarget[anchor.expectedGaze, default: []].append(sample)
    }

    /// Returns the number of accepted frames for one anchor's expected target.
    public func sampleCount(for anchor: CalibrationAnchor) -> Int {
        samplesByTarget[anchor.expectedGaze]?.count ?? 0
    }

    /// Fits a model only when coverage, conditioning, and fit quality are sufficient.
    public func fit() -> GazeModel? {
        let representatives = representativeSamples()
        guard representatives.count >= Self.minimumUniqueTargets else { return nil }

        let rawFeatures = representatives.map { GazeModel.features(for: $0.sample) }
        let targetsX = representatives.map(\.target.x)
        let targetsY = representatives.map(\.target.y)
        let normalization = featureNormalization(for: rawFeatures)
        let features = rawFeatures.map { row in
            row.indices.map { index in
                (row[index] - normalization.means[index]) / normalization.scales[index]
            }
        }

        guard
            let horizontalWeights = solveRidge(
                features: features,
                targets: targetsX,
                lambda: Self.ridgeLambda
            ),
            let verticalWeights = solveRidge(
                features: features,
                targets: targetsY,
                lambda: Self.ridgeLambda
            )
        else { return nil }

        let model = GazeModel(
            horizontalWeights: horizontalWeights,
            verticalWeights: verticalWeights,
            featureMeans: normalization.means,
            featureScales: normalization.scales
        )
        guard model.isValid else { return nil }

        let totalError = representatives.reduce(0.0) { partialResult, representative in
            let prediction = model.predict(representative.sample)
            return partialResult + sqrt(prediction.distanceSquared(to: representative.target))
        }
        let meanError = totalError / Double(representatives.count)
        return meanError <= Self.maximumMeanTrainingError ? model : nil
    }

    private func representativeSamples() -> [(sample: RawGazeSample, target: Point2D)] {
        samplesByTarget.compactMap { target, samples in
            guard samples.count >= Self.minimumSamplesPerTarget else { return nil }

            let medianX = median(samples.map(\.horizontal))
            let medianY = median(samples.map(\.vertical))
            let ranked = samples.sorted { lhs, rhs in
                let lhsDistance = (lhs.horizontal - medianX) * (lhs.horizontal - medianX) +
                    (lhs.vertical - medianY) * (lhs.vertical - medianY)
                let rhsDistance = (rhs.horizontal - medianX) * (rhs.horizontal - medianX) +
                    (rhs.vertical - medianY) * (rhs.vertical - medianY)
                return lhsDistance < rhsDistance
            }
            let retainedCount = max(
                Self.minimumSamplesPerTarget,
                Int((Double(ranked.count) * Self.retainedFraction).rounded(.down))
            )
            let retained = ranked.prefix(retainedCount)
            let divisor = Double(retained.count)
            let representative = RawGazeSample(
                horizontal: retained.reduce(0) { $0 + $1.horizontal } / divisor,
                vertical: retained.reduce(0) { $0 + $1.vertical } / divisor
            )
            return (sample: representative, target: target)
        }
    }

    private func featureNormalization(for features: [[Double]]) -> (means: [Double], scales: [Double]) {
        let featureCount = GazeModel.featureCount
        var means = Array(repeating: 0.0, count: featureCount)
        var scales = Array(repeating: 1.0, count: featureCount)

        for index in 1 ..< featureCount {
            means[index] = features.reduce(0) { $0 + $1[index] } / Double(features.count)
            let variance = features.reduce(0) { partialResult, row in
                let difference = row[index] - means[index]
                return partialResult + difference * difference
            } / Double(features.count)
            scales[index] = max(sqrt(variance), Self.scaleFloors[index])
        }
        return (means, scales)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func solveRidge(features: [[Double]], targets: [Double], lambda: Double) -> [Double]? {
        let dimensions = GazeModel.featureCount
        var augmented = Array(
            repeating: Array(repeating: 0.0, count: dimensions + 1),
            count: dimensions
        )

        for row in features.indices {
            for column in 0 ..< dimensions {
                for innerColumn in 0 ..< dimensions {
                    augmented[column][innerColumn] += features[row][column] * features[row][innerColumn]
                }
                augmented[column][dimensions] += features[row][column] * targets[row]
            }
        }
        for index in 1 ..< dimensions {
            augmented[index][index] += lambda
        }

        for pivotColumn in 0 ..< dimensions {
            guard let pivotRow = (pivotColumn ..< dimensions).max(by: {
                abs(augmented[$0][pivotColumn]) < abs(augmented[$1][pivotColumn])
            }), abs(augmented[pivotRow][pivotColumn]) > 1e-12 else { return nil }

            augmented.swapAt(pivotColumn, pivotRow)
            let pivot = augmented[pivotColumn][pivotColumn]
            for column in pivotColumn ... dimensions {
                augmented[pivotColumn][column] /= pivot
            }

            for row in 0 ..< dimensions where row != pivotColumn {
                let factor = augmented[row][pivotColumn]
                for column in pivotColumn ... dimensions {
                    augmented[row][column] -= factor * augmented[pivotColumn][column]
                }
            }
        }

        let result = augmented.map { $0[dimensions] }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}
