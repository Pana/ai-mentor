import { randomUUID } from 'node:crypto';
import { acceptWebSocket } from './websocket.mjs';
import { Board, describeLearner, normalizeSegment, teacherPrompt } from './board.mjs';

export const TEACHER_PATH = '/v1/teacher';
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
 * Server → client: `session.ready`, `input.transcript.partial|final|empty`, `response.start`, then per segment
 * `segment {index, speech, board, await}`, binary audio frames (4-byte header: uint16 response, uint16 segment,
 * then PCM16LE at `audio.output.sample_rate`) and `segment.audio.done`, finally `response.done`.
 * The client applies a segment's board ops when that segment starts playing, so drawing follows the voice.
 */
export function attachTeacher(server, { api, model = {}, asr = null, tts = null, mock = false, fetchImpl = fetch,
  idleMs = 600_000 } = {}) {
  const modelReady = Boolean(model.apiUrl && model.apiKey && model.model);
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    if (url.pathname !== TEACHER_PATH) return;
    const ctx = api?.deviceFor(req);
    if (!ctx) { socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); socket.destroy(); return; }

    const sessionID = randomUUID(), board = new Board(), history = [];
    let learner = null, closed = false, generation = 0, controller = null, utterance = null, inputTimes = [], idleTimer;
    let connection = null;
    const touch = () => { clearTimeout(idleTimer); idleTimer = setTimeout(() => connection?.close(true, 1000, 'idle'), idleMs); };
    const send = value => { if (!closed) connection?.sendJSON(value); };

    const cancelResponse = () => { generation += 1; controller?.abort(); controller = null; };
    const dropUtterance = () => { utterance?.stream?.abort(); utterance = null; };

    async function respond(text, turn) {
      inputTimes = inputTimes.filter(time => Date.now() - time < 60_000);
      if (inputTimes.length >= 20) return send({ type: 'error', code: 'rate_limited', turn });
      inputTimes.push(Date.now());
      cancelResponse();
      const response = generation, abort = new AbortController(), signal = abort.signal;
      controller = abort;
      const stale = () => closed || signal.aborted || response !== generation;
      send({ type: 'response.start', response, turn });
      const spoken = [];
      let index = 0;
      try {
        const source = modelReady ? modelSegments(text, signal) : mock ? mockSegments(text) : null;
        if (!source) return send({ type: 'error', code: 'teacher_model_not_configured' });
        for await (const raw of source) {
          if (stale()) return;
          const segment = normalizeSegment(raw, board);
          if (!segment) continue;
          send({ type: 'segment', response, index, ...segment });
          if (segment.speech) spoken.push(segment.speech);
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
        history.push({ role: 'user', content: text });
        history.push({ role: 'assistant', content: spoken.join('') || '（没有说完）' });
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
      const upstream = await fetchImpl(model.apiUrl, { method: 'POST', redirect: 'error', signal,
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${model.apiKey}` },
        body: JSON.stringify({ model: model.model, messages, stream: true, max_tokens: 1500, temperature: 0.5 }) });
      if (!upstream.ok) throw new Error(`model_http_${upstream.status}`);
      yield* segmentsFromStream(upstream.body);
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
          const stream = asr.stream({ onText: text => { if (utterance?.stream === stream) send({ type: 'input.transcript.partial', text }); } });
          utterance = { stream };
        }
        utterance.stream.write(message);
        return;
      }
      let event; try { event = JSON.parse(message); } catch { return send({ type: 'error', code: 'invalid_json' }); }
      if (event?.type === 'session.start') {
        if (learner) return send({ type: 'error', code: 'session_already_started' });
        learner = typeof event.childId === 'string' ? api.learnerContext(ctx.familyId, event.childId.toLowerCase()) : null;
        if (!learner) return send({ type: 'error', code: 'child_not_found' });
        return send({ type: 'session.ready', session_id: sessionID, child: { name: learner.child.name, grade: learner.child.grade },
          audio: { input: asr ? { format: 'pcm_s16le', sample_rate: 16_000, channels: 1 } : null,
            output: tts ? { format: 'pcm_s16le', sample_rate: tts.sampleRate, channels: 1 } : null } });
      }
      if (!learner) return send({ type: 'error', code: 'session_not_started' });
      switch (event?.type) {
        case 'response.cancel':
          // A cancel naming a reply only stops that one: a late cancel must not kill the reply to a newer sentence.
          if (event.response === undefined || event.response === generation) cancelResponse();
          return send({ type: 'response.cancelled' });
        case 'input.audio.cancel': return dropUtterance();
        case 'input.audio.end': {
          const current = utterance, turn = turnOf(event); utterance = null;
          if (!current || current.unsupported) return send({ type: 'input.transcript.empty', turn });
          let text = '';
          try { text = (await current.stream.end()).text.trim().slice(0, maxText); }
          catch (error) { if (!closed) { console.error('teacher asr error', error?.message); send({ type: 'error', code: 'asr_unavailable', turn }); } return; }
          if (closed) return;
          if (!text) return send({ type: 'input.transcript.empty', turn });
          send({ type: 'input.transcript.final', text, turn });
          return respond(text, turn);
        }
        case 'input.text': {
          const text = typeof event.text === 'string' ? event.text.trim().slice(0, maxText) : '';
          if (!text) return send({ type: 'error', code: 'empty_input' });
          dropUtterance(); // typing replaces a sentence that was still being heard
          const turn = turnOf(event);
          send({ type: 'input.transcript.final', text, turn });
          return respond(text, turn);
        }
        default: return undefined;
      }
    }, () => { closed = true; clearTimeout(idleTimer); cancelResponse(); dropUtterance(); });
    if (!connection) return;
    touch();
    connection.sendJSON({ type: 'hello', protocol: 'littlebear.teacher.v1' });
  });
  return server;
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
