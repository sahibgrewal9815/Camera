// Film recipes + colour science. Every colour step is baked into one 3D LUT per recipe;
// spatial effects (grain, halation, clarity, vignette) run in the WebGL shader.

export const SIMULATIONS = [
  'NATURAL', 'PROVIA', 'VELVIA', 'ASTIA', 'CLASSIC CHROME', 'CLASSIC NEG', 'ETERNA', 'ACROS',
  'PORTRA', 'GOLD', 'EKTAR', 'KODACHROME', 'TRI-X', 'TUNGSTEN 800', 'TEAL & ORANGE', 'INSTANT', 'VINTAGE 70s',
];
export const STRENGTHS = ['Off', 'Weak', 'Strong'];

const base = {
  simulation: 'NATURAL', wb: null, wbRed: 0, wbBlue: 0, grain: 'Off', grainSize: 'Small',
  colorChrome: 'Off', colorChromeBlue: 'Off', dr: 100, highlight: 0, shadow: 0, color: 0,
  sharpness: 0, nr: 0, clarity: 0, halation: 0, vignette: 0,
};
const r = (id, name, subtitle, opts) => ({ ...base, id, name, subtitle, ...opts });

export const PRESETS = [
  r('natural', 'Natural', 'No look', {}),
  // The four recipe cards
  r('portra800', 'Portra 800', 'Film Recipe · Classic Chrome base', { simulation: 'CLASSIC CHROME', wb: 6600, wbRed: -1, wbBlue: -3,
    grain: 'Strong', grainSize: 'Large', colorChrome: 'Strong', dr: 400, highlight: -2, shadow: -0.5, color: 3, sharpness: -2, nr: -4, clarity: -3 }),
  r('leicax', 'Leica X', 'Film Recipe · Street', { simulation: 'CLASSIC CHROME', wbRed: 1, wbBlue: -2, grain: 'Weak', colorChrome: 'Strong',
    colorChromeBlue: 'Strong', dr: 200, highlight: -1, color: 4, nr: -4 }),
  r('alpinegold', 'Alpine Gold', 'Film Recipe · Warm summer', { simulation: 'CLASSIC CHROME', wbRed: 5, wbBlue: -6, colorChrome: 'Strong',
    colorChromeBlue: 'Weak', dr: 400, highlight: -2, shadow: -2, color: 3, sharpness: 1, nr: -2 }),
  r('thetimes', 'The Times', 'Teal sky · warm skin · grain', { simulation: 'TEAL & ORANGE', wbRed: 1, wbBlue: -1, grain: 'Strong', grainSize: 'Large',
    colorChrome: 'Weak', dr: 400, highlight: -1, shadow: 1, color: 1, sharpness: -1, clarity: -1, halation: 0.25, vignette: 0.35 }),
  // Fujifilm-style
  r('classicchrome', 'Classic Chrome', 'Muted documentary colour', { simulation: 'CLASSIC CHROME', colorChrome: 'Weak', dr: 200, shadow: 1 }),
  r('classicneg', 'Classic Neg', 'Superia-like snapshot film', { simulation: 'CLASSIC NEG', grain: 'Weak', colorChrome: 'Strong', dr: 200, highlight: -1, shadow: 1, color: 1 }),
  r('velvia', 'Velvia', 'Punchy landscape slide film', { simulation: 'VELVIA', colorChrome: 'Strong', colorChromeBlue: 'Strong', shadow: 1, color: 2, sharpness: 1 }),
  r('eterna', 'Eterna', 'Soft cinema film', { simulation: 'ETERNA', grain: 'Weak', dr: 400, highlight: -1, shadow: -1, color: -1, sharpness: -1 }),
  r('acros', 'Acros', 'Fine-grain black & white', { simulation: 'ACROS', grain: 'Weak', shadow: 1, sharpness: 1 }),
  // Kodak-style
  r('portra400', 'Portra 400', 'Soft pastel skin tones', { simulation: 'PORTRA', wb: 5800, grain: 'Weak', dr: 400, highlight: -1, shadow: -1, clarity: -1 }),
  r('gold200', 'Gold 200', 'Golden everyday film', { simulation: 'GOLD', grain: 'Weak', grainSize: 'Large', dr: 200, shadow: 1, color: 1, vignette: 0.2 }),
  r('ektar', 'Ektar 100', 'Vivid fine-grain colour', { simulation: 'EKTAR', colorChrome: 'Weak', shadow: 1, color: 1, sharpness: 1 }),
  r('kodachrome', 'Kodachrome', 'Classic 64 slide look', { simulation: 'KODACHROME', grain: 'Weak', colorChrome: 'Strong', colorChromeBlue: 'Weak', shadow: 2, vignette: 0.2 }),
  r('trix', 'Tri-X 400', 'Gritty black & white', { simulation: 'TRI-X', grain: 'Strong', grainSize: 'Large', shadow: 2, sharpness: 1, vignette: 0.25 }),
  // Vintage / cine
  r('cine800t', 'Cine 800T', 'Tungsten night film + halation', { simulation: 'TUNGSTEN 800', grain: 'Strong', dr: 200, highlight: -1, halation: 0.6, vignette: 0.2 }),
  r('instant', 'Instant', 'Faded instant print', { simulation: 'INSTANT', grain: 'Weak', highlight: -2, shadow: -2, color: -1, sharpness: -2, clarity: -2, vignette: 0.45 }),
  r('vintage70s', 'Vintage 70s', 'Warm, faded, nostalgic', { simulation: 'VINTAGE 70s', grain: 'Strong', grainSize: 'Large', highlight: -1, shadow: -1,
    color: -1, sharpness: -1, clarity: -2, halation: 0.3, vignette: 0.4 }),
];

export const isMono = (sim) => sim === 'ACROS' || sim === 'TRI-X';
export const signed = (v) => (v > 0 ? `+${v}` : `${v}`);

// ---------- Base looks ----------
const band = (center, o = {}) => ({ center, width: 45, hueShift: 0, sat: 1, lum: 1, ...o });
const look = (o = {}) => ({ saturation: 1, contrast: 0, fade: 0, warmth: 0, shadowTint: [0, 0, 0], highlightTint: [0, 0, 0], bands: [], mono: null, ...o });

function baseLook(sim) {
  switch (sim) {
    case 'PROVIA': return look({ saturation: 1.08, contrast: 0.15 });
    case 'VELVIA': return look({ saturation: 1.35, contrast: 0.35, bands: [band(0, { sat: 1.15 }), band(120, { sat: 1.2 }), band(220, { sat: 1.1, lum: 0.85 })] });
    case 'ASTIA': return look({ saturation: 1.05, contrast: -0.05, bands: [band(25, { width: 30, sat: 0.95, lum: 1.03 })] });
    case 'CLASSIC CHROME': return look({ saturation: 0.78, contrast: 0.15, fade: 0.02, shadowTint: [-0.01, 0, 0.015], bands: [
      band(0, { sat: 0.85, lum: 0.95 }), band(25, { width: 30, sat: 0.9 }), band(110, { width: 60, hueShift: -15, sat: 0.7 }),
      band(215, { width: 50, hueShift: -10, sat: 0.75, lum: 0.9 })] });
    case 'CLASSIC NEG': return look({ saturation: 0.9, contrast: 0.35, fade: 0.02, shadowTint: [-0.02, 0.01, 0.03], highlightTint: [0.03, 0.015, -0.02],
      bands: [band(0, { hueShift: 5, sat: 1.05 }), band(115, { width: 60, hueShift: 15, sat: 0.8 })] });
    case 'ETERNA': return look({ saturation: 0.7, contrast: -0.25, fade: 0.04, shadowTint: [-0.005, 0.005, 0.01], highlightTint: [0.01, 0.005, -0.005] });
    case 'ACROS': return look({ contrast: 0.3, mono: [0.30, 0.60, 0.10] });
    case 'TRI-X': return look({ contrast: 0.45, fade: 0.03, mono: [0.35, 0.55, 0.10] });
    case 'PORTRA': return look({ saturation: 0.88, contrast: -0.05, fade: 0.02, warmth: 0.03, highlightTint: [0.02, 0.01, -0.01], bands: [
      band(25, { width: 30, hueShift: 3, sat: 0.9, lum: 1.04 }), band(115, { width: 60, hueShift: -10, sat: 0.8 }), band(215, { width: 50, hueShift: -8, sat: 0.85 })] });
    case 'GOLD': return look({ saturation: 1.1, contrast: 0.15, warmth: 0.06, highlightTint: [0.03, 0.02, -0.02], bands: [band(55, { width: 35, sat: 1.15 })] });
    case 'EKTAR': return look({ saturation: 1.3, contrast: 0.25, bands: [band(0, { sat: 1.2 }), band(220, { sat: 1.2, lum: 0.9 })] });
    case 'KODACHROME': return look({ saturation: 1.2, contrast: 0.35, shadowTint: [0, 0, -0.01], highlightTint: [0.015, 0.01, 0], bands: [
      band(0, { hueShift: -5, sat: 1.25 }), band(55, { width: 35, sat: 1.1 }), band(215, { hueShift: 8, sat: 1.1, lum: 0.85 })] });
    case 'TUNGSTEN 800': return look({ saturation: 0.95, contrast: 0.2, warmth: -0.04, shadowTint: [-0.02, 0, 0.035], highlightTint: [0.03, 0, -0.01] });
    case 'TEAL & ORANGE': return look({ contrast: 0.2, shadowTint: [-0.03, 0.01, 0.04], highlightTint: [0.04, 0.015, -0.03], bands: [
      band(28, { width: 35, sat: 1.15 }), band(120, { width: 60, hueShift: 40, sat: 0.7 }), band(215, { width: 60, hueShift: -25, sat: 0.9 })] });
    case 'INSTANT': return look({ saturation: 0.85, contrast: -0.1, fade: 0.08, shadowTint: [0, 0.02, 0.03], highlightTint: [0.03, 0.02, -0.01] });
    case 'VINTAGE 70s': return look({ saturation: 0.8, contrast: 0.05, fade: 0.06, warmth: 0.08, shadowTint: [0.03, 0.01, -0.02],
      highlightTint: [0.04, 0.025, -0.03], bands: [band(115, { width: 60, hueShift: -20, sat: 0.7 })] });
    default: return look();
  }
}

const strengthAmount = (s) => (s === 'Strong' ? 1 : s === 'Weak' ? 0.5 : 0);
const clamp01 = (x) => Math.min(1, Math.max(0, x));
const hueDist = (a, b) => Math.abs((((a - b + 540) % 360) + 360) % 360 - 180);

function rgbToHsv(r, g, b) {
  const max = Math.max(r, g, b), min = Math.min(r, g, b), d = max - min;
  let h = 0;
  if (d > 1e-5) {
    if (max === r) h = 60 * (((g - b) / d) % 6);
    else if (max === g) h = 60 * ((b - r) / d + 2);
    else h = 60 * ((r - g) / d + 4);
  }
  if (h < 0) h += 360;
  return [h, max > 1e-5 ? d / max : 0, max];
}

function hsvToRgb(h, s, v) {
  const c = v * s, x = c * (1 - Math.abs(((h / 60) % 2) - 1)), m = v - c;
  let rgb;
  if (h < 60) rgb = [c, x, 0]; else if (h < 120) rgb = [x, c, 0]; else if (h < 180) rgb = [0, c, x];
  else if (h < 240) rgb = [0, x, c]; else if (h < 300) rgb = [x, 0, c]; else rgb = [c, 0, x];
  return [rgb[0] + m, rgb[1] + m, rgb[2] + m];
}

// Monotone cubic spline through tone-curve points (like Core Image's tone curve).
function makeCurve(points) {
  const n = points.length, xs = points.map((p) => p[0]), ys = points.map((p) => p[1]);
  const d = [], m = new Array(n);
  for (let i = 0; i < n - 1; i++) d.push((ys[i + 1] - ys[i]) / (xs[i + 1] - xs[i]));
  m[0] = d[0]; m[n - 1] = d[n - 2];
  for (let i = 1; i < n - 1; i++) m[i] = d[i - 1] * d[i] <= 0 ? 0 : (d[i - 1] + d[i]) / 2;
  return (x) => {
    if (x <= xs[0]) return ys[0];
    if (x >= xs[n - 1]) return ys[n - 1];
    let i = 0; while (x > xs[i + 1]) i++;
    const h = xs[i + 1] - xs[i], t = (x - xs[i]) / h, t2 = t * t, t3 = t2 * t;
    return (2 * t3 - 3 * t2 + 1) * ys[i] + (t3 - 2 * t2 + t) * h * m[i] + (-2 * t3 + 3 * t2) * ys[i + 1] + (t3 - t2) * h * m[i + 1];
  };
}

/** Full per-pixel colour transform of a recipe (+ live "pro" adjustments). */
export function colorTransform(recipe, adj = {}) {
  const L = baseLook(recipe.simulation);
  const chrome = strengthAmount(recipe.colorChrome), chromeBlue = strengthAmount(recipe.colorChromeBlue);
  // White balance: Kelvin relative to daylight + red/blue shift + manual temperature/tint.
  const k = ((recipe.wb ?? 5500) - 5500) / 2000 + (adj.temperature || 0);
  const tint = adj.tint || 0;
  const wbR = (1 + k * 0.1) * (1 + recipe.wbRed * 0.022), wbG = 1 - tint * 0.06, wbB = (1 - k * 0.1) * (1 + recipe.wbBlue * 0.022);
  const h = recipe.highlight, s = recipe.shadow, dr = recipe.dr >= 400 ? 0.06 : recipe.dr >= 200 ? 0.03 : 0;
  const curve = makeCurve([[0, Math.max(0, -s * 0.015)], [0.25, 0.25 - s * 0.018], [0.5, 0.5], [0.75, 0.75 + h * 0.018 - dr],
    [1, 1 - dr * 0.5 - Math.max(0, -h) * 0.01]]);
  const sat = (isMono(recipe.simulation) ? 1 : 1 + recipe.color * 0.07) * (1 + (adj.saturation || 0));
  const contrastAdj = adj.contrast || 0;

  return (r0, g0, b0) => {
    let r = r0 * wbR, g = g0 * wbG, b = b0 * wbB;
    if (L.mono) {
      const l = r * L.mono[0] + g * L.mono[1] + b * L.mono[2];
      r = g = b = l;
    } else {
      let [hh, ss, vv] = rgbToHsv(clamp01(r), clamp01(g), clamp01(b));
      for (const bd of L.bands) {
        let w = Math.max(0, 1 - hueDist(hh, bd.center) / bd.width);
        w = w * w * (3 - 2 * w) * Math.min(1, ss * 3);
        hh += bd.hueShift * w; ss *= 1 + (bd.sat - 1) * w; vv *= 1 + (bd.lum - 1) * w;
      }
      ss *= L.saturation;
      if (chrome > 0) vv *= 1 - chrome * 0.12 * ss * ss;
      if (chromeBlue > 0) {
        const w = Math.max(0, 1 - hueDist(hh, 220) / 50);
        vv *= 1 - chromeBlue * 0.18 * w * ss; ss *= 1 + chromeBlue * 0.1 * w;
      }
      hh = ((hh % 360) + 360) % 360;
      [r, g, b] = hsvToRgb(hh, clamp01(ss), Math.max(0, vv));
      r += L.warmth; g += L.warmth * 0.4; b -= L.warmth;
    }
    const c = L.contrast + contrastAdj;
    if (c !== 0) {
      const sc = (x) => { x = clamp01(x); return x + c * (x * x * (3 - 2 * x) - x); };
      r = sc(r); g = sc(g); b = sc(b);
    }
    const l = 0.2126 * clamp01(r) + 0.7152 * clamp01(g) + 0.0722 * clamp01(b);
    r += L.shadowTint[0] * (1 - l) ** 2 + L.highlightTint[0] * l * l;
    g += L.shadowTint[1] * (1 - l) ** 2 + L.highlightTint[1] * l * l;
    b += L.shadowTint[2] * (1 - l) ** 2 + L.highlightTint[2] * l * l;
    r = L.fade + r * (1 - L.fade); g = L.fade + g * (1 - L.fade); b = L.fade + b * (1 - L.fade);
    r = curve(clamp01(r)); g = curve(clamp01(g)); b = curve(clamp01(b));
    if (sat !== 1) {
      const y = 0.2126 * r + 0.7152 * g + 0.0722 * b;
      r = y + (r - y) * sat; g = y + (g - y) * sat; b = y + (b - y) * sat;
    }
    return [clamp01(r), clamp01(g), clamp01(b)];
  };
}

export const LUT_SIZE = 33;

/** RGBA8 data for a LUT_SIZE³ 3D texture. */
export function buildLut(recipe, adj) {
  const n = LUT_SIZE, f = colorTransform(recipe, adj), data = new Uint8Array(n * n * n * 4);
  let i = 0;
  for (let b = 0; b < n; b++) for (let g = 0; g < n; g++) for (let r = 0; r < n; r++) {
    const o = f(r / (n - 1), g / (n - 1), b / (n - 1));
    data[i++] = Math.round(o[0] * 255); data[i++] = Math.round(o[1] * 255); data[i++] = Math.round(o[2] * 255); data[i++] = 255;
  }
  return data;
}

/** Shader parameters for the spatial effects. */
export function effectParams(recipe) {
  const g = strengthAmount(recipe.grain);
  return {
    grain: g * 0.09,
    grainSize: recipe.grainSize === 'Large' ? 2.2 : 1.1,
    // Clarity, sharpness and (positive) denoise all act on local contrast.
    clarity: recipe.clarity * 0.12 - Math.max(0, -recipe.sharpness) * 0.05 + Math.max(0, recipe.sharpness) * 0.04
      - Math.max(0, recipe.nr) * 0.02,
    halation: recipe.halation,
    vignette: recipe.vignette,
  };
}

export const isNeutral = (rc) => rc.simulation === 'NATURAL' && rc.wb == null && !rc.wbRed && !rc.wbBlue && rc.grain === 'Off' &&
  rc.colorChrome === 'Off' && rc.colorChromeBlue === 'Off' && rc.dr === 100 && !rc.highlight && !rc.shadow && !rc.color &&
  !rc.sharpness && !rc.clarity && !rc.halation && !rc.vignette;
