import "./style.css";
import { App, type ScreenLoader, type ScreenId } from "./app/App";
import { CalibrationScreen } from "./screens/CalibrationScreen";
import { GazeSquaresScreen } from "./screens/GazeSquaresScreen";
import { HomeScreen } from "./screens/HomeScreen";
import { PermissionScreen } from "./screens/PermissionScreen";

// The viewer screens pull in three.js + transformers.js (~1 MB of JS before
// gzip) — split behind dynamic import so that weight is only ever fetched if
// the user actually taps into a 3D viewer, not on first paint.
const screens: Record<ScreenId, ScreenLoader> = {
  permission: async () => PermissionScreen,
  calibration: async () => CalibrationScreen,
  "gaze-demo": async () => GazeSquaresScreen,
  home: async () => HomeScreen,
  "image-viewer": () => import("./screens/ImageViewerScreen").then((m) => m.ImageViewerScreen),
  "video-viewer": () => import("./screens/VideoViewerScreen").then((m) => m.VideoViewerScreen),
};

const root = document.getElementById("app");
if (!root) throw new Error("#app root element missing");

const app = new App(root, screens);
void app.go("permission");
