import * as THREE from "three";
import type { DepthMap } from "../depth/depthEstimator";
import { OneEuroFilter } from "../tracking/smoothing";
import type { HeadPosition } from "../tracking/types";

const MESH_SEGMENTS = 96;
const DEPTH_STRENGTH = 0.16; // world units of max vertex displacement toward the camera
const EYE_Z = 0.85; // fixed distance from the virtual screen plane to the neutral eye position
const HEAD_SENSITIVITY = 2.2; // scales a raw MediaPipe head-translation delta into scene units
const MAX_EYE_OFFSET = 0.4; // clamps an untuned sensitivity to a sane visual range
const NEAR = 0.05;
const FAR = 10;

// One Euro filter tuning, in the scene units HEAD_SENSITIVITY produces.
// MIN_CUTOFF_HZ sets how steady the image holds while the head is still;
// SPEED_BETA is the knob to raise first if motion still trails the head.
const MIN_CUTOFF_HZ = 1.2;
const SPEED_BETA = 0.8;

// Capture exposure, inference and compositing each add delay that no filter
// can remove, so aim slightly ahead of the last known position. Too large
// reads as overshoot when the head reverses direction.
const PREDICTION_SECONDS = 0.025;

// Clamp so a backgrounded tab resuming after several seconds integrates one
// sane step instead of one enormous one.
const MAX_FRAME_DT = 1 / 15;

// Below this, reprojection is invisible. Skipping it keeps a still viewer
// from spending the battery and thermal headroom that sustained frame rate
// depends on.
const MIN_EYE_DELTA = 0.00015;

function clampEyeOffset(value: number): number {
  return Math.min(MAX_EYE_OFFSET, Math.max(-MAX_EYE_OFFSET, value));
}

/**
 * Renders a depth-displaced plane with a head-tracked, off-axis ("fish tank
 * VR" / generalized perspective projection) camera: the screen plane stays
 * axis-aligned at z=0 and the projection frustum is skewed per-frame from
 * the tracked eye position, so the rendered scene behaves like a window
 * the viewer looks through rather than an object that just spins in place.
 */
export class ParallaxScene {
  readonly renderer: THREE.WebGLRenderer;
  private readonly scene = new THREE.Scene();
  private readonly camera = new THREE.PerspectiveCamera();
  private readonly geometry: THREE.PlaneGeometry;
  private readonly material: THREE.MeshBasicMaterial;
  private readonly halfWidth: number;
  private readonly halfHeight: number;
  /** Video content changes without any head motion, so it has to redraw unconditionally. */
  private readonly alwaysRedraw: boolean;

  private baseline: HeadPosition | null = null;
  private readonly filterX = new OneEuroFilter(MIN_CUTOFF_HZ, SPEED_BETA);
  private readonly filterY = new OneEuroFilter(MIN_CUTOFF_HZ, SPEED_BETA);
  private targetX = 0;
  private targetY = 0;
  private eyeX = 0;
  private eyeY = 0;
  private lastFrameMs = 0;
  private needsRedraw = true;
  private disposed = false;
  private rafHandle = 0;

  constructor(canvas: HTMLCanvasElement, texture: THREE.Texture, depth: DepthMap, aspect: number) {
    this.renderer = new THREE.WebGLRenderer({
      canvas,
      // The scene is a single fully-textured plane whose only silhouette is
      // the viewport border that the off-axis frustum pins in place, so MSAA
      // buys almost nothing here while costing real fill rate on a phone.
      antialias: false,
      powerPreference: "high-performance",
    });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
    this.alwaysRedraw = texture instanceof THREE.VideoTexture;

    this.halfWidth = aspect / 2;
    this.halfHeight = 0.5;

    this.geometry = new THREE.PlaneGeometry(aspect, 1, MESH_SEGMENTS, MESH_SEGMENTS);
    displaceGeometryFromDepth(this.geometry, depth);

    this.material = new THREE.MeshBasicMaterial({ map: texture });
    this.scene.add(new THREE.Mesh(this.geometry, this.material));

    this.camera.quaternion.identity();
    this.updateProjection();
  }

  start(): void {
    this.lastFrameMs = performance.now();
    const tick = (): void => {
      if (this.disposed) return;
      this.rafHandle = requestAnimationFrame(tick);

      const now = performance.now();
      const dt = Math.min(MAX_FRAME_DT, (now - this.lastFrameMs) / 1000);
      this.lastFrameMs = now;
      this.stepEye(dt);

      if (!this.needsRedraw && !this.alwaysRedraw) return;
      this.needsRedraw = false;
      this.renderer.render(this.scene, this.camera);
    };
    tick();
  }

  /**
   * Records where the head is; the render loop decides what to do with it.
   * Detection arrives at camera rate (~30 Hz) while the display runs at
   * 60-120 Hz, so filtering here would quantize the camera to a ~30 Hz
   * staircase and leave the projection stale between samples.
   */
  updateHeadPosition(head: HeadPosition | null): void {
    if (head && !this.baseline) this.baseline = head;
    if (!head || !this.baseline) {
      this.targetX = 0;
      this.targetY = 0;
      return;
    }

    this.targetX = clampEyeOffset((head.x - this.baseline.x) * HEAD_SENSITIVITY);
    // MediaPipe image-space +y is down; scene +y is up.
    this.targetY = clampEyeOffset(-(head.y - this.baseline.y) * HEAD_SENSITIVITY);
  }

  resize(width: number, height: number): void {
    this.renderer.setSize(width, height, true);
    this.needsRedraw = true;
  }

  dispose(): void {
    this.disposed = true;
    cancelAnimationFrame(this.rafHandle);
    this.renderer.dispose();
    this.geometry.dispose();
    this.material.dispose();
  }

  /** Advances the filtered eye position by `dt` seconds, reprojecting if it moved. */
  private stepEye(dt: number): void {
    const smoothedX = this.filterX.next(this.targetX, dt);
    const smoothedY = this.filterY.next(this.targetY, dt);
    const eyeX = clampEyeOffset(smoothedX + this.filterX.velocity * PREDICTION_SECONDS);
    const eyeY = clampEyeOffset(smoothedY + this.filterY.velocity * PREDICTION_SECONDS);

    if (Math.abs(eyeX - this.eyeX) < MIN_EYE_DELTA && Math.abs(eyeY - this.eyeY) < MIN_EYE_DELTA) return;

    this.eyeX = eyeX;
    this.eyeY = eyeY;
    this.updateProjection();
    this.needsRedraw = true;
  }

  private updateProjection(): void {
    this.camera.position.set(this.eyeX, this.eyeY, EYE_Z);

    // Asymmetric ("off-axis") frustum: the near-plane rectangle is the
    // screen rectangle re-projected through the eye, not a symmetric FOV
    // cone. This is what pins the plane's edges to the viewport as the eye
    // moves, instead of just rotating the plane toward the camera.
    const scale = NEAR / EYE_Z;
    this.camera.projectionMatrix.makePerspective(
      (-this.halfWidth - this.eyeX) * scale,
      (this.halfWidth - this.eyeX) * scale,
      (this.halfHeight - this.eyeY) * scale,
      (-this.halfHeight - this.eyeY) * scale,
      NEAR,
      FAR,
    );
    this.camera.projectionMatrixInverse.copy(this.camera.projectionMatrix).invert();
  }
}

function displaceGeometryFromDepth(geometry: THREE.PlaneGeometry, depth: DepthMap): void {
  const position = geometry.attributes["position"]!;
  const uv = geometry.attributes["uv"]!;

  for (let i = 0; i < position.count; i++) {
    const u = uv.getX(i);
    const v = uv.getY(i);
    const px = Math.min(depth.width - 1, Math.max(0, Math.round(u * (depth.width - 1))));
    const py = Math.min(depth.height - 1, Math.max(0, Math.round((1 - v) * (depth.height - 1))));
    // Depth-Anything's convention: brighter (higher byte value) = nearer.
    const nearness = depth.data[(py * depth.width + px) * depth.channels]! / 255;
    position.setZ(i, nearness * DEPTH_STRENGTH);
  }
  position.needsUpdate = true;

  // MeshBasicMaterial is unlit, so the normals PlaneGeometry ships with are
  // dead weight in the vertex buffer — and recomputing them to match the
  // displaced surface would be pure waste on top of that.
  geometry.deleteAttribute("normal");
}
