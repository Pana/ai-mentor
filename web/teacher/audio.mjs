import { VoiceActivityDetector, levelOf } from './vad.mjs';

const CHUNK_MS = 40;
const PREROLL_CHUNKS = 8; // ~320 ms: the first syllable starts before the detector is sure

/**
 * Mic capture at 16 kHz PCM16 with the browser's echo cancellation, voice activity detection, and playback of
 * the teacher's PCM16 audio, all on one AudioContext.
 *
 * Browsers only let a page make sound after a tap, so `unlock()` must be called from a click handler before
 * anything else; `start()` can then run later, once the server has said what it supports.
 */
export class TeacherAudio {
  onSpeechStart = null; onAudio = null; onSpeechEnd = null; onLevel = null;
  /** The mic went away (permission revoked, device unplugged) and could not be reopened. */
  onCaptureLost = null;
  strict = false;

  #ctx = null; #stream = null; #node = null; #source = null; #sink = null;
  #vad = new VoiceActivityDetector();
  #preroll = [];
  #muted = false;
  #outputRate = 24000;
  #nextTime = 0;
  #playing = new Set();
  #capture = false;
  #workletReady = false;
  #onVisible = () => { if (document.visibilityState === 'visible') this.#recover(); };

  /** Whether this browser can capture the mic here at all (needs HTTPS or localhost). */
  static get captureSupported() {
    return Boolean(navigator.mediaDevices?.getUserMedia && (window.AudioContext || window.webkitAudioContext) && window.AudioWorkletNode);
  }

  /** Call synchronously from a tap. */
  unlock() {
    const Context = window.AudioContext || window.webkitAudioContext;
    if (!Context) return;
    this.#ctx ??= new Context({ latencyHint: 'interactive' });
    this.#ctx.resume().catch(() => {});
  }

  get muted() { return this.#muted; }
  set muted(value) {
    this.#muted = value;
    for (const track of this.#stream?.getAudioTracks() ?? []) track.enabled = !value;
    if (value) this.resetDetection();
  }

  /** Forget a sentence in progress (it was cancelled); the next sound starts a new one. */
  resetDetection() { this.#vad.reset(); this.#preroll = []; }

  /** Starts the mic when `capture` is true. Throws when the mic cannot be opened; playback still works then. */
  async start({ capture, outputRate }) {
    this.#outputRate = outputRate;
    this.unlock();
    document.addEventListener('visibilitychange', this.#onVisible);
    this.#capture = capture;
    if (capture) await this.#openMic();
  }

  async #openMic() {
    this.#closeMic();
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true, autoGainControl: true } });
    const ctx = this.#ctx;
    try {
      if (!this.#workletReady) await ctx.audioWorklet.addModule('capture-worklet.mjs');
      this.#workletReady = true;
    } catch (error) {
      for (const track of stream.getTracks()) track.stop();
      throw error;
    }
    this.#stream = stream;
    this.#source = ctx.createMediaStreamSource(stream);
    this.#node = new AudioWorkletNode(ctx, 'capture', { numberOfInputs: 1, numberOfOutputs: 1 });
    this.#node.port.onmessage = event => this.#chunk(new Int16Array(event.data));
    // The worklet only runs while it leads to the output; a silent gain keeps the mic out of the speaker.
    this.#sink = ctx.createGain();
    this.#sink.gain.value = 0;
    this.#source.connect(this.#node).connect(this.#sink).connect(ctx.destination);
    for (const track of stream.getAudioTracks()) {
      track.enabled = !this.#muted;
      track.addEventListener('ended', () => { if (this.#stream === stream) this.#recover(); });
    }
  }

  #closeMic() {
    for (const track of this.#stream?.getTracks() ?? []) track.stop();
    this.#source?.disconnect(); this.#node?.disconnect(); this.#sink?.disconnect();
    if (this.#node) this.#node.port.onmessage = null;
    this.#stream = null; this.#source = null; this.#node = null; this.#sink = null;
    this.resetDetection();
  }

  stop() {
    document.removeEventListener('visibilitychange', this.#onVisible);
    this.stopPlayback();
    this.#closeMic();
    this.#capture = false;
    this.#ctx?.close().catch(() => {});
    this.#ctx = null;
    this.#workletReady = false;
  }

  /** The browser suspends audio when the page is hidden or a call comes in; pick up again when it is back. */
  async #recover() {
    const ctx = this.#ctx;
    if (!ctx) return;
    if (ctx.state !== 'running') await ctx.resume().catch(() => {});
    if (!this.#capture || this.#stream?.getAudioTracks().some(track => track.readyState === 'live')) return;
    try { await this.#openMic(); } catch { this.#capture = false; this.onCaptureLost?.(); }
  }

  #chunk(samples) {
    if (this.#muted) { this.onLevel?.(0); return; }
    const level = levelOf(samples);
    const wasSpeaking = this.#vad.speaking;
    const event = this.#vad.process(level, CHUNK_MS, this.strict);
    this.onLevel?.(Math.max(0, Math.min(1, (level + 60) / 45)));
    const bytes = new Uint8Array(samples.buffer);
    if (event === 'start') {
      this.onSpeechStart?.();
      for (const earlier of this.#preroll) this.onAudio?.(earlier);
      this.#preroll = [];
      this.onAudio?.(bytes);
    } else if (wasSpeaking && event !== 'end') {
      this.onAudio?.(bytes);
    } else if (event === 'end') {
      this.onSpeechEnd?.();
    } else {
      this.#preroll.push(bytes);
      if (this.#preroll.length > PREROLL_CHUNKS) this.#preroll.shift();
    }
  }

  /**
   * Queues PCM16LE mono audio (a Uint8Array of whole samples). `played` runs once it has been heard.
   * Returns false, without calling `played`, when nothing can be played right now.
   */
  play(pcm, played) {
    const ctx = this.#ctx, frames = pcm.byteLength >> 1;
    if (!ctx || !frames) return false;
    if (ctx.state !== 'running') { ctx.resume().catch(() => {}); return false; } // e.g. iOS paused it; this segment is shown as text
    const buffer = ctx.createBuffer(1, frames, this.#outputRate);
    const channel = buffer.getChannelData(0);
    const view = new DataView(pcm.buffer, pcm.byteOffset, frames * 2);
    for (let i = 0; i < frames; i++) channel[i] = view.getInt16(i * 2, true) / 32768;
    const source = ctx.createBufferSource();
    source.buffer = buffer;
    source.connect(ctx.destination);
    const at = Math.max(ctx.currentTime + 0.03, this.#nextTime);
    this.#nextTime = at + buffer.duration;
    this.#playing.add(source);
    source.onended = () => { this.#playing.delete(source); played?.(); };
    source.start(at);
    return true;
  }

  /** Drops everything queued (a barge-in). Their `played` callbacks are not called. */
  stopPlayback() {
    for (const source of this.#playing) { source.onended = null; try { source.stop(); } catch { /* not started */ } }
    this.#playing.clear();
    this.#nextTime = 0;
  }
}
