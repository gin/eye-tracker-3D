import type { ScreenFactory } from "../app/App";
import { GazeCalibrator } from "../gaze/gazeModel";

/** Normalized (0..1) screen positions, corners-then-edges-then-center order. */
const POINTS: ReadonlyArray<{ x: number; y: number }> = [
  { x: 0.08, y: 0.1 },
  { x: 0.92, y: 0.1 },
  { x: 0.08, y: 0.9 },
  { x: 0.92, y: 0.9 },
  { x: 0.5, y: 0.1 },
  { x: 0.08, y: 0.5 },
  { x: 0.92, y: 0.5 },
  { x: 0.5, y: 0.9 },
  { x: 0.5, y: 0.5 },
];

const SETTLE_MS = 500; // let the user find the new target before sampling
const CAPTURE_MS = 700; // sampling window per point

export const CalibrationScreen: ScreenFactory = (root, app) => {
  root.innerHTML = `
    <div class="screen calibration-screen">
      <h2 id="progress"></h2>
      <p class="hint">Hold your gaze on each dot as it appears. Keep your head roughly still.</p>
    </div>
    <div id="target" class="calibration-target"></div>
  `;

  const progressEl = root.querySelector<HTMLHeadingElement>("#progress")!;
  const targetEl = root.querySelector<HTMLDivElement>("#target")!;
  const calibrator = new GazeCalibrator();

  let index = 0;
  let cancelled = false;
  let timeoutHandle = 0;
  let unsubscribeTracker: (() => void) | null = null;

  const showPoint = (): void => {
    const point = POINTS[index]!;
    progressEl.textContent = `Look at the dot — ${index + 1} / ${POINTS.length}`;
    targetEl.classList.remove("calibration-target--capturing");
    targetEl.style.left = `${point.x * 100}%`;
    targetEl.style.top = `${point.y * 100}%`;
    timeoutHandle = window.setTimeout(() => beginCapture(point), SETTLE_MS);
  };

  const beginCapture = (point: { x: number; y: number }): void => {
    if (cancelled) return;
    targetEl.classList.add("calibration-target--capturing");
    const captureUntil = performance.now() + CAPTURE_MS;

    unsubscribeTracker = app.tracker.subscribe((sample) => {
      if (performance.now() > captureUntil) return;
      if (!sample.faceDetected || !sample.irisOffset || !sample.headPosition) return;
      calibrator.addSample({
        screenX: point.x,
        screenY: point.y,
        irisX: sample.irisOffset.x,
        irisY: sample.irisOffset.y,
        headX: sample.headPosition.x,
        headY: sample.headPosition.y,
      });
    });

    timeoutHandle = window.setTimeout(advance, CAPTURE_MS);
  };

  const advance = (): void => {
    unsubscribeTracker?.();
    unsubscribeTracker = null;
    if (cancelled) return;
    index += 1;
    if (index < POINTS.length) {
      showPoint();
      return;
    }
    const model = calibrator.fit();
    if (!model) {
      showError();
      return;
    }
    app.setGazeModel(model);
    app.go("gaze-demo");
  };

  const showError = (): void => {
    root.innerHTML = `
      <div class="screen">
        <h2>Couldn't get a clear view</h2>
        <p>Make sure you're in a well-lit space, your face is centered in frame, and the camera isn't blocked, then try again.</p>
        <button class="btn btn-primary" id="retry" type="button">Try again</button>
      </div>
    `;
    root.querySelector("#retry")!.addEventListener("click", () => app.go("calibration"));
  };

  showPoint();

  return () => {
    cancelled = true;
    clearTimeout(timeoutHandle);
    unsubscribeTracker?.();
  };
};
