import { randomUUID } from 'node:crypto';
import { acceptWebSocket } from './websocket.mjs';
import { Board, describeLearner, normalizeSegment, segmentLine, teacherPrompt } from './board.mjs';
import { wrongClaims } from './verify.mjs';
import { writeCard } from './memory.mjs';

export const TEACHER_PATH = '/v1/teacher';
const PROTOCOL = 'littlebear.teacher.v1';
const tokenProtocol = /^littlebear\.token\.([A-Za-z0-9_-]{24,128})$/;

/**
 * The upgrade request with its credential in the Authorization header. Browsers cannot set headers on a
 * WebSocket, so the page offers the subprotocols `littlebear.teacher.v1, littlebear.token.<device token>`.
 */
function credentials(req) {
  const offered = String(req.headers['sec-websocket-protocol'] ?? '').split(',').map(value => value.trim());
  const selected = offered.includes(PROTOCOL) ? PROTOCOL : undefined;
  if (req.headers.authorization) return { request: req, selected };
  const token = offered.map(value => tokenProtocol.exec(value)?.[1]).find(Boolean);
  return { request: { headers: { authorization: token ? `Bearer ${token}` : '' } }, selected };
}
const turnOf = event => (Number.isSafeInteger(event?.turn) ? event.turn : undefined);
const maxText = 1_000;
const maxHistory = 16;

/**
 * Voice teacher session (`littlebear.teacher.v1`), authenticated with a phase-1 device credential.
 *
 * Client → server: `session.start {childId}`; binary PCM16LE 16 kHz mono while the child speaks, then
 * `input.audio.end {turn}` (or `input.audio.cancel`); `input.text {text, turn}`; `response.cancel {response}` to
 * barge in. `turn` is the client's own counter, echoed on the transcript and `response.start`, so a client can
 * drop a reply to a sentence it has since moved on from; `response` limits a cancel to that reply.
 * A reply is generated much faster than it is spoken, so a cancel also says how many segments had started
 * playing (`played`): the history then keeps only what the child heard, and the board goes back to what they saw.
 * Server → client: `session.ready`, `input.transcript.partial|final|empty`, `input.speech_end` (the recognizer heard the
 * sentence end; the client then sends `input.audio.end` as if its own detector had), `response.start`, then per segment
 * `segment {index, speech, board, await, end?}` (`end`: the child said goodbye; the client closes the conversation
 * once this segment has been heard), binary audio frames (4-byte header: uint16 response, uint16 segment,
 * then PCM16LE at `audio.output.sample_rate`) and `segment.audio.done`, finally `response.done`.
 * The client applies a segment's board ops when that segment starts playing, so drawing follows the voice.
 * When the connection closes, the teacher's notes about the child are rewritten from what was said (memory.mjs);
 * the conversation itself is never stored.
 */
export function attachTeacher(server, { api, model = {}, asr = null, tts = null, mock = false, fetchImpl = fetch,
  idleMs = 600_000, log = false } = {}) {
  /** Development trace (`TEACHER_LOG=1`): what was heard, said and drawn. Off by default: it prints the child's words. */
  const trace = log ? (...parts) => console.log('[teacher]', ...parts) : () => {};
  const modelReady = Boolean(model.apiUrl && model.apiKey && model.model);
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    if (url.pathname !== TEACHER_PATH) return;
    const { request, selected } = credentials(req);
    const ctx = api?.deviceFor(request);
    if (!ctx) { socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); socket.destroy(); return; }

    const sessionID = randomUUID(), board = new Board(), history = [];
    let learner = null, closed = false, generation = 0, controller = null, utterance = null, inputTimes = [], idleTimer;
    let connection = null;
    const touch = () => { clearTimeout(idleTimer); idleTimer = setTimeout(() => connection?.close(true, 1000, 'idle'), idleMs); };
    const send = value => { if (!closed) connection?.sendJSON(value); };

    const cancelResponse = () => { generation += 1; controller?.abort(); controller = null; };
    // Per reply: each segment as the model wrote it (words and drawing) and the board after it, so an interrupted
    // reply can be cut back. The history keeps the drawing too: a history of words alone teaches the model to stop drawing.
    const records = new Map();
    let latest = null;
    const said = record => {
      if (record.played === null) return record.lines.join('\n') || '（没有说完）';
      const heard = record.lines.slice(0, record.played).join('\n');
      return heard ? `${heard}\n（说到这里被孩子打断了）` : '（还没开口就被孩子打断了）';
    };
    function cutBack(record, played) {
      record.played = Math.min(played, record.spoken.length);
      if (record.entry) record.entry.content = said(record);
      if (record === latest) board.elements = structuredClone(record.played ? record.boards[record.played - 1] : record.before);
    }
    const dropUtterance = () => { utterance?.stream?.abort(); utterance = null; };

    // What was said this session, as the child heard it; kept in memory only, for the note written when it ends.
    const turns = [];
    /** After the conversation: rewrite the teacher's notes about this child. The conversation itself is not stored. */
    async function remember() {
      if (!learner || !modelReady || !api?.saveTeacherMemory || turns.length < 2) return;
      const heard = turns.map(({ child, record }) => ({ child,
        teacher: (record.played === null ? record.spoken : record.spoken.slice(0, record.played)).join('') }));
      try {
        const card = await writeCard({ model, fetchImpl, learner, turns: heard });
        if (card && card !== learner.memory) api.saveTeacherMemory(ctx.familyId, learner.child.id, card);
        trace(card ? `记下了：\n${card}` : '这次没有要记的');
      } catch (error) { console.error('teacher memory error', error?.message); }
    }

    async function respond(text, turn) {
      inputTimes = inputTimes.filter(time => Date.now() - time < 60_000);
      if (inputTimes.length >= 20) return send({ type: 'error', code: 'rate_limited', turn });
      inputTimes.push(Date.now());
      cancelResponse();
      const response = generation, abort = new AbortController(), signal = abort.signal;
      controller = abort;
      const stale = () => closed || signal.aborted || response !== generation;
      send({ type: 'response.start', response, turn });
      const record = { spoken: [], lines: [], boards: [], before: structuredClone(board.elements), played: null, entry: null };
      records.set(response, record);
      for (const id of records.keys()) if (records.size > 4) records.delete(id);
      latest = record;
      let index = 0;
      try {
        const source = modelReady ? modelSegments(text, signal) : mock ? mockSegments(text) : null;
        if (!source) return send({ type: 'error', code: 'teacher_model_not_configured' });
        for await (const raw of source) {
          if (stale()) return;
          const segment = normalizeSegment(raw, board);
          const rawOps = Array.isArray(raw?.board) ? raw.board : [];
          trace(`  段${index} ${JSON.stringify(segment?.speech ?? '')}${segment?.await ? ' ⏸' : ''}${segment?.end ? ' ⏹结束' : ''} 画 ${segment?.board.length ?? 0}/${rawOps.length}`,
            rawOps.length !== (segment?.board.length ?? 0) ? `丢弃：${JSON.stringify(rawOps)}` : '');
          if (!segment) continue;
          send({ type: 'segment', response, index, ...segment });
          record.spoken.push(segment.speech);
          record.lines.push(segmentLine(segment));
          record.boards.push(structuredClone(board.elements));
          let audio = false;
          if (tts && segment.speech) {
            try {
              let odd = null; // a sample split across two chunks: frames always carry whole 16-bit samples
              for await (const chunk of tts.synthesize(segment.speech, { signal })) {
                if (stale()) return;
                let pcm = odd ? Buffer.concat([odd, chunk]) : chunk;
                odd = pcm.length % 2 ? pcm.subarray(pcm.length - 1) : null;
                if (odd) pcm = pcm.subarray(0, pcm.length - 1);
                if (!pcm.length) continue;
                const header = Buffer.alloc(4);
                header.writeUInt16BE(response & 0xffff, 0); header.writeUInt16BE(index & 0xffff, 2);
                connection.sendBinary(Buffer.concat([header, pcm]));
                audio = true;
              }
            } catch (error) {
              if (stale()) return;
              console.error('teacher tts error', error?.message);
            }
          }
          send({ type: 'segment.audio.done', response, index, audio });
          index += 1;
        }
        if (stale()) return;
        if (!index) return send({ type: 'error', code: 'teacher_model_unavailable' });
        send({ type: 'response.done', response });
      } catch (error) {
        if (!stale()) { console.error('teacher model error', error?.message); send({ type: 'error', code: 'teacher_model_unavailable' }); }
      } finally {
        // Keep what the child actually heard, even after a barge-in, so the next turn continues from there.
        record.entry = { role: 'assistant', content: said(record) };
        history.push({ role: 'user', content: text }, record.entry);
        turns.push({ child: text, record });
        if (turns.length > 80) turns.shift();
        history.splice(0, Math.max(0, history.length - maxHistory));
        if (response === generation) controller = null;
      }
    }

    async function* modelSegments(text, signal) {
      const messages = [
        { role: 'system', content: teacherPrompt },
        { role: 'system', content: `学情资料：\n${describeLearner(learner)}` },
        ...history,
        { role: 'user', content: `当前白板：${JSON.stringify(board.elements)}\n孩子说：${text}` }
      ];
      yield* checkedSegments(messages, (body, upstreamSignal) => fetchImpl(model.apiUrl, { method: 'POST', redirect: 'error',
        signal: upstreamSignal, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${model.apiKey}` },
        body: JSON.stringify(body) }), model, signal);
    }

    connection = acceptWebSocket(req, socket, head, async (message, binary, ws) => {
      connection ??= ws;
      if (closed) return;
      touch();
      if (binary) {
        if (!learner) return;
        if (!asr) {
          if (!utterance) { utterance = { unsupported: true }; send({ type: 'error', code: 'asr_not_configured' }); }
          return;
        }
        if (!utterance) {
          const stream = asr.stream({
            onText: text => { if (utterance?.stream === stream) send({ type: 'input.transcript.partial', text }); },
            // The recognizer heard the sentence end: the client ends the turn as if its own detector had.
            onEndpoint: () => { if (utterance?.stream === stream) { trace('识别服务判定说完'); send({ type: 'input.speech_end' }); } }
          });
          utterance = { stream, started: Date.now(), bytes: 0 };
        }
        utterance.stream.write(message);
        if (utterance.bytes !== undefined) utterance.bytes += message.length;
        return;
      }
      let event; try { event = JSON.parse(message); } catch { return send({ type: 'error', code: 'invalid_json' }); }
      if (event?.type === 'session.start') {
        if (learner) return send({ type: 'error', code: 'session_already_started' });
        learner = typeof event.childId === 'string' ? api.learnerContext(ctx.familyId, event.childId.toLowerCase()) : null;
        if (!learner) return send({ type: 'error', code: 'child_not_found' });
        trace(`会话开始：${learner.child.name}`);
        return send({ type: 'session.ready', session_id: sessionID, child: { name: learner.child.name, grade: learner.child.grade },
          audio: { input: asr ? { format: 'pcm_s16le', sample_rate: 16_000, channels: 1 } : null,
            output: tts ? { format: 'pcm_s16le', sample_rate: tts.sampleRate, channels: 1 } : null } });
      }
      if (!learner) return send({ type: 'error', code: 'session_not_started' });
      switch (event?.type) {
        case 'response.cancel':
          // A cancel naming a reply only stops that one: a late cancel must not kill the reply to a newer sentence.
          if (event.response === undefined || event.response === generation) cancelResponse();
          if (records.has(event.response) && Number.isInteger(event.played) && event.played >= 0) cutBack(records.get(event.response), event.played);
          return send({ type: 'response.cancelled' });
        case 'input.audio.cancel': return dropUtterance();
        case 'input.audio.end': {
          const current = utterance, turn = turnOf(event); utterance = null;
          if (current?.started) trace(`录音 ${(current.bytes / 32_000).toFixed(1)} 秒，开口后 ${((Date.now() - current.started) / 1000).toFixed(1)} 秒才收到“说完了”`);
          if (!current || current.unsupported) return send({ type: 'input.transcript.empty', turn });
          let text = '';
          try { text = (await current.stream.end()).text.trim().slice(0, maxText); }
          catch (error) { if (!closed) { console.error('teacher asr error', error?.message); send({ type: 'error', code: 'asr_unavailable', turn }); } return; }
          if (closed) return;
          if (!text) return send({ type: 'input.transcript.empty', turn });
          send({ type: 'input.transcript.final', text, turn });
          trace(`孩子：${JSON.stringify(text)}`);
          return respond(text, turn);
        }
        case 'input.text': {
          const text = typeof event.text === 'string' ? event.text.trim().slice(0, maxText) : '';
          if (!text) return send({ type: 'error', code: 'empty_input' });
          dropUtterance(); // typing replaces a sentence that was still being heard
          const turn = turnOf(event);
          send({ type: 'input.transcript.final', text, turn });
          trace(`孩子：${JSON.stringify(text)}`);
          return respond(text, turn);
        }
        default: return undefined;
      }
    }, () => { closed = true; clearTimeout(idleTimer); cancelResponse(); dropUtterance(); remember(); }, { protocol: selected });
    if (!connection) return;
    touch();
    connection.sendJSON({ type: 'hello', protocol: PROTOCOL });
  });
  return server;
}

/** The chat-completion request body for the teacher; the eval script sends exactly this. */
export function teacherRequestBody(model, messages) {
  return { model: model.model, messages, stream: true, max_tokens: 1500, temperature: 0.5,
    // DeepSeek thinks before answering unless told not to: about 1 s more before the first word is spoken.
    ...(['disabled', 'enabled'].includes(model.thinking) ? { thinking: { type: model.thinking } } : {}) };
}

const correctionLimit = 1;
const checkFallback = { speech: '这一步小熊想再算一遍，我们一起慢慢算，好吗？', board: [], await: true };

/**
 * Model segments with their spoken and written arithmetic checked (see verify.mjs). A segment with a wrong result
 * is never sent: the reply stops there and the model is asked once to go on from what was already said, told the
 * right result. If it is wrong again the reply ends with a question instead, so the child never hears a wrong sum.
 * The reply also ends at the first segment that waits for the child (`await`), even if the model went on.
 * `post(body, signal)` sends the request; `onCheck` (optional) sees each correction, for logs and the eval.
 */
export async function* checkedSegments(messages, post, model, signal, { onCheck } = {}) {
  const said = [];
  let request = messages;
  for (let attempt = 0; ; attempt++) {
    const upstream = new AbortController();
    const stop = () => upstream.abort();
    signal?.addEventListener('abort', stop, { once: true });
    let wrong = null;
    try {
      const response = await post(teacherRequestBody(model, request), upstream.signal);
      if (!response.ok) throw new Error(`model_http_${response.status}`);
      for await (const raw of segmentsFromStream(response.body)) {
        const claims = wrongClaims(raw);
        if (claims.length) { wrong = claims; break; }
        said.push(raw);
        yield raw;
        // A question waits for the child: anything after it would answer the question for them.
        // A goodbye ends the conversation: nothing comes after it.
        if (raw?.await === true || raw?.end === true) return;
      }
    } finally {
      upstream.abort();
      signal?.removeEventListener('abort', stop);
    }
    if (!wrong) return;
    const correcting = attempt < correctionLimit;
    onCheck?.({ wrong, corrected: correcting });
    console.warn('teacher check', JSON.stringify(wrong.map(({ claim, expected }) => ({ claim, expected }))), correcting ? 'retry' : 'gave up');
    if (!correcting) { yield checkFallback; return; }
    const fix = wrong.map(({ claim, expected }) => `${claim} 算错了，正确结果是 ${expected}`).join('；');
    request = [...messages,
      ...(said.length ? [{ role: 'assistant', content: said.map(segment => JSON.stringify(segment)).join('\n') }] : []),
      { role: 'user', content: `（系统核对，不是孩子说的）你接下来要说的内容里 ${fix}。请从已经说过的地方接着讲，不要重复已经说过的话，不要提到核对或算错，格式不变。` }];
  }
}

/**
 * Parses an OpenAI-compatible SSE completion into segment objects, one JSON object per output line.
 * Falls back to a whole-reply JSON array/object, or to plain sentences, when the model ignores the line format.
 */
export async function* segmentsFromStream(body) {
  const decoder = new TextDecoder();
  let sse = '', text = '', all = '', yielded = 0, done = false;
  function* lines(final) {
    let index;
    while ((index = text.indexOf('\n')) >= 0) {
      const segment = parseLine(text.slice(0, index));
      text = text.slice(index + 1);
      if (segment) { yielded++; yield segment; }
    }
    if (final) {
      const segment = parseLine(text); text = '';
      if (segment) { yielded++; yield segment; }
    }
  }
  for await (const chunk of body) {
    sse += decoder.decode(chunk, { stream: true });
    let index;
    while ((index = sse.indexOf('\n')) >= 0) {
      const line = sse.slice(0, index).trim(); sse = sse.slice(index + 1);
      if (!line.startsWith('data:')) continue;
      const payload = line.slice(5).trim();
      if (payload === '[DONE]') { done = true; break; }
      let delta = '';
      try { delta = JSON.parse(payload).choices?.[0]?.delta?.content ?? ''; } catch { continue; }
      text += delta; all += delta;
      if (all.length > 20_000) throw new Error('model_reply_too_long');
      yield* lines(false);
    }
    if (done) break;
  }
  yield* lines(true);
  if (yielded) return;
  yield* fallbackSegments(all);
}

function parseLine(line) {
  const trimmed = line.trim().replace(/,$/, '');
  if (!trimmed.startsWith('{')) return null;
  try { const value = JSON.parse(trimmed); return value && typeof value === 'object' && !Array.isArray(value) ? value : null; } catch { return null; }
}

function* fallbackSegments(all) {
  const cleaned = all.trim().replace(/^```(?:json)?\s*/, '').replace(/\s*```$/, '');
  if (!cleaned) return;
  try {
    const value = JSON.parse(cleaned);
    const list = Array.isArray(value) ? value : Array.isArray(value?.segments) ? value.segments : [value];
    for (const item of list) if (item && typeof item === 'object') yield item;
    return;
  } catch { /* plain text */ }
  if (cleaned.startsWith('{') || cleaned.startsWith('[')) return;
  for (const sentence of cleaned.match(/[^。！？!?\n]+[。！？!?]?/gu) ?? []) {
    if (sentence.trim()) yield { speech: sentence.trim(), board: [] };
  }
}

/** Deterministic lesson for UI work without a model (`VOICE_MOCK=true`). */
export async function* mockSegments(text) {
  if (/再见|拜拜/.test(text)) { yield { speech: '好的，下次见！记得把今天的作业做完哦。', board: [] }; return; }
  yield { speech: '好呀，我们一起来算三十八加二十七。', board: [{ op: 'clear' }, { op: 'add', el: { id: 't1', type: 'text', text: '38 + 27 = ?', style: 'title' } }] };
  yield { speech: '先把它写成竖式，个位对齐个位，十位对齐十位。', board: [{ op: 'add', el: { id: 'v1', type: 'vertical', a: 38, b: 27, operator: '+', reveal: 0, focus: 0 } }] };
  yield { speech: '个位上八加七等于十五，满十要向十位进一。', board: [{ op: 'update', id: 'v1', set: { reveal: 1, focus: 0 } }] };
  yield { speech: '你来试试：十位上三加二，再加上进的一，等于几呀？', board: [{ op: 'update', id: 'v1', set: { focus: 1 } }], await: true };
}
