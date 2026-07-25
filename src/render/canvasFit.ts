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
