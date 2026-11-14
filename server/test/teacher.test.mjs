import test from 'node:test';
import assert from 'node:assert/strict';
import { once, EventEmitter } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { gzipSync } from 'node:zlib';
import { createGateway } from '../src/gateway.mjs';
import { createApi } from '../src/api.mjs';
import { Board, describeLearner, normalizeElement, normalizeSegment } from '../src/board.mjs';
import { segmentsFromStream } from '../src/teacher.mjs';
import { createVolcTts } from '../src/volc-tts.mjs';
import { createVolcAsr } from '../src/volc-asr.mjs';

const bootstrapToken = 'parent-bootstrap-token-not-a-secret';
const tutorToken = 'device-test-token-not-a-secret-12345';
const model = { apiUrl: 'https://model.example/v1/chat/completions', apiKey: 'test-key', model: 'test-model' };

function sse(contents, split = 7) {
  const text = contents.map(content => `data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n\n`).join('') + 'data: [DONE]\n\n';
  const chunks = [];
  for (let i = 0; i < text.length; i += split) chunks.push(Buffer.from(text.slice(i, i + split)));
  return (async function* () { yield* chunks; })();
}
const collect = async source => { const out = []; for await (const item of source) out.push(item); return out; };

test('board: elements are validated and updates carry the whole element', () => {
  assert.equal(normalizeElement({ id: 'v1', type: 'vertical', a: 12, b: 30, operator: '-' }), null, 'no negative results');
  assert.equal(normalizeElement({ id: 'v1', type: 'vertical', a: 12, b: 13, operator: '×' }), null, 'multiplier is one digit');
  assert.equal(normalizeElement({ id: 'bad id', type: 'text', text: 'x' }), null);
  assert.equal(normalizeElement({ id: 'n1', type: 'number_line', from: 0, to: 100, step: 1 }), null, 'at most 20 ticks');
  assert.deepEqual(normalizeElement({ id: 'n1', type: 'number_line', from: 0, to: 20, marks: [8], jumps: [{ from: 8, to: 13, label: '+5' }] }),
    { id: 'n1', type: 'number_line', from: 0, to: 20, step: 1, marks: [8], jumps: [{ from: 8, to: 13, label: '+5' }] });
  assert.deepEqual(normalizeElement({ id: 'b1', type: 'bar', rows: [{ label: '小红', parts: [{ value: 12 }, { value: null, label: '?' }] }] }),
    { id: 'b1', type: 'bar', rows: [{ label: '小红', parts: [{ value: 12, label: '' }, { value: null, label: '?' }] }], total: '' });

  const board = new Board();
  assert.deepEqual(board.apply({ op: 'add', el: { id: 'v1', type: 'vertical', a: 38, b: 27, operator: '+' } }),
    { op: 'add', el: { id: 'v1', type: 'vertical', a: 38, b: 27, operator: '+', reveal: 0, focus: -1 } });
  assert.deepEqual(board.apply({ op: 'update', id: 'v1', set: { reveal: 1, focus: 0, type: 'text' } }),
    { op: 'update', el: { id: 'v1', type: 'vertical', a: 38, b: 27, operator: '+', reveal: 1, focus: 0 } });
  assert.equal(board.apply({ op: 'update', id: 'v1', set: { reveal: 99 } }), null, 'an invalid update leaves the element');
  assert.equal(board.get('v1').reveal, 1);
  assert.equal(board.apply({ op: 'update', id: 'missing', set: {} }), null);
  assert.equal(board.apply({ op: 'draw', path: 'M0 0' }), null);

  const segment = normalizeSegment({ speech: ' 好 ', board: [{ op: 'clear' }, { op: 'nope' }], await: true }, board);
  assert.deepEqual(segment, { speech: '好', board: [{ op: 'clear' }], await: true });
  assert.equal(board.elements.length, 0);
  assert.equal(normalizeSegment({ speech: '', board: [{ op: 'nope' }] }, board), null);
});

test('learner facts become prompt text', () => {
  const text = describeLearner({ child: { name: '林林', grade: 2 }, today: '2026-11-09', homework: [
    { date: '2026-11-09', subject: 'MATH', content: '口算本\n第 12 页', status: 'NEEDS_CORRECTION', review: { grade: 'FAIR', comment: '进位要细心', requireCorrection: true } }] });
  assert.match(text, /林林，2年级/);
  assert.match(text, /数学：口算本 第 12 页（需要订正，评分中，家长评语：进位要细心）/);
});

test('segments: one JSON line per segment across SSE chunks, with fallbacks', async () => {
  const lines = ['{"speech":"先列竖式。","board":[{"op":"clear"}]}\n', '```\n{"speech":"个位', '上八加七呢？","await":true}'];
  assert.deepEqual(await collect(segmentsFromStream(sse(lines))), [
    { speech: '先列竖式。', board: [{ op: 'clear' }] }, { speech: '个位上八加七呢？', await: true }]);
  assert.deepEqual(await collect(segmentsFromStream(sse(['[{"speech":"一"},', '{"speech":"二"}]']))), [{ speech: '一' }, { speech: '二' }]);
  assert.deepEqual(await collect(segmentsFromStream(sse(['你好呀！我们开始吧。']))), [
    { speech: '你好呀！', board: [] }, { speech: '我们开始吧。', board: [] }]);
});

test('Volc TTS streams base64 PCM lines until the finish code', async () => {
  let request;
  const pcm = Buffer.from([1, 2, 3, 4]);
  const body = [{ code: 0, data: pcm.toString('base64') }, { code: 0, data: Buffer.from([5, 6]).toString('base64') }, { code: 20000000, message: 'ok' }]
    .map(line => JSON.stringify(line)).join('\n') + '\n';
  const tts = createVolcTts({ apiKey: 'k', speaker: 'zh_female_test', fetchImpl: async (url, init) => {
    request = { url, init };
    return new Response(body.slice(0, 10) + body.slice(10));
  } });
  assert.equal(createVolcTts({ apiKey: 'k' }), null, 'a speaker is required');
  const chunks = await collect(tts.synthesize('你好'));
  assert.deepEqual(Buffer.concat(chunks), Buffer.from([1, 2, 3, 4, 5, 6]));
  assert.equal(request.url, 'https://openspeech.bytedance.com/api/v3/tts/unidirectional');
  assert.equal(request.init.headers['X-Api-Resource-Id'], 'seed-tts-2.0');
  const sent = JSON.parse(request.init.body);
  assert.equal(sent.req_params.speaker, 'zh_female_test');
  assert.deepEqual(sent.req_params.audio_params, { format: 'pcm', sample_rate: 24000, speech_rate: 0 });

  const failing = createVolcTts({ apiKey: 'k', speaker: 's', fetchImpl: async () => new Response('{"code":45000000,"message":"bad"}\n') });
  await assert.rejects(collect(failing.synthesize('x')), /volc_tts_45000000/);
});

test('Volc ASR stream queues audio until open, reports interim text and resolves on the last packet', async () => {
  const frames = [];
  class FakeWebSocket extends EventEmitter {
    constructor(url, options) { super(); this.url = url; this.options = options; FakeWebSocket.last = this; setTimeout(() => this.emit('open'), 5); }
    send(frame) {
      frames.push(frame);
      const last = (frame[1] & 0x0f) === 0b0011;
      const reply = text => {
        const body = gzipSync(Buffer.from(JSON.stringify({ result: { text } })));
        const out = Buffer.alloc(12 + body.length);
        Buffer.from([0x11, last ? 0x93 : 0x91, 0x11, 0]).copy(out, 0);
        out.writeInt32BE(last ? -frames.length : frames.length, 4); out.writeUInt32BE(body.length, 8); body.copy(out, 12);
        this.emit('message', out);
      };
      if (frames.length === 2) reply('八加');
      if (last) reply('八加七等于几');
    }
    close() {}
  }
  const asr = createVolcAsr({ apiKey: 'k', WebSocketImpl: FakeWebSocket });
  const partials = [];
  const stream = asr.stream({ onText: text => partials.push(text) });
  stream.write(Buffer.alloc(3200));
  stream.write(Buffer.alloc(3200));
  const result = await stream.end();
  assert.equal(result.text, '八加七等于几');
  assert.deepEqual(partials, ['八加', '八加七等于几']);
  assert.equal(FakeWebSocket.last.url, 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async');
  assert.equal(frames.length, 4, 'full request, two audio packets, last packet');
});

async function setup(t, { fetchImpl, asr = null, tts = null, mock = false, withModel = true } = {}) {
  const dataDir = mkdtempSync(join(tmpdir(), 'littlebear-teacher-'));
  const api = createApi({ dataDir, bootstrapToken });
  const server = createGateway({ token: tutorToken, api, voice: { mock },
    teacher: { asr, tts, model: withModel ? model : {} } }, { fetchImpl });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `127.0.0.1:${server.address().port}`;
  const sockets = [];
  t.after(() => new Promise(resolve => {
    for (const ws of sockets) ws.close();
    setTimeout(() => server.close(() => { api.close(); rmSync(dataDir, { recursive: true, force: true }); resolve(); }), 20);
    server.closeAllConnections();
  }));
  const call = async (method, path, token, body) => (await fetch(`http://${base}${path}`, { method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) })).json();
  const parent = (await call('POST', '/v1/devices/bootstrap', null, { token: bootstrapToken, deviceId: randomUUID(), name: 'iPhone' })).deviceToken;
  const childId = randomUUID();
  await call('PUT', `/v1/children/${childId}`, parent, { name: '林林', grade: 2 });
  const today = (await call('GET', '/v1/me', parent)).family.today;
  await call('POST', '/v1/homework', parent, { items: [{ id: randomUUID(), childId, subject: 'MATH', date: today, content: '口算本第 12 页', mode: 'OFFLINE' }] });

  async function connect(token = parent) {
    const ws = new WebSocket(`ws://${base}/v1/teacher`, { headers: { Authorization: `Bearer ${token}` } });
    ws.binaryType = 'arraybuffer';
    sockets.push(ws);
    const events = [];
    ws.onmessage = event => events.push(typeof event.data === 'string' ? JSON.parse(event.data) : { binary: Buffer.from(event.data) });
    await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
    const until = (predicate, ms = 2000) => new Promise((resolve, reject) => {
      const start = Date.now();
      const timer = setInterval(() => {
        const found = events.find(predicate);
        if (found) { clearInterval(timer); resolve(found); } else if (Date.now() - start > ms) { clearInterval(timer); reject(new Error(`timeout; got ${JSON.stringify(events.map(e => e.type ?? 'binary'))}`)); }
      }, 3);
    });
    const send = value => ws.send(JSON.stringify(value));
    return { ws, events, until, send };
  }
  return { connect, childId, parent };
}

test('teacher session: learner context reaches the model, segments arrive with board ops and audio in order', async t => {
  let modelRequest;
  const fetchImpl = async (url, init) => {
    modelRequest = JSON.parse(init.body);
    return new Response(sse([
      '{"speech":"我们来算三十八加二十七。","board":[{"op":"clear"},{"op":"add","el":{"id":"v1","type":"vertical","a":38,"b":27,"operator":"+"}}]}\n',
      '{"speech":"个位八加七等于几？","board":[{"op":"update","id":"v1","set":{"focus":0}},{"op":"add","el":{"id":"x","type":"svg"}}],"await":true}\n']));
  };
  // Chunks that split a 16-bit sample: 3 + 1 bytes must arrive as two whole samples.
  const tts = { sampleRate: 24000, async *synthesize(text) { yield Buffer.from([text.length, 0, 1]); yield Buffer.from([0]); } };
  const { connect, childId } = await setup(t, { fetchImpl, tts });
  const { send, until, events } = await connect();
  assert.equal((await until(e => e.type === 'hello')).protocol, 'littlebear.teacher.v1');
  send({ type: 'session.start', childId: childId.toUpperCase() });
  const ready = await until(e => e.type === 'session.ready');
  assert.deepEqual(ready.child, { name: '林林', grade: 2 });
  assert.deepEqual(ready.audio.output, { format: 'pcm_s16le', sample_rate: 24000, channels: 1 });
  assert.equal(ready.audio.input, null, 'no ASR configured');

  send({ type: 'input.text', text: '三十八加二十七怎么算', turn: 7 });
  await until(e => e.type === 'response.done');
  assert.equal(events.find(e => e.type === 'input.transcript.final').turn, 7);
  assert.equal(events.find(e => e.type === 'response.start').turn, 7);
  assert.equal(modelRequest.stream, true);
  assert.match(modelRequest.messages[1].content, /林林，2年级/);
  assert.match(modelRequest.messages[1].content, /口算本第 12 页（还没做）/);
  assert.match(modelRequest.messages.at(-1).content, /孩子说：三十八加二十七怎么算/);

  const kinds = events.slice(events.findIndex(e => e.type === 'response.start')).map(e => e.type ?? 'binary');
  assert.deepEqual(kinds, ['response.start', 'segment', 'binary', 'binary', 'segment.audio.done', 'segment', 'binary', 'binary', 'segment.audio.done', 'response.done']);
  assert.deepEqual(events.filter(e => e.binary).map(e => e.binary.length - 4), [2, 2, 2, 2], 'whole samples only');
  const segments = events.filter(e => e.type === 'segment');
  assert.deepEqual(segments[1].board, [{ op: 'update', el: { id: 'v1', type: 'vertical', a: 38, b: 27, operator: '+', reveal: 0, focus: 0 } }], 'invalid element dropped');
  assert.equal(segments[1].await, true);
  const audio = events.filter(e => e.binary);
  assert.deepEqual([...audio[1].binary.subarray(4)], [1, 0], 'the split sample is rejoined');
  assert.equal(audio[2].binary.readUInt16BE(0), segments[1].response);
  assert.equal(audio[2].binary.readUInt16BE(2), 1, 'segment index in the frame header');

  // The second turn carries the history and the current board.
  send({ type: 'input.text', text: '十五' });
  await until(e => e.type === 'response.done' && e.response === segments[0].response + 1);
  assert.equal(modelRequest.messages[2].content, '三十八加二十七怎么算');
  assert.equal(modelRequest.messages[3].content, '我们来算三十八加二十七。个位八加七等于几？');
  assert.match(modelRequest.messages.at(-1).content, /"id":"v1"/);
});

test('teacher session: speech goes through streaming ASR, and a barge-in cancels the response', async t => {
  let release, modelSignal;
  const fetchImpl = async (url, init) => { modelSignal = init.signal; return new Response((async function* () {
    yield Buffer.from(`data: ${JSON.stringify({ choices: [{ delta: { content: '{"speech":"第一段"}\n' } }] })}\n\n`);
    await new Promise(resolve => { release = resolve; init.signal.addEventListener('abort', resolve); });
    yield Buffer.from(`data: ${JSON.stringify({ choices: [{ delta: { content: '{"speech":"第二段"}\n' } }] })}\n\n`);
  })()); };
  const received = [];
  let aborted = 0;
  const asr = { stream({ onText }) {
    return { write(pcm) { received.push(pcm.length); onText(received.length === 1 ? '八加' : '八加七'); }, end: async () => ({ text: '八加七' }), abort() { aborted++; } };
  } };
  const { connect, childId } = await setup(t, { fetchImpl, asr });
  const { ws, send, until, events } = await connect();
  send({ type: 'session.start', childId });
  const ready = await until(e => e.type === 'session.ready');
  assert.deepEqual(ready.audio.input, { format: 'pcm_s16le', sample_rate: 16000, channels: 1 });
  ws.send(new Uint8Array(3200)); ws.send(new Uint8Array(3200));
  await until(e => e.type === 'input.transcript.partial' && e.text === '八加七');
  send({ type: 'input.audio.end' });
  assert.equal((await until(e => e.type === 'input.transcript.final')).text, '八加七');
  await until(e => e.type === 'segment.audio.done');
  assert.equal(events.find(e => e.type === 'segment.audio.done').audio, false, 'no TTS configured');
  const running = events.find(e => e.type === 'response.start').response;
  send({ type: 'response.cancel', response: running - 1 });
  await until(e => e.type === 'response.cancelled');
  await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(modelSignal.aborted, false, 'a cancel for an older reply leaves this one running');
  events.length = events.findIndex(e => e.type === 'response.cancelled'); // forget the first acknowledgement
  send({ type: 'response.cancel', response: running });
  await until(e => e.type === 'response.cancelled');
  assert.equal(modelSignal.aborted, true);
  release?.();
  await new Promise(resolve => setTimeout(resolve, 50));
  assert.equal(events.filter(e => e.type === 'segment').length, 1, 'nothing after the barge-in');
  assert.ok(!events.some(e => e.type === 'response.done'));
  assert.deepEqual(received, [3200, 3200]);

  // Typing while a sentence is being heard drops that sentence instead of leaving its recognition open.
  ws.send(new Uint8Array(3200));
  await until(e => e.type === 'input.transcript.partial' && events.indexOf(e) > events.findIndex(x => x.type === 'response.cancelled'));
  send({ type: 'input.text', text: '我打字', turn: 3 });
  await until(e => e.type === 'input.transcript.final' && e.text === '我打字' && e.turn === 3);
  assert.equal(aborted, 1);
});

test('teacher session: an interrupted reply keeps only what was heard and puts the board back', async t => {
  const requests = [];
  const fetchImpl = async (url, init) => {
    requests.push(JSON.parse(init.body));
    return new Response(sse([
      '{"speech":"先列竖式。","board":[{"op":"add","el":{"id":"v1","type":"vertical","a":38,"b":27,"operator":"+"}}]}\n',
      '{"speech":"个位写五。","board":[{"op":"update","id":"v1","set":{"reveal":1}}]}\n',
      '{"speech":"十位写六。","board":[{"op":"update","id":"v1","set":{"reveal":2}}]}\n']));
  };
  const { connect, childId } = await setup(t, { fetchImpl });
  const { send, until, events } = await connect();
  send({ type: 'session.start', childId });
  await until(e => e.type === 'session.ready');
  send({ type: 'input.text', text: '三十八加二十七', turn: 1 });
  const done = await until(e => e.type === 'response.done'); // generated in full, long before it would be spoken
  // The child speaks up while the second segment is playing.
  send({ type: 'response.cancel', response: done.response, played: 2 });
  await until(e => e.type === 'response.cancelled');
  send({ type: 'input.text', text: '等一下', turn: 2 });
  await until(e => e.type === 'response.done' && e.response !== done.response);
  const second = requests[1].messages;
  assert.equal(second.at(-2).content, '先列竖式。个位写五。（说到这里被孩子打断了）');
  assert.match(second.at(-1).content, /"reveal":1/, 'the board is what the child saw, not what was generated');

  // A reply that never started playing leaves no words and no drawing behind.
  const third = events.filter(e => e.type === 'response.start').at(-1).response;
  send({ type: 'response.cancel', response: third, played: 0 });
  events.length = 0;
  send({ type: 'input.text', text: '重新来', turn: 3 });
  await until(e => e.type === 'response.done');
  assert.equal(requests[2].messages.at(-2).content, '（还没开口就被孩子打断了）');
  assert.match(requests[2].messages.at(-1).content, /"reveal":1/);
});

test('teacher session: mock lesson without a model, unknown child and bad credentials are refused', async t => {
  const { connect, childId } = await setup(t, { mock: true, withModel: false });
  const { send, until, events } = await connect();
  send({ type: 'input.text', text: '你好' });
  assert.equal((await until(e => e.type === 'error')).code, 'session_not_started');
  send({ type: 'session.start', childId: randomUUID() });
  await until(e => e.code === 'child_not_found');
  send({ type: 'session.start', childId });
  await until(e => e.type === 'session.ready');
  send({ type: 'input.text', text: '教我做题' });
  await until(e => e.type === 'response.done');
  const ops = events.filter(e => e.type === 'segment').flatMap(e => e.board);
  assert.ok(ops.some(op => op.el?.type === 'vertical' && op.el.reveal === 1));
  await assert.rejects(connect('not-a-real-token'));
});
