/**
 * Largest rectangle of the given aspect ratio (width/height) that fits
 * inside a host box. Used so a scene rendered at a fixed aspect ratio never
 * gets stretched by the browser scaling a mismatched canvas element.
 */
export function computeContainSize(hostWidth: number, hostHeight: number, aspect: number): { width: number; height: number } {
  let width = hostWidth;
  let height = width / aspect;
  if (height > hostHeight) {
    height = hostHeight;
    width = height * aspect;
  }
  return { width, height };
}

/** Where a source frame lands inside a host box, and how much it was scaled to get there. */
export interface CoverMapping {
  scale: number;
  offsetX: number;
  offsetY: number;
}

/**
 * The placement `object-fit: cover` produces: fill the host box entirely,
 * preserving aspect, letting the overflowing axis hang off both edges.
 *
 * Returned rather than merely applied because anything that has to line up
 * with the displayed frame — a landmark drawn over a camera feed, say —
 * needs the same scale and offset the browser used, and the cropped-away
 * margin makes that more than a simple multiply.
 */
export function computeCoverMapping(
  hostWidth: number,
  hostHeight: number,
  sourceWidth: number,
  sourceHeight: number,
): CoverMapping {
  const scale = Math.max(hostWidth / sourceWidth, hostHeight / sourceHeight);
  return {
    scale,
    offsetX: (hostWidth - sourceWidth * scale) / 2,
    offsetY: (hostHeight - sourceHeight * scale) / 2,
  };
}
