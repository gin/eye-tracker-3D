import SwiftUI
import UIKit

struct GameView: View {
    let model: AppModel

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                GameCanvas(session: model.gameSession)

                GameHUD(session: model.gameSession, onExit: model.goHome)
                    .padding(.horizontal, 16)
                    .padding(.top, max(geometry.safeAreaInsets.top, 12))
                    .padding(.bottom, max(geometry.safeAreaInsets.bottom, 12))

                if model.gameSession.phase == .finished {
                    GameOverView(
                        model: model,
                        replay: { model.replay(in: geometry.size) }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .onAppear {
                UIApplication.shared.isIdleTimerDisabled = true
                model.gameSession.start(in: geometry.size)
            }
            .onChange(of: geometry.size) { _, size in
                model.gameSession.updateViewport(size)
            }
            .onDisappear {
                model.gameSession.stop()
                UIApplication.shared.isIdleTimerDisabled = false
            }
        }
        .animation(.snappy(duration: 0.28), value: model.gameSession.phase)
    }
}

private struct GameHUD: View {
    let session: GameSession
    let onExit: () -> Void

    var body: some View {
        VStack {
            HStack(alignment: .top, spacing: 12) {
                Button(action: onExit) {
                    Image(systemName: "xmark")
                        .font(.headline.bold())
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.circle)
                .accessibilityLabel("Leave game")

                HUDValue(label: "SCORE", value: session.score.formatted())

                Spacer(minLength: 8)

                HUDValue(
                    label: "TIME",
                    value: "\(session.remainingSeconds)",
                    warning: session.remainingSeconds <= 5
                )
            }

            Spacer()

            if !session.isFaceTracked, session.phase == .playing {
                Label("Center your face to aim", systemImage: "viewfinder")
                    .font(.subheadline.weight(.bold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(.ultraThinMaterial, in: Capsule())
                    .transition(.opacity)
            } else if session.phase == .playing {
                Text(session.isTargetLocked ? "OPEN MOUTH — HIT LOCKED" : "OPEN MOUTH TO FIRE")
                    .font(.caption.weight(.black))
                    .tracking(0.8)
                    .foregroundStyle(session.isTargetLocked ? Theme.accent : .white.opacity(0.75))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.black.opacity(0.38), in: Capsule())
            }
        }
        .allowsHitTesting(true)
    }
}

private struct HUDValue: View {
    let label: String
    let value: String
    var warning = false

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.caption2.weight(.black))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 24, weight: .black, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(warning ? .red : .white)
                .contentTransition(.numericText())
        }
        .frame(minWidth: 76)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

private struct GameOverView: View {
    let model: AppModel
    let replay: () -> Void

    var body: some View {
        Color.black.opacity(0.70)
            .ignoresSafeArea()
            .overlay {
                ScrollView {
                    VStack(spacing: 18) {
                        Image(systemName: "scope")
                            .font(.system(size: 38, weight: .bold))
                            .foregroundStyle(Theme.accent)

                        VStack(spacing: 4) {
                            Text("HUNT COMPLETE")
                                .font(.title2.weight(.black))
                            Text(model.gameSession.score, format: .number)
                                .font(.system(size: 52, weight: .black, design: .rounded))
                                .foregroundStyle(Theme.cyan)
                                .contentTransition(.numericText())
                            if let rank = model.latestRank {
                                Text(rank <= 10 ? "#\(rank) all time" : "Outside the top 10")
                                    .font(.headline)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !model.scores.isEmpty {
                            VStack(spacing: 8) {
                                ForEach(Array(model.scores.prefix(5).enumerated()), id: \.element.id) { index, record in
                                    HStack {
                                        Text("#\(index + 1)")
                                            .foregroundStyle(index == 0 ? Theme.accent : .secondary)
                                        Spacer()
                                        Text(record.score, format: .number)
                                            .fontWeight(.bold)
                                    }
                                    .font(.system(.body, design: .monospaced))
                                }
                            }
                            .padding(14)
                            .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        }

                        VStack(spacing: 10) {
                            Button(action: replay) {
                                Label("Hunt Again", systemImage: "arrow.counterclockwise")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)

                            Button("Back to Menu", action: model.goHome)
                                .buttonStyle(.bordered)
                                .controlSize(.large)
                        }
                    }
                    .gamePanel()
                    .padding(24)
                    .frame(maxWidth: 440)
                }
                .scrollIndicators(.hidden)
            }
    }
}
