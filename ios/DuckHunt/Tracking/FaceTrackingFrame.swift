import DuckHuntCore
import Foundation

struct NormalizedPoint: Sendable {
    let x: Double
    let y: Double

    func point(in size: Size2D) -> Point2D {
        Point2D(x: x * size.width, y: y * size.height)
    }
}

enum FaceTrackingStatus: Equatable, Sendable {
    case searching
    case tracked
    case failed(String)
}

struct FaceTrackingFrame: Sendable {
    let timestamp: TimeInterval
    /// Geometric screen estimate before per-user correction; may fall outside `0...1`.
    let rawGaze: RawGazeSample?
    let leftEye: NormalizedPoint?
    let rightEye: NormalizedPoint?
    let jawOpen: Double
    let eyeBlink: Double
    /// Head rotation rate in radians per second.
    let headAngularSpeed: Double
    /// Metres from the camera to the midpoint of the eyes.
    let viewingDistance: Double
    let status: FaceTrackingStatus

    /// Neutral values stand in for the quality signals: with no face there is nothing to
    /// measure, and the gate never sees these frames because `rawGaze` is already `nil`.
    static func searching(at timestamp: TimeInterval) -> FaceTrackingFrame {
        FaceTrackingFrame(
            timestamp: timestamp,
            rawGaze: nil,
            leftEye: nil,
            rightEye: nil,
            jawOpen: 0,
            eyeBlink: 0,
            headAngularSpeed: 0,
            viewingDistance: 0,
            status: .searching
        )
    }
}
