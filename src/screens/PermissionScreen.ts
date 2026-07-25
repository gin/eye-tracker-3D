import type { ScreenFactory } from "../app/App";
import type { TrackerStatus } from "../tracking/types";

const STATUS_LABEL: Record<TrackerStatus, string> = {
  idle: "",
  "requesting-camera": "Requesting camera permission…",
  "loading-model": "Loading tracking model (first run only, ~5 MB)…",
  running: "Camera ready.",
  "no-face": "Camera ready — center your face in frame.",
  error: "Something went wrong.",
};

export const PermissionScreen: ScreenFactory = (root, app) => {
  root.innerHTML = `
    <div class="screen">
      <h1>Eye Tracker 3D</h1>
      <p>
        This demo tracks your head position and eye direction through the front camera, entirely
        on-device — no video ever leaves your phone. It first calibrates to your gaze, then uses
        the same tracking to drive a pseudo-3D parallax effect on a photo and a video.
      </p>
      <div class="btn-row">
        <button class="btn btn-primary" id="enable-camera" type="button">Enable camera</button>
      </div>
      <p class="hint" id="status"></p>
    </div>
  `;

  const statusEl = root.querySelector<HTMLParagraphElement>("#status")!;
  const button = root.querySelector<HTMLButtonElement>("#enable-camera")!;

  button.addEventListener("click", async () => {
    button.disabled = true;
    const pollHandle = window.setInterval(() => {
      statusEl.textContent = STATUS_LABEL[app.tracker.status];
    }, 120);

    try {
      await app.tracker.start();
      clearInterval(pollHandle);
      app.go(app.gazeModel ? "home" : "calibration");
    } catch (err) {
      clearInterval(pollHandle);
      const message = err instanceof Error ? err.message : String(err);
      statusEl.textContent = `Couldn't start camera: ${message}`;
      button.disabled = false;
    }
  });
};
