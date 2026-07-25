// Dev-time tool (not shipped in the app bundle): generates the demo image,
// demo video loop, and PWA icons into public/. Run via `npm run gen:assets`.
import { execFileSync } from "node:child_process";
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import sharp from "sharp";
import { sceneSVG } from "./scene.mjs";

const ROOT = path.resolve(import.meta.dirname, "..");
const PUBLIC_DIR = path.join(ROOT, "public");
const IMAGE_WIDTH = 960;
const IMAGE_HEIGHT = 1280;
const VIDEO_FPS = 24;
const VIDEO_SECONDS = 6;

function eyeIconSVG({ size, scale }) {
  const s = scale;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 512 512">
    <rect width="512" height="512" fill="#0b0b14"/>
    <g transform="translate(256,256) scale(${s}) translate(-256,-256)">
      <path d="M 76 256 Q 256 146 436 256 Q 256 366 76 256 Z" fill="none" stroke="#5ec8ff" stroke-width="22" stroke-linejoin="round"/>
      <circle cx="256" cy="256" r="70" fill="#5ec8ff"/>
      <circle cx="278" cy="234" r="22" fill="#0b0b14" opacity="0.85"/>
    </g>
  </svg>`;
}

async function generateImage() {
  const svg = sceneSVG(IMAGE_WIDTH, IMAGE_HEIGHT, 0);
  const outDir = path.join(PUBLIC_DIR, "demo");
  await mkdir(outDir, { recursive: true });
  await sharp(Buffer.from(svg)).jpeg({ quality: 90 }).toFile(path.join(outDir, "scene.jpg"));
  console.log("wrote public/demo/scene.jpg");
}

async function generateVideo() {
  const frameCount = VIDEO_FPS * VIDEO_SECONDS;
  const tmpDir = await mkdtemp(path.join(os.tmpdir(), "eye3d-frames-"));
  try {
    for (let i = 0; i < frameCount; i++) {
      const t = i / frameCount;
      const svg = sceneSVG(IMAGE_WIDTH, IMAGE_HEIGHT, t);
      const framePath = path.join(tmpDir, `frame_${String(i).padStart(4, "0")}.png`);
      await sharp(Buffer.from(svg)).png().toFile(framePath);
    }

    const outDir = path.join(PUBLIC_DIR, "demo");
    await mkdir(outDir, { recursive: true });
    const outPath = path.join(outDir, "scene.mp4");
    execFileSync(
      "ffmpeg",
      [
        "-y",
        "-framerate",
        String(VIDEO_FPS),
        "-i",
        path.join(tmpDir, "frame_%04d.png"),
        "-c:v",
        "libx264",
        "-crf",
        "20",
        "-pix_fmt",
        "yuv420p",
        "-movflags",
        "+faststart",
        outPath,
      ],
      { stdio: "inherit" },
    );
    console.log("wrote public/demo/scene.mp4");
  } finally {
    await rm(tmpDir, { recursive: true, force: true });
  }
}

async function generateIcons() {
  const outDir = path.join(PUBLIC_DIR, "icons");
  await mkdir(outDir, { recursive: true });

  const anySvg = eyeIconSVG({ size: 512, scale: 1 });
  await sharp(Buffer.from(anySvg)).resize(192, 192).png().toFile(path.join(outDir, "icon-192.png"));
  await sharp(Buffer.from(anySvg)).resize(512, 512).png().toFile(path.join(outDir, "icon-512.png"));

  // Maskable icons get cropped to a circle/rounded-square by the OS; keep
  // content within the ~80% safe-zone by shrinking before centering.
  const maskableSvg = eyeIconSVG({ size: 512, scale: 0.62 });
  await sharp(Buffer.from(maskableSvg)).resize(512, 512).png().toFile(path.join(outDir, "icon-maskable-512.png"));

  await writeFile(path.join(PUBLIC_DIR, "favicon.svg"), eyeIconSVG({ size: 64, scale: 1 }));
  console.log("wrote public/icons/icon-192.png, icon-512.png, icon-maskable-512.png, public/favicon.svg");
}

await generateImage();
await generateVideo();
await generateIcons();
