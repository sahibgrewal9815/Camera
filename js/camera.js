// Camera stream: lenses, resolution, torch, microphone.

export class CameraStream {
  constructor(video) {
    this.video = video;
    this.stream = null;
    this.audioStream = null;
    this.devices = [];
    this.track = null;
    this.isFront = false;
    this.torchSupported = false;
  }

  async refreshDevices() {
    const all = await navigator.mediaDevices.enumerateDevices();
    this.devices = all.filter((d) => d.kind === 'videoinput');
  }

  /** Back lenses found on this phone: { ultra, wide, tele } deviceIds (labels come from iOS). */
  backLenses() {
    const back = this.devices.filter((d) => !/front|user|facetime/i.test(d.label));
    const find = (re) => back.find((d) => re.test(d.label));
    const wide = back.find((d) => /^back camera$/i.test(d.label.trim())) ||
      back.find((d) => !/ultra|tele|dual|triple/i.test(d.label)) || back[0];
    return {
      ultra: find(/ultra/i)?.deviceId,
      wide: wide?.deviceId,
      tele: find(/tele/i)?.deviceId,
    };
  }

  frontDevice() {
    return this.devices.find((d) => /front|user|facetime/i.test(d.label))?.deviceId;
  }

  /**
   * @param {{deviceId?: string, facing?: 'user'|'environment', quality: 'photo'|'video', videoHeight?: number, fps?: number}} opts
   */
  async start(opts) {
    this.stop();
    // "fast" keeps the live view smooth; "high" gives 12MP photos but a slower viewfinder.
    const size = opts.quality === 'photo'
      ? (opts.photoRes === 'high' ? { width: { ideal: 4032 }, height: { ideal: 3024 } } : { width: { ideal: 1920 }, height: { ideal: 1440 } })
      : { width: { ideal: opts.videoHeight === 720 ? 1280 : 1920 }, height: { ideal: opts.videoHeight || 1080 }, frameRate: { ideal: opts.fps || 30 } };
    const video = opts.deviceId ? { deviceId: { exact: opts.deviceId }, ...size } : { facingMode: opts.facing || 'environment', ...size };

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ video, audio: false });
    } catch (e) {
      // Fall back to anything that works.
      this.stream = await navigator.mediaDevices.getUserMedia({ video: opts.deviceId ? { deviceId: { exact: opts.deviceId } } : { facingMode: opts.facing || 'environment' }, audio: false });
    }
    this.track = this.stream.getVideoTracks()[0];
    const settings = this.track.getSettings ? this.track.getSettings() : {};
    this.isFront = settings.facingMode === 'user' || /front|user|facetime/i.test(this.track.label || '');
    const caps = this.track.getCapabilities ? this.track.getCapabilities() : {};
    this.torchSupported = !!caps.torch;

    this.video.srcObject = this.stream;
    await this.video.play().catch(() => {});
    if (!this.devices.some((d) => d.label)) await this.refreshDevices();
    return settings;
  }

  stop() {
    this.stream?.getTracks().forEach((t) => t.stop());
    this.stream = null;
    this.track = null;
  }

  async setTorch(on) {
    if (!this.torchSupported || !this.track) return;
    try { await this.track.applyConstraints({ advanced: [{ torch: on }] }); } catch { /* not supported */ }
  }

  async audioTrack() {
    if (!this.audioStream || this.audioStream.getAudioTracks()[0]?.readyState !== 'live') {
      this.audioStream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: false, noiseSuppression: false, autoGainControl: true },
      });
    }
    return this.audioStream.getAudioTracks()[0];
  }

  stopAudio() {
    this.audioStream?.getTracks().forEach((t) => t.stop());
    this.audioStream = null;
  }
}
