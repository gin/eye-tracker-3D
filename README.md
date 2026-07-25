# Eye Tracker 3D

A mobile PWA demo: webcam-based head/eye tracking drives (1) a gaze-controlled
square-selection demo and (2) a pseudo-3D parallax viewer for a photo and a
video — all running entirely on-device, no server, no video ever leaves the
phone.

**Flow:** enable camera → 9-point gaze calibration → live gaze-tracked square
grid → home → "View 3D image" / "View 3D video".

## How the pseudo-3D effect works

This is a real iPhone screen — there's no lenticular lens or stereo glasses.
The illusion is **head-coupled parallax** (the classic Johnny Lee / Wii
head-tracking trick, and the same idea behind Apple's spatial-photo effect):
as your head moves, the rendered viewpoint shifts to match, so the scene
looks like a window with real depth behind it rather than a flat image.

1. **Tracking** ([`src/tracking/faceTracker.ts`](src/tracking/faceTracker.ts)) — MediaPipe
   Face Landmarker (`@mediapipe/tasks-vision`) runs continuously on the
   webcam feed, giving a live head-position signal (from the facial
   transformation matrix) and an iris-offset signal (computed directly from
   478-point face-mesh landmarks).
2. **Gaze calibration** ([`src/gaze/gazeModel.ts`](src/gaze/gazeModel.ts)) — a
   9-point calibration fits a small ridge-regression model mapping
   (iris offset, head position) → screen coordinates. This is what drives
   the gaze-square demo. It's calibration-fitted rather than hand-derived
   specifically so it doesn't depend on knowing MediaPipe's exact axis/sign
   conventions.
3. **Depth** ([`src/depth/depthEstimator.ts`](src/depth/depthEstimator.ts)) — Depth
   Anything V2 (small, quantized) runs **once** per photo/video via
   `@huggingface/transformers`, entirely in-browser (WASM). This is too
   expensive to run per video frame on a phone today, so video depth comes
   from a single representative frame and stays fixed while the video
   texture keeps playing — valid for a mostly-static composition, not for a
   moving camera shot.
4. **Render** ([`src/render/parallaxScene.ts`](src/render/parallaxScene.ts)) — a
   depth-displaced Three.js mesh, rendered with an **off-axis ("fish tank
   VR") camera projection** recomputed every frame from the tracked head
   position — not just a camera that rotates toward you, but one whose
   asymmetric frustum keeps the screen's edges pinned in place as your eye
   moves, the way a real window would.

### Known limitations (by design, not oversights)

- **WASM only, not WebGPU**, for depth inference: WebGPU is on by default in
  iOS 26, but onnxruntime-web's WebGPU/JSEP backend has an open, severe
  resource-leak bug on Safari/WebKit 26 ([microsoft/onnxruntime#26827](https://github.com/microsoft/onnxruntime/issues/26827)).
  Revisit `device: "wasm"` in `depthEstimator.ts` once that's fixed.
- **Parallax direction/strength is tunable, not device-verified.** The sign
  and scale of the head→camera mapping (`HEAD_SENSITIVITY`, `MAX_EYE_OFFSET`
  in `parallaxScene.ts`) were validated for internal consistency (renders
  correctly, responds to input, math is sound) but not on a physical iPhone
  — I have no camera in this environment. If the parallax feels backwards or
  too subtle/aggressive on-device, tune those two constants first.
- **Gaze calibration accuracy**: webcam-based gaze estimation is inherently
  coarse. The live demo maps predicted gaze to a grid cell (not a precise
  cursor) specifically because cell-level accuracy is achievable; pixel-level
  isn't, with any webcam-based approach.

## Setup

```sh
pnpm install
pnpm run gen:assets   # regenerates public/demo/{scene.jpg,scene.mp4} and public/icons/* (already committed; only needed if you change scripts/scene.mjs)
pnpm run dev
```

Vite prints two URLs — `Local: https://localhost:5173/` for testing on the
same machine, `Network: https://<lan-ip>:5173/` for a phone on the same
Wi-Fi.

## Testing on an iPhone

Camera access requires a secure context, so the dev server always serves
HTTPS with a self-signed certificate (`@vitejs/plugin-basic-ssl`).

1. Make sure your iPhone and dev machine are on the **same Wi-Fi network**.
2. Run `pnpm run dev` and note the `Network: https://<lan-ip>:5173/` URL.
3. Open that URL in **Safari** on the iPhone (camera access requires Safari
   or another WebKit-based browser on iOS — all iOS browsers use WebKit).
4. Safari will warn the certificate isn't trusted ("This Connection Is Not
   Private"). Tap **Show Details → visit this website** to proceed. This is
   expected for a self-signed dev cert and only needs to be done once per
   session.
5. Tap **Enable camera** and allow the camera permission prompt.
6. Optional — install as a PWA: **Share → Add to Home Screen**. Subsequent
   launches from the home screen run standalone (no Safari chrome) and work
   offline except for the very first load of each ML model.

If the certificate warning is inconvenient, deploy to any static host with a
real TLS certificate (Vercel, Netlify, GitHub Pages, …) — `pnpm run build`
produces a static `dist/` directory — or tunnel the dev server through
`ngrok`/`cloudflared` for a trusted HTTPS URL without changing any code.

To test the production build (real service-worker caching behavior, not
`devOptions`-simulated):

```sh
pnpm run build
pnpm run preview -- --host
```

## Project layout

```
src/
  app/            App shell: screen router + shared tracker/calibration state
  tracking/       MediaPipe wrapper, tracking types, signal smoothing
  gaze/           Calibration fit + live gaze prediction (pure math, no DOM)
  depth/          transformers.js depth-estimation wrapper
  render/         Three.js parallax scene + canvas-fit/media-loading helpers
  screens/        One module per screen (permission, calibration, gaze-demo,
                  home, image-viewer, video-viewer)
scripts/
  scene.mjs             Procedural SVG scene generator (shared by image + video)
  generate-assets.mjs   Renders public/demo/* and public/icons/* via sharp + ffmpeg
```

The two viewer screens are code-split behind dynamic `import()` — three.js
and transformers.js (~1 MB before gzip) are only fetched when a user
actually taps into a 3D viewer, not on first paint.
