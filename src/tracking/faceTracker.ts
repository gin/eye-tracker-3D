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
 * driven by requestAnimationFrame.
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
        video: { facingMode: "user", width: { ideal: 640 }, height: { ideal: 480 } },
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
      this.landmarker = await FaceLandmarker.createFromOptions(fileset, {
        baseOptions: { modelAssetPath: MODEL_URL, delegate: "CPU" },
        runningMode: "VIDEO",
        numFaces: 1,
        outputFaceBlendshapes: false,
        outputFacialTransformationMatrixes: true,
      });

      this.status = "no-face";
      this.loop();
    } catch (err) {
      this.status = "error";
      this.error = err instanceof Error ? err : new Error(String(err));
      throw this.error;
    }
  }

  stop(): void {
    this.stopped = true;
    cancelAnimationFrame(this.rafHandle);
    this.stream?.getTracks().forEach((t) => t.stop());
    this.landmarker?.close();
    this.landmarker = null;
    this.stream = null;
    this.video = null;
    this.status = "idle";
  }

  private loop = (): void => {
    if (this.stopped || !this.video || !this.landmarker) return;
    if (this.video.readyState >= 2) {
      const result = this.landmarker.detectForVideo(this.video, performance.now());
      this.emit(result);
    }
    this.rafHandle = requestAnimationFrame(this.loop);
  };

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
