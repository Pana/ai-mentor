import { TeacherAudio } from './audio.mjs';

/**
 * One voice-teacher conversation over `/v1/teacher` (protocol `littlebear.teacher.v1`, see `server/src/teacher.mjs`).
 *
 * The server streams a reply as segments: words to say plus whiteboard ops. A segment's ops are applied when
 * that segment starts playing, and the next segment starts when the last of its audio has been heard, so the
 * drawing follows the voice. Without server TTS a segment stays on screen for a time based on its length.
 *
 * Every sentence the child sends carries a `turn` number that the server echoes. A reply is shown only if it
 * answers the latest turn and the child has not interrupted since; anything else is cancelled by its id.
 */
export class TeacherSession {
  /** phase: idle | connecting | listening | hearing | thinking | speaking | ended | failed */
  state = { phase: 'idle', failure: '', caption: '', heard: '', awaiting: false, voiceInput: false, notice: '', muted: false };
  /** Called after every state change. */
  onChange = null;
  /** Called with a segment's whiteboard ops when that segment starts. */
  onBoard = null;
  /** Called with the mic level, 0…1. */
  onLevel = null;

  audio = new TeacherAudio();
  #ws = null;
  #turn = 0; #minTurn = 0;
  #response = -1;
  #segments = new Map();
  #presenting = null; #nextIndex = 0; #outstanding = 0; #responseDone = false;
  #started = 0; // segments of this reply that began playing: what the child heard and saw
  #playToken = 0; #waitTimer = 0;

  constructor() {
    this.audio.onSpeechStart = () => this.#speechStarted();
    this.audio.onAudio = bytes => { if (this.state.voiceInput && this.state.phase === 'hearing') this.#ws?.send(bytes); };
    this.audio.onSpeechEnd = () => this.#speechEnded();
    this.audio.onLevel = level => this.onLevel?.(level);
    this.audio.onCaptureLost = () => {
      if (this.state.phase === 'hearing') this.#cancelHearing();
      this.#set({ voiceInput: false, notice: '麦克风断开了，可以先打字，或者刷新页面再试。' });
    };
  }

  get canTalk() { return Boolean(this.#ws) && !['idle', 'connecting', 'ended', 'failed'].includes(this.state.phase); }

  #set(patch) { Object.assign(this.state, patch); this.onChange?.(this.state); }

  // ---------- lifecycle ----------

  /** Call from a tap, so the browser lets the page make sound. */
  start({ token, childId }) {
    this.stop();
    this.audio.unlock();
    this.#set({ phase: 'connecting', failure: '', caption: '', heard: '', notice: '', awaiting: false });
    const url = new URL('/v1/teacher', location.href);
    url.protocol = location.protocol === 'https:' ? 'wss:' : 'ws:';
    let ws;
    try { ws = new WebSocket(url, ['littlebear.teacher.v1', `littlebear.token.${token}`]); }
    catch { this.#fail('连不上小熊老师，请检查网络。'); return; }
    ws.binaryType = 'arraybuffer';
    this.#ws = ws;
    ws.onopen = () => this.#send({ type: 'session.start', childId });
    ws.onmessage = event => {
      if (this.#ws !== ws) return;
      if (typeof event.data === 'string') { let value; try { value = JSON.parse(event.data); } catch { return; } this.#handle(value); }
      else this.#handleAudio(new Uint8Array(event.data));
    };
    ws.onclose = () => {
      if (this.#ws !== ws) return;
      this.#ws = null;
      this.#fail(this.state.phase === 'connecting' ? '连不上小熊老师，请检查网络。' : '和小熊老师的连接断开了。');
    };
  }

  stop() {
    const ws = this.#ws;
    this.#ws = null;
    try { ws?.close(); } catch { /* already closed */ }
    this.#resetPresentation();
    this.audio.stop();
    if (this.state.phase !== 'idle') this.#set({ phase: 'ended' });
  }

  /** Typed input, or a suggestion the child tapped. */
  say(text) {
    const value = String(text).trim().slice(0, 1000);
    if (!value || !this.canTalk) return false;
    // The server drops a sentence it was still hearing when typed text arrives.
    if (this.state.phase === 'hearing') this.audio.resetDetection();
    this.#interruptIfNeeded();
    this.#turn += 1;
    this.#set({ heard: value, notice: '', phase: 'thinking' });
    this.#send({ type: 'input.text', text: value, turn: this.#turn });
    return true;
  }

  /** The child tapped the bear while it was talking or thinking: stop and listen. */
  interrupt() {
    if (!['speaking', 'thinking'].includes(this.state.phase)) return;
    this.#interruptIfNeeded();
    this.#minTurn = this.#turn + 1; // also drops the reply to a sentence that is still being recognized
    this.#set({ phase: 'listening' });
  }

  setMuted(muted) {
    this.audio.muted = muted;
    if (muted && this.state.phase === 'hearing') this.#cancelHearing();
    this.#set({ muted });
  }

  // ---------- mic events ----------

  #speechStarted() {
    if (!this.state.voiceInput || !this.canTalk) return;
    this.#interruptIfNeeded();
    this.#set({ heard: '', notice: '', phase: 'hearing' });
  }

  #speechEnded() {
    if (!this.state.voiceInput || this.state.phase !== 'hearing') return;
    this.#turn += 1;
    this.#set({ phase: 'thinking' });
    this.#send({ type: 'input.audio.end', turn: this.#turn });
  }

  /** Drops the sentence being heard (muted mid-sentence, or the mic went away). */
  #cancelHearing() {
    this.#send({ type: 'input.audio.cancel' });
    this.audio.resetDetection();
    this.#set({ heard: '', phase: 'listening' });
  }

  #interruptIfNeeded() {
    // The server has usually generated the whole reply already; tell it how far the child actually got.
    if (this.#response >= 0) this.#send({ type: 'response.cancel', response: this.#response, played: this.#started });
    this.#resetPresentation();
    this.state.caption = '';
  }

  // ---------- server events ----------

  #handle(event) {
    const phase = this.state.phase;
    /** This event is about the latest sentence, and the child has not interrupted or started talking since. */
    const wanted = event.turn === this.#turn && this.#turn >= this.#minTurn && phase !== 'hearing';
    switch (event.type) {
      case 'session.ready':
        this.#startAudio(Boolean(event.audio?.input), event.audio?.output?.sample_rate ?? 24000);
        break;
      case 'input.transcript.partial':
        if (phase === 'hearing' && typeof event.text === 'string') this.#set({ heard: event.text });
        break;
      case 'input.transcript.final':
        if (wanted) this.#set({ heard: event.text ?? this.state.heard, phase: 'thinking' });
        break;
      case 'input.transcript.empty':
        if (event.turn === this.#turn && phase === 'thinking') this.#set({ phase: 'listening' });
        break;
      case 'response.start':
        if (!Number.isInteger(event.response)) break;
        if (!wanted) { this.#send({ type: 'response.cancel', response: event.response, played: 0 }); break; }
        this.#resetPresentation();
        this.#response = event.response;
        this.#set({ phase: 'thinking' });
        break;
      case 'segment':
        if (event.response !== this.#response || !Number.isInteger(event.index)) break;
        this.#segments.set(event.index, { speech: event.speech ?? '', ops: Array.isArray(event.board) ? event.board : [],
          awaits: event.await === true, chunks: [], audioDone: false, hasAudio: false, played: false, waiting: false, waited: false });
        this.#presentNextIfReady();
        break;
      case 'segment.audio.done': {
        const segment = event.response === this.#response ? this.#segments.get(event.index) : null;
        if (!segment) break;
        segment.audioDone = true;
        segment.hasAudio = event.audio === true;
        if (this.#presenting === event.index) this.#finishIfPlayed();
        break;
      }
      case 'response.done':
        if (event.response !== this.#response) break;
        this.#responseDone = true;
        if (this.#presenting === null) this.#presentNextIfReady();
        break;
      case 'error':
        if (event.turn !== undefined && event.turn !== this.#turn) break; // about a sentence the child has moved on from
        this.#handleError(event.code);
        break;
      default: break;
    }
  }

  #handleAudio(frame) {
    if (frame.byteLength <= 4 || this.#response < 0) return;
    const response = (frame[0] << 8) | frame[1], index = (frame[2] << 8) | frame[3];
    const segment = this.#segments.get(index);
    if (response !== (this.#response & 0xffff) || !segment) return;
    const pcm = frame.subarray(4);
    if (this.#presenting === index) this.#schedule(pcm, segment); else segment.chunks.push(pcm);
  }

  #handleError(code) {
    switch (code) {
      case 'child_not_found': case 'session_not_started':
        this.#fail('找不到这个孩子的资料，请家长检查设置。'); break;
      case 'teacher_model_not_configured':
        this.#fail('服务器还没有配置小熊老师的 AI 模型。'); break;
      case 'asr_not_configured':
        this.audio.resetDetection();
        this.#set({ voiceInput: false, notice: '服务器还没有配置语音识别，可以先打字和小熊说话。', phase: 'listening' }); break;
      case 'rate_limited': this.#recoverable('说得太快啦，休息一下再问。'); break;
      case 'asr_unavailable': this.#recoverable('刚才没听清，再说一遍好吗？'); break;
      default: this.#recoverable('小熊刚才走神了，再说一遍吧。');
    }
  }

  #fail(message) {
    const ws = this.#ws;
    this.#ws = null;
    try { ws?.close(); } catch { /* already closed */ }
    this.#resetPresentation();
    this.audio.stop();
    this.#set({ phase: 'failed', failure: message, awaiting: false, voiceInput: false });
  }

  /** Shows a hint and goes back to listening, unless the child is already saying the next sentence. */
  #recoverable(message) {
    if (this.state.phase === 'hearing') { this.#set({ notice: message }); return; }
    this.#resetPresentation();
    this.#set({ notice: message, phase: 'listening' });
  }

  async #startAudio(serverHears, outputRate) {
    const ws = this.#ws;
    let voiceInput = serverHears, notice = '';
    if (serverHears && !TeacherAudio.captureSupported) {
      voiceInput = false;
      notice = window.isSecureContext ? '这个浏览器不支持麦克风，可以先打字。' : '这个地址不是 HTTPS，浏览器不让用麦克风，可以先打字。';
    }
    try {
      await this.audio.start({ capture: voiceInput, outputRate });
    } catch (error) {
      voiceInput = false;
      notice = error?.name === 'NotAllowedError' ? '没有麦克风权限，可以先打字。家长可以在浏览器的网站设置里打开。' : '麦克风启动失败，可以先打字和小熊说话。';
    }
    if (this.#ws !== ws || !ws) return; // closed while the permission prompt was up
    this.audio.muted = this.state.muted;
    this.#set({ voiceInput, notice, phase: this.state.phase === 'connecting' ? 'listening' : this.state.phase });
  }

  // ---------- presentation ----------

  #presentNextIfReady() {
    if (this.#presenting !== null) return;
    const index = this.#nextIndex, segment = this.#segments.get(index);
    if (!segment) {
      if (this.#responseDone) {
        this.#response = -1;
        this.audio.strict = false;
        if (['speaking', 'thinking'].includes(this.state.phase)) this.#set({ phase: 'listening' });
      }
      return;
    }
    this.#presenting = index;
    this.#started = index + 1;
    this.audio.strict = true;
    this.#set({ phase: 'speaking', caption: segment.speech, awaiting: segment.awaits });
    if (segment.ops.length) this.onBoard?.(segment.ops);
    const chunks = segment.chunks;
    segment.chunks = [];
    for (const chunk of chunks) this.#schedule(chunk, segment);
    this.#finishIfPlayed();
  }

  #schedule(pcm, segment) {
    const token = this.#playToken;
    const queued = this.audio.play(pcm, () => {
      if (token !== this.#playToken) return;
      this.#outstanding -= 1;
      this.#finishIfPlayed();
    });
    if (queued) { this.#outstanding += 1; segment.played = true; }
  }

  #finishIfPlayed() {
    const index = this.#presenting, segment = this.#segments.get(index);
    if (index === null || !segment || !segment.audioDone || this.#outstanding > 0) return;
    if (!(segment.hasAudio && segment.played) && !segment.waited) {
      // Nothing was heard for this segment (no TTS, or sound is blocked): leave it up long enough to read.
      if (segment.waiting) return;
      segment.waiting = true;
      const token = this.#playToken;
      this.#waitTimer = setTimeout(() => {
        if (token !== this.#playToken) return;
        segment.waited = true;
        this.#finishIfPlayed();
      }, Math.max(1500, segment.speech.length * 220));
      return;
    }
    this.#segments.delete(index);
    this.#presenting = null;
    this.#nextIndex = index + 1;
    this.#presentNextIfReady();
  }

  #resetPresentation() {
    this.#playToken += 1;
    clearTimeout(this.#waitTimer);
    this.audio.stopPlayback();
    this.audio.strict = false;
    this.#response = -1;
    this.#segments.clear();
    this.#presenting = null; this.#nextIndex = 0; this.#outstanding = 0; this.#responseDone = false; this.#started = 0;
    this.state.awaiting = false;
  }

  #send(value) {
    if (this.#ws?.readyState === WebSocket.OPEN) this.#ws.send(JSON.stringify(value));
  }
}
