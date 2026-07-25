import { defineConfig } from "vite";
import basicSsl from "@vitejs/plugin-basic-ssl";
import { VitePWA } from "vite-plugin-pwa";

// Model/runtime assets are fetched from CDNs at runtime (MediaPipe's WASM+task
// file, the depth ONNX weights) rather than vendored into the repo — they are
// multi-MB binaries that don't belong in source control. Workbox runtime
// caching below makes the app fully offline-capable after the first visit.
//
// onnxruntime-web's own WASM binary, by contrast, gets bundled by Vite as a
// same-origin asset (confirmed via `vite build` output) rather than fetched
// from jsdelivr — it's excluded from the precache manifest by extension
// (see globPatterns below) since it's too large to force onto every first
// install, so it needs its own same-origin runtime-cache rule instead.
const RUNTIME_CACHE_RULES: { pattern: RegExp; cacheName: string }[] = [
  { pattern: /^https:\/\/cdn\.jsdelivr\.net\//, cacheName: "cdn-jsdelivr" },
  { pattern: /^https:\/\/storage\.googleapis\.com\/mediapipe-models\//, cacheName: "mediapipe-models" },
  { pattern: /^https:\/\/huggingface\.co\//, cacheName: "huggingface" },
  { pattern: /^https:\/\/cdn-lfs(-[a-z0-9]+)?\.hf\.co\//, cacheName: "huggingface-lfs" },
  { pattern: /^https:\/\/cdn-lfs(-[a-z0-9]+)?\.huggingface\.co\//, cacheName: "huggingface-lfs-legacy" },
  { pattern: /\/assets\/.*\.(wasm|onnx)$/, cacheName: "same-origin-wasm" },
];

export default defineConfig({
  server: {
    host: true, // listen on LAN so an iPhone on the same network can reach the dev server
  },
  plugins: [
    basicSsl(), // getUserMedia requires a secure context; self-signed cert is enough
    VitePWA({
      registerType: "autoUpdate",
      devOptions: { enabled: true }, // exercise the service worker during `vite dev` too
      includeAssets: ["favicon.svg"],
      manifest: {
        name: "Eye Tracker 3D",
        short_name: "Eye3D",
        description:
          "Webcam eye/head tracking driving on-screen gaze selection and pseudo-3D parallax for images and video.",
        theme_color: "#0b0b14",
        background_color: "#0b0b14",
        display: "standalone",
        orientation: "portrait",
        start_url: "/",
        scope: "/",
        icons: [
          { src: "/icons/icon-192.png", sizes: "192x192", type: "image/png" },
          { src: "/icons/icon-512.png", sizes: "512x512", type: "image/png" },
          { src: "/icons/icon-maskable-512.png", sizes: "512x512", type: "image/png", purpose: "maskable" },
        ],
      },
      workbox: {
        navigateFallback: "/index.html",
        globPatterns: ["**/*.{js,css,html,svg,png,jpg,jpeg,mp4,webm,ico}"],
        maximumFileSizeToCacheInBytes: 8 * 1024 * 1024,
        runtimeCaching: RUNTIME_CACHE_RULES.map(({ pattern, cacheName }) => ({
          urlPattern: pattern,
          handler: "CacheFirst" as const,
          options: {
            cacheName,
            cacheableResponse: { statuses: [0, 200] },
            expiration: { maxEntries: 32, maxAgeSeconds: 60 * 60 * 24 * 30 },
          },
        })),
      },
    }),
  ],
});
