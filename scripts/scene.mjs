// Procedural "mountain lake at sunset" scene, shared by the static image and
// the looping video generators. Deliberately built for strong monocular
// depth cues: a flat, hazy far sky/mountains, and large, sharp, frame-edge
// foreground silhouettes (trees + ground) — the single strongest "near" cue
// these depth models pick up on.

function mulberry32(seed) {
  let a = seed;
  return function rand() {
    a |= 0;
    a = (a + 0x6d2b79f5) | 0;
    let t = Math.imul(a ^ (a >>> 15), 1 | a);
    t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function cloudPuffSVG(x, y, r) {
  const puffs = [
    [0, 0, 1],
    [r * 0.6, r * 0.1, 0.7],
    [-r * 0.6, r * 0.15, 0.65],
    [r * 0.25, -r * 0.35, 0.55],
    [-r * 0.2, -r * 0.3, 0.5],
  ];
  return puffs.map(([dx, dy, s]) => `<ellipse cx="${x + dx}" cy="${y + dy}" rx="${r * s}" ry="${r * s * 0.6}" fill="#ffffff"/>`).join("");
}

function mountainRangeSVG(width, horizon, amplitude, peaks, seed, color, opacity) {
  const rand = mulberry32(seed);
  const step = width / peaks;
  const pts = [[0, horizon - amplitude * 0.3]];
  for (let i = 0; i <= peaks; i++) {
    const h = amplitude * (0.35 + rand() * 0.65);
    pts.push([i * step, horizon - h]);
  }
  pts.push([width, horizon - amplitude * 0.25]);

  let d = `M 0 ${horizon + 2} L ${pts[0][0]} ${pts[0][1]}`;
  for (let i = 1; i < pts.length; i++) {
    const [px, py] = pts[i - 1];
    const [cx, cy] = pts[i];
    d += ` Q ${px + (cx - px) / 2} ${Math.min(py, cy)} ${cx} ${cy}`;
  }
  d += ` L ${width} ${horizon + 2} Z`;
  return `<path d="${d}" fill="${color}" fill-opacity="${opacity}"/>`;
}

function pineSVG(x, baseY, height) {
  const width = height * 0.5;
  const tiers = 4;
  let d = `M ${x} ${baseY - height}`;
  for (let i = 1; i <= tiers; i++) {
    const tierY = baseY - height + (height * i) / tiers;
    const tierW = (width * i) / tiers;
    d += ` L ${x + tierW} ${tierY - height * 0.06} L ${x} ${tierY} L ${x - tierW} ${tierY - height * 0.06} L ${x} ${tierY - height * 0.12}`;
  }
  d += ` L ${x} ${baseY} Z`;
  return `<path d="${d}"/>`;
}

function foregroundSVG(width, height) {
  const pines = [
    pineSVG(width * 0.06, height * 0.98, height * 0.42),
    pineSVG(width * 0.17, height * 1.0, height * 0.34),
    pineSVG(width * 0.92, height * 0.98, height * 0.46),
    pineSVG(width * 0.82, height * 1.0, height * 0.3),
  ].join("");
  const groundD = `M 0 ${height} L 0 ${height * 0.94} Q ${width * 0.3} ${height * 0.9} ${width * 0.5} ${height * 0.95} Q ${width * 0.75} ${height * 1.0} ${width} ${height * 0.93} L ${width} ${height} Z`;
  return `<g fill="#0b0710">${pines}<path d="${groundD}"/></g>`;
}

/** Renders the scene at loop-phase `t` (0..1) to an SVG document string sized exactly `width`x`height`. */
export function sceneSVG(width, height, t) {
  const horizon = height * 0.52;
  const sunX = width * 0.62;
  const sunY = horizon * 0.62;
  const sunR = width * 0.09;

  const clouds = [];
  for (let i = 0; i < 5; i++) {
    const baseX = (i / 5) * (width * 1.4) - width * 0.2;
    const x = (((baseX + t * width * 0.3) % (width * 1.4)) + width * 1.4) % (width * 1.4) - width * 0.2;
    const y = horizon * (0.15 + 0.12 * (i % 3));
    clouds.push(cloudPuffSVG(x, y, 60 + (i % 3) * 20));
  }

  const reflectionLines = [];
  for (let i = 0; i < 14; i++) {
    const y = horizon + 10 + i * ((height - horizon) / 16);
    const wobble = Math.sin(t * Math.PI * 2 + i) * 6;
    const strokeWidth = Math.max(1, 3 - i * 0.15);
    reflectionLines.push(
      `<line x1="${sunX - 90 + wobble}" y1="${y}" x2="${sunX + 90 - wobble}" y2="${y}" stroke="#ffe3ad" stroke-width="${strokeWidth}" stroke-opacity="0.25"/>`,
    );
  }

  return `<svg xmlns="http://www.w3.org/2000/svg" width="${width}" height="${height}" viewBox="0 0 ${width} ${height}">
    <defs>
      <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stop-color="#1b2a52"/>
        <stop offset="35%" stop-color="#5b4a86"/>
        <stop offset="65%" stop-color="#c8608a"/>
        <stop offset="85%" stop-color="#f2a35e"/>
        <stop offset="100%" stop-color="#ffd27a"/>
      </linearGradient>
      <linearGradient id="water" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0%" stop-color="#f2a35e"/>
        <stop offset="15%" stop-color="#8a5a86"/>
        <stop offset="100%" stop-color="#1a1030"/>
      </linearGradient>
      <radialGradient id="glow" cx="50%" cy="50%" r="50%">
        <stop offset="0%" stop-color="#ffe6b4" stop-opacity="0.9"/>
        <stop offset="30%" stop-color="#ffc88c" stop-opacity="0.35"/>
        <stop offset="100%" stop-color="#ffc88c" stop-opacity="0"/>
      </radialGradient>
    </defs>
    <rect x="0" y="0" width="${width}" height="${horizon + 2}" fill="url(#sky)"/>
    <circle cx="${sunX}" cy="${sunY}" r="${sunR * 4}" fill="url(#glow)"/>
    <circle cx="${sunX}" cy="${sunY}" r="${sunR}" fill="#fff3d6"/>
    <g opacity="0.35">${clouds.join("")}</g>
    ${mountainRangeSVG(width, horizon, horizon * 0.55, 7, 11, "#8b7aa8", 0.55)}
    ${mountainRangeSVG(width, horizon, horizon * 0.32, 5, 23, "#5c4f7a", 0.8)}
    <rect x="0" y="${horizon}" width="${width}" height="${height - horizon}" fill="url(#water)"/>
    <g>${reflectionLines.join("")}</g>
    ${foregroundSVG(width, height)}
  </svg>`;
}
