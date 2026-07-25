import * as THREE from "three";
import type { DepthMap } from "../depth/depthEstimator";
import { ExponentialSmoother } from "../tracking/smoothing";
import type { HeadPosition } from "../tracking/types";

const MESH_SEGMENTS = 96;
const DEPTH_STRENGTH = 0.16; // world units of max vertex displacement toward the camera
const EYE_Z = 0.85; // fixed distance from the virtual screen plane to the neutral eye position
const HEAD_SENSITIVITY = 2.2; // scales a raw MediaPipe head-translation delta into scene units
const MAX_EYE_OFFSET = 0.4; // clamps an untuned sensitivity to a sane visual range
const SMOOTHING_ALPHA = 0.15;
const NEAR = 0.05;
const FAR = 10;

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

  private baseline: HeadPosition | null = null;
  private readonly smoothX = new ExponentialSmoother(SMOOTHING_ALPHA);
  private readonly smoothY = new ExponentialSmoother(SMOOTHING_ALPHA);
  private disposed = false;
  private rafHandle = 0;

  constructor(canvas: HTMLCanvasElement, texture: THREE.Texture, depth: DepthMap, aspect: number) {
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));

    this.halfWidth = aspect / 2;
    this.halfHeight = 0.5;

    this.geometry = new THREE.PlaneGeometry(aspect, 1, MESH_SEGMENTS, MESH_SEGMENTS);
    displaceGeometryFromDepth(this.geometry, depth);

    this.material = new THREE.MeshBasicMaterial({ map: texture });
    const mesh = new THREE.Mesh(this.geometry, this.material);
    this.scene.add(mesh);

    this.camera.quaternion.identity();
    this.applyHeadPosition(null);
  }

  start(): void {
    const tick = (): void => {
      if (this.disposed) return;
      this.renderer.render(this.scene, this.camera);
      this.rafHandle = requestAnimationFrame(tick);
    };
    tick();
  }

  updateHeadPosition(head: HeadPosition | null): void {
    this.applyHeadPosition(head);
  }

  resize(width: number, height: number): void {
    this.renderer.setSize(width, height, true);
  }

  dispose(): void {
    this.disposed = true;
    cancelAnimationFrame(this.rafHandle);
    this.renderer.dispose();
    this.geometry.dispose();
    this.material.dispose();
  }

  private applyHeadPosition(head: HeadPosition | null): void {
    if (head && !this.baseline) this.baseline = head;

    let rawX = 0;
    let rawY = 0;
    if (head && this.baseline) {
      rawX = (head.x - this.baseline.x) * HEAD_SENSITIVITY;
      // MediaPipe image-space +y is down; scene +y is up.
      rawY = -(head.y - this.baseline.y) * HEAD_SENSITIVITY;
    }

    const eyeX = this.smoothX.next(Math.min(MAX_EYE_OFFSET, Math.max(-MAX_EYE_OFFSET, rawX)));
    const eyeY = this.smoothY.next(Math.min(MAX_EYE_OFFSET, Math.max(-MAX_EYE_OFFSET, rawY)));

    this.camera.position.set(eyeX, eyeY, EYE_Z);

    // Asymmetric ("off-axis") frustum: the near-plane rectangle is the
    // screen rectangle re-projected through the eye, not a symmetric FOV
    // cone. This is what pins the plane's edges to the viewport as the eye
    // moves, instead of just rotating the plane toward the camera.
    const scale = NEAR / EYE_Z;
    this.camera.projectionMatrix.makePerspective(
      (-this.halfWidth - eyeX) * scale,
      (this.halfWidth - eyeX) * scale,
      (this.halfHeight - eyeY) * scale,
      (-this.halfHeight - eyeY) * scale,
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
  geometry.computeVertexNormals();
}
