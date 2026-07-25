import DuckHuntCore
import SwiftUI

struct GameCanvas: View {
    let session: GameSession

    var body: some View {
        let snapshot = session.renderSnapshot
        Canvas(opaque: false, rendersAsynchronously: true) { context, size in
            GameRenderer.draw(snapshot, in: &context, size: size)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

private enum GameRenderer {
    static func draw(_ snapshot: GameSnapshot, in context: inout GraphicsContext, size: CGSize) {
        for duck in snapshot.ducks {
            draw(duck, in: &context)
        }
        for laser in snapshot.lasers {
            draw(laser, elapsedTime: snapshot.elapsedTime, in: &context)
        }
        for burst in snapshot.bursts {
            draw(burst, elapsedTime: snapshot.elapsedTime, in: &context)
        }
        drawReticle(snapshot, size: size, in: &context)
    }

    private static func draw(_ duck: Duck, in context: inout GraphicsContext) {
        context.drawLayer { layer in
            layer.translateBy(x: duck.center.x, y: duck.center.y)
            if !duck.facesRight {
                layer.scaleBy(x: -1, y: 1)
            }

            let radius = duck.radius

            var tail = Path()
            tail.move(to: CGPoint(x: -radius * 0.75, y: -radius * 0.06))
            tail.addLine(to: CGPoint(x: -radius * 1.23, y: -radius * 0.48))
            tail.addLine(to: CGPoint(x: -radius * 1.12, y: radius * 0.12))
            tail.addLine(to: CGPoint(x: -radius * 1.24, y: radius * 0.50))
            tail.closeSubpath()
            layer.fill(tail, with: .color(Color(red: 0.24, green: 0.63, blue: 0.28)))

            let body = Path(
                ellipseIn: CGRect(
                    x: -radius * 0.82,
                    y: -radius * 0.52,
                    width: radius * 1.64,
                    height: radius * 1.04
                )
            )
            layer.fill(body, with: .color(Color(red: 0.31, green: 0.78, blue: 0.35)))
            layer.stroke(body, with: .color(Color.black.opacity(0.65)), lineWidth: max(1.5, radius * 0.07))

            let head = Path(
                ellipseIn: CGRect(
                    x: radius * 0.33,
                    y: -radius * 0.75,
                    width: radius * 0.88,
                    height: radius * 0.88
                )
            )
            layer.fill(head, with: .color(Color(red: 0.38, green: 0.88, blue: 0.42)))
            layer.stroke(head, with: .color(Color.black.opacity(0.65)), lineWidth: max(1.5, radius * 0.07))

            layer.drawLayer { wing in
                wing.rotate(by: .radians(sin(duck.wingPhase) * 0.38))
                var wingPath = Path()
                wingPath.move(to: CGPoint(x: -radius * 0.18, y: -radius * 0.12))
                wingPath.addCurve(
                    to: CGPoint(x: -radius * 0.52, y: radius * 0.50),
                    control1: CGPoint(x: -radius * 0.08, y: radius * 0.08),
                    control2: CGPoint(x: -radius * 0.25, y: radius * 0.52)
                )
                wingPath.addCurve(
                    to: CGPoint(x: radius * 0.28, y: radius * 0.14),
                    control1: CGPoint(x: -radius * 0.25, y: radius * 0.55),
                    control2: CGPoint(x: radius * 0.13, y: radius * 0.38)
                )
                wingPath.closeSubpath()
                wing.fill(wingPath, with: .color(Color(red: 0.16, green: 0.48, blue: 0.22)))
            }

            var beak = Path()
            beak.move(to: CGPoint(x: radius * 1.02, y: -radius * 0.30))
            beak.addLine(to: CGPoint(x: radius * 1.53, y: -radius * 0.10))
            beak.addLine(to: CGPoint(x: radius * 1.02, y: radius * 0.04))
            beak.closeSubpath()
            layer.fill(beak, with: .color(Color(red: 1.00, green: 0.66, blue: 0.12)))
            layer.stroke(beak, with: .color(Color.black.opacity(0.65)), lineWidth: max(1, radius * 0.055))

            let eyeWhite = Path(
                ellipseIn: CGRect(
                    x: radius * 0.73,
                    y: -radius * 0.53,
                    width: radius * 0.25,
                    height: radius * 0.25
                )
            )
            layer.fill(eyeWhite, with: .color(.white))
            let pupil = Path(
                ellipseIn: CGRect(
                    x: radius * 0.83,
                    y: -radius * 0.46,
                    width: radius * 0.11,
                    height: radius * 0.11
                )
            )
            layer.fill(pupil, with: .color(.black))
        }
    }

    private static func draw(
        _ laser: LaserBeam,
        elapsedTime: Double,
        in context: inout GraphicsContext
    ) {
        let progress = min(max((elapsedTime - laser.bornAt) / laser.duration, 0), 1)
        let opacity = 1 - progress
        var path = Path()
        path.move(to: CGPoint(x: laser.origin.x, y: laser.origin.y))
        path.addLine(to: CGPoint(x: laser.target.x, y: laser.target.y))

        context.drawLayer { layer in
            layer.addFilter(.shadow(color: Theme.accent.opacity(opacity), radius: 9))
            layer.stroke(
                path,
                with: .color(Theme.accent.opacity(opacity * 0.78)),
                style: StrokeStyle(lineWidth: 7, lineCap: .round)
            )
            layer.stroke(
                path,
                with: .color(Color.white.opacity(opacity)),
                style: StrokeStyle(lineWidth: 2, lineCap: .round)
            )
        }
    }

    private static func draw(
        _ burst: ImpactBurst,
        elapsedTime: Double,
        in context: inout GraphicsContext
    ) {
        let progress = min(max((elapsedTime - burst.bornAt) / burst.duration, 0), 1)
        let radius = 12 + 48 * progress
        let rect = CGRect(
            x: burst.center.x - radius,
            y: burst.center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.stroke(
            Path(ellipseIn: rect),
            with: .color(Theme.accent.opacity(1 - progress)),
            style: StrokeStyle(lineWidth: 5 * (1 - progress), lineCap: .round)
        )
    }

    private static func drawReticle(
        _ snapshot: GameSnapshot,
        size: CGSize,
        in context: inout GraphicsContext
    ) {
        let radius = min(size.width, size.height) * 0.075
        let center = CGPoint(x: snapshot.aim.x, y: snapshot.aim.y)
        let color = if !snapshot.isFaceTracked {
            Color.white.opacity(0.35)
        } else if snapshot.isTargetLocked {
            Theme.accent
        } else {
            Theme.cyan
        }

        context.drawLayer { layer in
            if snapshot.isTargetLocked {
                layer.addFilter(.shadow(color: Theme.accent.opacity(0.9), radius: 10))
            }
            layer.stroke(
                Path(
                    ellipseIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                ),
                with: .color(color),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [8, 7])
            )

            var crosshair = Path()
            crosshair.move(to: CGPoint(x: center.x - radius * 1.28, y: center.y))
            crosshair.addLine(to: CGPoint(x: center.x - radius * 0.55, y: center.y))
            crosshair.move(to: CGPoint(x: center.x + radius * 0.55, y: center.y))
            crosshair.addLine(to: CGPoint(x: center.x + radius * 1.28, y: center.y))
            crosshair.move(to: CGPoint(x: center.x, y: center.y - radius * 1.28))
            crosshair.addLine(to: CGPoint(x: center.x, y: center.y - radius * 0.55))
            crosshair.move(to: CGPoint(x: center.x, y: center.y + radius * 0.55))
            crosshair.addLine(to: CGPoint(x: center.x, y: center.y + radius * 1.28))
            layer.stroke(
                crosshair,
                with: .color(color),
                style: StrokeStyle(lineWidth: 3, lineCap: .round)
            )
        }
    }
}
