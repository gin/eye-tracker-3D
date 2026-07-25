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

const RIDGE_LAMBDA = 0.5;

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

/** Ridge regression: minimizes ||Xw - y||^2 + lambda||w||^2, solved via the normal equations. */
function solveRidge(features: number[][], targets: number[], lambda: number): number[] {
  const dims = features[0]!.length;
  const gram: number[][] = Array.from({ length: dims }, () => new Array(dims).fill(0) as number[]);
  const moment: number[] = new Array(dims).fill(0) as number[];

  for (let s = 0; s < features.length; s++) {
    const row = features[s]!;
    const target = targets[s]!;
    for (let i = 0; i < dims; i++) {
      moment[i]! += row[i]! * target;
      for (let j = 0; j < dims; j++) {
        gram[i]![j]! += row[i]! * row[j]!;
      }
    }
  }
  for (let i = 0; i < dims; i++) gram[i]![i]! += lambda;

  return solveLinearSystem(gram, moment);
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

  /** Returns null if there isn't enough data yet to fit a well-posed model. */
  fit(): GazeModel | null {
    if (this.samples.length < 8) return null;
    const features = this.samples.map((s) => featureVector(s.irisX, s.irisY, s.headX, s.headY));
    const weightsX = solveRidge(
      features,
      this.samples.map((s) => s.screenX),
      RIDGE_LAMBDA,
    );
    const weightsY = solveRidge(
      features,
      this.samples.map((s) => s.screenY),
      RIDGE_LAMBDA,
    );
    return { weightsX, weightsY };
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
