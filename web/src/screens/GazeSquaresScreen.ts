import type { ScreenFactory } from "../app/App";
import { predictGaze } from "../gaze/gazeModel";
import { OneEuroFilter } from "../tracking/smoothing";

const GRID_COLS = 4;
const GRID_ROWS = 6;
const GAZE_MIN_CUTOFF_HZ = 1.2;
const GAZE_SPEED_BETA = 0.8;

export const GazeSquaresScreen: ScreenFactory = (root, app) => {
  if (!app.gazeModel) {
    app.go("calibration");
    return;
  }
  const model = app.gazeModel;

  root.innerHTML = `
    <div class="screen gaze-screen">
      <div class="top-bar">
        <span>Gaze demo — look around the screen</span>
        <span><span class="status-dot live"></span></span>
      </div>
      <div id="grid" class="gaze-grid"></div>
      <button class="btn btn-primary floating-btn" id="continue" type="button">Continue</button>
    </div>
  `;

  const gridEl = root.querySelector<HTMLDivElement>("#grid")!;
  gridEl.style.gridTemplateColumns = `repeat(${GRID_COLS}, 1fr)`;
  gridEl.style.gridTemplateRows = `repeat(${GRID_ROWS}, 1fr)`;

  const cells: HTMLDivElement[] = [];
  for (let i = 0; i < GRID_COLS * GRID_ROWS; i++) {
    const cell = document.createElement("div");
    cell.className = "gaze-cell";
    gridEl.appendChild(cell);
    cells.push(cell);
  }

  const smoothX = new OneEuroFilter(GAZE_MIN_CUTOFF_HZ, GAZE_SPEED_BETA);
  const smoothY = new OneEuroFilter(GAZE_MIN_CUTOFF_HZ, GAZE_SPEED_BETA);
  let lastSampleTimeMs = 0;
  let activeIndex = -1;

  const unsubscribe = app.tracker.subscribe((sample) => {
    if (!sample.faceDetected || !sample.irisOffset || !sample.headPosition) return;
    const gaze = predictGaze(model, sample.irisOffset.x, sample.irisOffset.y, sample.headPosition.x, sample.headPosition.y);
    const dt = lastSampleTimeMs === 0 ? 1 / 30 : Math.min(0.1, Math.max(1 / 120, (sample.timestampMs - lastSampleTimeMs) / 1000));
    lastSampleTimeMs = sample.timestampMs;
    const x = smoothX.next(gaze.x, dt);
    const y = smoothY.next(gaze.y, dt);

    const col = Math.min(GRID_COLS - 1, Math.max(0, Math.floor(x * GRID_COLS)));
    const row = Math.min(GRID_ROWS - 1, Math.max(0, Math.floor(y * GRID_ROWS)));
    const index = row * GRID_COLS + col;
    if (index === activeIndex) return;
    cells[activeIndex]?.classList.remove("gaze-cell--active");
    cells[index]?.classList.add("gaze-cell--active");
    activeIndex = index;
  });

  root.querySelector("#continue")!.addEventListener("click", () => app.go("home"));

  return () => unsubscribe();
};
