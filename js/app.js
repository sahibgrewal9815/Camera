import { PRESETS, SIMULATIONS, STRENGTHS, buildLut, effectParams, isNeutral, signed } from './looks.js';
import { FilmRenderer } from './renderer.js';
import { CameraStream } from './camera.js';
import { Motion } from './motion.js';
import { enableSegmentation, pump, latestMask } from './segmentation.js';
import { addItem, deleteItem, listItems, saveToDevice } from './gallery.js';

const $ = (s) => document.querySelector(s);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const clamp = (v, a, b) => Math.min(b, Math.max(a, v));

// ---------- State ----------
const DEFAULTS = {
  recipeId: 'natural', intensity: 1, aspect: '4:3', grid: false, level: false, mirror: true, autosave: false,
  quality: 0.92, fps: 30, res: 1080, stab: 'off', mic: true, histogram: false, aperture: 2.8, customs: [],
  photoRes: 'fast',
};
let S;
try { S = { ...DEFAULTS, ...JSON.parse(localStorage.getItem('procam') || '{}') }; } catch { S = { ...DEFAULTS }; }
const persist = () => { try { localStorage.setItem('procam', JSON.stringify(S)); } catch { /* private mode */ } };

const R = {
  mode: 'photo', lens: 'wide', facing: 'environment', zoom: 1, flash: false, timer: 0,
  showLooks: false, showPro: false, trayCollapsed: false, recording: false, recorder: null,
  countdownTimer: null, capturing: false, started: false, frame: 0, lastThumbs: 0, maskVersion: -1,
  pro: { exposure: 0, temperature: 0, tint: 0, contrast: 0, saturation: 0 }, proParam: 'exposure',
  draft: null, cardTimer: null, viewerItem: null, recTimer: null, outAspect: 3 / 4, depthReady: false,
};

const allRecipes = () => [...PRESETS, ...S.customs];
let recipe = allRecipes().find((r) => r.id === S.recipeId) || PRESETS[0];

const isVideoMode = () => R.mode === 'video';
const depthActive = () => R.mode === 'depth';
const depthAmount = () => clamp((16 - S.aperture) / (16 - 1.4), 0, 1);

// ---------- Setup ----------
const video = $('#video');
const canvas = $('#view');
const camera = new CameraStream(video);
const motion = new Motion();
let renderer, thumbRenderer;
const thumbCanvas = document.createElement('canvas');

try {
  renderer = new FilmRenderer(canvas);
  thumbRenderer = new FilmRenderer(thumbCanvas);
} catch (e) {
  showStartError('This browser does not support WebGL2, which ProCam needs. Please update iOS / Safari.');
}

const lutCache = new Map();
function lutFor(rc, adj = {}) {
  const key = JSON.stringify([rc, adj]);
  let lut = lutCache.get(key);
  if (!lut) {
    lut = buildLut(rc, adj);
    if (lutCache.size > 60) lutCache.delete(lutCache.keys().next().value);
    lutCache.set(key, lut);
  }
  return lut;
}

let lutDirty = true;
function applyLook() { lutDirty = true; }

// ---------- Layout ----------
function layout() {
  const W = innerWidth, H = innerHeight;
  const aspect = isVideoMode() ? 9 / 16 : { '4:3': 3 / 4, '1:1': 1, '16:9': 9 / 16 }[S.aspect];
  let h = W / aspect;
  let top = isVideoMode() ? (H - h) / 2 : Math.max(0, H * 0.43 - h / 2);
  if (h > H) { h = H; top = 0; }
  const vf = $('#viewfinder');
  vf.style.top = `${Math.round(top)}px`;
  vf.style.height = `${Math.round(h)}px`;
  R.outAspect = W / h;
  document.body.classList.toggle('video-mode', isVideoMode());
}

/** Short blur-and-settle animation when the mode, lens or camera changes (like the system camera). */
function switchAnimation(ms = 380) {
  const vf = $('#viewfinder');
  vf.classList.add('switching');
  clearTimeout(R.switchTimer);
  R.switchTimer = setTimeout(() => vf.classList.remove('switching'), ms);
}

function previewSize() {
  if (isVideoMode()) {
    const w = S.res === 720 ? 720 : 1080;
    return [w, Math.round(w / R.outAspect)];
  }
  const r = canvas.getBoundingClientRect();
  const dpr = Math.min(devicePixelRatio || 1, 1.5);
  return [Math.max(2, Math.round(r.width * dpr)), Math.max(2, Math.round(r.height * dpr))];
}

/** Visible part of the camera frame: aspect crop, digital zoom and stabilization. */
function cropRect() {
  const vw = video.videoWidth, vh = video.videoHeight;
  if (!vw || !vh) return [0, 0, 1, 1];
  const va = vw / vh, oa = R.outAspect;
  let w = 1, h = 1;
  if (va > oa) w = oa / va; else h = va / oa;
  w /= R.zoom; h /= R.zoom;
  let x = (1 - w) / 2, y = (1 - h) / 2;
  const stab = isVideoMode() && !camera.isFront && S.stab !== 'off' && motion.granted;
  if (stab) {
    const keep = S.stab === 'strong' ? 0.8 : 0.9;
    const slackX = (w * (1 - keep)) / 2, slackY = (h * (1 - keep)) / 2;
    x += slackX + clamp(motion.offset.x * w, -slackX, slackX);
    y += slackY + clamp(motion.offset.y * h, -slackY, slackY);
    w *= keep; h *= keep;
  }
  return [x, y, w, h];
}

function renderParams(time) {
  const fx = effectParams(recipe);
  return {
    crop: cropRect(),
    mirror: camera.isFront && S.mirror,
    exposure: R.pro.exposure,
    intensity: S.intensity,
    grain: fx.grain, grainSize: fx.grainSize, clarity: fx.clarity, halation: fx.halation, vignette: fx.vignette,
    depth: depthActive() ? depthAmount() : 0,
    time,
  };
}

// ---------- Render loop ----------
const hasFrameCallback = 'requestVideoFrameCallback' in HTMLVideoElement.prototype;
R.lastFrameAt = performance.now();
function watchFrames() {
  video.requestVideoFrameCallback(() => {
    R.newFrame = true;
    R.lastFrameAt = performance.now();
    watchFrames();
  });
}
if (hasFrameCallback) watchFrames();

function loop(t) {
  requestAnimationFrame(loop);
  if (!R.started || R.capturing || !renderer) return;
  // Only draw when the camera has a new frame (30fps), not on every 60/120Hz screen refresh.
  if (hasFrameCallback && !R.newFrame && !lutDirty) return;
  R.newFrame = false;
  if (lutDirty) { renderer.setLut(lutFor(recipe, R.pro)); lutDirty = false; }
  if (!renderer.uploadFrame(video)) return;
  if (!hasFrameCallback) R.lastFrameAt = performance.now();
  R.frame++;

  if (depthActive() && R.depthReady) {
    pump(video);
    const { mask, version } = latestMask();
    if (mask && version !== R.maskVersion) {
      renderer.uploadMask(mask);
      R.maskVersion = version;
      updateBadge();
    }
  }

  const [w, h] = previewSize();
  renderer.render(w, h, renderParams(t / 1000));

  if (R.showPro && S.histogram && R.frame % 15 === 0) drawHistogram(renderer.histogram());
  if (R.showLooks && t - R.lastThumbs > 1200) { R.lastThumbs = t; renderLookThumbs(); }
  if (S.level && motion.granted) updateLevel();
}

function updateLevel() {
  const el = $('#level');
  const deg = (motion.roll * 180) / Math.PI;
  el.classList.toggle('hidden', Math.abs(deg) > 25);
  el.classList.toggle('flat', Math.abs(deg) < 1);
  el.style.transform = `translate(-50%, -50%) rotate(${Math.abs(deg) < 1 ? 0 : -deg}deg)`;
}

function drawHistogram(bins) {
  if (!bins) return;
  const c = $('#histogram'), ctx = c.getContext('2d');
  ctx.clearRect(0, 0, c.width, c.height);
  ctx.beginPath();
  ctx.moveTo(0, c.height);
  bins.forEach((v, i) => ctx.lineTo((i / (bins.length - 1)) * c.width, c.height - v * (c.height - 4)));
  ctx.lineTo(c.width, c.height);
  ctx.closePath();
  ctx.fillStyle = 'rgba(255,255,255,0.75)';
  ctx.fill();
}

// ---------- Camera ----------
async function startCamera() {
  let deviceId;
  if (R.facing === 'user') deviceId = camera.frontDevice();
  else {
    const lenses = camera.backLenses();
    deviceId = lenses[R.lens] || lenses.wide;
  }
  await camera.start({
    deviceId, facing: R.facing, quality: isVideoMode() ? 'video' : 'photo',
    videoHeight: S.res, fps: S.fps, photoRes: S.photoRes,
  });
  if (R.facing === 'environment' && !camera.devices.some((d) => d.label)) await camera.refreshDevices();
  buildZoom();
  renderUI();
}

async function boot() {
  try {
    await startCamera();
    R.started = true;
    R.lastFrameAt = performance.now();
    $('#start').classList.add('hidden');
    layout();
  } catch (e) {
    $('#start').classList.remove('hidden');
    console.error(e);
    const denied = e && (e.name === 'NotAllowedError' || e.name === 'SecurityError');
    showStartError(denied
      ? 'Camera access was blocked. On iPhone: Settings → Apps → Safari → Camera → Allow, then reload this page.'
      : `Could not start the camera (${e?.name || e}).`);
  }
}

let staleTicks = 0;
async function healCamera() {
  if (!R.started || document.hidden || R.healing || R.capturing) return;
  const track = camera.track;
  const stale = performance.now() - R.lastFrameAt > 2000 || video.readyState < 2;
  if (track && track.readyState === 'live' && !stale) { staleTicks = 0; return; }
  R.healing = true;
  try {
    staleTicks++;
    if (track && track.readyState === 'live' && staleTicks < 2) {
      await video.play();               // usually enough after iOS pauses the video
    } else {
      staleTicks = 0;
      await startCamera();              // stream ended: reopen the camera
    }
  } catch (e) {
    console.warn('camera heal failed', e);
  } finally {
    R.lastFrameAt = performance.now();
    R.healing = false;
  }
}
setInterval(healCamera, 1000);

function showStartError(msg) {
  const el = $('#start-error');
  el.textContent = msg;
  el.classList.remove('hidden');
}

// ---------- Zoom / lenses ----------
function buildZoom() {
  const pill = $('#zoom');
  pill.innerHTML = '';
  const options = [];
  if (R.facing === 'environment') {
    const lenses = camera.backLenses();
    if (lenses.ultra) options.push({ lens: 'ultra', zoom: 1, label: '.5' });
    options.push({ lens: 'wide', zoom: 1, label: '1' });
    options.push({ lens: 'wide', zoom: 2, label: '2' });
    if (lenses.tele) options.push({ lens: 'tele', zoom: 1, label: 'T' });
  } else {
    options.push({ lens: 'front', zoom: 1, label: '1' }, { lens: 'front', zoom: 1.5, label: '1.5' });
  }
  const currentLens = R.facing === 'user' ? 'front' : R.lens;
  // The selected option is the highest one on the current lens at or below the current zoom.
  const sameLens = options.filter((o) => o.lens === currentLens);
  const active = sameLens.filter((o) => o.zoom <= R.zoom + 0.01).pop() || sameLens[0];
  for (const o of options) {
    const b = document.createElement('button');
    const selected = o === active;
    b.className = `zoom-btn${selected ? ' selected' : ''}`;
    if (selected) {
      if (o.lens === 'tele') {
        b.textContent = R.zoom > 1.05 ? `T${R.zoom.toFixed(1)}` : 'T';
      } else {
        const value = (o.lens === 'ultra' ? 0.5 : 1) * R.zoom;
        const text = Math.abs(value - Math.round(value)) < 0.05 ? String(Math.round(value)) : value.toFixed(1);
        b.textContent = `${text.replace(/^0\./, '.')}×`;
      }
    } else {
      b.textContent = o.label;
    }
    b.onclick = async () => {
      if (R.recording && o.lens !== currentLens) return;
      const lensChanged = o.lens !== currentLens;
      R.zoom = o.zoom;
      if (lensChanged && o.lens !== 'front') {
        R.lens = o.lens;
        switchAnimation(450);
        await startCamera().catch((e) => toast(`Could not switch lens (${e.name})`));
      }
      buildZoom();
    };
    pill.appendChild(b);
  }
}

// Pinch to zoom (digital, within the current lens)
let pinch = null;
$('#viewfinder').addEventListener('touchstart', (e) => {
  if (e.touches.length === 2) {
    const [a, b] = e.touches;
    pinch = { d: Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY), z: R.zoom };
  }
}, { passive: true });
$('#viewfinder').addEventListener('touchmove', (e) => {
  if (pinch && e.touches.length === 2) {
    const [a, b] = e.touches;
    const d = Math.hypot(a.clientX - b.clientX, a.clientY - b.clientY);
    R.zoom = clamp(pinch.z * (d / pinch.d), 1, 6);
    buildZoom();
  }
}, { passive: true });
$('#viewfinder').addEventListener('touchend', () => { pinch = null; }, { passive: true });

// Swipe left/right on the viewfinder to change PHOTO / VIDEO
let swipe = null;
$('#viewfinder').addEventListener('pointerdown', (e) => { swipe = { x: e.clientX, y: e.clientY }; });
$('#viewfinder').addEventListener('pointerup', (e) => {
  if (!swipe || pinch) return;
  const dx = e.clientX - swipe.x, dy = e.clientY - swipe.y;
  swipe = null;
  if (Math.abs(dx) > 50 && Math.abs(dx) > Math.abs(dy) * 1.5) {
    const order = ['video', 'photo', 'depth'];
    const i = order.indexOf(R.mode) + (dx < 0 ? 1 : -1);
    if (i >= 0 && i < order.length) setMode(order[i]);
  }
});

$('#modes').addEventListener('pointerdown', (e) => { swipe = { x: e.clientX, y: e.clientY }; });
$('#modes').addEventListener('pointerup', (e) => $('#viewfinder').dispatchEvent(new PointerEvent('pointerup', e)));

// ---------- Modes ----------
async function setMode(mode) {
  if (R.recording || mode === R.mode) return;
  const wasVideo = isVideoMode();
  R.mode = mode;
  cancelCountdown();
  if (depthActive()) {
    updateBadge('Loading depth…');
    enableSegmentation().then((ok) => {
      R.depthReady = ok;
      if (!ok) toast('Depth effect is not supported in this browser');
      updateBadge();
    });
  }
  switchAnimation(wasVideo !== isVideoMode() ? 650 : 380);
  layout();
  renderUI();
  if (wasVideo !== isVideoMode()) {
    await startCamera().catch((e) => toast(`Camera error (${e.name})`));
  }
}

function updateBadge(text) {
  const badge = $('#badge');
  if (!depthActive()) { badge.classList.add('hidden'); return; }
  const f = `ƒ${S.aperture.toFixed(1)}`;
  const label = text || (!R.depthReady ? 'Loading depth…'
    : R.maskVersion < 0 ? 'Looking for people…'
      : `DEPTH · ${f}`);
  badge.textContent = label;
  badge.classList.remove('hidden');
}

// ---------- UI rendering ----------
const ICON = (id) => `<svg><use href="#${id}"/></svg>`;

function renderUI() {
  const video = isVideoMode();
  document.body.classList.toggle('recording', R.recording);
  document.body.classList.toggle('video-mode', video);

  // Top bar
  $('#btn-flash').innerHTML = ICON(R.flash ? 'i-bolt' : 'i-bolt-off');
  $('#btn-flash').classList.toggle('active-y', R.flash);
  $('#btn-looks').classList.toggle('active-y', R.showLooks || !isNeutral(recipe));
  $('#btn-drawer').classList.toggle('open', R.drawerOpen);
  $('#btn-drawer').classList.toggle('hidden', R.recording);
  $('#btn-looks').style.visibility = R.recording ? 'hidden' : 'visible';
  $('#rec-time').classList.toggle('hidden', !R.recording);
  $('#video').classList.toggle('mirror', camera.isFront && S.mirror);

  // Shutter
  const sh = $('#shutter');
  sh.classList.toggle('video', video);
  sh.classList.toggle('recording', R.recording);
  sh.classList.toggle('counting', !!R.countdownTimer);

  // Overlays
  $('#grid').classList.toggle('hidden', !S.grid);
  $('#level').classList.toggle('hidden', !S.level || !motion.granted);
  $('#histogram').classList.toggle('hidden', !(R.showPro && S.histogram));
  updateBadge();

  // Panels
  $('#panel-looks').classList.toggle('hidden', !R.showLooks);
  $('#panel-pro').classList.toggle('hidden', !R.showPro || R.showLooks);
  $('#panel-depth').classList.toggle('hidden', !depthActive() || R.showLooks || R.showPro);
  $('#aperture').value = S.aperture;
  $('#aperture-value').textContent = S.aperture.toFixed(1);
  $('#intensity').value = S.intensity;
  $('#intensity-value').textContent = Math.round(S.intensity * 100);

  // Mode carousel: slide so the active mode sits in the middle
  for (const b of document.querySelectorAll('#mode-track button')) b.classList.toggle('active', b.dataset.mode === R.mode);
  centerModes();

  // Drawer of extra controls (opened with the chevron)
  const drawer = $('#drawer');
  drawer.classList.toggle('open', R.drawerOpen && !R.recording);
  const items = [
    { label: 'LOOKS', icon: 'i-film', active: R.showLooks || !isNeutral(recipe), act: toggleLooks },
    { label: 'PRO', icon: 'i-sliders', active: R.showPro, act: togglePro },
    ...(video
      ? [
        { label: S.stab === 'strong' ? 'STABLE+' : 'STABLE', icon: 'i-stab', active: S.stab !== 'off', act: cycleStabilization },
        { label: S.mic ? 'SOUND' : 'MUTED', icon: 'i-mic', active: S.mic, act: () => { S.mic = !S.mic; persist(); renderUI(); } },
      ]
      : [
        { label: R.timer ? `${R.timer}S` : 'TIMER', icon: 'i-timer', active: R.timer > 0, act: () => { R.timer = R.timer === 0 ? 3 : R.timer === 3 ? 10 : 0; renderUI(); } },
        { label: S.aspect, icon: 'i-aspect', active: S.aspect !== '4:3', act: cycleAspect },
      ]),
    { label: 'GRID', icon: 'i-grid', active: S.grid, act: () => { S.grid = !S.grid; persist(); renderUI(); } },
    { label: 'SETTINGS', icon: 'i-gear', active: false, act: () => { R.drawerOpen = false; renderUI(); renderSettings(); openSheet('#sheet-settings'); } },
  ];
  drawer.innerHTML = '';
  for (const it of items) {
    const b = document.createElement('button');
    b.className = `d-item${it.active ? ' active' : ''}`;
    b.innerHTML = `<i>${ICON(it.icon)}</i><span>${it.label}</span>`;
    b.onclick = it.act;
    drawer.appendChild(b);
  }
  if (R.showPro) renderPro();
}

function centerModes() {
  const track = $('#mode-track');
  const active = track.querySelector('.active');
  if (!active) return;
  const x = innerWidth / 2 - (active.offsetLeft + active.offsetWidth / 2);
  track.style.transform = `translateX(${x}px)`;
}

function cycleAspect() {
  S.aspect = { '4:3': '1:1', '1:1': '16:9', '16:9': '4:3' }[S.aspect];
  persist();
  layout();
  renderUI();
}

function toggleLooks() {
  R.drawerOpen = false;
  R.showLooks = !R.showLooks;
  if (R.showLooks) { R.showPro = false; buildLooksStrip(); R.lastThumbs = 0; }
  renderUI();
}

function togglePro() {
  R.drawerOpen = false;
  R.showPro = !R.showPro;
  if (R.showPro) R.showLooks = false;
  renderUI();
}

// ---------- Looks strip ----------
const THUMB = 116;
function buildLooksStrip() {
  const strip = $('#looks-strip');
  strip.innerHTML = '';
  for (const rc of allRecipes()) {
    const el = document.createElement('button');
    el.className = `look${rc.id === recipe.id ? ' selected' : ''}`;
    el.dataset.id = rc.id;
    el.innerHTML = `<canvas width="${THUMB}" height="${THUMB}"></canvas><span></span>`;
    el.querySelector('span').textContent = rc.name;
    el.onclick = () => {
      if (rc.id === recipe.id) { openRecipeCard(); return; }
      selectRecipe(rc);
    };
    strip.appendChild(el);
  }
  strip.querySelector('.selected')?.scrollIntoView({ inline: 'center', block: 'nearest' });
}

function selectRecipe(rc) {
  recipe = rc;
  S.recipeId = rc.id;
  persist();
  applyLook();
  for (const el of document.querySelectorAll('.look')) el.classList.toggle('selected', el.dataset.id === rc.id);
  renderUI();
}

function squareCrop() {
  const vw = video.videoWidth, vh = video.videoHeight;
  if (vw > vh) return [(1 - vh / vw) / 2, 0, vh / vw, 1];
  return [0, (1 - vw / vh) / 2, 1, vw / vh];
}

function renderLookThumbs() {
  if (!thumbRenderer || !thumbRenderer.uploadFrame(video)) return;
  const crop = squareCrop();
  for (const el of document.querySelectorAll('.look')) {
    const rc = allRecipes().find((r) => r.id === el.dataset.id);
    if (!rc) continue;
    const fx = effectParams(rc);
    thumbRenderer.setLut(lutFor(rc, {}));
    thumbRenderer.render(THUMB, THUMB, { crop, mirror: camera.isFront && S.mirror, intensity: 1, ...fx, time: 0 });
    el.querySelector('canvas').getContext('2d').drawImage(thumbCanvas, 0, 0, THUMB, THUMB);
  }
}

$('#intensity').addEventListener('input', (e) => {
  S.intensity = +e.target.value;
  $('#intensity-value').textContent = Math.round(S.intensity * 100);
  persist();
});
$('#btn-card').onclick = () => openRecipeCard();

// ---------- Pro panel ----------
const PRO = {
  exposure: { label: 'EV', min: -2, max: 2, step: 0.1, fmt: (v) => (v > 0 ? '+' : '') + v.toFixed(1) },
  temperature: { label: 'WB', min: -1, max: 1, step: 0.05, fmt: (v) => `${Math.round((5500 + v * 2000) / 100) * 100}K` },
  tint: { label: 'TINT', min: -1, max: 1, step: 0.05, fmt: (v) => signed(Math.round(v * 10)) },
  contrast: { label: 'CONTRAST', min: -0.5, max: 0.5, step: 0.05, fmt: (v) => signed(Math.round(v * 20)) },
  saturation: { label: 'SAT', min: -1, max: 1, step: 0.05, fmt: (v) => signed(Math.round(v * 10)) },
};

function renderPro() {
  const box = $('#pro-params');
  box.innerHTML = '';
  for (const [key, def] of Object.entries(PRO)) {
    const b = document.createElement('button');
    b.className = `pro-param${R.proParam === key ? ' selected' : ''}`;
    b.innerHTML = `<b>${def.label}</b><span>${def.fmt(R.pro[key])}</span>`;
    b.onclick = () => { R.proParam = key; renderPro(); };
    box.appendChild(b);
  }
  const def = PRO[R.proParam];
  const sl = $('#pro-slider');
  sl.min = def.min; sl.max = def.max; sl.step = def.step; sl.value = R.pro[R.proParam];
}

$('#pro-slider').addEventListener('input', (e) => {
  R.pro[R.proParam] = +e.target.value;
  if (R.proParam !== 'exposure') applyLook();
  const sel = document.querySelector('.pro-param.selected span');
  if (sel) sel.textContent = PRO[R.proParam].fmt(R.pro[R.proParam]);
});
$('#pro-reset').onclick = () => {
  R.pro = { exposure: 0, temperature: 0, tint: 0, contrast: 0, saturation: 0 };
  applyLook();
  renderPro();
};

$('#aperture').addEventListener('input', (e) => {
  S.aperture = +e.target.value;
  $('#aperture-value').textContent = S.aperture.toFixed(1);
  updateBadge();
  persist();
});

// ---------- Capture ----------
function blink() {
  const b = $('#blink');
  b.classList.add('on');
  setTimeout(() => b.classList.remove('on'), 90);
}

const stamp = () => new Date().toISOString().replace(/[-:T]/g, '').slice(0, 14);

async function makeThumb(source) {
  const bmp = source instanceof Blob ? await createImageBitmap(source) : source;
  const w = bmp.width, h = bmp.height, s = 240 / Math.min(w, h);
  const c = document.createElement('canvas');
  c.width = c.height = 240;
  c.getContext('2d').drawImage(bmp, (240 - w * s) / 2, (240 - h * s) / 2, w * s, h * s);
  return new Promise((r) => c.toBlob(r, 'image/jpeg', 0.8));
}

async function takePhoto() {
  if (R.capturing || !video.videoWidth || !renderer) return;
  R.capturing = true;
  $('#thumb-spinner').classList.remove('hidden');
  const frontFlash = R.flash && camera.isFront;
  const torch = R.flash && !camera.isFront && camera.torchSupported;
  let blob;
  try {
    if (frontFlash) { $('#front-flash').classList.add('on'); await sleep(450); }
    if (torch) { await camera.setTorch(true); await sleep(700); }
    if (lutDirty) { renderer.setLut(lutFor(recipe, R.pro)); lutDirty = false; }
    renderer.uploadFrame(video);
    const params = renderParams(performance.now() / 1000);
    let W = Math.round(params.crop[2] * video.videoWidth), H = Math.round(params.crop[3] * video.videoHeight);
    const s = Math.min(1, 4096 / Math.max(W, H));
    W = Math.round(W * s); H = Math.round(H * s);
    renderer.render(W, H, params);
    blob = await new Promise((r) => canvas.toBlob(r, 'image/jpeg', S.quality));
    blink();
  } finally {
    $('#front-flash').classList.remove('on');
    if (torch) camera.setTorch(false);
    R.capturing = false;
  }
  try {
    if (!blob) throw new Error('empty');
    const thumb = await makeThumb(blob);
    const item = { blob, thumb, type: 'photo', name: `ProCam_${stamp()}.jpg` };
    await addItem(item);
    setThumb(thumb);
    if (S.autosave) saveToDevice(item).catch(() => toast('Tap the thumbnail to save to Photos'));
  } catch (e) {
    toast('Could not save the photo');
  } finally {
    $('#thumb-spinner').classList.add('hidden');
  }
}

async function startRecording() {
  if (!renderer || R.recording) return;
  const fps = S.fps;
  const stream = canvas.captureStream(fps);
  if (S.mic) {
    try { stream.addTrack(await camera.audioTrack()); } catch { toast('No microphone access, recording without sound'); }
  }
  const types = ['video/mp4;codecs=avc1.640028,mp4a.40.2', 'video/mp4;codecs=avc1', 'video/mp4', 'video/webm;codecs=vp9,opus', 'video/webm'];
  const mimeType = types.find((t) => window.MediaRecorder?.isTypeSupported?.(t)) || '';
  let rec;
  try {
    rec = new MediaRecorder(stream, { mimeType, videoBitsPerSecond: S.res === 720 ? 6_000_000 : 12_000_000 });
  } catch (e) {
    toast('Video recording is not supported in this browser');
    return;
  }
  const chunks = [];
  let thumbPromise = null;
  rec.ondataavailable = (e) => { if (e.data && e.data.size) chunks.push(e.data); };
  rec.onstop = async () => {
    stream.getVideoTracks().forEach((t) => t.stop());
    camera.stopAudio();
    const type = rec.mimeType || mimeType || 'video/mp4';
    const blob = new Blob(chunks, { type });
    const ext = type.includes('mp4') ? 'mp4' : 'webm';
    try {
      const thumb = await thumbPromise;
      const item = { blob, thumb, type: 'video', name: `ProCam_${stamp()}.${ext}` };
      await addItem(item);
      setThumb(thumb);
      if (S.autosave) saveToDevice(item).catch(() => toast('Tap the thumbnail to save to Photos'));
    } catch {
      toast('Could not save the video');
    }
    $('#thumb-spinner').classList.add('hidden');
  };
  rec.start(1000);
  R.recorder = rec;
  R.recording = true;
  R.stopThumb = () => { thumbPromise = makeThumb(canvas); };
  if (R.flash && camera.torchSupported && !camera.isFront) camera.setTorch(true);
  const start = performance.now();
  const tick = () => {
    const s = Math.floor((performance.now() - start) / 1000);
    $('#rec-time').textContent = [s / 3600, (s / 60) % 60, s % 60].map((v) => String(Math.floor(v)).padStart(2, '0')).join(':');
  };
  tick();
  R.recTimer = setInterval(tick, 500);
  renderUI();
}

function stopRecording() {
  if (!R.recording) return;
  R.stopThumb?.();
  $('#thumb-spinner').classList.remove('hidden');
  R.recorder.stop();
  R.recording = false;
  clearInterval(R.recTimer);
  camera.setTorch(false);
  renderUI();
}

function cancelCountdown() {
  if (!R.countdownTimer) return;
  clearInterval(R.countdownTimer);
  R.countdownTimer = null;
  $('#countdown').classList.add('hidden');
  renderUI();
}

function withTimer(fn) {
  if (!R.timer) return fn();
  let left = R.timer;
  const el = $('#countdown');
  el.textContent = left;
  el.classList.remove('hidden');
  R.countdownTimer = setInterval(() => {
    left -= 1;
    if (left <= 0) {
      cancelCountdown();
      fn();
    } else {
      el.textContent = left;
    }
  }, 1000);
  renderUI();
}

$('#shutter').onclick = () => {
  if (!R.started) return;
  if (R.countdownTimer) { cancelCountdown(); return; }
  if (isVideoMode()) {
    if (R.recording) stopRecording(); else withTimer(startRecording);
  } else {
    withTimer(takePhoto);
  }
};

// Volume buttons can't be read by websites, but a hardware keyboard / remote shutter (space/enter) works.
addEventListener('keydown', (e) => { if (e.key === ' ' || e.key === 'Enter' || e.key === 'AudioVolumeUp') $('#shutter').click(); });

// ---------- Gallery ----------
function setThumb(blob) {
  const img = $('#thumb-img');
  if (img.dataset.url) URL.revokeObjectURL(img.dataset.url);
  if (!blob) { img.removeAttribute('src'); return; }
  const url = URL.createObjectURL(blob);
  img.dataset.url = url;
  img.src = url;
  const t = $('#thumb');
  t.classList.remove('pop');
  void t.offsetWidth;
  t.classList.add('pop');
}

async function refreshThumb() {
  try {
    const items = await listItems();
    setThumb(items[0]?.thumb || null);
  } catch { /* IndexedDB unavailable */ }
}

async function openGallery() {
  const grid = $('#gallery-grid');
  grid.innerHTML = '';
  const items = await listItems().catch(() => []);
  $('#gallery-empty').classList.toggle('hidden', items.length > 0);
  for (const it of items) {
    const b = document.createElement('button');
    b.className = 'g-item';
    const url = URL.createObjectURL(it.thumb);
    b.innerHTML = `<img src="${url}" alt="">${it.type === 'video' ? '<em>▶ VIDEO</em>' : ''}`;
    b.onclick = () => openViewer(it);
    grid.appendChild(b);
  }
  openSheet('#sheet-gallery');
}

function openViewer(item) {
  R.viewerItem = item;
  const box = $('#viewer-media');
  box.innerHTML = '';
  const url = URL.createObjectURL(item.blob);
  const el = document.createElement(item.type === 'video' ? 'video' : 'img');
  el.src = url;
  if (item.type === 'video') { el.controls = true; el.playsInline = true; el.autoplay = true; }
  box.appendChild(el);
  $('#viewer').classList.remove('hidden');
}

function closeViewer() {
  const media = $('#viewer-media').firstElementChild;
  if (media?.src) URL.revokeObjectURL(media.src);
  $('#viewer-media').innerHTML = '';
  $('#viewer').classList.add('hidden');
  R.viewerItem = null;
}

$('#thumb').onclick = openGallery;
$('#viewer-close').onclick = closeViewer;
$('#viewer-save').onclick = async () => {
  if (!R.viewerItem) return;
  const result = await saveToDevice(R.viewerItem);
  if (result === 'downloaded') toast('Saved to Downloads');
};
$('#viewer-delete').onclick = async () => {
  if (!R.viewerItem || !confirm('Delete this from the ProCam gallery?')) return;
  await deleteItem(R.viewerItem.id);
  closeViewer();
  await refreshThumb();
  openGallery();
};

// ---------- Recipe card ----------
const TILE_DEFS = () => {
  const d = R.draft;
  const range = (a, b, step = 1) => { const out = []; for (let v = b; v >= a - 1e-9; v -= step) out.push(+v.toFixed(1)); return out; };
  const simple = (key, label, values, fmt = signed) => ({
    label, value: fmt(d[key]), options: values.map((v) => [String(v), fmt(v)]), current: String(d[key]),
    set: (v) => { d[key] = typeof d[key] === 'number' ? +v : v; },
  });
  const wbValues = ['AUTO'];
  for (let k = 2500; k <= 10000; k += 100) wbValues.push(k);
  return [
    { cls: 'wide', label: 'Film simulations', value: d.simulation, current: d.simulation,
      options: SIMULATIONS.map((s) => [s, s]), set: (v) => { d.simulation = v; } },
    { cls: 'wide', label: `Red: ${signed(d.wbRed)} Blue: ${signed(d.wbBlue)}`, value: d.wb ? `${d.wb}K` : 'AUTO',
      current: `wb:${d.wb ?? 'AUTO'}`,
      groups: [
        ['White balance', wbValues.map((k) => [`wb:${k}`, k === 'AUTO' ? 'AUTO' : `${k}K`])],
        ['Red shift', range(-9, 9).map((v) => [`r:${v}`, `Red ${signed(v)}`])],
        ['Blue shift', range(-9, 9).map((v) => [`b:${v}`, `Blue ${signed(v)}`])],
      ],
      set: (v) => {
        const [k, val] = v.split(':');
        if (k === 'wb') d.wb = val === 'AUTO' ? null : +val;
        if (k === 'r') d.wbRed = +val;
        if (k === 'b') d.wbBlue = +val;
      } },
    { cls: 'grain', label: 'Grain Effect', value: d.grain === 'Off' ? 'Off' : `${d.grain}\n${d.grainSize}`,
      current: `g:${d.grain}`,
      groups: [['Grain', STRENGTHS.map((s) => [`g:${s}`, s])], ['Size', ['Small', 'Large'].map((s) => [`s:${s}`, s])]],
      set: (v) => { const [k, val] = v.split(':'); if (k === 'g') d.grain = val; else d.grainSize = val; } },
    simple('colorChrome', 'Color Effect', STRENGTHS, (v) => v),
    simple('colorChromeBlue', 'Color FX Blue', STRENGTHS, (v) => v),
    simple('dr', 'Dynamic Range', [100, 200, 400], (v) => `DR${v}`),
    simple('highlight', 'Highlight', range(-2, 4, 0.5), (v) => (v > 0 ? '+' : '') + (+v).toFixed(1)),
    simple('shadow', 'Shadow', range(-2, 4, 0.5), (v) => (v > 0 ? '+' : '') + (+v).toFixed(1)),
    simple('color', 'Color', range(-4, 4)),
    simple('sharpness', 'Sharpness', range(-4, 4)),
    simple('nr', 'ISO Denoise', range(-4, 4)),
    simple('clarity', 'Clarity', range(-5, 5)),
    { label: 'Strength', value: `${Math.round(S.intensity * 100)}%`, current: String(S.intensity),
      options: [1, 0.75, 0.5, 0.25].map((v) => [String(v), `${v * 100}%`]),
      set: (v) => { S.intensity = +v; persist(); } },
  ];
};

function renderCard() {
  const d = R.draft;
  $('#recipe-name').textContent = d.name;
  $('#recipe-sub').textContent = d.subtitle || 'Film Recipe';
  const tiles = $('#recipe-tiles');
  tiles.innerHTML = '';
  for (const t of TILE_DEFS()) {
    const el = document.createElement('div');
    el.className = `tile glass ${t.cls || ''}`;
    el.innerHTML = '<div class="v"></div><div class="l"></div>';
    el.querySelector('.v').textContent = t.value;
    el.querySelector('.l').textContent = t.label;
    const sel = document.createElement('select');
    const addOpts = (parent, opts) => {
      for (const [v, text] of opts) {
        const o = document.createElement('option');
        o.value = v; o.textContent = text;
        parent.appendChild(o);
      }
    };
    if (t.groups) {
      for (const [label, opts] of t.groups) {
        const g = document.createElement('optgroup');
        g.label = label;
        addOpts(g, opts);
        sel.appendChild(g);
      }
    } else addOpts(sel, t.options);
    sel.value = t.current;
    sel.onchange = () => { t.set(sel.value); renderCard(); renderCardPreview(); };
    el.appendChild(sel);
    tiles.appendChild(el);
  }
  $('#r-halation').value = d.halation;
  $('#r-vignette').value = d.vignette;
  $('#recipe-delete').classList.toggle('hidden', !d.custom);
}

function renderCardPreview() {
  if (!thumbRenderer || !thumbRenderer.uploadFrame(video) || !R.draft) return;
  const W = 640, H = 480;
  const vw = video.videoWidth, vh = video.videoHeight, va = vw / vh, oa = W / H;
  const crop = va > oa ? [(1 - oa / va) / 2, 0, oa / va, 1] : [0, (1 - va / oa) / 2, 1, va / oa];
  thumbRenderer.setLut(lutFor(R.draft, {}));
  thumbRenderer.render(W, H, { crop, mirror: camera.isFront && S.mirror, intensity: S.intensity, ...effectParams(R.draft), time: performance.now() / 1000 });
  for (const id of ['#recipe-preview', '#recipe-bg']) {
    const c = $(id);
    if (c.width !== W) { c.width = W; c.height = H; }
    c.getContext('2d').drawImage(thumbCanvas, 0, 0, W, H);
  }
}

function openRecipeCard() {
  R.draft = JSON.parse(JSON.stringify(recipe));
  renderCard();
  renderCardPreview();
  clearInterval(R.cardTimer);
  R.cardTimer = setInterval(renderCardPreview, 700);
  openSheet('#sheet-recipe');
}

for (const id of ['halation', 'vignette']) {
  $(`#r-${id}`).addEventListener('input', (e) => { R.draft[id] = +e.target.value; renderCardPreview(); });
}

$('#recipe-use').onclick = () => {
  const d = R.draft;
  if (d.custom) {
    S.customs = S.customs.map((c) => (c.id === d.id ? d : c));
  }
  selectRecipe(d);
  buildLooksStrip();
  closeSheets();
};

$('#recipe-save').onclick = () => {
  const name = prompt('Name your recipe', R.draft.custom ? R.draft.name : `${R.draft.name} Custom`);
  if (!name) return;
  const rc = { ...R.draft, id: `custom-${Date.now()}`, name, subtitle: 'My recipe', custom: true };
  S.customs.push(rc);
  selectRecipe(rc);
  buildLooksStrip();
  renderSettings();
  closeSheets();
  toast(`Saved "${name}"`);
};

$('#recipe-delete').onclick = () => {
  const d = R.draft;
  if (!d.custom || !confirm(`Delete "${d.name}"?`)) return;
  deleteCustom(d.id);
  closeSheets();
};

function deleteCustom(id) {
  S.customs = S.customs.filter((c) => c.id !== id);
  if (recipe.id === id) selectRecipe(PRESETS[0]);
  persist();
  buildLooksStrip();
  renderSettings();
}

// ---------- Sheets ----------
function openSheet(id) { $(id).classList.remove('hidden'); }
function closeSheets() {
  document.querySelectorAll('.sheet').forEach((s) => s.classList.add('hidden'));
  clearInterval(R.cardTimer);
  R.cardTimer = null;
}
document.querySelectorAll('[data-close]').forEach((b) => { b.onclick = closeSheets; });
document.querySelectorAll('.sheet').forEach((s) => s.addEventListener('click', (e) => { if (e.target === s) closeSheets(); }));

// ---------- Settings ----------
function renderSettings() {
  $('#set-aspect').value = S.aspect;
  $('#set-photores').value = S.photoRes;
  $('#set-grid').checked = S.grid;
  $('#set-level').checked = S.level;
  $('#set-mirror').checked = S.mirror;
  $('#set-autosave').checked = S.autosave;
  $('#set-quality').value = String(S.quality);
  $('#set-fps').value = String(S.fps);
  $('#set-res').value = String(S.res);
  $('#set-stab').value = S.stab;
  $('#set-mic').checked = S.mic;
  $('#set-histogram').checked = S.histogram;
  const box = $('#custom-recipes');
  box.innerHTML = '';
  $('#custom-recipes-group').classList.toggle('hidden', S.customs.length === 0);
  for (const c of S.customs) {
    const row = document.createElement('div');
    row.className = 'custom-row';
    row.innerHTML = `<span></span><button class="glass circle small"><svg><use href="#i-trash"/></svg></button>`;
    row.querySelector('span').textContent = c.name;
    row.querySelector('button').onclick = () => { if (confirm(`Delete "${c.name}"?`)) deleteCustom(c.id); };
    box.appendChild(row);
  }
}

const bind = (id, key, parse, after) => {
  $(id).addEventListener('change', (e) => {
    S[key] = parse(e.target);
    persist();
    after?.();
    renderUI();
  });
};
bind('#set-aspect', 'aspect', (t) => t.value, () => layout());
bind('#set-photores', 'photoRes', (t) => t.value, () => { if (!isVideoMode()) startCamera(); });
bind('#set-grid', 'grid', (t) => t.checked);
bind('#set-level', 'level', (t) => t.checked, () => { if (S.level && !motion.granted) motion.request().then(renderUI); });
bind('#set-mirror', 'mirror', (t) => t.checked);
bind('#set-autosave', 'autosave', (t) => t.checked);
bind('#set-quality', 'quality', (t) => +t.value);
bind('#set-fps', 'fps', (t) => +t.value, () => { if (R.mode === 'video') startCamera(); });
bind('#set-res', 'res', (t) => +t.value, () => { if (isVideoMode()) startCamera(); });
bind('#set-stab', 'stab', (t) => t.value, () => { if (S.stab !== 'off' && !motion.granted) motion.request(); });
bind('#set-mic', 'mic', (t) => t.checked);
bind('#set-histogram', 'histogram', (t) => t.checked);


// ---------- Top bar & tray buttons ----------
$('#btn-flash').onclick = () => {
  R.flash = !R.flash;
  if (R.flash && !camera.isFront && !camera.torchSupported) toast('This browser cannot use the flash on the back camera');
  renderUI();
};
async function cycleStabilization() {
  if (!motion.granted) await motion.request();
  if (!motion.granted) { toast('Stabilization needs motion access'); return; }
  S.stab = { off: 'standard', standard: 'strong', strong: 'off' }[S.stab];
  persist();
  toast(`Stabilization: ${S.stab === 'off' ? 'Off' : S.stab === 'standard' ? 'Standard' : 'Strong'}`);
  renderUI();
}
$('#btn-flip').onclick = async () => {
  if (R.recording) return;
  R.facing = R.facing === 'environment' ? 'user' : 'environment';
  R.zoom = 1;
  switchAnimation(600);
  const icon = $('#btn-flip svg');
  R.flipTurns = (R.flipTurns || 0) + 1;
  icon.style.transform = `rotate(${R.flipTurns * 180}deg)`;
  await startCamera().catch((e) => toast(`Could not switch camera (${e.name})`));
};
document.querySelectorAll('#mode-track button').forEach((b) => {
  b.onclick = () => setMode(b.dataset.mode);
});
$('#btn-drawer').onclick = () => { R.drawerOpen = !R.drawerOpen; renderUI(); };
$('#btn-looks').onclick = toggleLooks;
// Tapping the viewfinder closes the drawer
$('#viewfinder').addEventListener('click', () => { if (R.drawerOpen) { R.drawerOpen = false; renderUI(); } });

// ---------- Toast ----------
let toastTimer;
function toast(msg) {
  const t = $('#toast');
  t.textContent = msg;
  t.classList.remove('hidden');
  clearTimeout(toastTimer);
  toastTimer = setTimeout(() => t.classList.add('hidden'), 2600);
}

// ---------- Start ----------
$('#btn-start').onclick = () => {
  if ((S.level || S.stab !== 'off') && !motion.granted) motion.request().then(renderUI);
  boot();
};

// Motion permission needs a tap on iOS; ask on the first touch if a motion feature is on.
addEventListener('pointerdown', function once() {
  if ((S.level || S.stab !== 'off') && !motion.granted) motion.request().then(renderUI);
  removeEventListener('pointerdown', once);
});
if (typeof DeviceMotionEvent !== 'undefined' && !DeviceMotionEvent.requestPermission) motion.attach();

const isIOS = /iP(hone|ad|od)/.test(navigator.userAgent);
if (isIOS && !navigator.standalone) $('#install-hint').classList.remove('hidden');

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    if (R.recording) stopRecording();
  } else if (R.started) {
    R.lastFrameAt = performance.now();
    if (camera.track?.readyState === 'live') video.play().catch(() => {});
    else startCamera().catch(() => {});
  }
});
addEventListener('pageshow', () => { if (R.started) healCamera(); });
addEventListener('resize', () => { layout(); centerModes(); });

if ('serviceWorker' in navigator) navigator.serviceWorker.register('sw.js').catch(() => {});

layout();
renderUI();
refreshThumb();
requestAnimationFrame(loop);

// Open the camera straight away. The start card only appears if the camera can't open.
boot();
