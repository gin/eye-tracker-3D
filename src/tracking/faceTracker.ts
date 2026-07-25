import { FaceLandmarker, FilesetResolver, type FaceLandmarkerResult, type Matrix } from "@mediapipe/tasks-vision";
import type { HeadPosition, IrisOffset, TrackerListener, TrackerStatus, TrackingSample } from "./types";

// Must match the installed npm package version: the WASM binary and the JS
// bindings that talk to it are version-locked.
const MEDIAPIPE_VERSION = "0.10.35";
const WASM_BASE_URL = `https://cdn.jsdelivr.net/npm/@mediapipe/tasks-vision@${MEDIAPIPE_VERSION}/wasm`;
const MODEL_URL =
  "https://storage.googleapis.com/mediapipe-models/face_landmarker/face_landmarker/float16/latest/face_landmarker.task";

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
  private stopped = false;

  subscribe(listener: TrackerListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }

  getLatest(): TrackingSample | null {
    return this.latest;
  }

  async start(): Promise<void> {
    if (this.status !== "idle" && this.status !== "error") return;
    this.stopped = false;
    this.error = null;

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
    this.stream?.getTracks().forEach((t) => t.stop());
    this.landmarker?.close();
    this.landmarker = null;
    this.stream = null;
    this.video = null;
    this.lastFrameTime = -1;
    this.status = "idle";
  }

  /**
   * Runs one detection per *camera* frame rather than per animation frame.
   * Inference is the most expensive thing on this thread, and a 30 fps
   * camera behind a 60–120 Hz rAF loop meant most calls re-analyzed a frame
   * that had already been analyzed — full cost, no fresher data.
   * `requestVideoFrameCallback` fires exactly once per presented frame; the
   * rAF fallback de-dupes on the video clock to get the same property.
   */
  private startDetectionLoop(video: HTMLVideoElement): void {
    // Typed as always-present by lib.dom, but only actually shipped in
    // Safari 15.4+ / Firefox 132+, so this needs a real runtime test.
    const requestVideoFrame =
      typeof video.requestVideoFrameCallback === "function" ? video.requestVideoFrameCallback.bind(video) : null;
    if (requestVideoFrame) {
      const onVideoFrame = (): void => {
        if (this.stopped) return;
        this.detectCurrentFrame();
        this.videoFrameHandle = requestVideoFrame(onVideoFrame);
      };
      this.videoFrameHandle = requestVideoFrame(onVideoFrame);
      return;
    }

    const onAnimationFrame = (): void => {
      if (this.stopped) return;
      if (video.currentTime !== this.lastFrameTime) {
        this.lastFrameTime = video.currentTime;
        this.detectCurrentFrame();
      }
      this.rafHandle = requestAnimationFrame(onAnimationFrame);
    };
    onAnimationFrame();
  }

  private detectCurrentFrame(): void {
    const video = this.video;
    const landmarker = this.landmarker;
    if (!video || !landmarker || video.readyState < 2) return;

    // detectForVideo rejects non-monotonic timestamps, and performance.now()
    // is coarsened enough on some browsers to repeat within a single frame.
    const timestampMs = Math.max(performance.now(), this.lastDetectTimeMs + 0.01);
    this.lastDetectTimeMs = timestampMs;
    this.emit(landmarker.detectForVideo(video, timestampMs));
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
    };

    this.latest = sample;
    for (const listener of this.listeners) listener(sample);
  }
}
