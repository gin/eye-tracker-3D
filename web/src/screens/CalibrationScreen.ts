import type { ScreenFactory } from "../app/App";
import { GazeCalibrator } from "../gaze/gazeModel";

interface CalibrationPoint {
  displayX: number;
  displayY: number;
  screenX: number;
  screenY: number;
}

/**
 * Edge targets stay inset far enough to see and fixate, but are deliberately
 * labeled as 0/1. This maps the user's comfortable eye-motion range onto the
 * whole display instead of leaving every prediction compressed toward 0.5.
 * Center is repeated last so slow posture drift cannot silently skew edges.
 */
const POINTS: readonly CalibrationPoint[] = [
  { displayX: 0.5, displayY: 0.5, screenX: 0.5, screenY: 0.5 },
  { displayX: 0.08, displayY: 0.1, screenX: 0, screenY: 0 },
  { displayX: 0.5, displayY: 0.1, screenX: 0.5, screenY: 0 },
  { displayX: 0.92, displayY: 0.1, screenX: 1, screenY: 0 },
  { displayX: 0.92, displayY: 0.5, screenX: 1, screenY: 0.5 },
  { displayX: 0.92, displayY: 0.9, screenX: 1, screenY: 1 },
  { displayX: 0.5, displayY: 0.9, screenX: 0.5, screenY: 1 },
  { displayX: 0.08, displayY: 0.9, screenX: 0, screenY: 1 },
  { displayX: 0.08, displayY: 0.5, screenX: 0, screenY: 0.5 },
  { displayX: 0.5, displayY: 0.5, screenX: 0.5, screenY: 0.5 },
];

// The dot itself moves for 350 ms in CSS. This leaves another 400 ms for the
// eye's saccade to settle before any sample can enter the fit.
const SETTLE_MS = 750;
const CAPTURE_MS = 700;

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
    targetEl.style.left = `${point.displayX * 100}%`;
    targetEl.style.top = `${point.displayY * 100}%`;
    timeoutHandle = window.setTimeout(() => beginCapture(point), SETTLE_MS);
  };

  const beginCapture = (point: CalibrationPoint): void => {
    if (cancelled) return;
    targetEl.classList.add("calibration-target--capturing");
    const captureUntil = performance.now() + CAPTURE_MS;

    unsubscribeTracker = app.tracker.subscribe((sample) => {
      if (performance.now() > captureUntil) return;
      if (!sample.faceDetected || !sample.irisOffset || !sample.headPosition) return;
      calibrator.addSample({
        screenX: point.screenX,
        screenY: point.screenY,
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
