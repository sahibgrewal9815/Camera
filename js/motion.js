// Gyroscope: horizon level + software video stabilization.

const DEG = Math.PI / 180;

export class Motion {
  constructor() {
    this.roll = 0;              // radians, 0 = phone upright
    this.offset = { x: 0, y: 0 }; // stabilization offset in frame units
    this.granted = false;
    this.attached = false;
    this._angle = { x: 0, y: 0 };
    this._low = { x: 0, y: 0 };
    this._last = 0;
  }

  /** Must be called from a tap (iOS asks for permission). */
  request() {
    const ask = [];
    if (typeof DeviceMotionEvent !== 'undefined' && DeviceMotionEvent.requestPermission) ask.push(DeviceMotionEvent.requestPermission());
    if (typeof DeviceOrientationEvent !== 'undefined' && DeviceOrientationEvent.requestPermission) ask.push(DeviceOrientationEvent.requestPermission());
    return Promise.all(ask)
      .then((results) => { this.granted = results.every((r) => r === 'granted'); if (this.granted) this.attach(); return this.granted; })
      .catch(() => false);
  }

  attach() {
    if (this.attached || typeof window === 'undefined') return;
    this.attached = true;
    this.granted = true;
    window.addEventListener('devicemotion', (e) => this._onMotion(e));
  }

  _onMotion(e) {
    const g = e.accelerationIncludingGravity;
    if (g && g.x != null && g.y != null) {
      // Works for both sign conventions: upright portrait has |y| ≈ 9.8.
      const y = Math.abs(g.y) > 0.5 ? g.y : -9.8;
      const r = Math.atan2(g.x, Math.abs(y)) * (y > 0 ? -1 : 1);
      this.roll += (r - this.roll) * 0.25;
    }

    const rate = e.rotationRate;
    const now = performance.now();
    const dt = this._last ? Math.min(0.1, (now - this._last) / 1000) : 0;
    this._last = now;
    if (!rate || !dt) return;
    // Integrate pitch (beta) and yaw (gamma), then high-pass so only shake is removed (not intentional pans).
    this._angle.x += (rate.gamma || 0) * DEG * dt;
    this._angle.y += (rate.beta || 0) * DEG * dt;
    const k = 1 - Math.exp(-dt / 0.5);
    this._low.x += (this._angle.x - this._low.x) * k;
    this._low.y += (this._angle.y - this._low.y) * k;
    // ~52° × 67° portrait field of view → frame units per radian.
    this.offset.x = (this._angle.x - this._low.x) * 1.0;
    this.offset.y = (this._angle.y - this._low.y) * 0.75;
  }
}
