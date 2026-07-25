import SwiftUI

struct HomeView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 36)

                ZStack {
                    Circle()
                        .stroke(Theme.cyan.opacity(0.35), lineWidth: 2)
                        .frame(width: 108, height: 108)
                    Circle()
                        .stroke(Theme.accent, style: StrokeStyle(lineWidth: 5, lineCap: .round, dash: [20, 10]))
                        .frame(width: 78, height: 78)
                    Image(systemName: "bird.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(.white)
                }
                .accessibilityHidden(true)

                VStack(spacing: 8) {
                    Text("GAZE DUCK HUNT")
                        .font(.system(size: 34, weight: .black, design: .rounded))
                        .multilineTextAlignment(.center)
                    Text("Aim with your eyes. Open your mouth to fire.")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                FaceStatusPill(status: model.trackingStatus)

                VStack(spacing: 12) {
                    Button(action: model.play) {
                        Label("Start 30-Second Hunt", systemImage: "scope")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .font(.headline)

                    Button("Recalibrate Eye Tracking", action: model.beginCalibration)
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                .frame(maxWidth: 420)

                if !model.scores.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Best Hunts", systemImage: "trophy.fill")
                            .font(.headline)
                            .foregroundStyle(Theme.cyan)

                        ForEach(Array(model.scores.prefix(5).enumerated()), id: \.element.id) { index, record in
                            HStack {
                                Text("#\(index + 1)")
                                    .font(.system(.body, design: .monospaced, weight: .bold))
                                    .foregroundStyle(index == 0 ? Theme.accent : .secondary)
                                    .frame(width: 34, alignment: .leading)
                                Text(record.playedAt, format: .dateTime.month(.abbreviated).day())
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(record.score, format: .number)
                                    .font(.system(.headline, design: .rounded, weight: .bold))
                            }
                        }
                    }
                    .gamePanel()
                    .frame(maxWidth: 420)
                }

                Label("Face frames stay on-device. Only calibration coefficients and scores are saved.", systemImage: "lock.shield.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)
        }
        .scrollIndicators(.hidden)
    }
}

struct FaceStatusPill: View {
    let status: FaceTrackingStatus

    var body: some View {
        Label(message, systemImage: icon)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityLabel(message)
    }

    private var message: String {
        switch status {
        case .searching:
            "Center your face"
        case .tracked:
            "Face locked"
        case .failed:
            "Tracking unavailable"
        }
    }

    private var icon: String {
        switch status {
        case .searching:
            "face.dashed"
        case .tracked:
            "faceid"
        case .failed:
            "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .searching:
            .yellow
        case .tracked:
            .green
        case .failed:
            .red
        }
    }
}
