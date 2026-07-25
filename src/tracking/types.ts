/** Lifecycle status of the underlying camera + MediaPipe pipeline. */
export type TrackerStatus =
  | "idle"
  | "requesting-camera"
  | "loading-model"
  | "running"
  | "no-face"
  | "error";

/**
 * Head translation in the camera's coordinate frame, taken directly from
 * MediaPipe's facial transformation matrix (columns 12/13/14 of the
 * column-major 4x4 matrix). Roughly metric, roughly centered on zero for a
 * face held at arm's length facing the camera. We deliberately do NOT derive
 * yaw/pitch/roll from the rotation block here — extracting Euler angles
 * requires committing to an axis convention we can't verify without a
 * physical device, and head-coupled parallax only needs *position* anyway
 * (true head-tracked rendering, à la Johnny Lee's Wii demo, reprojects from
 * where the head IS, not which way it's rotated).
 */
export interface HeadPosition {
  x: number;
  y: number;
  z: number;
}

/**
 * Iris center offset within its eye socket, normalized so the eye corners
 * sit at roughly ±1. Computed directly from 2D landmark coordinates (no
 * external convention ambiguity), averaged across both eyes.
 * +x = iris shifted toward the camera-frame's right; +y = shifted down.
 */
export interface IrisOffset {
  x: number;
  y: number;
}

export interface TrackingSample {
  timestampMs: number;
  faceDetected: boolean;
  headPosition: HeadPosition | null;
  irisOffset: IrisOffset | null;
}

export type TrackerListener = (sample: TrackingSample) => void;
