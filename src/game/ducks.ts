export interface Duck {
  x: number;
  y: number;
  vx: number;
  vy: number;
  radius: number;
  facing: 1 | -1;
  bobPhase: number;
  alive: boolean;
}

export interface GameBounds {
  width: number;
  height: number;
}

/** Total run length the difficulty curve is tuned against — see {@link spawnDuck}. */
const GAME_DURATION_MS = 30_000;
const MIN_SPEED_PX_S = 90;
const MAX_SPEED_PX_S = 260;
const SPEED_JITTER_PX_S = 25;
const VERTICAL_DRIFT_PX_S = 22;
/** Ducks spawn no lower than this fraction of the screen so they never fly through the bottom HUD. */
const SPAWN_HEIGHT_FRACTION = 0.7;
const RADIUS_FRACTION_OF_SCREEN = 0.045;
const MIN_RADIUS_PX = 16;
const MAX_RADIUS_PX = 34;
const BOB_AMPLITUDE_PX = 6;
const BOB_ANGULAR_SPEED = 4; // rad/s
const WING_FLAP_ANGULAR_SPEED = 0.012; // rad/ms
const WING_FLAP_RANGE_RAD = 0.9;

const BODY_FILL = "#ffcf40";
const BODY_STROKE = "#3a2607";
const BEAK_FILL = "#ff8c1a";
const WING_FILL = "#e8a91f";
const EYE_FILL = "#1a1208";
const OUTLINE_WIDTH_FRACTION = 0.09;

export function spawnDuck(bounds: GameBounds, elapsedMs: number): Duck {
  const radius = Math.min(MAX_RADIUS_PX, Math.max(MIN_RADIUS_PX, Math.min(bounds.width, bounds.height) * RADIUS_FRACTION_OF_SCREEN));
  // Linear ramp over the run length, plus per-duck jitter so speeds don't feel quantized.
  const progress = Math.min(1, Math.max(0, elapsedMs / GAME_DURATION_MS));
  const speed = MIN_SPEED_PX_S + (MAX_SPEED_PX_S - MIN_SPEED_PX_S) * progress + (Math.random() * 2 - 1) * SPEED_JITTER_PX_S;
  const fromLeft = Math.random() < 0.5;
  const facing: 1 | -1 = fromLeft ? 1 : -1;
  const x = fromLeft ? -radius : bounds.width + radius;
  const y = radius + Math.random() * Math.max(0, bounds.height * SPAWN_HEIGHT_FRACTION - radius * 2);
  return {
    x,
    y,
    vx: facing * speed,
    vy: (Math.random() * 2 - 1) * VERTICAL_DRIFT_PX_S,
    radius,
    facing,
    bobPhase: Math.random() * Math.PI * 2,
    alive: true,
  };
}

export function updateDucks(ducks: Duck[], dtSeconds: number, bounds: GameBounds): void {
  for (const duck of ducks) {
    if (!duck.alive) continue;
    duck.x += duck.vx * dtSeconds;
    duck.y += duck.vy * dtSeconds;
    // Bob is layered on as a delta between successive phase samples rather than
    // a stored base-y, so it composes with drift/gravity without extra state.
    const prevBob = Math.sin(duck.bobPhase);
    duck.bobPhase += dtSeconds * BOB_ANGULAR_SPEED;
    duck.y += (Math.sin(duck.bobPhase) - prevBob) * BOB_AMPLITUDE_PX;
    if (duck.x + duck.radius < 0 || duck.x - duck.radius > bounds.width) duck.alive = false;
  }
}

export function firstDuckHit(ducks: readonly Duck[], x: number, y: number, hitRadius: number): Duck | null {
  for (const duck of ducks) {
    if (!duck.alive) continue;
    const dx = duck.x - x;
    const dy = duck.y - y;
    const maxDist = hitRadius + duck.radius;
    if (dx * dx + dy * dy <= maxDist * maxDist) return duck;
  }
  return null;
}

/** Draws a duck facing {@link Duck.facing}, centered on `(duck.x, duck.y)` and sized off `duck.radius`. */
export function drawDuck(ctx: CanvasRenderingContext2D, duck: Duck, timeMs: number): void {
  const r = duck.radius;
  ctx.save();
  ctx.translate(duck.x, duck.y);
  ctx.scale(duck.facing, 1); // local +x is always "forward"; flip the whole path for left-facing ducks
  ctx.lineWidth = Math.max(1.5, r * OUTLINE_WIDTH_FRACTION);
  ctx.strokeStyle = BODY_STROKE;
  ctx.lineJoin = "round";

  // Wing first so the body's outline draws over its root and hides the seam.
  const flap = Math.sin(timeMs * WING_FLAP_ANGULAR_SPEED) * WING_FLAP_RANGE_RAD;
  ctx.save();
  ctx.translate(-r * 0.1, r * 0.05);
  ctx.rotate(-0.3 + flap);
  ctx.beginPath();
  ctx.ellipse(0, 0, r * 0.55, r * 0.3, 0, 0, Math.PI * 2);
  ctx.fillStyle = WING_FILL;
  ctx.fill();
  ctx.stroke();
  ctx.restore();

  // Body.
  ctx.beginPath();
  ctx.ellipse(0, r * 0.1, r * 1.05, r * 0.75, 0, 0, Math.PI * 2);
  ctx.fillStyle = BODY_FILL;
  ctx.fill();
  ctx.stroke();

  // Head.
  ctx.beginPath();
  ctx.arc(r * 0.65, -r * 0.35, r * 0.55, 0, Math.PI * 2);
  ctx.fillStyle = BODY_FILL;
  ctx.fill();
  ctx.stroke();

  // Beak.
  ctx.beginPath();
  ctx.moveTo(r * 1.1, -r * 0.35);
  ctx.lineTo(r * 1.6, -r * 0.25);
  ctx.lineTo(r * 1.1, -r * 0.12);
  ctx.closePath();
  ctx.fillStyle = BEAK_FILL;
  ctx.fill();
  ctx.stroke();

  // Eye.
  ctx.beginPath();
  ctx.arc(r * 0.8, -r * 0.45, Math.max(1, r * 0.09), 0, Math.PI * 2);
  ctx.fillStyle = EYE_FILL;
  ctx.fill();

  ctx.restore();
}
