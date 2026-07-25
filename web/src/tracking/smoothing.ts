/**
 * Exponential moving average for a scalar signal. Used to damp per-frame
 * jitter from tracking output before it drives UI or camera motion.
 * `alpha` in (0, 1]: higher tracks the raw signal more closely, lower is
 * smoother but laggier.
 */
export class ExponentialSmoother {
  private value: number | null = null;

  constructor(private readonly alpha: number) {}

  next(sample: number): number {
    this.value = this.value === null ? sample : this.value + this.alpha * (sample - this.value);
    return this.value;
  }

  reset(): void {
    this.value = null;
  }
}

/** Smoothing factor of a first-order low-pass with the given cutoff (Hz) over a `dt`-second step. */
function alphaForCutoff(cutoffHz: number, dt: number): number {
  const tau = 1 / (2 * Math.PI * cutoffHz);
  return dt / (dt + tau);
}

/**
 * One Euro filter (Casiez, Roussel & Vogel, CHI 2012) for a scalar signal.
 *
 * A fixed-alpha EMA forces one global jitter-vs-lag tradeoff: enough
 * smoothing to hide tracking noise while the head is still costs a constant
 * delay that is very visible while the head is moving. This filter raises
 * its cutoff with the signal's own speed instead — heavy smoothing when
 * nearly static, almost none mid-motion — so it stays far more responsive
 * than an EMA at equal steadiness.
 *
 * Unlike {@link ExponentialSmoother} it is parameterized in seconds rather
 * than in samples, so its behavior doesn't drift when the frame rate does.
 */
export class OneEuroFilter {
  private xPrev: number | null = null;
  private xHat = 0;
  private dxHat = 0;

  /**
   * @param minCutoff Cutoff (Hz) approached at zero speed. Lower is steadier at rest but laggier.
   * @param beta Speed coefficient. Higher cuts lag during fast motion at the cost of more jitter.
   * @param dCutoff Cutoff (Hz) of the internal speed estimate; 1 Hz suits human-scale motion.
   */
  constructor(
    private readonly minCutoff: number,
    private readonly beta: number,
    private readonly dCutoff = 1,
  ) {}

  /** Filters one sample taken `dt` seconds after the previous one. */
  next(x: number, dt: number): number {
    if (this.xPrev === null || dt <= 0) {
      this.xPrev = x;
      this.xHat = x;
      this.dxHat = 0;
      return x;
    }

    const dx = (x - this.xPrev) / dt;
    this.dxHat += alphaForCutoff(this.dCutoff, dt) * (dx - this.dxHat);

    const cutoff = this.minCutoff + this.beta * Math.abs(this.dxHat);
    this.xHat += alphaForCutoff(cutoff, dt) * (x - this.xHat);

    this.xPrev = x;
    return this.xHat;
  }

  /** Filtered rate of change, in units/second — drives latency-compensating extrapolation. */
  get velocity(): number {
    return this.dxHat;
  }

  reset(): void {
    this.xPrev = null;
    this.xHat = 0;
    this.dxHat = 0;
  }
}
