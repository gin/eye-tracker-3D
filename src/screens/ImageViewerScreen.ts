import * as THREE from "three";
import type { ScreenFactory } from "../app/App";
import { estimateDepth } from "../depth/depthEstimator";
import { computeContainSize } from "../render/canvasFit";
import { drawToCanvas, loadImage } from "../render/mediaUtils";
import { ParallaxScene } from "../render/parallaxScene";

const IMAGE_URL = "/demo/scene.jpg";

export const ImageViewerScreen: ScreenFactory = (root, app) => {
  root.innerHTML = `
    <div class="screen">
      <button class="btn btn-ghost back-btn" id="back" type="button">&larr; Back</button>
      <div class="viewer-canvas-host" id="host"><canvas id="canvas"></canvas></div>
      <div class="viewer-overlay" id="overlay">
        <div class="spinner"></div>
        <p class="hint" id="status">Loading image…</p>
        <div class="progress-track"><div class="progress-fill" id="progress-fill"></div></div>
      </div>
    </div>
  `;

  root.querySelector("#back")!.addEventListener("click", () => app.go("home"));

  const host = root.querySelector<HTMLDivElement>("#host")!;
  const canvas = root.querySelector<HTMLCanvasElement>("#canvas")!;
  const overlay = root.querySelector<HTMLDivElement>("#overlay")!;
  const statusEl = root.querySelector<HTMLParagraphElement>("#status")!;
  const progressFill = root.querySelector<HTMLDivElement>("#progress-fill")!;

  let cancelled = false;
  let scene: ParallaxScene | null = null;
  let unsubscribeTracker: (() => void) | null = null;
  let handleResize: (() => void) | null = null;

  (async () => {
    const img = await loadImage(IMAGE_URL);
    if (cancelled) return;

    const aspect = img.naturalWidth / img.naturalHeight;
    const depthSource = drawToCanvas(img, img.naturalWidth, img.naturalHeight);

    statusEl.textContent = "Preparing depth model…";
    const depth = await estimateDepth(depthSource, (_label, fraction) => {
      if (cancelled || fraction === null) return;
      statusEl.textContent = `Downloading depth model… ${Math.round(fraction * 100)}%`;
      progressFill.style.width = `${Math.round(fraction * 100)}%`;
    });
    if (cancelled) return;

    const texture = new THREE.Texture(img);
    texture.colorSpace = THREE.SRGBColorSpace;
    texture.needsUpdate = true;

    scene = new ParallaxScene(canvas, texture, depth, aspect);
    const initial = computeContainSize(host.clientWidth, host.clientHeight, aspect);
    scene.resize(initial.width, initial.height);
    scene.start();
    overlay.style.display = "none";

    handleResize = () => {
      const { width, height } = computeContainSize(host.clientWidth, host.clientHeight, aspect);
      scene?.resize(width, height);
    };
    window.addEventListener("resize", handleResize);

    unsubscribeTracker = app.tracker.subscribe((sample) => scene?.updateHeadPosition(sample.headPosition));
  })().catch((err: unknown) => {
    if (cancelled) return;
    statusEl.textContent = err instanceof Error ? err.message : String(err);
  });

  return () => {
    cancelled = true;
    if (handleResize) window.removeEventListener("resize", handleResize);
    unsubscribeTracker?.();
    scene?.dispose();
  };
};
