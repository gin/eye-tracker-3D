import type { ScreenFactory } from "../app/App";

export const HomeScreen: ScreenFactory = (root, app) => {
  root.innerHTML = `
    <div class="screen">
      <div class="top-bar">
        <span>Eye Tracker 3D</span>
        <span><span class="status-dot live"></span> tracking</span>
      </div>
      <h1>Pick a demo</h1>
      <p>
        Each viewer runs a one-time on-device depth estimate, then reprojects it live as you move
        your head — a pseudo-3D parallax effect on an ordinary flat screen.
      </p>
      <div class="btn-row">
        <button class="btn btn-primary" id="view-image" type="button">View 3D image</button>
        <button class="btn btn-primary" id="view-video" type="button">View 3D video</button>
      </div>
      <button class="btn btn-ghost" id="recalibrate" type="button">Recalibrate gaze</button>
    </div>
  `;

  root.querySelector("#view-image")!.addEventListener("click", () => app.go("image-viewer"));
  root.querySelector("#view-video")!.addEventListener("click", () => app.go("video-viewer"));
  root.querySelector("#recalibrate")!.addEventListener("click", () => app.go("calibration"));
};
