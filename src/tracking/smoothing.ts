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
