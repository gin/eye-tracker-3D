import { FaceLandmarker, FilesetResolver, type FaceLandmarkerResult, type Matrix } from "@mediapipe/tasks-vision";
import type { HeadPosition, IrisOffset, TrackerListener, TrackerStatus, TrackingSample } from "./types";

// Must match the installed npm package version: the WASM binary and the JS
// bindings that talk to it are version-locked.
const MEDIAPIPE_VERSION = "0.10.35";
const WASM_BASE_URL = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${MEDIAPIPE_VERSION}/wasm`;
const MODEL_URL =
  "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task";

// Landmark inference is synchronous even with the GPU delegate. Keep it out
// of the rendering phase and cap its share of the main-thread budget. Slow
// devices automatically settle toward 20 Hz; fast devices stay near 30 Hz.
const FASTEST_DETECTION_INTERVAL_MS = 30;
const SLOWEST_DETECTION_INTERVAL_MS = 50;
const INFERENCE_BUDGET_MULTIPLIER = 4;
const INFERENCE_DURATION_ALPHA = 0.2;

// Landmark indices from MediaPipe's 478-point face mesh (iris refinement on).
const LEFT_IRIS = 468;
const LEFT_EYE_OUTER = 33;
const LEFT_EYE_INNER = 133;
const LEFT_EYE_TOP = 159;
const LEFT_EYE_BOTTOM = 145;

const RIGHT_IRIS = 473;
const RIGHT_EYE_OUTER = 263;
const RIGHT_EYE_INNER = 362;
const RIGHT_EYE_TOP = 386;
const RIGHT_EYE_BOTTOM = 374;

// Inner lip centers: the gap between these two closes to nearly zero with
// the mouth shut, which the outer lip contour never does.
const UPPER_LIP_INNER = 13;
const LOWER_LIP_INNER = 14;

interface Point2 {
  x: number;
  y: number;
}

function irisOffsetForEye(
  landmarks: readonly Point2[],
  irisIdx: number,
  outerIdx: number,
  innerIdx: number,
  topIdx: number,
  bottomIdx: number,
): IrisOffset {
  const iris = landmarks[irisIdx]!;
  const outer = landmarks[outerIdx]!;
  const inner = landmarks[innerIdx]!;
  const top = landmarks[topIdx]!;
  const bottom = landmarks[bottomIdx]!;

  const width = Math.hypot(outer.x - inner.x, outer.y - inner.y) || 1e-6;
  const height = Math.hypot(top.x - bottom.x, top.y - bottom.y) || 1e-6;
  const centerX = (outer.x + inner.x) / 2;
  const centerY = (top.y + bottom.y) / 2;

  // Half-width/height normalize so the eye corners sit at roughly +-1.
  return {
    x: ((iris.x - centerX) / (width / 2)) * 2,
    y: ((iris.y - centerY) / (height / 2)) * 2,
  };
}

function extractIrisOffset(landmarks: readonly Point2[]): IrisOffset {
  const left = irisOffsetForEye(landmarks, LEFT_IRIS, LEFT_EYE_OUTER, LEFT_EYE_INNER, LEFT_EYE_TOP, LEFT_EYE_BOTTOM);
  const right = irisOffsetForEye(landmarks, RIGHT_IRIS, RIGHT_EYE_OUTER, RIGHT_EYE_INNER, RIGHT_EYE_TOP, RIGHT_EYE_BOTTOM);
  return {
    x: Math.min(2.5, Math.max(-2.5, (left.x + right.x) / 2)),
    y: Math.min(2.5, Math.max(-2.5, (left.y + right.y) / 2)),
  };
}

/**
 * Mouth aperture as a fraction of face width. Dividing by the outer-eye-
 * corner span is what makes the number comparable between a face close to
 * the camera and one further back — the raw lip gap alone just tracks how
 * near the user is sitting.
 */
function extractMouthOpenness(landmarks: readonly Point2[]): number {
  const upper = landmarks[UPPER_LIP_INNER]!;
  const lower = landmarks[LOWER_LIP_INNER]!;
  const leftCorner = landmarks[LEFT_EYE_OUTER]!;
  const rightCorner = landmarks[RIGHT_EYE_OUTER]!;

  const faceWidth = Math.hypot(leftCorner.x - rightCorner.x, leftCorner.y - rightCorner.y) || 1e-6;
  return Math.hypot(upper.x - lower.x, upper.y - lower.y) / faceWidth;
}

function extractHeadPosition(matrix: Matrix | undefined): HeadPosition | null {
  if (!matrix || matrix.data.length < 16) return null;
  // MediaPipe's MatrixData proto is documented column-major: for a 4x4
  // affine [R|t; 0 1], translation occupies the last column, i.e. flat
  // indices [12, 13, 14].
  return { x: matrix.data[12]!, y: matrix.data[13]!, z: matrix.data[14]! };
}

/**
 * Wraps camera acquisition + MediaPipe FaceLandmarker into a small
 * push-based tracker: subscribe for a live stream of {@link TrackingSample}s
 * driven by the camera's own frame callbacks.
 */
export class FaceTracker {
  status: TrackerStatus = "idle";
  error: Error | null = null;

  private video: HTMLVideoElement | null = null;
  private stream: MediaStream | null = null;
  private landmarker: FaceLandmarker | null = null;
  private readonly listeners = new Set<TrackerListener>();
  private latest: TrackingSample | null = null;
  private rafHandle = 0;
  private videoFrameHandle = 0;
  private lastDetectTimeMs = 0;
  private lastFrameTime = -1;
  private detectionTimerHandle = 0;
  private lastDetectionStartedAt = -Infinity;
  private averageDetectionMs = 0;
  private stopped = false;

  subscribe(listener: TrackerListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  getLatest(): TrackingSample | null {
    return this.latest;
  }

  /**
   * The element MediaPipe reads each frame. Exposed so a screen can show the
   * user their own camera feed by attaching it to the DOM; detection does
   * not care whether it is attached, so callers must remove it again on
   * unmount rather than tearing anything down here.
   */
  get videoElement(): HTMLVideoElement | null {
    return this.video;
  }

  async start(): Promise<void> {
    if (this.status !== "idle" && this.status !== "error") return;
    this.stopped = false;
    this.error = null;
    this.lastDetectionStartedAt = -Infinity;
    this.averageDetectionMs = 0;

    try {
      this.status = "requesting-camera";
      this.stream = await navigator.mediaDevices.getUserMedia({
        // A faster capture rate is the cheapest latency win there is: it
        // shortens the gap between the head moving and a frame existing to
        // detect it in. Detection is driven per *delivered* frame below, so
        // asking for 60 costs nothing on hardware that only grants 30.
        video: {
          facingMode: "user",
          width: { ideal: 640 },
          height: { ideal: 480 },
          frameRate: { ideal: 60 },
        },
        audio: false,
      });

      const video = document.createElement("video");
      video.srcObject = this.stream;
      video.playsInline = true;
      video.muted = true;
      await video.play();
      this.video = video;

      this.status = "loading-model";
      const fileset = await FilesetResolver.forVisionTasks(WASM_BASE_URL);
      const landmarkerOptions = {
        runningMode: "VIDEO",
        numFaces: 1,
        outputFaceBlendshapes: false,
        outputFacialTransformationMatrixes: true,
      } as const;
      // Prefer the GPU delegate: landmarking runs on the main thread, where
      // CPU inference can eat most of a phone's frame budget and stall
      // rendering. Not every WebGL/driver combination accepts it, so fall
      // back rather than leaving the tracker dead.
      try {
        this.landmarker = await FaceLandmarker.createFromOptions(fileset, {
          ...landmarkerOptions,
          baseOptions: { modelAssetPath: MODEL_URL, delegate: "GPU" },
        });
      } catch {
        this.landmarker = await FaceLandmarker.createFromOptions(fileset, {
          ...landmarkerOptions,
          baseOptions: { modelAssetPath: MODEL_URL, delegate: "CPU" },
        });
      }

      this.status = "no-face";
      this.startDetectionLoop(video);
    } catch (err) {
      this.status = "error";
      this.error = err instanceof Error ? err : new Error(String(err));
      throw this.error;
    }
  }

  stop(): void {
    this.stopped = true;
    cancelAnimationFrame(this.rafHandle);
    this.video?.cancelVideoFrameCallback?.(this.videoFrameHandle);
    window.clearTimeout(this.detectionTimerHandle);
    this.detectionTimerHandle = 0;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.landmarker?.close();
    this.landmarker = null;
    this.stream = null;
    this.video = null;
    this.lastFrameTime = -1;
    this.status = "idle";
  }

  /**
   * Observes each camera frame, then queues at most one inference after the
   * browser finishes the current rendering phase. Running detectForVideo
   * directly inside requestVideoFrameCallback blocks requestAnimationFrame;
   * processing all 60 camera frames can therefore turn a 60 fps scene into a
   * 30–45 fps one. The queue below adapts between 20 and ~30 detections/sec.
   */
  private startDetectionLoop(video: HTMLVideoElement): void {
    // Typed as always-present by lib.dom, but only actually shipped in
    // Safari 15.4+ / Firefox 132+, so this needs a real runtime test.
    const requestVideoFrame =
      typeof video.requestVideoFrameCallback === "function" ? video.requestVideoFrameCallback.bind(video) : null;
    if (requestVideoFrame) {
      const onVideoFrame = (): void => {
        if (this.stopped) return;
        this.queueCurrentFrame();
        this.videoFrameHandle = requestVideoFrame(onVideoFrame);
      };
      this.videoFrameHandle = requestVideoFrame(onVideoFrame);
      return;
    }

    const onAnimationFrame = (): void => {
      if (this.stopped) return;
      if (video.currentTime !== this.lastFrameTime) {
        this.lastFrameTime = video.currentTime;
        this.queueCurrentFrame();
      }
      this.rafHandle = requestAnimationFrame(onAnimationFrame);
    };
    onAnimationFrame();
  }

  private queueCurrentFrame(): void {
    if (this.stopped || this.detectionTimerHandle !== 0) return;
    const now = performance.now();
    const intervalMs = Math.min(
      SLOWEST_DETECTION_INTERVAL_MS,
      Math.max(FASTEST_DETECTION_INTERVAL_MS, this.averageDetectionMs * INFERENCE_BUDGET_MULTIPLIER),
    );
    if (now - this.lastDetectionStartedAt < intervalMs) return;

    // A zero-delay task runs after the current video/rAF rendering update,
    // preventing synchronous inference from delaying the frame being painted.
    this.detectionTimerHandle = window.setTimeout(() => {
      this.detectionTimerHandle = 0;
      if (this.stopped) return;
      this.lastDetectionStartedAt = performance.now();
      this.detectCurrentFrame();
    }, 0);
  }

  private detectCurrentFrame(): void {
    const video = this.video;
    const landmarker = this.landmarker;
    if (!video || !landmarker || video.readyState < 2) return;

    // detectForVideo rejects non-monotonic timestamps, and performance.now()
    // is coarsened enough on some browsers to repeat within a single frame.
    const timestampMs = Math.max(performance.now(), this.lastDetectTimeMs + 0.01);
    this.lastDetectTimeMs = timestampMs;
    const startedAt = performance.now();
    const result = landmarker.detectForVideo(video, timestampMs);
    const durationMs = performance.now() - startedAt;
    this.averageDetectionMs =
      this.averageDetectionMs === 0
        ? durationMs
        : this.averageDetectionMs +
          (durationMs - this.averageDetectionMs) * INFERENCE_DURATION_ALPHA;
    this.emit(result);
  }


  private emit(result: FaceLandmarkerResult): void {
    const landmarks = result.faceLandmarks[0];
    const faceDetected = !!landmarks;
    this.status = faceDetected ? "running" : "no-face";

    const sample: TrackingSample = {
      timestampMs: performance.now(),
      faceDetected,
      headPosition: faceDetected ? extractHeadPosition(result.facialTransformationMatrixes[0]) : null,
      irisOffset: faceDetected ? extractIrisOffset(landmarks) : null,
      mouthOpenness: faceDetected ? extractMouthOpenness(landmarks) : null,
      eyeCenters: faceDetected
        ? {
            left: { x: landmarks[LEFT_IRIS]!.x, y: landmarks[LEFT_IRIS]!.y },
            right: { x: landmarks[RIGHT_IRIS]!.x, y: landmarks[RIGHT_IRIS]!.y },
          }
        : null,
    };

    this.latest = sample;
    for (const listener of this.listeners) listener(sample);
  }
}
