import ARKit
import DuckHuntCore
import RealityKit
import simd
import SwiftUI

struct ARFaceTrackingView: UIViewRepresentable {
    let isRunning: Bool
    let onFrame: @MainActor @Sendable (FaceTrackingFrame) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onFrame: onFrame)
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: false)
        view.isOpaque = true
        view.renderOptions.formUnion([
            .disableAREnvironmentLighting,
            .disableAutomaticLighting,
            .disableCameraGrain,
            .disableDepthOfField,
            .disableFaceMesh,
            .disableFaceOcclusions,
            .disableGroundingShadows,
            .disableHDR,
            .disableMotionBlur,
            .disablePersonOcclusion,
        ])
        context.coordinator.attach(to: view, isRunning: isRunning)
        return view
    }

    func updateUIView(_ view: ARView, context: Context) {
        context.coordinator.setRunning(isRunning)
    }

    static func dismantleUIView(_ view: ARView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        private let onFrame: @MainActor @Sendable (FaceTrackingFrame) -> Void
        private let stream: AsyncStream<TrackingPayload>
        nonisolated private let continuation: AsyncStream<TrackingPayload>.Continuation
        @MainActor private weak var arView: ARView?
        @MainActor private var consumerTask: Task<Void, Never>?
        @MainActor private var isRunning = false

        init(onFrame: @escaping @MainActor @Sendable (FaceTrackingFrame) -> Void) {
            self.onFrame = onFrame
            let pair = AsyncStream.makeStream(
                of: TrackingPayload.self,
                bufferingPolicy: .bufferingNewest(1)
            )
            stream = pair.stream
            continuation = pair.continuation
            super.init()
        }

        @MainActor
        func attach(to view: ARView, isRunning: Bool) {
            arView = view
            view.session.delegate = self
            let stream = stream
            consumerTask = Task { @MainActor [weak self] in
                for await payload in stream {
                    guard !Task.isCancelled else { return }
                    self?.consume(payload)
                }
            }
            setRunning(isRunning)
        }

        @MainActor
        func detach() {
            isRunning = false
            arView?.session.pause()
            arView?.session.delegate = nil
            arView = nil
            consumerTask?.cancel()
            consumerTask = nil
            continuation.finish()
        }

        @MainActor
        func setRunning(_ shouldRun: Bool) {
            guard shouldRun != isRunning else { return }
            isRunning = shouldRun
            if shouldRun {
                runFaceTracking(reset: true)
            } else {
                arView?.session.pause()
            }
        }

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard
                let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first,
                face.isTracked
            else {
                continuation.yield(.status(.searching, timestamp: frame.timestamp))
                return
            }

            let lookAt = face.lookAtPoint
            let depth = max(abs(Double(lookAt.z)), 0.001)
            let rawGaze = RawGazeSample(
                horizontal: Double(lookAt.x) / depth,
                vertical: Double(lookAt.y) / depth
            )
            let leftEyeTransform = simd_mul(face.transform, face.leftEyeTransform)
            let rightEyeTransform = simd_mul(face.transform, face.rightEyeTransform)
            let leftColumn = leftEyeTransform.columns.3
            let rightColumn = rightEyeTransform.columns.3
            let jawOpen = face.blendShapes[.jawOpen]?.doubleValue ?? 0

            continuation.yield(
                .face(
                    UnprojectedFaceFrame(
                        timestamp: frame.timestamp,
                        rawGaze: rawGaze,
                        leftEye: SIMD3(leftColumn.x, leftColumn.y, leftColumn.z),
                        rightEye: SIMD3(rightColumn.x, rightColumn.y, rightColumn.z),
                        jawOpen: min(max(jawOpen, 0), 1)
                    )
                )
            )
        }

        nonisolated func session(_ session: ARSession, didFailWithError error: any Error) {
            let timestamp = session.currentFrame?.timestamp ?? 0
            continuation.yield(.status(.failed(error.localizedDescription), timestamp: timestamp))
        }

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            let timestamp = session.currentFrame?.timestamp ?? 0
            continuation.yield(.status(.searching, timestamp: timestamp))
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            continuation.yield(.restart)
        }

        @MainActor
        private func consume(_ payload: TrackingPayload) {
            switch payload {
            case .face(let frame):
                guard isRunning, let arView else { return }
                let bounds = arView.bounds
                guard bounds.width > 0, bounds.height > 0 else { return }

                onFrame(
                    FaceTrackingFrame(
                        timestamp: frame.timestamp,
                        rawGaze: frame.rawGaze,
                        leftEye: normalized(arView.project(frame.leftEye), in: bounds),
                        rightEye: normalized(arView.project(frame.rightEye), in: bounds),
                        jawOpen: frame.jawOpen,
                        status: .tracked
                    )
                )
            case .status(let status, let timestamp):
                guard isRunning else { return }
                switch status {
                case .searching:
                    onFrame(.searching(at: timestamp))
                case .failed:
                    onFrame(
                        FaceTrackingFrame(
                            timestamp: timestamp,
                            rawGaze: nil,
                            leftEye: nil,
                            rightEye: nil,
                            jawOpen: 0,
                            status: status
                        )
                    )
                case .tracked:
                    break
                }
            case .restart:
                if isRunning {
                    runFaceTracking(reset: true)
                }
            }
        }

        @MainActor
        private func runFaceTracking(reset: Bool) {
            guard let arView else { return }
            guard ARFaceTrackingConfiguration.isSupported else {
                onFrame(
                    FaceTrackingFrame(
                        timestamp: 0,
                        rawGaze: nil,
                        leftEye: nil,
                        rightEye: nil,
                        jawOpen: 0,
                        status: .failed("This device does not support ARKit face tracking.")
                    )
                )
                return
            }

            let configuration = ARFaceTrackingConfiguration()
            configuration.maximumNumberOfTrackedFaces = 1
            configuration.isLightEstimationEnabled = false
            configuration.providesAudioData = false
            let options: ARSession.RunOptions = reset ? [.resetTracking, .removeExistingAnchors] : []
            arView.session.run(configuration, options: options)
        }

        @MainActor
        private func normalized(_ point: CGPoint?, in bounds: CGRect) -> NormalizedPoint? {
            guard let point else { return nil }
            return NormalizedPoint(
                x: min(max(point.x / bounds.width, 0), 1),
                y: min(max(point.y / bounds.height, 0), 1)
            )
        }
    }
}

private struct UnprojectedFaceFrame: Sendable {
    let timestamp: TimeInterval
    let rawGaze: RawGazeSample
    let leftEye: SIMD3<Float>
    let rightEye: SIMD3<Float>
    let jawOpen: Double
}

private enum TrackingPayload: Sendable {
    case face(UnprojectedFaceFrame)
    case status(FaceTrackingStatus, timestamp: TimeInterval)
    case restart
}
