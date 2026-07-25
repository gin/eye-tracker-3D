const MAX_DEPTH_INPUT_DIM = 896; // caps on-device depth-inference cost regardless of source resolution

export function loadImage(url: string): Promise<HTMLImageElement> {
  const { promise, resolve, reject } = Promise.withResolvers<HTMLImageElement>();
  const img = new Image();
  img.crossOrigin = "anonymous";
  img.onload = () => resolve(img);
  img.onerror = () => reject(new Error(`Couldn't load ${url}`));
  img.src = url;
  return promise;
}

export function loadVideo(url: string): Promise<HTMLVideoElement> {
  const { promise, resolve, reject } = Promise.withResolvers<HTMLVideoElement>();
  const video = document.createElement("video");
  video.crossOrigin = "anonymous";
  video.loop = true;
  video.muted = true;
  video.playsInline = true;
  video.preload = "auto";
  video.oncanplaythrough = () => resolve(video);
  video.onerror = () => reject(new Error(`Couldn't load ${url}`));
  video.src = url;
  return promise;
}

/** Draws a source (image or a video frame) into a downscaled offscreen canvas, for depth inference. */
export function drawToCanvas(source: CanvasImageSource, sourceWidth: number, sourceHeight: number): HTMLCanvasElement {
  const scale = Math.min(1, MAX_DEPTH_INPUT_DIM / Math.max(sourceWidth, sourceHeight));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(sourceWidth * scale));
  canvas.height = Math.max(1, Math.round(sourceHeight * scale));
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("2D canvas context unavailable");
  ctx.drawImage(source, 0, 0, canvas.width, canvas.height);
  return canvas;
}
