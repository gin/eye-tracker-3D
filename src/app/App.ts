import { FaceTracker } from "../tracking/faceTracker";
import type { GazeModel } from "../gaze/gazeModel";

export type ScreenId =
  | "permission"
  | "calibration"
  | "gaze-demo"
  | "home"
  | "image-viewer"
  | "video-viewer"
  | "duck-hunt";
export type UnmountFn = () => void;
export type ScreenFactory = (root: HTMLElement, app: App) => UnmountFn | void;
/** Resolves a screen on demand — lets heavy screens (three.js, transformers.js) load via dynamic import. */
export type ScreenLoader = () => Promise<ScreenFactory>;

const GAZE_MODEL_STORAGE_KEY = "eye3d.gazeModel.v1";

function loadStoredGazeModel(): GazeModel | null {
  try {
    const raw = localStorage.getItem(GAZE_MODEL_STORAGE_KEY);
    return raw ? (JSON.parse(raw) as GazeModel) : null;
  } catch {
    // Private-browsing storage lockouts and corrupted JSON both just mean
    // "no saved calibration" — falling through to recalibration is fine.
    return null;
  }
}

function buildLoadingPlaceholder(): HTMLDivElement {
  const el = document.createElement("div");
  el.className = "screen";
  el.innerHTML = '<div class="spinner"></div>';
  return el;
}

/** Owns the shared tracker/calibration state and swaps the single mounted screen. */
export class App {
  readonly tracker = new FaceTracker();
  gazeModel: GazeModel | null = loadStoredGazeModel();

  private readonly root: HTMLElement;
  private readonly screens: Record<ScreenId, ScreenLoader>;
  private unmountCurrent: UnmountFn | null = null;
  private navToken = 0;

  constructor(root: HTMLElement, screens: Record<ScreenId, ScreenLoader>) {
    this.root = root;
    this.screens = screens;
  }

  setGazeModel(model: GazeModel | null): void {
    this.gazeModel = model;
    if (model) localStorage.setItem(GAZE_MODEL_STORAGE_KEY, JSON.stringify(model));
    else localStorage.removeItem(GAZE_MODEL_STORAGE_KEY);
  }

  async go(screenId: ScreenId): Promise<void> {
    const token = ++this.navToken;
    this.unmountCurrent?.();
    this.unmountCurrent = null;
    this.root.replaceChildren(buildLoadingPlaceholder());

    const factory = await this.screens[screenId]();
    if (token !== this.navToken) return; // superseded by a newer go() while this one loaded

    this.root.replaceChildren();
    const result = factory(this.root, this);
    if (typeof result === "function") this.unmountCurrent = result;
  }
}
