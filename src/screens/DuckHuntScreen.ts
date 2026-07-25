import type { ScreenFactory } from "../app/App";
import { drawDuck, firstDuckHit, spawnDuck, updateDucks, type Duck, type GameBounds } from "../game/ducks";
import { recordScore, type LeaderboardEntry } from "../game/leaderboard";
import { predictGaze } from "../gaze/gazeModel";
import { computeCoverMapping } from "../render/canvasFit";
import { OneEuroFilter } from "../tracking/smoothing";

const GAME_DURATION_MS = 30_000;
const POINTS_PER_DUCK = 100;

// Mouth aperture (see TrackingSample.mouthOpenness) needs two thresholds
// rather than one: a single edge sitting inside a noisy signal would
// retrigger continuously whenever the mouth hovered near it.
const MOUTH_FIRE_AT = 0.09;
const MOUTH_REARM_AT = 0.055;
const FIRE_COOLDOWN_MS = 220;

const LASER_VISIBLE_MS = 130;
const BURST_MS = 320;

// Deliberately generous next to the ducks themselves: webcam gaze estimation
// is cell-accurate at best (see README), so a pixel-tight hit test would make
// this unplayable rather than difficult.
const AIM_RADIUS_FRACTION = 0.075;

// Reticle smoothing, steadier than the parallax camera's — a crosshair that
// jitters is far more distracting than a background that does.
const AIM_MIN_CUTOFF_HZ = 0.9;
const AIM_SPEED_BETA = 0.5;

const SPAWN_INTERVAL_START_MS = 1100;
const SPAWN_INTERVAL_END_MS = 420;

const MAX_FRAME_DT = 1 / 15;

// A transparent canvas sits over a live video and shares the GPU with
// MediaPipe. Rendering at Retina density quadruples that composite work but
// does not make these large vector shapes meaningfully clearer.
const MAX_CANVAS_DPR = 1;
interface Laser {
  fromX: number;
  fromY: number;
  toX: number;
  toY: number;
  bornAt: number;
}

interface Burst {
  x: number;
  y: number;
  bornAt: number;
}

interface Point {
  x: number;
  y: number;
}

function buildLeaderboardRow(entry: LeaderboardEntry, index: number, newRank: number): HTMLLIElement {
  const row = document.createElement("li");
  row.className = index + 1 === newRank ? "leaderboard-row leaderboard-row--new" : "leaderboard-row";

  const rank = document.createElement("span");
  rank.textContent = `${index + 1}`;
  const score = document.createElement("strong");
  score.textContent = `${entry.score}`;
  const when = document.createElement("span");
  when.className = "leaderboard-when";
  when.textContent = new Date(entry.at).toLocaleDateString(undefined, { month: "short", day: "numeric" });

  row.append(rank, score, when);
  return row;
}

export const DuckHuntScreen: ScreenFactory = (root, app) => {
  if (!app.gazeModel) {
    app.go("calibration");
    return;
  }
  const model = app.gazeModel;

  root.innerHTML = `
    <div class="screen game-screen">
      <div class="game-cam-host" id="cam-host"></div>
      <canvas class="game-stage" id="stage"></canvas>
      <div class="top-bar">
        <span class="game-score" id="score">0</span>
        <span class="game-clock" id="clock">30.0s</span>
      </div>
      <p class="hint game-hint" id="hint">Open your mouth to fire</p>
      <button class="btn btn-ghost back-btn" id="back" type="button">&larr; Back</button>
      <div class="game-over" id="over" hidden>
        <h2>Time!</h2>
        <p class="game-final" id="final"></p>
        <ol class="leaderboard" id="board"></ol>
        <div class="btn-row">
          <button class="btn btn-primary" id="again" type="button">Play again</button>
          <button class="btn btn-ghost" id="home" type="button">Home</button>
        </div>
      </div>
    </div>
  `;

  const camHost = root.querySelector<HTMLDivElement>("#cam-host")!;
  const stage = root.querySelector<HTMLCanvasElement>("#stage")!;
  const scoreEl = root.querySelector<HTMLSpanElement>("#score")!;
  const clockEl = root.querySelector<HTMLSpanElement>("#clock")!;
  const hintEl = root.querySelector<HTMLParagraphElement>("#hint")!;
  const overEl = root.querySelector<HTMLDivElement>("#over")!;
  const finalEl = root.querySelector<HTMLParagraphElement>("#final")!;
  const boardEl = root.querySelector<HTMLOListElement>("#board")!;
  const ctx = stage.getContext("2d", { alpha: true, desynchronized: true })!;

  // Borrowed, not owned: the tracker keeps reading this element either way,
  // so unmount only has to put the DOM back, never stop the camera.
  const video = app.tracker.videoElement;
  if (video) {
    video.classList.add("game-cam");
    camHost.appendChild(video);
  }

  const ducks: Duck[] = [];
  const lasers: Laser[] = [];
  const bursts: Burst[] = [];
  const aimFilterX = new OneEuroFilter(AIM_MIN_CUTOFF_HZ, AIM_SPEED_BETA);
  const aimFilterY = new OneEuroFilter(AIM_MIN_CUTOFF_HZ, AIM_SPEED_BETA);

  let bounds: GameBounds = { width: 1, height: 1 };
  let aimRadius = 24;
  let aim: Point | null = null;
  let running = true;
  let score = 0;
  let mouthArmed = true;
  let lastFireAt = 0;
  let shownTenths = -1;
  let shownTracking: boolean | null = null;
  let startedAt = performance.now();
  let lastFrameMs = startedAt;
  let nextSpawnAt = startedAt;
  let rafHandle = 0;

  const resize = (): void => {
    const dpr = Math.min(window.devicePixelRatio, MAX_CANVAS_DPR);
    bounds = { width: camHost.clientWidth, height: camHost.clientHeight };
    aimRadius = Math.min(bounds.width, bounds.height) * AIM_RADIUS_FRACTION;
    const pixelWidth = Math.round(bounds.width * dpr);
    const pixelHeight = Math.round(bounds.height * dpr);
    stage.style.width = `${bounds.width}px`;
    stage.style.height = `${bounds.height}px`;
    if (stage.width !== pixelWidth || stage.height !== pixelHeight) {
      stage.width = pixelWidth;
      stage.height = pixelHeight;
    }
    // Draw in CSS pixels; the transform absorbs the device ratio.
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  };

  /** Laser origins: the user's own eyes, as currently displayed on screen. */
  const eyeOrigins = (): Point[] => {
    const centers = app.tracker.getLatest()?.eyeCenters;
    if (!centers || !video?.videoWidth) {
      // Face lost mid-shot — fire from the bottom edge so the beam still
      // reads as coming from the player rather than from nowhere.
      return [{ x: bounds.width / 2, y: bounds.height }];
    }

    const map = computeCoverMapping(bounds.width, bounds.height, video.videoWidth, video.videoHeight);
    return [centers.left, centers.right].map((point) => ({
      // The feed is mirrored for a natural selfie view, so the camera
      // frame's x axis runs backwards across the screen.
      x: map.offsetX + (1 - point.x) * video.videoWidth * map.scale,
      y: map.offsetY + point.y * video.videoHeight * map.scale,
    }));
  };

  const fire = (now: number): void => {
    if (!aim) return;
    for (const origin of eyeOrigins()) {
      lasers.push({ fromX: origin.x, fromY: origin.y, toX: aim.x, toY: aim.y, bornAt: now });
    }

    const hit = firstDuckHit(ducks, aim.x, aim.y, aimRadius);
    if (!hit) return;
    hit.alive = false;
    score += POINTS_PER_DUCK;
    scoreEl.textContent = `${score}`;
    bursts.push({ x: hit.x, y: hit.y, bornAt: now });
  };

  const finish = (): void => {
    running = false;
    cancelAnimationFrame(rafHandle);
    rafHandle = 0;
    clockEl.textContent = "0.0s";
    const { entries, rank } = recordScore(score);
    finalEl.textContent = rank > 0 ? `${score} points — #${rank} all time` : `${score} points`;
    boardEl.replaceChildren(...entries.map((entry, index) => buildLeaderboardRow(entry, index, rank)));
    overEl.hidden = false;
  };

  const restart = (): void => {
    ducks.length = 0;
    lasers.length = 0;
    bursts.length = 0;
    aimFilterX.reset();
    aimFilterY.reset();
    score = 0;
    scoreEl.textContent = "0";
    mouthArmed = true;
    lastFireAt = 0;
    shownTenths = -1;
    startedAt = performance.now();
    lastFrameMs = startedAt;
    nextSpawnAt = startedAt;
    overEl.hidden = true;
    running = true;
    if (rafHandle === 0) frame();
  };

  const drawReticle = (now: number): void => {
    if (!aim) return;
    const overDuck = firstDuckHit(ducks, aim.x, aim.y, aimRadius) !== null;
    const pulse = 1 + 0.06 * Math.sin(now / 140);

    ctx.save();
    ctx.strokeStyle = overDuck ? "#ff6fae" : "#5ec8ff";
    ctx.lineWidth = overDuck ? 4 : 2.5;
    ctx.globalAlpha = overDuck ? 1 : 0.8;

    ctx.beginPath();
    ctx.arc(aim.x, aim.y, aimRadius * pulse, 0, Math.PI * 2);
    ctx.stroke();

    const tick = aimRadius * 0.42;
    ctx.beginPath();
    ctx.moveTo(aim.x - tick, aim.y);
    ctx.lineTo(aim.x + tick, aim.y);
    ctx.moveTo(aim.x, aim.y - tick);
    ctx.lineTo(aim.x, aim.y + tick);
    ctx.stroke();
    ctx.restore();
  };

  const drawEffects = (now: number): void => {
    if (lasers.length === 0 && bursts.length === 0) return;
    ctx.save();
    ctx.lineCap = "round";
    for (const laser of lasers) {
      const life = 1 - (now - laser.bornAt) / LASER_VISIBLE_MS;
      ctx.globalAlpha = Math.max(0, life);
      ctx.strokeStyle = "#ff2d6f";
      ctx.lineWidth = 9;
      ctx.beginPath();
      ctx.moveTo(laser.fromX, laser.fromY);
      ctx.lineTo(laser.toX, laser.toY);
      ctx.stroke();
      // A white core over the wide colored beam is what sells it as light
      // rather than as a drawn line.
      ctx.strokeStyle = "#ffffff";
      ctx.lineWidth = 3;
      ctx.stroke();
    }

    for (const burst of bursts) {
      const life = (now - burst.bornAt) / BURST_MS;
      ctx.globalAlpha = Math.max(0, 1 - life);
      ctx.strokeStyle = "#ffd166";
      ctx.lineWidth = 5 * (1 - life);
      ctx.beginPath();
      ctx.arc(burst.x, burst.y, aimRadius * (0.4 + life * 1.6), 0, Math.PI * 2);
      ctx.stroke();
    }
    ctx.restore();
  };

  const frame = (): void => {
    rafHandle = requestAnimationFrame(frame);

    const now = performance.now();
    const dt = Math.min(MAX_FRAME_DT, (now - lastFrameMs) / 1000);
    lastFrameMs = now;

    const sample = app.tracker.getLatest();
    const tracking = sample?.faceDetected === true && sample.irisOffset !== null && sample.headPosition !== null;
    if (tracking && sample?.irisOffset && sample.headPosition) {
      const gaze = predictGaze(model, sample.irisOffset.x, sample.irisOffset.y, sample.headPosition.x, sample.headPosition.y);
      const x = aimFilterX.next(gaze.x * bounds.width, dt);
      const y = aimFilterY.next(gaze.y * bounds.height, dt);
      if (aim) {
        aim.x = x;
        aim.y = y;
      } else {
        aim = { x, y };
      }
    }
    // Replacing an identical text node every frame forces needless style,
    // layout, and paint work over the live video.
    if (tracking !== shownTracking) {
      shownTracking = tracking;
      hintEl.textContent = tracking ? "Open your mouth to fire" : "Looking for your face…";
    }

    if (running) {
      const elapsed = now - startedAt;
      const remaining = Math.max(0, GAME_DURATION_MS - elapsed);
      const tenths = Math.ceil(remaining / 100);
      if (tenths !== shownTenths) {
        shownTenths = tenths;
        clockEl.textContent = `${(tenths / 10).toFixed(1)}s`;
      }

      if (now >= nextSpawnAt) {
        ducks.push(spawnDuck(bounds, elapsed));
        const progress = Math.min(1, elapsed / GAME_DURATION_MS);
        nextSpawnAt = now + SPAWN_INTERVAL_START_MS + (SPAWN_INTERVAL_END_MS - SPAWN_INTERVAL_START_MS) * progress;
      }

      const openness = sample?.mouthOpenness;
      if (openness !== null && openness !== undefined) {
        if (mouthArmed && openness >= MOUTH_FIRE_AT && now - lastFireAt >= FIRE_COOLDOWN_MS) {
          fire(now);
          mouthArmed = false;
          lastFireAt = now;
        } else if (!mouthArmed && openness <= MOUTH_REARM_AT) {
          mouthArmed = true;
        }
      }

      updateDucks(ducks, dt, bounds);
      if (remaining === 0) finish();
    }

    for (let i = ducks.length - 1; i >= 0; i--) if (!ducks[i]!.alive) ducks.splice(i, 1);
    for (let i = lasers.length - 1; i >= 0; i--) if (now - lasers[i]!.bornAt > LASER_VISIBLE_MS) lasers.splice(i, 1);
    for (let i = bursts.length - 1; i >= 0; i--) if (now - bursts[i]!.bornAt > BURST_MS) bursts.splice(i, 1);

    ctx.clearRect(0, 0, bounds.width, bounds.height);
    for (const duck of ducks) drawDuck(ctx, duck, now);
    drawEffects(now);
    if (running) drawReticle(now);
  };

  resize();
  window.addEventListener("resize", resize);
  root.querySelector("#back")!.addEventListener("click", () => app.go("home"));
  root.querySelector("#home")!.addEventListener("click", () => app.go("home"));
  root.querySelector("#again")!.addEventListener("click", restart);
  frame();

  return () => {
    cancelAnimationFrame(rafHandle);
    window.removeEventListener("resize", resize);
    if (video) {
      video.classList.remove("game-cam");
      video.remove();
    }
  };
};
