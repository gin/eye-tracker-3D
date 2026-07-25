import type { ScreenFactory } from "../app/App";
import { predictGaze } from "../gaze/gazeModel";
import { ExponentialSmoother } from "../tracking/smoothing";

const GRID_COLS = 4;
const GRID_ROWS = 6;
const SMOOTHING_ALPHA = 0.25;

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

  const smoothX = new ExponentialSmoother(SMOOTHING_ALPHA);
  const smoothY = new ExponentialSmoother(SMOOTHING_ALPHA);
  let activeIndex = -1;

  const unsubscribe = app.tracker.subscribe((sample) => {
    if (!sample.faceDetected || !sample.irisOffset || !sample.headPosition) return;
    const gaze = predictGaze(model, sample.irisOffset.x, sample.irisOffset.y, sample.headPosition.x, sample.headPosition.y);
    const x = smoothX.next(gaze.x);
    const y = smoothY.next(gaze.y);
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
