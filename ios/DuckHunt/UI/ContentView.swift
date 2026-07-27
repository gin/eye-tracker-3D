import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    let model: AppModel

    var body: some View {
        ZStack {
            if model.destination != .unsupported {
                ARFaceTrackingView(
                    isRunning: scenePhase == .active,
                    onFrame: { frame in model.receive(frame) }
                )
                .accessibilityHidden(true)
                .ignoresSafeArea()

                Color.black.opacity(cameraDimming)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
            } else {
                LinearGradient(
                    colors: [Theme.background, Color(red: 0.10, green: 0.04, blue: 0.13)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            }

            switch model.destination {
            case .unsupported:
                UnsupportedView()
            case .calibration:
                CalibrationView(model: model)
            case .home:
                HomeView(model: model)
            case .game:
                GameView(model: model)
            }
        }
        .tint(Theme.accent)
        .fontDesign(.rounded)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.appDidBecomeActive()
            } else {
                model.appWillResignActive()
            }
        }
    }

    /// The user's own eyes are the strongest gaze attractor on the screen, so the camera
    /// feed is blacked out entirely while we ask them to look at a dot.
    private var cameraDimming: Double {
        switch model.destination {
        case .calibration:
            1
        case .home:
            0.58
        case .game:
            0.08
        case .unsupported:
            0
        }
    }
}

private struct UnsupportedView: View {
    var body: some View {
        ContentUnavailableView {
            Label("Face Tracking Unavailable", systemImage: "faceid")
        } description: {
            Text("Duck Hunt requires an iPhone or iPad that supports ARKit face tracking.")
        }
        .padding()
    }
}

enum Theme {
    static let accent = Color(red: 1.00, green: 0.24, blue: 0.58)
    static let cyan = Color(red: 0.28, green: 0.88, blue: 1.00)
    static let background = Color(red: 0.03, green: 0.025, blue: 0.055)
    static let panel = Color.white.opacity(0.11)
}

struct PanelModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
            }
    }
}

extension View {
    func gamePanel() -> some View {
        modifier(PanelModifier())
    }
}
