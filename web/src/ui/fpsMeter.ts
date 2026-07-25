const SHOW_FPS_STORAGE_KEY = "eye3d.showFps.v1";
const UPDATE_INTERVAL_MS = 250;

function loadShowFpsPref(): boolean {
  try {
    return localStorage.getItem(SHOW_FPS_STORAGE_KEY) === "1";
  } catch {
    // Private-browsing storage lockouts just mean "don't remember the toggle".
    return false;
  }
}

function saveShowFpsPref(show: boolean): void {
  try {
    if (show) localStorage.setItem(SHOW_FPS_STORAGE_KEY, "1");
    else localStorage.removeItem(SHOW_FPS_STORAGE_KEY);
  } catch {
    // Nothing to fall back to — the toggle just won't survive a reload.
  }
}

/** Mounts a bottom-left toggle button that drives a top-right FPS readout; returns its teardown. */
export function mountFpsToggle(host: HTMLElement): () => void {
  const toggle = document.createElement("button");
  toggle.type = "button";
  toggle.className = "fps-toggle";
  toggle.textContent = "FPS";

  const meter = document.createElement("div");
  meter.className = "fps-meter";
  meter.setAttribute("aria-hidden", "true");

  let visible = loadShowFpsPref();
  let rafId: number | null = null;
  let lastFrameTime = 0;
  let frameCount = 0;
  let frameTimeSum = 0;
  let lastUpdateTime = 0;

  const tick = (now: number): void => {
    if (lastFrameTime > 0) {
      frameTimeSum += now - lastFrameTime;
      frameCount++;
    }
    lastFrameTime = now;

    // Updating the DOM every frame would itself cost frames and skew the reading,
    // so only refresh the text a few times a second.
    if (now - lastUpdateTime >= UPDATE_INTERVAL_MS && frameCount > 0) {
      const avgFrameMs = frameTimeSum / frameCount;
      meter.textContent = `${Math.round(1000 / avgFrameMs)} fps  ${avgFrameMs.toFixed(1)} ms`;
      frameCount = 0;
      frameTimeSum = 0;
      lastUpdateTime = now;
    }

    rafId = requestAnimationFrame(tick);
  };

  const startMeasuring = (): void => {
    if (rafId !== null) return;
    lastFrameTime = 0;
    frameCount = 0;
    frameTimeSum = 0;
    lastUpdateTime = 0;
    rafId = requestAnimationFrame(tick);
  };

  const stopMeasuring = (): void => {
    if (rafId === null) return;
    cancelAnimationFrame(rafId);
    rafId = null;
  };

  const applyVisibility = (): void => {
    toggle.classList.toggle("fps-toggle--on", visible);
    toggle.setAttribute("aria-pressed", String(visible));
    meter.style.display = visible ? "block" : "none";
    if (visible) startMeasuring();
    else stopMeasuring();
  };

  const onToggleClick = (): void => {
    visible = !visible;
    saveShowFpsPref(visible);
    applyVisibility();
  };

  toggle.addEventListener("click", onToggleClick);
  applyVisibility();

  host.append(toggle, meter);

  return () => {
    stopMeasuring();
    toggle.removeEventListener("click", onToggleClick);
    toggle.remove();
    meter.remove();
  };
}
