import Foundation

/// An adaptive low-pass filter that suppresses stationary jitter without adding
/// the same amount of latency to deliberate, fast movement.
public struct OneEuroFilter: Sendable {
    private let minimumCutoff: Double
    private let beta: Double
    private let derivativeCutoff: Double
    private var previousRawValue: Double?
    private var previousFilteredValue: Double?
    private var previousFilteredDerivative = 0.0
    private var previousTimestamp: Double?

    public init(
        minimumCutoff: Double = 0.9,
        beta: Double = 0.80,
        derivativeCutoff: Double = 1.0
    ) {
        self.minimumCutoff = minimumCutoff
        self.beta = beta
        self.derivativeCutoff = derivativeCutoff
    }

    /// Filters a sample. Non-increasing timestamps reuse the last output.
    public mutating func filter(_ value: Double, at timestamp: Double) -> Double {
        guard
            let previousRawValue,
            let previousFilteredValue,
            let previousTimestamp
        else {
            self.previousRawValue = value
            self.previousFilteredValue = value
            self.previousTimestamp = timestamp
            return value
        }

        let deltaTime = timestamp - previousTimestamp
        guard deltaTime > 0 else { return previousFilteredValue }

        let derivative = (value - previousRawValue) / deltaTime
        let derivativeAlpha = smoothingFactor(cutoff: derivativeCutoff, deltaTime: deltaTime)
        let filteredDerivative = derivativeAlpha * derivative +
            (1 - derivativeAlpha) * previousFilteredDerivative
        let cutoff = minimumCutoff + beta * abs(filteredDerivative)
        let alpha = smoothingFactor(cutoff: cutoff, deltaTime: deltaTime)
        let filteredValue = alpha * value + (1 - alpha) * previousFilteredValue

        self.previousRawValue = value
        self.previousFilteredValue = filteredValue
        self.previousFilteredDerivative = filteredDerivative
        self.previousTimestamp = timestamp
        return filteredValue
    }

    /// Clears the filter history so the next sample passes through unchanged.
    public mutating func reset() {
        previousRawValue = nil
        previousFilteredValue = nil
        previousFilteredDerivative = 0
        previousTimestamp = nil
    }

    private func smoothingFactor(cutoff: Double, deltaTime: Double) -> Double {
        let timeConstant = 1 / (2 * Double.pi * max(cutoff, 0.000_1))
        return 1 / (1 + timeConstant / deltaTime)
    }
}
