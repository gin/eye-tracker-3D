export interface CalibrationSample {
  screenX: number; // normalized 0..1
  screenY: number; // normalized 0..1
  irisX: number;
  irisY: number;
  headX: number;
  headY: number;
}

export interface GazeModel {
  weightsX: number[];
  weightsY: number[];
}

const RIDGE_LAMBDA = 0.1;
const MIN_CALIBRATION_POINTS = 8;
const MIN_SAMPLES_PER_POINT = 5;
const TRIM_FRACTION = 0.2;
const MAX_MEAN_TRAINING_ERROR = 0.12;
// Matches featureVector order. Floors stop tiny incidental head motion from
// being normalized into a full-strength signal and overfitting nine targets.
const FEATURE_SCALE_FLOORS = [1, 0.03, 0.03, 0.01, 0.01, 0.01, 0.02, 0.02] as const;

/**
 * Expands raw tracking features into a small quadratic basis. Iris offset
 * gets the nonlinear terms (gaze direction within the socket is the primary,
 * genuinely nonlinear signal); head position enters linearly as a corrective
 * term for how much the face itself has shifted.
 *
 * Shared verbatim between {@link GazeCalibrator.fit} and {@link predictGaze}
 * — the fitted weights are only meaningful against this exact expansion, so
 * the two must never drift apart.
 */
function featureVector(irisX: number, irisY: number, headX: number, headY: number): number[] {
  return [1, irisX, irisY, irisX * irisX, irisY * irisY, irisX * irisY, headX, headY];
}

/** Solves the square linear system `a x = b` via Gauss-Jordan elimination with partial pivoting. */
function solveLinearSystem(a: number[][], b: number[]): number[] {
  const n = b.length;
  const m = a.map((row, i) => [...row, b[i]!]);

  for (let col = 0; col < n; col++) {
    let pivotRow = col;
    for (let r = col + 1; r < n; r++) {
      if (Math.abs(m[r]![col]!) > Math.abs(m[pivotRow]![col]!)) pivotRow = r;
    }
    [m[col], m[pivotRow]] = [m[pivotRow]!, m[col]!];

    const pivot = m[col]![col]!;
    if (Math.abs(pivot) < 1e-10) continue; // near-singular column: leave its weight at 0

    for (let r = 0; r < n; r++) {
      if (r === col) continue;
      const factor = m[r]![col]! / pivot;
      for (let c = col; c <= n; c++) {
        m[r]![c]! -= factor * m[col]![c]!;
      }
    }
  }

  return m.map((row, i) => (Math.abs(row[i]!) < 1e-10 ? 0 : row[n]! / row[i]!));
}

/**
 * Ridge regression on standardized columns. Raw iris/head features have very
 * different scales; regularizing them without normalization shrinks the
 * smallest signals hardest and pulls edge predictions toward screen center.
 * The intercept is deliberately not regularized.
 *
 * Returned weights are converted back to the raw feature basis, so prediction
 * remains a small dot product and stores no normalization arrays.
 */
function solveRidge(features: number[][], targets: number[], lambda: number): number[] {
  const dims = features[0]!.length;
  const means: number[] = new Array(dims).fill(0) as number[];
  const scales: number[] = new Array(dims).fill(1) as number[];

  for (let i = 1; i < dims; i++) {
    for (const row of features) means[i]! += row[i]!;
    means[i]! /= features.length;
    let variance = 0;
    for (const row of features) variance += (row[i]! - means[i]!) ** 2;
    const scale = Math.sqrt(variance / features.length);
    // Meaningful head movement can still exceed its floor and enter the fit;
    // sub-floor movement is mostly landmark noise while the user holds still.
    scales[i] = Math.max(scale, FEATURE_SCALE_FLOORS[i]!);
  }

  const standardized = features.map((row) =>
    row.map((value, i) => (i === 0 ? 1 : (value - means[i]!) / scales[i]!)),
  );
  const gram: number[][] = Array.from({ length: dims }, () => new Array(dims).fill(0) as number[]);
  const moment: number[] = new Array(dims).fill(0) as number[];

  for (let s = 0; s < standardized.length; s++) {
    const row = standardized[s]!;
    const target = targets[s]!;
    for (let i = 0; i < dims; i++) {
      moment[i]! += row[i]! * target;
      for (let j = 0; j < dims; j++) gram[i]![j]! += row[i]! * row[j]!;
    }
  }
  for (let i = 1; i < dims; i++) gram[i]![i]! += lambda;

  const normalizedWeights = solveLinearSystem(gram, moment);
  const weights: number[] = new Array(dims).fill(0) as number[];
  weights[0] = normalizedWeights[0]!;
  for (let i = 1; i < dims; i++) {
    weights[i] = normalizedWeights[i]! / scales[i]!;
    weights[0]! -= (normalizedWeights[i]! * means[i]!) / scales[i]!;
  }
  return weights;
}

type TrackingField = "irisX" | "irisY" | "headX" | "headY";

/** Central 60% mean: robust against blinks, saccades, and single bad landmark frames. */
function trimmedMean(samples: readonly CalibrationSample[], field: TrackingField): number {
  const values = samples.map((sample) => sample[field]).sort((a, b) => a - b);
  const trim = Math.min(Math.floor(values.length * TRIM_FRACTION), Math.floor((values.length - 1) / 2));
  let sum = 0;
  for (let i = trim; i < values.length - trim; i++) sum += values[i]!;
  return sum / (values.length - trim * 2);
}

/**
 * Gives every target one robust representative instead of weighting frames.
 * Camera-rate variation can otherwise make one dot count twice as much as
 * another, while transient frames at a new target distort the edge range.
 */
function representativeSamples(samples: readonly CalibrationSample[]): CalibrationSample[] {
  const groups = new Map<string, CalibrationSample[]>();
  for (const sample of samples) {
    const key = `${sample.screenX}:${sample.screenY}`;
    const group = groups.get(key);
    if (group) group.push(sample);
    else groups.set(key, [sample]);
  }

  const representatives: CalibrationSample[] = [];
  for (const group of groups.values()) {
    if (group.length < MIN_SAMPLES_PER_POINT) continue;
    representatives.push({
      screenX: group[0]!.screenX,
      screenY: group[0]!.screenY,
      irisX: trimmedMean(group, "irisX"),
      irisY: trimmedMean(group, "irisY"),
      headX: trimmedMean(group, "headX"),
      headY: trimmedMean(group, "headY"),
    });
  }
  return representatives;
}

/** Accumulates (screen point, tracking feature) pairs during calibration and fits a {@link GazeModel}. */
export class GazeCalibrator {
  private readonly samples: CalibrationSample[] = [];

  addSample(sample: CalibrationSample): void {
    this.samples.push(sample);
  }

  get sampleCount(): number {
    return this.samples.length;
  }

  /** Returns null if the capture is incomplete or cannot explain its own targets. */
  fit(): GazeModel | null {
    const samples = representativeSamples(this.samples);
    if (samples.length < MIN_CALIBRATION_POINTS) return null;
    const features = samples.map((s) => featureVector(s.irisX, s.irisY, s.headX, s.headY));
    const weightsX = solveRidge(
      features,
      samples.map((s) => s.screenX),
      RIDGE_LAMBDA,
    );
    const weightsY = solveRidge(
      features,
      samples.map((s) => s.screenY),
      RIDGE_LAMBDA,
    );
    if (![...weightsX, ...weightsY].every(Number.isFinite)) return null;

    const model = { weightsX, weightsY };
    let totalError = 0;
    for (const sample of samples) {
      const predicted = predictGaze(model, sample.irisX, sample.irisY, sample.headX, sample.headY);
      totalError += Math.hypot(predicted.x - sample.screenX, predicted.y - sample.screenY);
    }
    return totalError / samples.length <= MAX_MEAN_TRAINING_ERROR ? model : null;
  }
}

/** Applies a fitted {@link GazeModel} to a live tracking sample, clamped to the visible screen. */
export function predictGaze(
  model: GazeModel,
  irisX: number,
  irisY: number,
  headX: number,
  headY: number,
): { x: number; y: number } {
  const f = featureVector(irisX, irisY, headX, headY);
  let x = 0;
  let y = 0;
  for (let i = 0; i < f.length; i++) {
    x += f[i]! * model.weightsX[i]!;
    y += f[i]! * model.weightsY[i]!;
  }
  return { x: Math.min(1, Math.max(0, x)), y: Math.min(1, Math.max(0, y)) };
}
