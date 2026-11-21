import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createGateway } from '../src/gateway.mjs';
import { createApi } from '../src/api.mjs';
import { Board, describeLearner, normalizeSegment, segmentLine } from '../src/board.mjs';
import { cleanCard, transcriptText } from '../src/memory.mjs';
import { checkedSegments } from '../src/teacher.mjs';

const bootstrapToken = 'parent-bootstrap-token-not-a-secret';
const model = { apiUrl: 'https://model.example/v1/chat/completions', apiKey: 'test-key', model: 'test-model', thinking: 'disabled' };
const sse = lines => new Response(lines.map(content => `data: ${JSON.stringify({ choices: [{ delta: { content } }] })}\n\n`).join('') + 'data: [DONE]\n\n');

test('a card keeps note lines only and stays short', () => {
  assert.equal(cleanCard('```\n- 11-18 进位加法：十位忘加进上来的一\n好的，以上是卡片。\n• 11-18 会背《静夜思》\n```'),
    '- 11-18 进位加法：十位忘加进上来的一\n- 11-18 会背《静夜思》');
  assert.equal(cleanCard('（无）'), '');
  assert.equal(cleanCard(Array.from({ length: 20 }, (_, i) => `- 第${i}条`).join('\n')).split('\n').length, 8);
  assert.equal(transcriptText([{ child: '八加七\n等于几', teacher: '十五。' }]), '孩子：八加七 等于几\n小熊：十五。');
});

test('learner facts carry the notes; a goodbye segment ends and does not wait', () => {
  const text = describeLearner({ child: { name: '林林', grade: 2 }, today: '2026-11-18', homework: [], memory: '- 11-17 进位加法十位忘加一' });
  assert.match(text, /以前对话的小结（小熊老师自己记的）：\n- 11-17 进位加法十位忘加一/);
  const segment = normalizeSegment({ speech: '再见！', board: [], await: true, end: true }, new Board());
  assert.deepEqual(segment, { speech: '再见！', board: [], await: false, end: true });
  assert.equal(segmentLine(segment), '{"speech":"再见！","board":[],"end":true}');
});

test('nothing is said after the goodbye', async () => {
  const post = async () => sse(['{"speech":"再见，子安！","board":[],"end":true}\n', '{"speech":"对了，还有一件事。","board":[]}\n']);
  const out = [];
  for await (const segment of checkedSegments([{ role: 'user', content: '再见' }], post, { model: 'm' }, undefined)) out.push(segment.speech);
  assert.deepEqual(out, ['再见，子安！']);
});

async function setup(t, fetchImpl) {
  const dataDir = mkdtempSync(join(tmpdir(), 'littlebear-memory-'));
  const api = createApi({ dataDir, bootstrapToken });
  const server = createGateway({ token: 'device-test-token-not-a-secret-12345', api, voice: { mock: false }, teacher: { model } }, { fetchImpl });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `127.0.0.1:${server.address().port}`;
  const sockets = [];
  t.after(() => new Promise(resolve => {
    for (const ws of sockets) ws.close();
    setTimeout(() => server.close(() => { api.close(); rmSync(dataDir, { recursive: true, force: true }); resolve(); }), 20);
    server.closeAllConnections();
  }));
  const call = async (method, path, token, body) => {
    const response = await fetch(`http://${base}${path}`, { method, headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body && JSON.stringify(body) });
    return { status: response.status, body: await response.json() };
  };
  const parent = (await call('POST', '/v1/devices/bootstrap', null, { token: bootstrapToken, deviceId: randomUUID(), name: 'iPhone' })).body.deviceToken;
  const childId = randomUUID();
  await call('PUT', `/v1/children/${childId}`, parent, { name: '林林', grade: 2 });
  const code = (await call('POST', '/v1/devices/pairing-codes', parent)).body.code;
  const childDevice = (await call('POST', '/v1/devices/pair', null, { code, deviceId: randomUUID(), name: 'iPad' })).body.deviceToken;
  /** One conversation: says each sentence, waits for the reply, then closes. */
  async function talk(sentences) {
    const ws = new WebSocket(`ws://${base}/v1/teacher`, ['littlebear.teacher.v1', `littlebear.token.${childDevice}`]);
    sockets.push(ws);
    const events = [];
    ws.onmessage = event => { if (typeof event.data === 'string') events.push(JSON.parse(event.data)); };
    await new Promise((resolve, reject) => { ws.onopen = resolve; ws.onerror = reject; });
    const until = async predicate => { for (let i = 0; i < 400; i++) { const found = events.find(predicate); if (found) return found; await new Promise(r => setTimeout(r, 5)); } throw new Error(`timeout: ${JSON.stringify(events.map(e => e.type))}`); };
    ws.send(JSON.stringify({ type: 'session.start', childId }));
    await until(e => e.type === 'session.ready');
    let turn = 0;
    for (const text of sentences) {
      const seen = events.filter(e => e.type === 'response.done').length;
      ws.send(JSON.stringify({ type: 'input.text', text, turn: ++turn }));
      for (let i = 0; i < 400 && events.filter(e => e.type === 'response.done').length === seen; i++) await new Promise(r => setTimeout(r, 5));
    }
    ws.close();
    return events;
  }
  const memory = () => call('GET', `/v1/children/${childId}/teacher-memory`, parent);
  const settled = async predicate => { for (let i = 0; i < 400; i++) { const m = (await memory()).body; if (predicate(m)) return m; await new Promise(r => setTimeout(r, 5)); } throw new Error('memory did not settle'); };
  return { call, parent, childDevice, childId, talk, memory, settled };
}

test('after a conversation the notes are rewritten, the next one starts with them, and the parent can clear them', async t => {
  const requests = [];
  let card = '- 11-18 进位加法：十位忘了加进上来的一\n- 11-18 喜欢用数轴';
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body);
    requests.push(body);
    if (body.stream) return sse(['{"speech":"个位八加七等于几？","board":[],"await":true}\n']);
    return Response.json({ choices: [{ message: { content: card } }] });
  };
  const { call, parent, childDevice, childId, talk, memory, settled } = await setup(t, fetchImpl);
  assert.deepEqual((await memory()).body, { card: '', sessions: 0, updatedAt: null });

  await talk(['教我算三十八加二十七', '十四']);
  const first = await settled(m => m.sessions === 1);
  assert.equal(first.card, card);
  const summary = requests.find(r => !r.stream);
  assert.equal(summary.stream, false);
  assert.deepEqual(summary.thinking, { type: 'disabled' });
  assert.match(summary.messages[1].content, /【旧卡片】\n（无）\n【这次对话】\n孩子：教我算三十八加二十七\n小熊：个位八加七等于几？\n孩子：十四/);
  assert.doesNotMatch(summary.messages[1].content, /"board"/, 'words only, not the drawing ops');

  // The next conversation knows the notes, and its summary starts from them.
  card = '- 11-18 进位加法：已掌握';
  requests.length = 0;
  await talk(['再来一道', '十五']);
  assert.match(requests.find(r => r.stream).messages[1].content, /以前对话的小结（小熊老师自己记的）：\n- 11-18 进位加法：十位忘了加进上来的一/);
  const second = await settled(m => m.sessions === 2);
  assert.equal(second.card, '- 11-18 进位加法：已掌握');
  assert.match(requests.find(r => !r.stream).messages[1].content, /【旧卡片】\n- 11-18 进位加法：十位忘了加进上来的一/);

  // Only a parent device reads or clears the notes.
  assert.equal((await call('GET', `/v1/children/${childId}/teacher-memory`, childDevice)).status, 403);
  assert.equal((await call('DELETE', `/v1/children/${childId}/teacher-memory`, parent)).status, 200);
  assert.equal((await memory()).body.card, '');
});

test('a one-line chat, an empty reply or a failed summary leaves the notes as they were', async t => {
  let summary = () => Response.json({ choices: [{ message: { content: '- 11-18 会二的乘法口诀' } }] });
  let summaries = 0;
  const fetchImpl = async (url, init) => {
    if (JSON.parse(init.body).stream) return sse(['{"speech":"好的。","board":[]}\n']);
    summaries++;
    return summary();
  };
  const { talk, settled, memory } = await setup(t, fetchImpl);
  await talk(['你好']);
  await new Promise(r => setTimeout(r, 50));
  assert.equal(summaries, 0, 'one sentence is not worth a summary');
  await talk(['二二得几', '四']);
  await settled(m => m.sessions === 1);
  summary = () => Response.json({ choices: [{ message: { content: '（无）' } }] });
  await talk(['你好', '再见']);
  summary = () => new Response('nope', { status: 502 });
  await talk(['你好', '再见']);
  await new Promise(r => setTimeout(r, 80));
  assert.equal(summaries, 3);
  assert.deepEqual([(await memory()).body.card, (await memory()).body.sessions], ['- 11-18 会二的乘法口诀', 1]);
});
