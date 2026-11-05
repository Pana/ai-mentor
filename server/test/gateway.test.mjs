import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createGateway, validateRequest, validateReply, providerBody } from '../src/gateway.mjs';

const token = 'device-test-token-not-a-secret-12345';
const config = { token, apiUrl: 'https://model.example/v1/chat/completions', apiKey: 'upstream-test-key', model: 'configured-model', jsonMode: true };
const input = { mode: 'help', grade: 2, subject: 'MATH', title: '加法作业', message: '个位怎么计算？', history: [] };
const reply = content => new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(content) } }] }), { status: 200 });
async function withServer(t, overrides = {}, dependencies = {}) {
  const server = createGateway({ ...config, ...overrides }, dependencies);
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const url = `http://127.0.0.1:${server.address().port}`;
  return (body = input, auth = token) => fetch(url + '/v1/tutor', { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${auth}` }, body: JSON.stringify(body) });
}

test('requires a device credential before invoking the model', async t => {
  let calls = 0;
  const post = await withServer(t, {}, { fetchImpl: async () => { calls++; return reply({ message: '提示' }); } });
  assert.equal((await post(input, 'wrong')).status, 401);
  assert.equal(calls, 0);
});

test('missing model configuration is explicit, never simulated tutoring', async t => {
  const post = await withServer(t, { apiKey: '' });
  const response = await post();
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: 'model_not_configured' });
});

test('sends configured credentials upstream and returns only the validated result', async t => {
  let request;
  const post = await withServer(t, {}, { fetchImpl: async (url, options) => { request = { url, options }; return reply({ message: '先看看个位相加是多少。', assessment: 'CORRECT', ignored: 'private' }); } });
  const response = await post();
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { message: '先看看个位相加是多少。', assessment: 'UNKNOWN' });
  assert.equal(request.options.headers.Authorization, 'Bearer upstream-test-key');
  const body = JSON.parse(request.options.body);
  assert.equal(body.model, config.model);
  assert.equal(body.messages[0].role, 'system');
  assert.equal(body.messages.at(-1).content[0].type, 'text');
  assert.ok(!JSON.stringify(body).includes(token));
});

test('invalid child grade, subject, mode, history and photo are rejected', () => {
  for (const change of [{ grade: 6 }, { subject: 'BIOLOGY' }, { mode: 'delete' }, { message: 'x'.repeat(2001) }, { history: [{}] }, { image: 'not-base64' }, { mode: 'recognize' }]) {
    assert.throws(() => validateRequest({ ...input, ...change }));
  }
});

test('photo input uses a JPEG data URL and only current task history', () => {
  const image = Buffer.from([0xff, 0xd8, 0xff, 0x00]).toString('base64');
  const body = providerBody(validateRequest({ ...input, image, history: [{ question: '我算到32', reply: '再看看个位' }] }), config);
  assert.equal(body.messages.length, 4);
  assert.equal(body.messages.at(-1).content[1].image_url.url, `data:image/jpeg;base64,${image}`);
  assert.ok(!('response_format' in providerBody(validateRequest(input), { ...config, jsonMode: false })));
});

test('ambiguous checking remains UNKNOWN and malformed answers are rejected', () => {
  assert.equal(validateReply('{"message":"请补拍题目","assessment":"UNKNOWN"}', { ...input, mode: 'check' }).assessment, 'UNKNOWN');
  for (const value of ['not json', '{}', '{"message":"提示","assessment":"MAYBE"}']) assert.throws(() => validateReply(value, input));
});

test('recognition is a draft with subject and readable requirements', () => {
  const result = validateReply(JSON.stringify({ message: '请核对页码', title: '数学', instructions: '第20页', subject: 'MATH' }), { ...input, mode: 'recognize' });
  assert.equal(result.instructions, '第20页');
  assert.equal(result.assessment, 'UNKNOWN');
});

test('generated exercise IDs and subjects are controlled by the gateway', () => {
  const result = validateReply(JSON.stringify({ message: '试试新题', exercise: { id: 'injected', subject: 'ENGLISH', concept: '加法', prompt: '2+3=?', answer: '5', hints: ['数一数', '加三个', '五个'], explanation: '2+3=5' } }), { ...input, mode: 'practice' });
  assert.notEqual(result.exercise.id, 'injected');
  assert.equal(result.exercise.subject, 'MATH');
  assert.equal(result.exercise.hints.length, 3);
});

test('upstream failures never expose its body or key', async t => {
  const post = await withServer(t, {}, { fetchImpl: async () => new Response('upstream-test-key private prompt', { status: 500 }) });
  const response = await post();
  assert.equal(response.status, 502);
  assert.deepEqual(await response.json(), { error: 'model_unavailable' });
});

test('oversized model replies fail closed', async t => {
  const post = await withServer(t, {}, { fetchImpl: async () => reply({ message: 'x'.repeat(70_000) }) });
  assert.notEqual((await post()).status, 200);
});

test('enforces per-device request limits', async t => {
  const post = await withServer(t, {}, { fetchImpl: async () => reply({ message: '提示' }), now: () => 1000 });
  for (let i = 0; i < 20; i++) assert.equal((await post()).status, 200);
  assert.equal((await post()).status, 429);
});

test('rejects insecure remote upstream URLs and weak device credentials', () => {
  assert.throws(() => createGateway({ ...config, token: 'short' }));
  assert.throws(() => createGateway({ ...config, apiUrl: 'http://remote.example/chat' }));
  assert.throws(() => createGateway({ ...config, apiUrl: 'https://user:password@example.com/chat' }));
});

test('disconnecting the client aborts the upstream operation', async t => {
  let started;
  const start = new Promise(resolve => { started = resolve; });
  let aborted;
  const abort = new Promise(resolve => { aborted = resolve; });
  const server = createGateway(config, { fetchImpl: async (_url, options) => {
    started();
    return new Promise((_resolve, reject) => options.signal.addEventListener('abort', () => { aborted(); reject(new Error('cancelled')); }, { once: true }));
  } });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(resolve); server.closeAllConnections(); }));
  const controller = new AbortController();
  const response = fetch(`http://127.0.0.1:${server.address().port}/v1/tutor`, { method: 'POST', signal: controller.signal,
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify(input) }).catch(() => null);
  await start;
  controller.abort();
  await response;
  let timer;
  try { await Promise.race([abort, new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('upstream not cancelled')), 2000); })]); }
  finally { clearTimeout(timer); }
});
