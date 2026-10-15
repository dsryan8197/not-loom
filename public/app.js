'use strict';

/*
 * not-loom: record your screen with your camera in a bubble.
 *
 * How it works:
 *   screen (getDisplayMedia) ─┐
 *                              ├─> drawn onto a <canvas> ─> canvas.captureStream() ─┐
 *   camera (getUserMedia) ────┘                                                     ├─> MediaRecorder ─> file
 *   mic + optional tab/system audio ─> Web Audio mix ─> MediaStreamDestination ─────┘
 *                                           └─> AnalyserNode ─> level meter
 *
 * The floating controls window uses Chrome's Document Picture-in-Picture API, which
 * stays on top of every app, so the Stop button is always one click away.
 */

// ---------- helpers ----------
const $ = (sel, root = document) => root.querySelector(sel);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const clamp = (v, lo, hi) => Math.min(hi, Math.max(lo, v));
const even = (n) => Math.max(2, Math.round(n / 2) * 2);
const stopStream = (s) => s?.getTracks().forEach((t) => t.stop());

const BUBBLE_SIZES = { s: 0.2, m: 0.28, l: 0.38 }; // diameter as a fraction of video height
const MAX_WIDTH = 2560; // keeps Retina recordings crisp but files reasonable
const FPS = 30;
const HEARD_DB = -50; // anything louder than this counts as "picking up audio"
// H.264 + AAC MP4 opens in QuickTime. Without those codecs, WebM is the honest
// choice: an MP4 holding VP9/Opus wouldn't open in QuickTime either.
const MIME_CANDIDATES = [
  'video/mp4;codecs=avc1,mp4a.40.2',
  'video/mp4;codecs=avc1.42E01E,mp4a.40.2',
  'video/webm;codecs=vp9,opus',
  'video/webm;codecs=vp8,opus',
  'video/webm',
  'video/mp4',
];

// ---------- settings (remembered between visits) ----------
const SETTINGS_KEY = 'not-loom:settings';
const DEFAULTS = {
  camId: 'default', micId: 'default', position: 'br', size: 'm',
  sysAudio: false, countdown: true, autoDownload: true,
};
const settings = (() => {
  try { return { ...DEFAULTS, ...JSON.parse(localStorage.getItem(SETTINGS_KEY) || '{}') }; }
  catch { return { ...DEFAULTS }; }
})();
function saveSettings() {
  try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch { /* private mode */ }
}

// ---------- DOM ----------
const el = {
  error: $('#error'),
  setup: $('#setup'), recording: $('#recording'), done: $('#done'),
  bubble: $('#bubble'), camPreview: $('#camPreview'),
  camSelect: $('#camSelect'), micSelect: $('#micSelect'),
  posSeg: $('#posSeg'), sizeSeg: $('#sizeSeg'),
  sysAudio: $('#sysAudio'), countdownChk: $('#countdown'), autoDownload: $('#autoDownload'),
  startBtn: $('#startBtn'), stopHint: $('#stopHint'),
  recDot: $('#recDot'), timer: $('#timer'), recState: $('#recState'),
  pauseBtn: $('#pauseBtn'), muteBtn: $('#muteBtn'), stopBtn: $('#stopBtn'),
  result: $('#result'), savedNote: $('#savedNote'), downloadLink: $('#downloadLink'), againBtn: $('#againBtn'),
  countdown: $('#countdown'),
};

// ---------- state ----------
const state = {
  phase: 'setup', // setup | countdown | recording | saving | done
  camStream: null,
  micStream: null,
  // audio graph
  audioCtx: null, micSource: null, micGain: null, analyser: null, mixDest: null, displaySource: null,
  meterBuf: null, level: 0, lastHeardAt: -Infinity,
  // capture
  screenStream: null, screenSrc: null, camSrc: null,
  canvas: null, ctx: null, recordStream: null,
  recorder: null, chunks: [],
  startedAt: 0, pausedAt: 0, pausedTotal: 0,
  muted: false,
  pip: null,
  resultUrl: null,
};

function showError(msg) { el.error.textContent = msg; el.error.hidden = false; }
function hideError() { el.error.hidden = true; }

// ---------- audio ----------
function setupAudio() {
  const ctx = new AudioContext();
  const micGain = ctx.createGain();
  const analyser = ctx.createAnalyser();
  analyser.fftSize = 1024;
  const mixDest = ctx.createMediaStreamDestination();
  // Some browsers only process nodes that lead to the speakers, so route the
  // analyser to the output through a silent gain.
  const silent = ctx.createGain();
  silent.gain.value = 0;

  micGain.connect(analyser);
  micGain.connect(mixDest);
  analyser.connect(silent).connect(ctx.destination);

  Object.assign(state, { audioCtx: ctx, micGain, analyser, mixDest, meterBuf: new Float32Array(analyser.fftSize) });

  // Browsers keep audio suspended until the first click/keypress.
  const wake = () => { if (ctx.state === 'suspended') ctx.resume(); };
  document.addEventListener('pointerdown', wake);
  document.addEventListener('keydown', wake);
}

async function startMic(id) {
  stopStream(state.micStream);
  state.micStream = null;
  state.micSource?.disconnect();
  state.micSource = null;
  if (id === 'none') return;

  const audio = { echoCancellation: true, noiseSuppression: true, autoGainControl: true };
  if (id && id !== 'default') audio.deviceId = { exact: id };
  try {
    state.micStream = await navigator.mediaDevices.getUserMedia({ audio });
  } catch (err) {
    if (audio.deviceId) return startMic('default'); // saved device unplugged
    showError(`Couldn't open a microphone (${err.name}). Check the browser's site permissions and System Settings → Privacy & Security → Microphone.`);
    return;
  }
  state.micSource = state.audioCtx.createMediaStreamSource(state.micStream);
  state.micSource.connect(state.micGain);
}

// ---------- camera ----------
async function startCamera(id) {
  stopStream(state.camStream);
  state.camStream = null;
  el.camPreview.srcObject = null;
  if (id !== 'none') {
    const video = { width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 } };
    if (id && id !== 'default') video.deviceId = { exact: id };
    try {
      state.camStream = await navigator.mediaDevices.getUserMedia({ video });
      el.camPreview.srcObject = state.camStream;
    } catch (err) {
      if (video.deviceId) return startCamera('default');
      showError(`Couldn't open a camera (${err.name}). Check the browser's site permissions and System Settings → Privacy & Security → Camera.`);
    }
  }
  renderBubble();
}

// ---------- device pickers ----------
async function refreshDevices() {
  const devices = await navigator.mediaDevices.enumerateDevices();
  fillSelect(el.camSelect, devices.filter((d) => d.kind === 'videoinput'), 'No camera', state.camStream);
  fillSelect(el.micSelect, devices.filter((d) => d.kind === 'audioinput'), 'No microphone (silent video)', state.micStream);
}

function fillSelect(select, devices, noneLabel, activeStream) {
  const activeId = activeStream?.getTracks()[0]?.getSettings().deviceId;
  select.replaceChildren(new Option(noneLabel, 'none'));
  devices
    .filter((d) => d.deviceId && d.deviceId !== 'default' && d.deviceId !== 'communications')
    .forEach((d, i) => select.add(new Option(d.label || `Device ${i + 1}`, d.deviceId)));
  select.value = activeStream ? activeId : 'none';
  if (!select.value) select.selectedIndex = activeStream && select.options.length > 1 ? 1 : 0;
}

// ---------- bubble preview ----------
function renderBubble() {
  el.bubble.dataset.pos = settings.position;
  el.bubble.style.setProperty('--d', BUBBLE_SIZES[settings.size]);
  el.bubble.hidden = !state.camStream;
  for (const b of el.posSeg.querySelectorAll('button')) b.setAttribute('aria-checked', b.dataset.pos === settings.position);
  for (const b of el.sizeSeg.querySelectorAll('button')) b.setAttribute('aria-checked', b.dataset.size === settings.size);
}

// ---------- frame sources ----------
// Prefer MediaStreamTrackProcessor (Chrome): it keeps delivering frames even when
// this tab is hidden behind the app you're recording. Fall back to a <video>.
function makeFrameSource(track) {
  if ('MediaStreamTrackProcessor' in window) {
    const reader = new MediaStreamTrackProcessor({ track }).readable.getReader();
    const src = {
      frame: null, width: 0, height: 0,
      stop() { reader.cancel().catch(() => {}); src.frame?.close(); src.frame = null; },
    };
    (async () => {
      try {
        for (;;) {
          const { value, done } = await reader.read();
          if (done) break;
          src.frame?.close();
          src.frame = value;
          src.width = value.displayWidth;
          src.height = value.displayHeight;
        }
      } catch { /* track ended */ }
    })();
    return src;
  }
  const v = document.createElement('video');
  v.muted = true;
  v.playsInline = true;
  v.srcObject = new MediaStream([track]);
  v.play().catch(() => {});
  return {
    get frame() { return v.readyState >= 2 ? v : null; },
    get width() { return v.videoWidth; },
    get height() { return v.videoHeight; },
    stop() { v.srcObject = null; },
  };
}

// ---------- compositing ----------
function drawFrame() {
  const { ctx, canvas, screenSrc, camSrc } = state;
  const W = canvas.width, H = canvas.height;

  if (screenSrc.frame && screenSrc.width) {
    // Contain-fit, in case the shared window is resized mid-recording.
    const s = Math.min(W / screenSrc.width, H / screenSrc.height);
    const dw = screenSrc.width * s, dh = screenSrc.height * s;
    ctx.fillStyle = '#000';
    ctx.fillRect(0, 0, W, H);
    ctx.drawImage(screenSrc.frame, (W - dw) / 2, (H - dh) / 2, dw, dh);
  }

  if (camSrc?.frame && camSrc.width) {
    const d = H * BUBBLE_SIZES[settings.size];
    const m = H * 0.03;
    const left = settings.position.endsWith('l');
    const top = settings.position.startsWith('t');
    const cx = left ? m + d / 2 : W - m - d / 2;
    const cy = top ? m + d / 2 : H - m - d / 2;
    const side = Math.min(camSrc.width, camSrc.height);
    const sx = (camSrc.width - side) / 2, sy = (camSrc.height - side) / 2;

    ctx.save();
    ctx.beginPath();
    ctx.arc(cx, cy, d / 2, 0, Math.PI * 2);
    ctx.clip();
    ctx.translate(cx, cy);
    ctx.scale(-1, 1); // mirror, like looking in a mirror
    ctx.drawImage(camSrc.frame, sx, sy, side, side, -d / 2, -d / 2, d, d);
    ctx.restore();

    ctx.beginPath();
    ctx.arc(cx, cy, d / 2, 0, Math.PI * 2);
    ctx.lineWidth = Math.max(3, d * 0.025);
    ctx.strokeStyle = 'rgba(255,255,255,0.9)';
    ctx.stroke();
  }
}

// ---------- meter ----------
function meterTargets() {
  const targets = [...document.querySelectorAll('[data-meter]')];
  if (state.pip) targets.push(...state.pip.win.document.querySelectorAll('[data-meter]'));
  return targets;
}

function meterStatus(now) {
  const hasMic = !!state.micStream, hasSys = !!state.displaySource;
  if (!hasMic && !hasSys) return { text: 'No audio — this video will be silent', tone: 'off' };
  if (state.audioCtx.state !== 'running') return { text: 'Click anywhere to wake up the meter', tone: 'warn' };
  const heard = now - state.lastHeardAt < 1500;
  if (state.muted) return heard ? { text: 'Mic muted · recording computer audio', tone: 'ok' } : { text: 'Mic muted', tone: 'warn' };
  if (heard) return { text: 'Picking up audio', tone: 'ok' };
  return { text: 'Silent — say something to test', tone: 'warn' };
}

function updateMeter() {
  const { analyser, meterBuf } = state;
  analyser.getFloatTimeDomainData(meterBuf);
  let sum = 0;
  for (let i = 0; i < meterBuf.length; i++) sum += meterBuf[i] * meterBuf[i];
  const db = 20 * Math.log10(Math.sqrt(sum / meterBuf.length) || 1e-8);
  const now = performance.now();
  if (db > HEARD_DB) state.lastHeardAt = now;
  // -60 dB..0 dB → 0..1, fast attack, slow release
  state.level = Math.max(clamp((db + 60) / 60, 0, 1), state.level * 0.88);

  const status = meterStatus(now);
  for (const m of meterTargets()) {
    m.querySelector('[data-meter-mask]').style.width = `${(1 - state.level) * 100}%`;
    const s = m.querySelector('[data-meter-status]');
    if (s.textContent !== status.text) s.textContent = status.text;
    s.dataset.tone = status.tone;
  }
}

// ---------- timer / controls ----------
function elapsedMs() {
  if (state.phase !== 'recording') return 0;
  const now = performance.now();
  return now - state.startedAt - state.pausedTotal - (state.pausedAt ? now - state.pausedAt : 0);
}

function fmt(ms) {
  const t = Math.floor(ms / 1000);
  const h = Math.floor(t / 3600), m = Math.floor((t % 3600) / 60), s = t % 60;
  const mm = String(m).padStart(2, '0'), ss = String(s).padStart(2, '0');
  return h ? `${h}:${mm}:${ss}` : `${mm}:${ss}`;
}

function updateTimer() {
  const text = fmt(elapsedMs());
  if (el.timer.textContent !== text) {
    el.timer.textContent = text;
    if (state.pip) state.pip.timer.textContent = text;
    document.title = `${state.pausedAt ? '❚❚' : '●'} ${text} · not-loom`;
  }
}

function updateControls() {
  const paused = !!state.pausedAt;
  const label = {
    countdown: 'Starting…', saving: 'Saving…', recording: paused ? 'Paused' : 'Recording',
  }[state.phase] || '';
  el.recState.textContent = label;
  el.recDot.classList.toggle('paused', paused);
  el.pauseBtn.textContent = paused ? 'Resume' : 'Pause';
  el.muteBtn.textContent = state.muted ? 'Unmute mic' : 'Mute mic';
  el.muteBtn.disabled = !state.micStream || state.phase !== 'recording';
  el.pauseBtn.disabled = state.phase !== 'recording';
  el.stopBtn.disabled = state.phase === 'saving';

  const p = state.pip;
  if (p) {
    p.dot.classList.toggle('paused', paused);
    p.state.textContent = label;
    p.pause.textContent = paused ? 'Resume' : 'Pause';
    p.mute.textContent = state.muted ? 'Unmute' : 'Mute';
    p.mute.disabled = el.muteBtn.disabled;
    p.pause.disabled = el.pauseBtn.disabled;
    p.stop.disabled = el.stopBtn.disabled;
  }
}

function setPhase(phase) {
  state.phase = phase;
  el.setup.hidden = phase !== 'setup';
  el.recording.hidden = !['countdown', 'recording', 'saving'].includes(phase);
  el.done.hidden = phase !== 'done';
  if (phase === 'setup' || phase === 'done') document.title = 'not-loom';
  updateControls();
}

// ---------- floating controls (Document Picture-in-Picture) ----------
const PIP_CSS = `
  * { box-sizing: border-box; }
  body { margin: 0; padding: 12px 14px; background: #17171c; color: #ececf1;
         font: 13px/1.3 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
         display: flex; flex-direction: column; gap: 9px; user-select: none; }
  .head { display: flex; align-items: center; gap: 8px; }
  .dot { width: 10px; height: 10px; border-radius: 50%; background: #e5484d; animation: pulse 1.2s infinite; }
  .dot.paused { animation: none; background: #e0a72a; }
  @keyframes pulse { 50% { opacity: .25; } }
  .timer { font: 600 18px ui-monospace, Menlo, monospace; font-variant-numeric: tabular-nums; }
  .state { color: #9a9aa6; margin-left: auto; }
  .meter { position: relative; height: 10px; border-radius: 5px; overflow: hidden;
           background: linear-gradient(90deg, #2f9e5b 0%, #4cc27a 60%, #e0a72a 82%, #e5484d 100%); }
  .mask { position: absolute; top: 0; right: 0; bottom: 0; width: 100%; background: #2a2a32; }
  .status { font-size: 12px; font-weight: 600; color: #9a9aa6; }
  .status[data-tone="ok"] { color: #4cc27a; }
  .status[data-tone="warn"] { color: #e0a72a; }
  .buttons { display: flex; gap: 6px; }
  button { font: 600 13px -apple-system, BlinkMacSystemFont, sans-serif; border: 0; border-radius: 8px;
           padding: 8px 10px; cursor: pointer; background: #2c2c35; color: #ececf1; }
  button:disabled { opacity: .4; cursor: default; }
  .stop { flex: 1; background: #e5484d; color: #fff; display: flex; align-items: center; justify-content: center; gap: 7px; }
  .stop:hover { background: #d13a40; }
  .sq { width: 10px; height: 10px; background: #fff; border-radius: 2px; }
  .count { position: fixed; inset: 0; display: grid; place-items: center; background: #17171c;
           font: 700 64px -apple-system, sans-serif; }
  .count[hidden] { display: none; }
`;

const PIP_HTML = `
  <div class="head"><span class="dot"></span><span class="timer">00:00</span><span class="state"></span></div>
  <div data-meter>
    <div class="meter"><div class="mask" data-meter-mask></div></div>
    <div class="status" data-meter-status></div>
  </div>
  <div class="buttons">
    <button data-act="pause">Pause</button>
    <button data-act="mute">Mute</button>
    <button class="stop" data-act="stop"><span class="sq"></span>Stop &amp; save</button>
  </div>
  <div class="count" hidden></div>
`;

async function openPip() {
  if (!('documentPictureInPicture' in window)) return null;
  try {
    const win = await window.documentPictureInPicture.requestWindow({ width: 320, height: 132 });
    const doc = win.document;
    doc.title = 'not-loom';
    const style = doc.createElement('style');
    style.textContent = PIP_CSS;
    doc.head.append(style);
    doc.body.innerHTML = PIP_HTML;

    const pip = {
      win,
      dot: $('.dot', doc), timer: $('.timer', doc), state: $('.state', doc), count: $('.count', doc),
      pause: $('[data-act=pause]', doc), mute: $('[data-act=mute]', doc), stop: $('[data-act=stop]', doc),
    };
    pip.pause.addEventListener('click', togglePause);
    pip.mute.addEventListener('click', toggleMute);
    pip.stop.addEventListener('click', stopRecording);
    doc.addEventListener('keydown', onKey);
    win.addEventListener('pagehide', () => { if (state.pip?.win === win) state.pip = null; });

    state.pip = pip;
    updateControls();
    return pip;
  } catch (err) {
    console.warn('Floating controls unavailable:', err);
    return null;
  }
}

function closePip() {
  const win = state.pip?.win;
  state.pip = null;
  win?.close();
}

function showCountdown(n) {
  el.countdown.hidden = n == null;
  el.countdown.textContent = n ?? '';
  if (state.pip) {
    state.pip.count.hidden = n == null;
    state.pip.count.textContent = n ?? '';
  }
}

// ---------- recording ----------
function pickMime() {
  return MIME_CANDIDATES.find((m) => MediaRecorder.isTypeSupported(m)) || '';
}

async function startRecording() {
  if (state.phase !== 'setup' && state.phase !== 'done') return;
  hideError();
  state.audioCtx.resume();

  // Both of these need the click's "user activation", so start them before any await.
  // getDisplayMedia goes first: Safari/Firefox check activation for it, while
  // Chrome's Picture-in-Picture call consumes the activation.
  const wantSys = settings.sysAudio;
  let screenP;
  try {
    screenP = navigator.mediaDevices.getDisplayMedia({
      video: { frameRate: { ideal: FPS } },
      audio: wantSys,
      selfBrowserSurface: 'exclude',
      surfaceSwitching: 'include',
      systemAudio: wantSys ? 'include' : 'exclude',
    });
  } catch (err) {
    screenP = Promise.reject(err);
  }
  const pipP = openPip();

  let screen;
  try {
    screen = await screenP;
  } catch (err) {
    await pipP;
    closePip();
    if (err.name !== 'NotAllowedError' && err.name !== 'AbortError') {
      showError(`Couldn't capture the screen (${err.name}: ${err.message}).`);
    } else if (/by system/i.test(err.message)) {
      showError('Screen capture was blocked. On macOS, allow your browser in System Settings → Privacy & Security → Screen & System Audio Recording, then restart the browser.');
    }
    return;
  }
  await pipP;

  const vTrack = screen.getVideoTracks()[0];
  vTrack.addEventListener('ended', stopRecording); // browser's own "Stop sharing" button
  state.screenStream = screen;
  state.screenSrc = makeFrameSource(vTrack);
  const camTrack = state.camStream?.getVideoTracks()[0];
  state.camSrc = camTrack ? makeFrameSource(camTrack) : null;

  const { width = 1920, height = 1080 } = vTrack.getSettings();
  const scale = Math.min(1, MAX_WIDTH / width);
  state.canvas = document.createElement('canvas');
  state.canvas.width = even(width * scale);
  state.canvas.height = even(height * scale);
  state.ctx = state.canvas.getContext('2d', { alpha: false });
  state.ctx.fillStyle = '#000';
  state.ctx.fillRect(0, 0, state.canvas.width, state.canvas.height);

  const sysTracks = screen.getAudioTracks();
  if (sysTracks.length) {
    state.displaySource = state.audioCtx.createMediaStreamSource(new MediaStream(sysTracks));
    state.displaySource.connect(state.mixDest);
    state.displaySource.connect(state.analyser);
  }

  const tracks = [...state.canvas.captureStream(FPS).getVideoTracks()];
  if (state.micStream || state.displaySource) tracks.push(state.mixDest.stream.getAudioTracks()[0]);
  state.recordStream = new MediaStream(tracks);

  setPhase('countdown');
  if (settings.countdown) {
    for (const n of [3, 2, 1]) {
      showCountdown(n);
      await sleep(1000);
      if (state.phase !== 'countdown') return; // cancelled
    }
  }
  showCountdown(null);

  const mimeType = pickMime();
  const { width: W, height: H } = state.canvas;
  try {
    state.recorder = new MediaRecorder(state.recordStream, {
      mimeType,
      videoBitsPerSecond: clamp(Math.round(W * H * FPS * 0.08), 2_500_000, 12_000_000),
      audioBitsPerSecond: 128_000,
    });
  } catch (err) {
    cleanupCapture();
    setPhase('setup');
    showError(`This browser can't record video (${err.message}). Try Chrome.`);
    return;
  }
  state.chunks = [];
  state.recorder.ondataavailable = (e) => { if (e.data.size) state.chunks.push(e.data); };
  state.recorder.onstop = finishRecording;
  state.recorder.onerror = (e) => { showError(`Recording error: ${e.error?.message || e.error || 'unknown'}`); stopRecording(); };
  state.recorder.start(1000);

  state.startedAt = performance.now();
  state.pausedAt = 0;
  state.pausedTotal = 0;
  setPhase('recording');
}

function stopRecording() {
  if (state.phase === 'countdown') {
    showCountdown(null);
    cleanupCapture();
    setPhase('setup');
    return;
  }
  if (state.phase !== 'recording') return;
  if (state.pausedAt) state.recorder.resume();
  setPhase('saving');
  state.recorder.stop(); // → finishRecording
}

function togglePause() {
  if (state.phase !== 'recording') return;
  const r = state.recorder;
  if (r.state === 'recording') {
    r.pause();
    state.pausedAt = performance.now();
  } else if (r.state === 'paused') {
    r.resume();
    state.pausedTotal += performance.now() - state.pausedAt;
    state.pausedAt = 0;
  }
  updateControls();
  updateTimer();
}

function toggleMute() {
  if (state.phase !== 'recording' || !state.micStream) return;
  state.muted = !state.muted;
  state.micGain.gain.setValueAtTime(state.muted ? 0 : 1, state.audioCtx.currentTime);
  updateControls();
}

function cleanupCapture() {
  stopStream(state.screenStream);
  state.screenSrc?.stop();
  state.camSrc?.stop();
  // Only stop the canvas track: the audio track belongs to the reusable mix bus.
  state.recordStream?.getVideoTracks().forEach((t) => t.stop());
  state.displaySource?.disconnect();
  Object.assign(state, {
    screenStream: null, screenSrc: null, camSrc: null, recordStream: null,
    displaySource: null, canvas: null, ctx: null, pausedAt: 0, muted: false,
  });
  state.micGain.gain.setValueAtTime(1, state.audioCtx.currentTime);
  closePip();
}

function timestamp() {
  const d = new Date();
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} at ${p(d.getHours())}.${p(d.getMinutes())}.${p(d.getSeconds())}`;
}

function finishRecording() {
  const type = state.recorder.mimeType || 'video/webm';
  const blob = new Blob(state.chunks, { type });
  state.chunks = [];
  cleanupCapture();

  if (state.resultUrl) URL.revokeObjectURL(state.resultUrl);
  state.resultUrl = URL.createObjectURL(blob);
  const name = `not-loom ${timestamp()}.${type.includes('mp4') ? 'mp4' : 'webm'}`;
  const mb = (blob.size / 1e6).toFixed(1);

  el.result.src = state.resultUrl;
  el.downloadLink.href = state.resultUrl;
  el.downloadLink.download = name;
  el.savedNote.textContent = settings.autoDownload
    ? `Saved to your Downloads folder as “${name}” (${mb} MB).`
    : `“${name}” (${mb} MB) is ready. Click Download to save it.`;
  el.downloadLink.textContent = settings.autoDownload ? 'Download again' : 'Download';
  if (settings.autoDownload) el.downloadLink.click();

  setPhase('done');
  window.focus();
}

// ---------- keyboard ----------
function onKey(e) {
  if (!['countdown', 'recording'].includes(state.phase)) return;
  if (e.metaKey || e.ctrlKey || e.altKey) return;
  const k = e.key.toLowerCase();
  if (k === 'escape') { e.preventDefault(); stopRecording(); }
  else if (k === 'p') { e.preventDefault(); togglePause(); }
  else if (k === 'm') { e.preventDefault(); toggleMute(); }
}

// ---------- ticker ----------
// Timers on a hidden tab get throttled to once a second; timers inside a worker
// don't, so a worker drives the frame loop while you're in another app.
function startTicker(onTick) {
  const src = 'let id; onmessage = (e) => { clearInterval(id); id = setInterval(() => postMessage(0), e.data); };';
  const worker = new Worker(URL.createObjectURL(new Blob([src], { type: 'text/javascript' })));
  worker.onmessage = onTick;
  worker.postMessage(1000 / FPS);
}

function tick() {
  if (state.ctx) drawFrame();
  updateMeter();
  if (state.phase === 'recording') updateTimer();
}

// ---------- wiring ----------
function bindUI() {
  el.sysAudio.checked = settings.sysAudio;
  el.countdownChk.checked = settings.countdown;
  el.autoDownload.checked = settings.autoDownload;

  el.camSelect.addEventListener('change', async () => {
    settings.camId = el.camSelect.value;
    saveSettings();
    await startCamera(settings.camId);
  });
  el.micSelect.addEventListener('change', async () => {
    settings.micId = el.micSelect.value;
    saveSettings();
    await startMic(settings.micId);
  });
  el.posSeg.addEventListener('click', (e) => {
    const pos = e.target.closest('button')?.dataset.pos;
    if (pos) { settings.position = pos; saveSettings(); renderBubble(); }
  });
  el.sizeSeg.addEventListener('click', (e) => {
    const size = e.target.closest('button')?.dataset.size;
    if (size) { settings.size = size; saveSettings(); renderBubble(); }
  });
  for (const [box, key] of [[el.sysAudio, 'sysAudio'], [el.countdownChk, 'countdown'], [el.autoDownload, 'autoDownload']]) {
    box.addEventListener('change', () => { settings[key] = box.checked; saveSettings(); });
  }

  el.startBtn.addEventListener('click', startRecording);
  el.againBtn.addEventListener('click', () => setPhase('setup'));
  el.stopBtn.addEventListener('click', stopRecording);
  el.pauseBtn.addEventListener('click', togglePause);
  el.muteBtn.addEventListener('click', toggleMute);
  document.addEventListener('keydown', onKey);

  window.addEventListener('beforeunload', (e) => {
    if (['countdown', 'recording', 'saving'].includes(state.phase)) e.preventDefault();
  });
  navigator.mediaDevices.addEventListener?.('devicechange', () => refreshDevices().catch(() => {}));

  el.stopHint.innerHTML = 'documentPictureInPicture' in window
    ? 'A small <b>floating window</b> with a red <b>Stop &amp; save</b> button stays on top of everything while you record. You can also press <kbd>Esc</kbd> in it.'
    : 'Floating controls need Chrome or Edge. In this browser, come back to this tab to stop, or use the browser’s own “Stop sharing” button.';
}

async function init() {
  if (!navigator.mediaDevices?.getDisplayMedia || !window.MediaRecorder) {
    showError('This browser can’t record the screen. Use a recent Chrome (recommended), Edge, or Safari.');
    el.startBtn.disabled = true;
    return;
  }
  if (!window.isSecureContext) {
    showError('Open this page from http://localhost (run `npm start`), not as a file, or the browser will block the camera and mic.');
  }

  setupAudio();
  bindUI();
  renderBubble();
  setPhase('setup');
  startTicker(tick);

  await Promise.all([startCamera(settings.camId), startMic(settings.micId)]);
  await refreshDevices();
}

init();
