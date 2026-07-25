import Foundation

/// A two-dimensional point expressed in logical display points.
public struct Point2D: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Point2D(x: 0, y: 0)

    /// Returns this point constrained to the supplied rectangular size.
    public func clamped(to size: Size2D) -> Point2D {
        Point2D(
            x: min(max(x, 0), size.width),
            y: min(max(y, 0), size.height)
        )
    }

    /// Returns the squared Euclidean distance to another point.
    public func distanceSquared(to other: Point2D) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        return dx * dx + dy * dy
    }
}


/// A positive two-dimensional logical display size.
public struct Size2D: Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = max(width, 1)
        self.height = max(height, 1)
    }
}
