import * as THREE from "three";
import type { ScreenFactory } from "../app/App";
import { estimateDepth } from "../depth/depthEstimator";
import { computeContainSize } from "../render/canvasFit";
import { drawToCanvas, loadVideo } from "../render/mediaUtils";
import { ParallaxScene } from "../render/parallaxScene";

const VIDEO_URL = "/demo/scene.mp4";

export const VideoViewerScreen: ScreenFactory = (root, app) => {
  root.innerHTML = `
    <div class="screen">
      <button class="btn btn-ghost back-btn" id="back" type="button">&larr; Back</button>
      <div class="viewer-canvas-host" id="host"><canvas id="canvas"></canvas></div>
      <div class="viewer-overlay" id="overlay">
        <div class="spinner"></div>
        <p class="hint" id="status">Loading video…</p>
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
    const video = await loadVideo(VIDEO_URL);
    if (cancelled) return;

    const aspect = video.videoWidth / video.videoHeight;
    // Depth comes from a single representative frame and stays fixed while
    // the video keeps playing — per-frame depth inference isn't realistic
    // on-device today (see depthEstimator.ts). Works well for a mostly
    // static-composition loop; would look wrong for a moving camera shot.
    const depthSource = drawToCanvas(video, video.videoWidth, video.videoHeight);

    statusEl.textContent = "Preparing depth model…";
    const depth = await estimateDepth(depthSource, (_label, fraction) => {
      if (cancelled || fraction === null) return;
      statusEl.textContent = `Downloading depth model… ${Math.round(fraction * 100)}%`;
      progressFill.style.width = `${Math.round(fraction * 100)}%`;
    });
    if (cancelled) return;

    const texture = new THREE.VideoTexture(video);
    texture.colorSpace = THREE.SRGBColorSpace;
    await video.play();
    if (cancelled) return;

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
