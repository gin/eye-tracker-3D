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
    let rawGaze: RawGazeSample?
    let leftEye: NormalizedPoint?
    let rightEye: NormalizedPoint?
    let jawOpen: Double
    let status: FaceTrackingStatus

    static func searching(at timestamp: TimeInterval) -> FaceTrackingFrame {
        FaceTrackingFrame(
            timestamp: timestamp,
            rawGaze: nil,
            leftEye: nil,
            rightEye: nil,
            jawOpen: 0,
            status: .searching
        )
    }
}
