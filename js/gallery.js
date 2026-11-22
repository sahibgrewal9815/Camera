// In-app gallery stored in IndexedDB.

const DB_NAME = 'procam';
const STORE = 'media';
let dbPromise;

function db() {
  dbPromise ??= new Promise((resolve, reject) => {
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => req.result.createObjectStore(STORE, { keyPath: 'id', autoIncrement: true });
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error);
  });
  return dbPromise;
}

function tx(mode, fn) {
  return db().then((d) => new Promise((resolve, reject) => {
    const t = d.transaction(STORE, mode);
    const result = fn(t.objectStore(STORE));
    t.oncomplete = () => resolve(result.result ?? result);
    t.onerror = () => reject(t.error);
  }));
}

/** item: { blob, thumb (Blob), type: 'photo'|'video', name } */
export const addItem = (item) => tx('readwrite', (s) => s.add({ ...item, created: Date.now() }));
export const deleteItem = (id) => tx('readwrite', (s) => s.delete(id));
export const listItems = () => tx('readonly', (s) => s.getAll()).then((items) => items.sort((a, b) => b.created - a.created));

/** Opens the iOS share sheet ("Save Image" / "Save Video"), or downloads as a fallback. */
export async function saveToDevice(item) {
  const file = new File([item.blob], item.name, { type: item.blob.type });
  if (navigator.canShare?.({ files: [file] })) {
    try {
      await navigator.share({ files: [file] });
      return 'shared';
    } catch (e) {
      if (e.name === 'AbortError') return 'cancelled';
    }
  }
  const url = URL.createObjectURL(item.blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = item.name;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 10000);
  return 'downloaded';
}
