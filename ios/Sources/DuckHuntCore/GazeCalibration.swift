import Foundation

/// An uncalibrated gaze position on the display, in normalized display coordinates.
///
/// Unlike a face-relative gaze angle, this is produced by intersecting the eye ray with
/// the physical screen plane, so head pose and device pose are already accounted for.
/// Values may fall outside `0...1`: the per-user affine correction is what pins the
/// geometric estimate to the real display.
public struct RawGazeSample: Sendable {
    public var horizontal: Double
    public var vertical: Double

    public init(horizontal: Double, vertical: Double) {
        self.horizontal = horizontal
        self.vertical = vertical
    }
}

/// Physical dimensions of a display's active area, and where the front camera sits on it.
public struct PhysicalDisplay: Hashable, Sendable {
    public let widthMillimetres: Double
    public let heightMillimetres: Double
    /// Front camera centre relative to the active area's centre, portrait, +x right, +y up.
    public let cameraOffsetXMillimetres: Double
    public let cameraOffsetYMillimetres: Double

    public init(
        widthMillimetres: Double,
        heightMillimetres: Double,
        cameraOffsetXMillimetres: Double,
        cameraOffsetYMillimetres: Double
    ) {
        self.widthMillimetres = max(widthMillimetres, 1)
        self.heightMillimetres = max(heightMillimetres, 1)
        self.cameraOffsetXMillimetres = cameraOffsetXMillimetres
        self.cameraOffsetYMillimetres = cameraOffsetYMillimetres
    }
}

/// Whether a calibration dot teaches the model or audits it.
///
/// Validation dots are never fitted. They are the only honest measure of accuracy: a
/// three-parameter fit over nine training dots can absorb almost any training residual,
/// so training error says nothing about how the model will behave in the game.
public enum CalibrationRole: Hashable, Sendable {
    case training
    case validation
}

/// One dot the user is asked to look at.
public struct CalibrationAnchor: Hashable, Sendable {
    public let displayPoint: Point2D
    public let role: CalibrationRole

    public init(displayPoint: Point2D, role: CalibrationRole) {
        self.displayPoint = displayPoint
        self.role = role
    }
}

/// The ordered calibration path used by the native app.
public enum GazeCalibration {
    /// Nine training dots on a 5%/50%/95% grid, plus four validation dots interleaved
    /// between them.
    ///
    /// Dots sit where they claim to sit — a dot at 5% teaches 5%, not 0%. Teaching the
    /// display edge from an inset dot forces the fit to extrapolate and multiplies the
    /// noise on every coefficient by the same factor.
    ///
    /// Validation is interleaved rather than appended so that pose drift accumulated
    /// during the session lands on the audit dots and the training dots alike.
    public static let standardAnchors: [CalibrationAnchor] = [
        CalibrationAnchor(displayPoint: Point2D(x: 0.500, y: 0.500), role: .training),
        CalibrationAnchor(displayPoint: Point2D(x: 0.050, y: 0.050), role: .training),
        CalibrationAnchor(displayPoint: Point2D(x: 0.275, y: 0.275), role: .validation),
        CalibrationAnchor(displayPoint: Point2D(x: 0.500, y: 0.050), role: .training),
        CalibrationAnchor(displayPoint: Point2D(x: 0.950, y: 0.050), role: .training),
        CalibrationAnchor(displayPoint: Point2D(x: 0.725, y: 0.275), role: .validation),
        CalibrationAnchor(displayPoint: Point2D(x: 0.950, y: 0.500), role: .training),
        CalibrationAnchor(displayPoint: Point2D(x: 0.950, y: 0.950), role: .training),
        CalibrationAnchor(displayPoint: Point2D(x: 0.725, y: 0.725), role: .validation),
        CalibrationAnchor(displayPoint: Point2D(x: 0.500, y: 0.950), role: .training),
        CalibrationAnchor(displayPoint: Point2D(x: 0.050, y: 0.950), role: .training),
        CalibrationAnchor(displayPoint: Point2D(x: 0.275, y: 0.725), role: .validation),
        CalibrationAnchor(displayPoint: Point2D(x: 0.050, y: 0.500), role: .training),
    ]
}

/// Rejects tracking frames that cannot carry gaze information.
///
/// A blink, a head still swinging toward the dot, or a face at reading distance for a
/// different device all produce plausible-looking samples that a trimmed mean cannot
/// remove, because they are biased rather than noisy.
public enum GazeSampleGate {
    public static let maximumBlink = 0.30
    public static let maximumHeadSpeedRadiansPerSecond = 0.45
    public static let viewingDistanceRange: ClosedRange<Double> = 0.22 ... 0.60

    public static func accepts(blink: Double, headSpeed: Double, viewingDistance: Double) -> Bool {
        rejection(blink: blink, headSpeed: headSpeed, viewingDistance: viewingDistance) == nil
    }

    /// Coaching text for the dominant reason a frame was rejected, or `nil` when it passed.
    public static func rejection(
        blink: Double,
        headSpeed: Double,
        viewingDistance: Double
    ) -> String? {
        guard blink.isFinite, headSpeed.isFinite, viewingDistance.isFinite else {
            return "Lost your eyes"
        }
        if viewingDistance < viewingDistanceRange.lowerBound { return "Hold the phone a little further away" }
        if viewingDistance > viewingDistanceRange.upperBound { return "Hold the phone a little closer" }
        if blink > maximumBlink { return "Keep your eyes open" }
        if headSpeed > maximumHeadSpeedRadiansPerSecond { return "Hold steady" }
        return nil
    }
}

/// A versioned affine correction from a geometric gaze estimate to normalized screen space.
///
/// Once the eye ray is intersected with the screen plane, everything still unknown is
/// per-user and small: the kappa angle between the visual and optical axes, ARKit's gain
/// on eye-in-head rotation, and any error in the device's physical screen table. All three
/// are affine, so three coefficients per axis span them — leaving nine training dots to
/// constrain three parameters instead of six.
public struct GazeModel: Codable, Sendable {
    public static let currentVersion = 2

    public let version: Int
    /// Measured accuracy on dots the fit never saw. Surfaced to the user.
    public let validationErrorMillimetres: Double
    private let horizontalWeights: [Double]
    private let verticalWeights: [Double]

    init(
        horizontalWeights: [Double],
        verticalWeights: [Double],
        validationErrorMillimetres: Double
    ) {
        version = Self.currentVersion
        self.horizontalWeights = horizontalWeights
        self.verticalWeights = verticalWeights
        self.validationErrorMillimetres = validationErrorMillimetres
    }

    /// Whether the decoded model has the expected shape and finite coefficients.
    public var isValid: Bool {
        version == Self.currentVersion &&
            validationErrorMillimetres.isFinite &&
            validationErrorMillimetres >= 0 &&
            [horizontalWeights, verticalWeights].allSatisfy {
                $0.count == Self.featureCount && $0.allSatisfy(\.isFinite)
            }
    }

    /// Predicts a normalized screen location, clamped to the full display.
    public func predict(_ sample: RawGazeSample) -> Point2D {
        guard isValid, sample.horizontal.isFinite, sample.vertical.isFinite else {
            return Point2D(x: 0.5, y: 0.5)
        }

        let features = Self.features(for: sample)
        let horizontal = zip(horizontalWeights, features).reduce(0) { $0 + $1.0 * $1.1 }
        let vertical = zip(verticalWeights, features).reduce(0) { $0 + $1.0 * $1.1 }

        return Point2D(
            x: min(max(horizontal, 0), 1),
            y: min(max(vertical, 0), 1)
        )
    }

    static let featureCount = 3

    static func features(for sample: RawGazeSample) -> [Double] {
        [1, sample.horizontal, sample.vertical]
    }
}

/// Collects per-dot gaze samples and fits an affine correction validated on held-out dots.
public struct GazeCalibrator: Sendable {
    private static let minimumTrainingAnchors = 6
    private static let minimumValidationAnchors = 3
    private static let minimumSamplesPerAnchor = 12
    private static let retainedFraction = 0.60
    private static let ridgeLambda = 0.05
    /// Roughly the width of a fingertip. Beyond this the game is unplayable anyway.
    private static let maximumValidationErrorMillimetres = 15.0
    /// How precisely a dot's representative sample must be pinned down before the dot is
    /// accepted, in millimetres on the display.
    ///
    /// This is the standard error of the retained mean, not the scatter of individual
    /// frames. Raw per-frame scatter is the wrong quantity twice over: it says nothing
    /// about the average that actually reaches the fit, and ARKit's per-frame gaze error
    /// is several millimetres on its own, so any threshold tight enough to mean something
    /// would never be met. Bounding the standard error instead makes a noisy user or a
    /// dim room simply cost more frames rather than fail the session, and it caps each
    /// dot's contribution to the fit at a known physical size.
    private static let maximumUncertaintyMillimetres = 3.0

    private var samplesByAnchor: [CalibrationAnchor: [RawGazeSample]] = [:]

    public init() {}

    /// Adds a finite sample for one dot. Invalid tracking frames are ignored.
    public mutating func add(_ sample: RawGazeSample, for anchor: CalibrationAnchor) {
        guard sample.horizontal.isFinite, sample.vertical.isFinite else { return }
        samplesByAnchor[anchor, default: []].append(sample)
    }

    /// Throws away one dot's samples so it can be presented again.
    public mutating func discardSamples(for anchor: CalibrationAnchor) {
        samplesByAnchor[anchor] = nil
    }

    /// Returns the number of accepted frames for one dot.
    public func sampleCount(for anchor: CalibrationAnchor) -> Int {
        samplesByAnchor[anchor]?.count ?? 0
    }

    /// Standard error of a dot's retained mean, in millimetres on the display, or `nil`
    /// before enough frames have arrived to estimate it.
    ///
    /// Reported in physical units because normalized ones are not comparable between the
    /// two axes: a phone screen is roughly twice as tall as it is wide, so the same
    /// angular error is twice the fraction horizontally that it is vertically.
    public func uncertaintyMillimetres(
        for anchor: CalibrationAnchor,
        display: PhysicalDisplay
    ) -> Double? {
        guard let samples = samplesByAnchor[anchor], samples.count >= Self.minimumSamplesPerAnchor else {
            return nil
        }
        let retained = retainedSamples(samples)
        let centre = mean(of: retained)
        let variance = retained.reduce(0.0) { partial, sample in
            let dx = (sample.horizontal - centre.horizontal) * display.widthMillimetres
            let dy = (sample.vertical - centre.vertical) * display.heightMillimetres
            return partial + dx * dx + dy * dy
        } / Double(retained.count)
        return sqrt(variance / Double(retained.count))
    }

    /// Whether a dot is pinned down well enough to stop collecting and move on.
    public func isSettled(for anchor: CalibrationAnchor, display: PhysicalDisplay) -> Bool {
        guard let uncertainty = uncertaintyMillimetres(for: anchor, display: display) else {
            return false
        }
        return uncertainty <= Self.maximumUncertaintyMillimetres
    }

    /// Fits on the training dots, then accepts or rejects on the validation dots.
    ///
    /// Returns `nil` when coverage is short or when measured held-out accuracy is worse
    /// than the game can use. Training residual is deliberately not consulted.
    public func fit(display: PhysicalDisplay) -> GazeModel? {
        let training = representatives(for: .training)
        let validation = representatives(for: .validation)
        guard
            training.count >= Self.minimumTrainingAnchors,
            validation.count >= Self.minimumValidationAnchors
        else { return nil }

        let features = training.map { GazeModel.features(for: $0.sample) }
        guard
            let horizontalWeights = solveRidge(
                features: features,
                targets: training.map(\.target.x),
                lambda: Self.ridgeLambda
            ),
            let verticalWeights = solveRidge(
                features: features,
                targets: training.map(\.target.y),
                lambda: Self.ridgeLambda
            )
        else { return nil }

        let candidate = GazeModel(
            horizontalWeights: horizontalWeights,
            verticalWeights: verticalWeights,
            validationErrorMillimetres: 0
        )
        guard candidate.isValid else { return nil }

        let totalError = validation.reduce(0.0) { partial, sample in
            let prediction = candidate.predict(sample.sample)
            let dx = (prediction.x - sample.target.x) * display.widthMillimetres
            let dy = (prediction.y - sample.target.y) * display.heightMillimetres
            return partial + sqrt(dx * dx + dy * dy)
        }
        let meanError = totalError / Double(validation.count)
        guard meanError.isFinite, meanError <= Self.maximumValidationErrorMillimetres else { return nil }

        return GazeModel(
            horizontalWeights: horizontalWeights,
            verticalWeights: verticalWeights,
            validationErrorMillimetres: meanError
        )
    }

    private func representatives(
        for role: CalibrationRole
    ) -> [(sample: RawGazeSample, target: Point2D)] {
        samplesByAnchor.compactMap { anchor, samples in
            guard anchor.role == role, samples.count >= Self.minimumSamplesPerAnchor else { return nil }
            return (sample: mean(of: retainedSamples(samples)), target: anchor.displayPoint)
        }
    }

    /// The 60% of a dot's samples closest to its median, which drops blinks and the tail
    /// of the saccade without assuming the noise is symmetric.
    private func retainedSamples(_ samples: [RawGazeSample]) -> ArraySlice<RawGazeSample> {
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
            Self.minimumSamplesPerAnchor,
            Int((Double(ranked.count) * Self.retainedFraction).rounded(.down))
        )
        return ranked.prefix(retainedCount)
    }

    private func mean(of samples: some Collection<RawGazeSample>) -> RawGazeSample {
        let divisor = Double(samples.count)
        return RawGazeSample(
            horizontal: samples.reduce(0) { $0 + $1.horizontal } / divisor,
            vertical: samples.reduce(0) { $0 + $1.vertical } / divisor
        )
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
