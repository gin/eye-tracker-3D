import DuckHuntCore
import SwiftUI
import UIKit

struct CalibrationView: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                calibrationTarget(in: geometry.size)

                VStack(spacing: 14) {
                    HStack {
                        if model.canCancelCalibration {
                            Button("Cancel", action: model.cancelCalibration)
                                .buttonStyle(.bordered)
                        }
                        Spacer()
                        Text("\(model.calibrationIndex + 1) / \(GazeCalibration.standardAnchors.count)")
                            .font(.system(.subheadline, design: .monospaced, weight: .bold))
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: model.calibrationProgress)
                        .tint(Theme.accent)

                    VStack(spacing: 6) {
                        Text("CALIBRATE YOUR GAZE")
                            .font(.headline.weight(.black))
                        Text("Keep your head still. Follow the dot using only your eyes.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .gamePanel()

                    Spacer()

                    FaceStatusPill(status: model.trackingStatus)
                    Text(model.isCapturingCalibration ? "Hold your gaze" : "Find the next dot")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(model.isCapturingCalibration ? Theme.accent : .secondary)
                        .animation(.easeInOut(duration: 0.2), value: model.isCapturingCalibration)
                }
                .padding(20)

                if let error = model.calibrationError {
                    calibrationError(error)
                }
            }
        }
        .task(id: model.calibrationAttempt) {
            await model.performCalibration()
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    private func calibrationTarget(in size: CGSize) -> some View {
        let anchor = model.currentCalibrationAnchor.displayPoint
        return ZStack {
            Circle()
                .fill(Theme.accent.opacity(0.18))
                .frame(width: 72, height: 72)
                .blur(radius: 9)
            Circle()
                .stroke(Theme.cyan.opacity(0.8), lineWidth: 2)
                .frame(width: 42, height: 42)
            Circle()
                .fill(Theme.accent)
                .frame(width: 18, height: 18)
                .shadow(color: Theme.accent, radius: 12)
        }
        .scaleEffect(model.isCapturingCalibration ? 0.82 : 1)
        .position(x: anchor.x * size.width, y: anchor.y * size.height)
        .animation(.easeInOut(duration: 0.35), value: model.calibrationIndex)
        .animation(.easeInOut(duration: 0.18), value: model.isCapturingCalibration)
        .accessibilityLabel("Calibration target")
    }

    private func calibrationError(_ message: String) -> some View {
        Color.black.opacity(0.72)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 18) {
                    Image(systemName: "eye.trianglebadge.exclamationmark")
                        .font(.system(size: 42))
                        .foregroundStyle(.yellow)
                    Text("Try Calibration Again")
                        .font(.title2.bold())
                    Text(message)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Retry", action: model.retryCalibration)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    if model.canCancelCalibration {
                        Button("Keep Previous Calibration", action: model.cancelCalibration)
                            .buttonStyle(.bordered)
                    }
                }
                .gamePanel()
                .padding(24)
                .frame(maxWidth: 460)
            }
    }
}
