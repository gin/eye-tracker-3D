import ARKit
import DuckHuntCore
import os
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
        nonisolated private let headMotion = HeadMotionTracker()
        /// Resolved once. The device cannot change under a running session, and the lookup
        /// reaches for `sysctl`, which has no business on a 60 Hz callback.
        nonisolated private let display = PhysicalDisplay.current
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
                headMotion.forget()
                arView?.session.pause()
            }
        }

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            guard
                let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first,
                face.isTracked
            else {
                headMotion.forget()
                continuation.yield(.status(.searching, timestamp: frame.timestamp))
                return
            }

            let headAngularSpeed = headMotion.angularSpeed(of: face.transform, at: frame.timestamp)
            let leftEyeTransform = simd_mul(face.transform, face.leftEyeTransform)
            let rightEyeTransform = simd_mul(face.transform, face.rightEyeTransform)
            let worldToCamera = simd_inverse(frame.camera.transform)

            guard
                let leftHit = screenHit(of: leftEyeTransform, worldToCamera: worldToCamera),
                let rightHit = screenHit(of: rightEyeTransform, worldToCamera: worldToCamera)
            else {
                // A ray parallel to the screen, or pointing away from it, carries no gaze.
                // Reporting the miss beats handing the calibrator an invented point.
                continuation.yield(.status(.searching, timestamp: frame.timestamp))
                return
            }

            let leftColumn = leftEyeTransform.columns.3
            let rightColumn = rightEyeTransform.columns.3
            let jawOpen = face.blendShapes[.jawOpen]?.doubleValue ?? 0
            let blinkLeft = face.blendShapes[.eyeBlinkLeft]?.doubleValue ?? 0
            let blinkRight = face.blendShapes[.eyeBlinkRight]?.doubleValue ?? 0
            let eyeMidpoint = (leftHit.origin + rightHit.origin) / 2

            continuation.yield(
                .face(
                    UnprojectedFaceFrame(
                        timestamp: frame.timestamp,
                        rawGaze: normalizedGaze(
                            of: (leftHit.screenPoint + rightHit.screenPoint) / 2,
                            on: display
                        ),
                        leftEye: SIMD3(leftColumn.x, leftColumn.y, leftColumn.z),
                        rightEye: SIMD3(rightColumn.x, rightColumn.y, rightColumn.z),
                        jawOpen: min(max(jawOpen, 0), 1),
                        eyeBlink: min(max(max(blinkLeft, blinkRight), 0), 1),
                        headAngularSpeed: headAngularSpeed,
                        viewingDistance: Double(simd_length(eyeMidpoint))
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

        /// Where an eye's optical axis meets the plane of the device, in camera space.
        ///
        /// Apple documents the eye transform's translation as the centre of the eyeball and
        /// its positive z axis as running from that centre out through the pupil, so the eye
        /// is a ray and the screen is the plane `z == 0` of the camera's own space. Folding
        /// head and device pose in this way is the whole point: a face-relative gaze angle
        /// cannot tell a turned head from a moved eye.
        nonisolated private func screenHit(
            of eyeTransform: simd_float4x4,
            worldToCamera: simd_float4x4
        ) -> EyeScreenHit? {
            let centre = eyeTransform.columns.3
            let forward = eyeTransform.columns.2
            let eye = simd_mul(worldToCamera, SIMD4<Float>(centre.x, centre.y, centre.z, 1))
            let heading = simd_mul(worldToCamera, SIMD4<Float>(forward.x, forward.y, forward.z, 0))
            let origin = SIMD3<Float>(eye.x, eye.y, eye.z)
            let direction = simd_normalize(SIMD3<Float>(heading.x, heading.y, heading.z))
            guard abs(direction.z) > 1e-5 else { return nil }
            let distance = -origin.z / direction.z
            guard distance > 0, distance.isFinite else { return nil }
            return EyeScreenHit(origin: origin, screenPoint: origin + direction * distance)
        }

        /// Converts a camera-space point on the device plane to normalized display coordinates.
        ///
        /// ARKit's camera space is landscape-native whatever the interface orientation: its x
        /// axis runs the long edge of the device from the TrueDepth camera toward the bottom,
        /// and its y axis runs the short edge. This app is portrait, so screen x comes from
        /// the camera's y component and screen y from its x. The exact signs matter less than
        /// they look, because `GazeModel` fits both outputs against both inputs and so absorbs
        /// any reflection or swap left over. What it cannot recover from is an axis collapsed
        /// to a constant, so both components stay independent here.
        nonisolated private func normalizedGaze(
            of point: SIMD3<Float>,
            on display: PhysicalDisplay
        ) -> RawGazeSample {
            // `PhysicalDisplay` measures the camera from the centre of the active area with
            // +y up, while these coordinates run +y down, so the vertical offset flips sign.
            let rightMillimetres = Double(point.y) * 1000 + display.cameraOffsetXMillimetres
            let downMillimetres = Double(point.x) * 1000 - display.cameraOffsetYMillimetres
            return RawGazeSample(
                horizontal: 0.5 + rightMillimetres / display.widthMillimetres,
                vertical: 0.5 + downMillimetres / display.heightMillimetres
            )
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
                        eyeBlink: frame.eyeBlink,
                        headAngularSpeed: frame.headAngularSpeed,
                        viewingDistance: frame.viewingDistance,
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
                            eyeBlink: 0,
                            headAngularSpeed: 0,
                            viewingDistance: 0,
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
                        eyeBlink: 0,
                        headAngularSpeed: 0,
                        viewingDistance: 0,
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
    let eyeBlink: Double
    let headAngularSpeed: Double
    let viewingDistance: Double
}

/// One eye's ray, already intersected with the plane of the device, in camera space.
private struct EyeScreenHit {
    let origin: SIMD3<Float>
    let screenPoint: SIMD3<Float>
}

/// Frame-to-frame head rotation, kept off the main actor.
///
/// `ARSessionDelegate` callbacks are nonisolated and ARKit promises nothing about which
/// thread delivers them, so the only state the geometry carries between frames sits behind
/// a lock. Hopping to the main actor for it would put an actor round trip in a 60 Hz path
/// that otherwise touches nothing shared.
private final class HeadMotionTracker: Sendable {
    private struct Previous {
        var rotation: simd_quatf
        var timestamp: TimeInterval
    }

    private let previous = OSAllocatedUnfairLock<Previous?>(initialState: nil)

    /// Radians per second since the last frame, or 0 for the first frame after `forget()`.
    func angularSpeed(of transform: simd_float4x4, at timestamp: TimeInterval) -> Double {
        let rotation = Self.rotation(of: transform)
        return previous.withLock { state in
            defer { state = Previous(rotation: rotation, timestamp: timestamp) }
            guard let last = state, timestamp > last.timestamp else { return 0 }
            let change = (rotation * last.rotation.inverse).normalized
            // A quaternion and its negation name the same rotation, so `angle` can come back
            // as the long way round. Folding stops a small nod reading as a violent lurch.
            let angle = Double(change.angle)
            let shortest = angle > Double.pi ? 2 * Double.pi - angle : angle
            return shortest / (timestamp - last.timestamp)
        }
    }

    /// Drops the history so the next frame starts a fresh interval.
    func forget() {
        previous.withLock { $0 = nil }
    }

    /// ARKit hands back rigid transforms, but normalizing the basis keeps `simd_quatf` from
    /// producing nonsense should any scale ever creep into the anchor.
    private static func rotation(of transform: simd_float4x4) -> simd_quatf {
        simd_quatf(
            simd_float3x3(
                simd_normalize(simd_make_float3(transform.columns.0)),
                simd_normalize(simd_make_float3(transform.columns.1)),
                simd_normalize(simd_make_float3(transform.columns.2))
            )
        )
    }
}

private enum TrackingPayload: Sendable {
    case face(UnprojectedFaceFrame)
    case status(FaceTrackingStatus, timestamp: TimeInterval)
    case restart
}
