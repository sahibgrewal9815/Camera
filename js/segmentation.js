// Person segmentation (MediaPipe Selfie Segmentation, bundled in /vendor) for Depth and Cinematic.

const BASE = 'vendor/selfie_segmentation/';
let segmenter = null;
let readyPromise = null;
let busy = false;
let mask = null;
let version = 0;

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = src;
    s.onload = resolve;
    s.onerror = () => reject(new Error(`Could not load ${src}`));
    document.head.appendChild(s);
  });
}

/** Loads the model the first time; resolves true when ready. */
export function enableSegmentation() {
  if (readyPromise) return readyPromise;
  readyPromise = (async () => {
    try {
      await loadScript(BASE + 'selfie_segmentation.js');
      segmenter = new window.SelfieSegmentation({ locateFile: (f) => BASE + f });
      segmenter.setOptions({ modelSelection: 1, selfieMode: false });
      segmenter.onResults((r) => { mask = r.segmentationMask; version++; });
      await segmenter.initialize();
      return true;
    } catch (e) {
      console.warn('Segmentation unavailable', e);
      return false;
    }
  })();
  return readyPromise;
}

/** Feed a frame; skips if the previous one is still being processed. */
export function pump(video) {
  if (!segmenter || busy || video.readyState < 2) return;
  busy = true;
  segmenter.send({ image: video }).catch(() => {}).finally(() => { busy = false; });
}

export const latestMask = () => ({ mask, version });
