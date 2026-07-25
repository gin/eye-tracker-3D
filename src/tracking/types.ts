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

/**
 * A point in MediaPipe's normalized camera-frame space: (0,0) is the frame's
 * top-left and (1,1) its bottom-right, independent of how that frame is
 * later scaled, cropped or mirrored for display.
 */
export interface FramePoint {
  x: number;
  y: number;
}

export interface TrackingSample {
  timestampMs: number;
  faceDetected: boolean;
  headPosition: HeadPosition | null;
  irisOffset: IrisOffset | null;
  /**
   * Inner-lip gap divided by face width, so it means the same thing at any
   * distance from the camera. Roughly 0.01 with the mouth shut, rising past
   * 0.1 when it is clearly open.
   */
  mouthOpenness: number | null;
  /** Iris centers in camera-frame space, for anchoring effects to the on-screen face. */
  eyeCenters: { left: FramePoint; right: FramePoint } | null;
}

export type TrackerListener = (sample: TrackingSample) => void;
