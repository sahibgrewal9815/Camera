// WebGL2 film renderer: video → (exposure, clarity, depth blur) → 3D LUT → halation, vignette, grain.
import { LUT_SIZE } from './looks.js';

const VERT = `#version 300 es
in vec2 aPos;
out vec2 vUv;
void main() {
  vUv = vec2(aPos.x * 0.5 + 0.5, 0.5 - aPos.y * 0.5); // top-left origin
  gl_Position = vec4(aPos, 0.0, 1.0);
}`;

// Shared source transform: output uv → video uv (mirror, crop/zoom, stabilization offset).
const SRC_UV = `
uniform vec4 uCrop;      // x, y, w, h of the visible part of the video (0..1)
uniform float uMirror;
vec2 srcUv(vec2 p) {
  if (uMirror > 0.5) p.x = 1.0 - p.x;
  return uCrop.xy + p * uCrop.zw;
}`;

// Small, very soft copy of the frame (used for clarity, halation, depth blur, histogram).
const BLUR_FRAG = `#version 300 es
precision highp float;
uniform sampler2D uVideo;
uniform vec2 uStep;
${SRC_UV}
in vec2 vUv;
out vec4 outColor;
void main() {
  vec3 c = vec3(0.0);
  float total = 0.0;
  for (int x = -3; x <= 3; x++) {
    for (int y = -3; y <= 3; y++) {
      float w = 1.0 - length(vec2(x, y)) / 5.0;
      if (w <= 0.0) continue;
      c += texture(uVideo, clamp(srcUv(vUv + vec2(x, y) * uStep), 0.001, 0.999)).rgb * w;
      total += w;
    }
  }
  outColor = vec4(c / total, 1.0);
}`;

const MAIN_FRAG = `#version 300 es
precision highp float;
precision highp sampler3D;
uniform sampler2D uVideo;
uniform sampler2D uBlur;
uniform sampler2D uMask;
uniform sampler3D uLut;
uniform float uIntensity, uGrain, uGrainSize, uClarity, uHalation, uVignette, uTime, uExposure, uAspect;
uniform float uDepth;      // 0 = off, 1 = strongest background blur
uniform float uHasMask;
uniform vec2 uBlurTexel;
${SRC_UV}
in vec2 vUv;
out vec4 outColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

vec3 softBlur(vec2 uv) {
  vec3 c = texture(uBlur, uv).rgb * 0.4;
  c += texture(uBlur, uv + vec2(uBlurTexel.x, 0.0)).rgb * 0.15;
  c += texture(uBlur, uv - vec2(uBlurTexel.x, 0.0)).rgb * 0.15;
  c += texture(uBlur, uv + vec2(0.0, uBlurTexel.y)).rgb * 0.15;
  c += texture(uBlur, uv - vec2(0.0, uBlurTexel.y)).rgb * 0.15;
  return c;
}

void main() {
  vec2 suv = srcUv(vUv);
  vec3 src = texture(uVideo, suv).rgb;
  vec3 blur = softBlur(vUv);

  // Depth: blur everything that isn't the subject.
  if (uDepth > 0.0 && uHasMask > 0.5) {
    float subject = smoothstep(0.35, 0.75, texture(uMask, suv).r);
    src = mix(src, blur, (1.0 - subject) * uDepth);
  }

  float exposure = exp2(uExposure);
  vec3 c = src * exposure;
  vec3 b = blur * exposure;
  c += (c - b) * uClarity;                                // clarity / softness

  vec3 g = texture(uLut, clamp(c, 0.0, 1.0) * (${(LUT_SIZE - 1).toFixed(1)} / ${LUT_SIZE.toFixed(1)}) + 0.5 / ${LUT_SIZE.toFixed(1)}).rgb;

  // Halation: red glow from bright areas (screen blend).
  float lum = dot(b, vec3(0.299, 0.587, 0.114));
  float hl = clamp((lum - 0.62) / 0.38, 0.0, 1.0);
  g = 1.0 - (1.0 - g) * (1.0 - vec3(1.0, 0.28, 0.12) * hl * hl * uHalation);

  // Vignette
  vec2 d = vUv - 0.5;
  d.x *= uAspect;
  float v = length(d) / length(vec2(0.5 * uAspect, 0.5));
  g *= 1.0 - uVignette * smoothstep(0.45, 1.05, v);

  // Film grain (stronger in the midtones, animated)
  float n = hash(floor(gl_FragCoord.xy / uGrainSize) + fract(uTime * 7.31) * 113.0) - 0.5;
  float mid = 1.0 - abs(dot(g, vec3(0.3333)) - 0.5) * 1.4;
  g = clamp(g + n * uGrain * mid, 0.0, 1.0);

  outColor = vec4(mix(clamp(c, 0.0, 1.0), g, uIntensity), 1.0);
}`;

function compile(gl, type, src) {
  const s = gl.createShader(type);
  gl.shaderSource(s, src);
  gl.compileShader(s);
  if (!gl.getShaderParameter(s, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(s));
  return s;
}

function program(gl, frag) {
  const p = gl.createProgram();
  gl.attachShader(p, compile(gl, gl.VERTEX_SHADER, VERT));
  gl.attachShader(p, compile(gl, gl.FRAGMENT_SHADER, frag));
  gl.bindAttribLocation(p, 0, 'aPos');
  gl.linkProgram(p);
  if (!gl.getProgramParameter(p, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(p));
  const uniforms = {};
  const count = gl.getProgramParameter(p, gl.ACTIVE_UNIFORMS);
  for (let i = 0; i < count; i++) {
    const name = gl.getActiveUniform(p, i).name;
    uniforms[name] = gl.getUniformLocation(p, name);
  }
  return { p, u: uniforms };
}

function texture2D(gl, filter = gl.LINEAR) {
  const t = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, t);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, 1, 1, 0, gl.RGBA, gl.UNSIGNED_BYTE, new Uint8Array([0, 0, 0, 255]));
  return t;
}

export class FilmRenderer {
  constructor(canvas) {
    const gl = canvas.getContext('webgl2', { preserveDrawingBuffer: true, alpha: false, antialias: false, premultipliedAlpha: false });
    if (!gl) throw new Error('WebGL2 is not available');
    this.gl = gl;
    this.canvas = canvas;
    this.main = program(gl, MAIN_FRAG);
    this.blurProg = program(gl, BLUR_FRAG);

    const vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    const buf = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buf);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1, -1, 1, -1, -1, 1, 1, 1]), gl.STATIC_DRAW);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);

    this.videoTex = texture2D(gl);
    this.maskTex = texture2D(gl);
    this.blurTex = texture2D(gl);
    this.blurFbo = gl.createFramebuffer();
    this.blurSize = [0, 0];

    this.lutTex = gl.createTexture();
    gl.bindTexture(gl.TEXTURE_3D, this.lutTex);
    for (const p of [gl.TEXTURE_MIN_FILTER, gl.TEXTURE_MAG_FILTER]) gl.texParameteri(gl.TEXTURE_3D, p, gl.LINEAR);
    for (const p of [gl.TEXTURE_WRAP_S, gl.TEXTURE_WRAP_T, gl.TEXTURE_WRAP_R]) gl.texParameteri(gl.TEXTURE_3D, p, gl.CLAMP_TO_EDGE);
    this.hasMask = false;
  }

  setLut(data) {
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_3D, this.lutTex);
    gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
    gl.texImage3D(gl.TEXTURE_3D, 0, gl.RGBA8, LUT_SIZE, LUT_SIZE, LUT_SIZE, 0, gl.RGBA, gl.UNSIGNED_BYTE, data);
  }

  /** Upload the current camera frame. Returns false if the video isn't ready. */
  uploadFrame(video) {
    if (!video || video.readyState < 2 || !video.videoWidth) return false;
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.videoTex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, video);
    return true;
  }

  uploadMask(mask) {
    if (!mask) { this.hasMask = false; return; }
    const gl = this.gl;
    gl.bindTexture(gl.TEXTURE_2D, this.maskTex);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, true);
    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, mask);
    gl.pixelStorei(gl.UNPACK_PREMULTIPLY_ALPHA_WEBGL, false);
    this.hasMask = true;
  }

  /**
   * Draw the frame into the canvas at width × height.
   * p: { crop:[x,y,w,h], mirror, exposure, intensity, grain, grainSize, clarity, halation, vignette, depth, time }
   */
  render(width, height, p) {
    const gl = this.gl;
    if (this.canvas.width !== width || this.canvas.height !== height) {
      this.canvas.width = width;
      this.canvas.height = height;
    }
    // 1. Soft low-res copy
    const bw = Math.max(16, Math.round(width / 10)), bh = Math.max(16, Math.round(height / 10));
    if (this.blurSize[0] !== bw || this.blurSize[1] !== bh) {
      gl.bindTexture(gl.TEXTURE_2D, this.blurTex);
      gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, bw, bh, 0, gl.RGBA, gl.UNSIGNED_BYTE, null);
      gl.bindFramebuffer(gl.FRAMEBUFFER, this.blurFbo);
      gl.framebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, this.blurTex, 0);
      this.blurSize = [bw, bh];
    }
    const b = this.blurProg;
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.blurFbo);
    gl.viewport(0, 0, bw, bh);
    gl.useProgram(b.p);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.videoTex);
    gl.uniform1i(b.u.uVideo, 0);
    gl.uniform2f(b.u.uStep, 1.6 / bw, 1.6 / bh);
    gl.uniform4fv(b.u.uCrop, p.crop);
    gl.uniform1f(b.u.uMirror, p.mirror ? 1 : 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);

    // 2. Final image
    const m = this.main;
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    gl.viewport(0, 0, width, height);
    gl.useProgram(m.p);
    gl.activeTexture(gl.TEXTURE0); gl.bindTexture(gl.TEXTURE_2D, this.videoTex); gl.uniform1i(m.u.uVideo, 0);
    gl.activeTexture(gl.TEXTURE1); gl.bindTexture(gl.TEXTURE_2D, this.blurTex); gl.uniform1i(m.u.uBlur, 1);
    gl.activeTexture(gl.TEXTURE2); gl.bindTexture(gl.TEXTURE_3D, this.lutTex); gl.uniform1i(m.u.uLut, 2);
    gl.activeTexture(gl.TEXTURE3); gl.bindTexture(gl.TEXTURE_2D, this.maskTex); gl.uniform1i(m.u.uMask, 3);
    gl.uniform4fv(m.u.uCrop, p.crop);
    gl.uniform1f(m.u.uMirror, p.mirror ? 1 : 0);
    gl.uniform1f(m.u.uExposure, p.exposure || 0);
    gl.uniform1f(m.u.uIntensity, p.intensity ?? 1);
    gl.uniform1f(m.u.uGrain, p.grain || 0);
    // Grain size scales with resolution so photos look like the preview.
    gl.uniform1f(m.u.uGrainSize, Math.max(1, (p.grainSize || 1) * Math.max(width, height) / 1600));
    gl.uniform1f(m.u.uClarity, p.clarity || 0);
    gl.uniform1f(m.u.uHalation, p.halation || 0);
    gl.uniform1f(m.u.uVignette, p.vignette || 0);
    gl.uniform1f(m.u.uDepth, p.depth || 0);
    gl.uniform1f(m.u.uHasMask, this.hasMask ? 1 : 0);
    gl.uniform1f(m.u.uTime, p.time || 0);
    gl.uniform1f(m.u.uAspect, width / height);
    gl.uniform2f(m.u.uBlurTexel, 1.5 / bw, 1.5 / bh);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  /** 64-bin luminance histogram from the soft copy (cheap). */
  histogram() {
    const gl = this.gl;
    const [w, h] = this.blurSize;
    if (!w) return null;
    const px = new Uint8Array(w * h * 4);
    gl.bindFramebuffer(gl.FRAMEBUFFER, this.blurFbo);
    gl.readPixels(0, 0, w, h, gl.RGBA, gl.UNSIGNED_BYTE, px);
    gl.bindFramebuffer(gl.FRAMEBUFFER, null);
    const bins = new Float32Array(64);
    for (let i = 0; i < px.length; i += 4) {
      const l = 0.299 * px[i] + 0.587 * px[i + 1] + 0.114 * px[i + 2];
      bins[Math.min(63, l >> 2)]++;
    }
    const max = Math.max(...bins) || 1;
    return bins.map((v) => v / max);
  }
}
