import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { createGateway } from '../src/gateway.mjs';
import { createApi } from '../src/api.mjs';
import { columnCalc, shown } from '../../web/teacher/calc.mjs';
import { VoiceActivityDetector, levelOf } from '../../web/teacher/vad.mjs';

const bootstrapToken = 'parent-bootstrap-token-not-a-secret';

test('web column calc: carries, borrows and shown digits', () => {
  assert.deepEqual({ ...columnCalc(38, 27, '+'), borrows: undefined }, { a: 38, b: 27, operator: '+', result: 65, carries: { 1: 1 }, borrows: undefined, width: 2 });
  assert.deepEqual(columnCalc(999, 1, '+').carries, { 1: 1, 2: 1, 3: 1 });
  assert.equal(columnCalc(999, 1, '+').width, 4);
  assert.deepEqual([...columnCalc(52, 17, '-').borrows], [1]);
  assert.deepEqual([...columnCalc(100, 1, '-').borrows], [1, 2], 'borrowing across a zero');
  assert.equal(columnCalc(100, 1, '-').result, 99);
  assert.deepEqual(columnCalc(47, 6, '×').carries, { 1: 4, 2: 2 });
  assert.equal(columnCalc(47, 6, '×').result, 282);
  assert.equal(shown(65, 0), 5);
  assert.equal(shown(65, 2), null);
  assert.equal(shown(0, 0), 0);
});

test('web voice activity detector: ignores clicks, ends after a pause, stricter while the teacher talks', () => {
  const vad = new VoiceActivityDetector();
  for (let i = 0; i < 25; i++) assert.equal(vad.process(-62, 40), null);
  assert.equal(vad.process(-20, 40), null, 'a short click is not speech');
  assert.equal(vad.process(-62, 40), null);
  const events = [];
  for (let i = 0; i < 6; i++) events.push(vad.process(-25, 40));
  assert.deepEqual(events.filter(Boolean), ['start']);
  for (let i = 0; i < 10; i++) assert.equal(vad.process(-62, 40), null, 'a short pause does not end the sentence');
  assert.equal(vad.process(-25, 40), null);
  const after = [];
  for (let i = 0; i < 22; i++) after.push(vad.process(-62, 40));
  assert.deepEqual(after.filter(Boolean), ['end']);

  const echo = new VoiceActivityDetector();
  for (let i = 0; i < 25; i++) echo.process(-62, 40, true);
  for (let i = 0; i < 10; i++) assert.equal(echo.process(-42, 40, true), null, 'residual echo does not barge in');
  let started = false;
  for (let i = 0; i < 10 && !started; i++) started = echo.process(-42, 40, false) === 'start';
  assert.ok(started);

  assert.ok(Math.abs(levelOf(new Int16Array(100).fill(32767))) < 0.01, "full scale is 0 dBFS");
  assert.equal(levelOf(new Int16Array(100)), -100);
});

test('teacher web page is served with a CSP, and the WebSocket accepts a device token as a subprotocol', async t => {
  const dataDir = mkdtempSync(join(tmpdir(), 'littlebear-teacher-web-'));
  const api = createApi({ dataDir, bootstrapToken });
  const server = createGateway({ token: 'device-test-token-not-a-secret-12345', api, voice: { mock: true } });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const host = `127.0.0.1:${server.address().port}`;
  const sockets = [];
  t.after(() => new Promise(resolve => {
    for (const ws of sockets) ws.close();
    setTimeout(() => server.close(() => { api.close(); rmSync(dataDir, { recursive: true, force: true }); resolve(); }), 20);
    server.closeAllConnections();
  }));

  const page = await fetch(`http://${host}/teacher/`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type'), /text\/html/);
  assert.match(page.headers.get('content-security-policy'), new RegExp(`connect-src 'self' ws://${host} wss://${host};`));
  assert.match(await page.text(), /小熊老师/);
  const module = await fetch(`http://${host}/teacher/app.mjs`);
  assert.match(module.headers.get('content-type'), /text\/javascript/);
  assert.equal((await fetch(`http://${host}/teacher`, { redirect: 'manual' })).status, 301);
  assert.equal((await fetch(`http://${host}/teacher/..%2f..%2fserver%2f.env.example`)).status, 404);
  assert.equal((await fetch(`http://${host}/teacher/README.md`)).status, 404, 'only page assets are served');
  assert.equal((await fetch(`http://${host}/teacher/`, { method: 'POST' })).status, 405);

  const json = async (method, path, token, body) => (await fetch(`http://${host}${path}`, { method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: JSON.stringify(body) })).json();
  const token = (await json('POST', '/v1/devices/bootstrap', null, { token: bootstrapToken, deviceId: randomUUID(), name: '网页' })).deviceToken;
  const childId = randomUUID();
  await json('PUT', `/v1/children/${childId}`, token, { name: '林林', grade: 2 });

  const open = protocols => new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://${host}/v1/teacher`, protocols);
    sockets.push(ws);
    ws.onopen = () => resolve(ws); ws.onerror = () => reject(new Error('refused'));
  });
  const ws = await open(['littlebear.teacher.v1', `littlebear.token.${token}`]);
  assert.equal(ws.protocol, 'littlebear.teacher.v1', 'the server selects the protocol, never the token');
  const events = [];
  ws.onmessage = event => events.push(JSON.parse(event.data));
  ws.send(JSON.stringify({ type: 'session.start', childId }));
  await new Promise(resolve => { const timer = setInterval(() => { if (events.some(e => e.type === 'session.ready')) { clearInterval(timer); resolve(); } }, 3); });
  await assert.rejects(open(['littlebear.teacher.v1', 'littlebear.token.not-a-real-token-0000000000000000']));
  await assert.rejects(open(['littlebear.teacher.v1']));
});
