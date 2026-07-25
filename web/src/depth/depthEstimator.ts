import { pipeline, type DepthEstimationPipeline, type ProgressInfo } from "@huggingface/transformers";

export interface DepthMap {
  width: number;
  height: number;
  channels: number;
  /** Row-major samples, `channels` bytes per pixel; read intensity via `data[(y*width+x)*channels]`. */
  data: Uint8ClampedArray;
}

export type DepthProgress = (label: string, fraction: number | null) => void;

const MODEL_ID = "onnx-community/depth-anything-v2-small";

let pipelinePromise: Promise<DepthEstimationPipeline> | null = null;

function toProgressUpdate(info: ProgressInfo): { label: string; fraction: number | null } {
  if ("progress" in info && typeof info.progress === "number") {
    return { label: "file" in info ? info.file : MODEL_ID, fraction: info.progress / 100 };
  }
  return { label: info.status, fraction: null };
}

function getPipeline(onProgress?: DepthProgress): Promise<DepthEstimationPipeline> {
  // Cached across calls: the ~25 MB quantized weights should only ever be
  // fetched (or read back from the Cache Storage API) once per session.
  pipelinePromise ??= pipeline("depth-estimation", MODEL_ID, {
    dtype: "q8",
    // onnxruntime-web's WebGPU/JSEP backend has a severe, currently-open
    // resource leak on Safari/WebKit 26 (unbounded CPU + memory growth after
    // inference — microsoft/onnxruntime#26827). WASM is slower but correct.
    device: "wasm",
    progress_callback: (info) => {
      if (!onProgress) return;
      const { label, fraction } = toProgressUpdate(info);
      onProgress(label, fraction);
    },
  });
  return pipelinePromise;
}

/**
 * Runs monocular depth estimation once on the given source, returning a
 * grayscale depth map (brighter = nearer, per Depth-Anything's convention)
 * sized to match the source. Expensive (on-device transformer inference) —
 * callers should run this once per asset and reuse the result, never per
 * animation frame.
 */
export async function estimateDepth(source: HTMLCanvasElement, onProgress?: DepthProgress): Promise<DepthMap> {
  const estimator = await getPipeline(onProgress);
  const { depth } = await estimator(source);
  return {
    width: depth.width,
    height: depth.height,
    channels: depth.channels,
    data: new Uint8ClampedArray(depth.data),
  };
}
