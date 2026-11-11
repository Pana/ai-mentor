import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createGateway } from '../src/gateway.mjs';
import { createHanzi, validateLookupReply, validStrokeData, normalizeQuery, normalizeDetailWord } from '../src/hanzi.mjs';

const token = 'device-test-token-not-a-secret-12345';
const model = { apiUrl: 'https://model.test/chat/completions', apiKey: 'k', model: 'm', jsonMode: true };
const strokeJson = { strokes: ['M 1 1 Z', 'M 2 2 Z'], medians: [[[1, 1]], [[2, 2]]], radStrokes: [0] };
const jiang = { word: '江', chars: [{ char: '江', pinyin: 'jiāng', radical: '氵', radical_name: '三点水', radical_meaning: '和水有关',
  structure: '左右结构', meaning: '大河', words: ['长江', '江水'], tip: '三点水加工' }], alternatives: [], message: '' };

async function setup(t, { reply = jiang, replies = [], strokes = strokeJson } = {}) {
  const dataDir = mkdtempSync(join(tmpdir(), 'hanzi-'));
  const webDir = join(dataDir, 'web');
  mkdirSync(webDir);
  writeFileSync(join(webDir, 'index.html'), '<!doctype html><title>小熊写字</title>');
  writeFileSync(join(dataDir, 'secret.txt'), 'nope');
  const calls = { model: [], strokes: [] };
  const fetchImpl = async (url, init) => {
    if (url === model.apiUrl) {
      calls.model.push(JSON.parse(init.body));
      const content = replies.length ? replies.shift() : reply;
      return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(content) } }] }));
    }
    calls.strokes.push(url);
    return strokes ? new Response(JSON.stringify(strokes)) : new Response('Not found', { status: 404 });
  };
  const hanzi = createHanzi({ token, model, dataDir, webDir, fetchImpl });
  const server = createGateway({ token, hanzi });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(() => { rmSync(dataDir, { recursive: true, force: true }); resolve(); }); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${server.address().port}`;
  const post = path => (body, auth = token) => fetch(`${base}${path}`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(auth ? { Authorization: `Bearer ${auth}` } : {}) }, body: JSON.stringify(body) });
  return { base, calls, lookup: post('/v1/hanzi/lookup'), detail: post('/v1/hanzi/detail') };
}

test('lookup turns what the child said into characters and caches the answer', async t => {
  const { lookup, calls } = await setup(t);
  const first = await lookup({ text: '  三点水的将 ' });
  assert.equal(first.status, 200);
  const body = await first.json();
  assert.equal(body.word, '江');
  assert.deepEqual(body.chars[0], { char: '江', pinyin: 'jiāng', radical: '氵', radicalName: '三点水', radicalMeaning: '和水有关',
    structure: '左右结构', meaning: '大河', words: ['长江', '江水'], tip: '三点水加工' });
  assert.equal(JSON.parse(calls.model[0].messages[1].content).text, '三点水的将');
  assert.equal((await lookup({ text: '三点水的将' })).status, 200);
  assert.equal(calls.model.length, 1);
});

test('lookup needs the device token and a short text', async t => {
  const { lookup } = await setup(t);
  assert.equal((await lookup({ text: '江' }, null)).status, 401);
  assert.equal((await lookup({ text: '江' }, 'wrong-token-wrong-token-wrong-token!')).status, 401);
  assert.equal((await lookup({ text: '' })).status, 400);
  assert.equal((await lookup({ text: '字'.repeat(61) })).status, 400);
});

test('detail describes decided characters and shares the answer cache with lookup', async t => {
  const { detail, lookup, calls } = await setup(t);
  const first = await detail({ word: '江' });
  assert.equal(first.status, 200);
  const body = await first.json();
  assert.equal(body.word, '江');
  assert.equal(body.chars[0].pinyin, 'jiāng');
  assert.deepEqual(body.alternatives, []);
  assert.match(calls.model[0].messages[0].content, /已经确定/);
  assert.equal(JSON.parse(calls.model[0].messages[1].content).word, '江');
  assert.equal((await detail({ word: ' 江 ' })).status, 200);   // same word, served from cache
  assert.equal((await lookup({ text: '江' })).status, 200);     // detail answers satisfy lookup too
  assert.equal(calls.model.length, 1);
});

test('detail needs the device token and a word of plain han characters', async t => {
  const { detail, calls } = await setup(t);
  assert.equal((await detail({ word: '江' }, null)).status, 401);
  assert.equal((await detail({ word: 'ma' })).status, 400);
  assert.equal((await detail({ word: '' })).status, 400);
  assert.equal((await detail({ word: '江!' })).status, 400);
  assert.equal((await detail({ word: '字'.repeat(9) })).status, 400);
  assert.equal(calls.model.length, 0);                          // nothing reached the model
  const wordy = await setup(t, { reply: { word: '长江', chars: [{ char: '长' }, { char: '江' }], alternatives: [], message: '' } });
  assert.equal((await wordy.detail({ word: '长江' })).status, 200);   // a decided word is fine too
  assert.equal(normalizeDetailWord(' 长  江 '), '长江');
  assert.equal(normalizeDetailWord('妈妈的妈'), '妈妈的妈');
  assert.equal(normalizeDetailWord('mǎ'), null);
});

test('detail retries once when the model swaps the characters, then gives up', async t => {
  const he = { word: '河', chars: [{ char: '河', pinyin: 'hé' }], alternatives: [], message: '' };
  const retried = await setup(t, { replies: [he, jiang] });
  const recovered = await retried.detail({ word: '江' });
  assert.equal(recovered.status, 200);
  assert.equal((await recovered.json()).word, '江');
  assert.equal(retried.calls.model.length, 2);
  const stubborn = await setup(t, { replies: [he, he] });
  assert.equal((await stubborn.detail({ word: '江' })).status, 502);
  assert.equal(stubborn.calls.model.length, 2);
});

test('answers survive a server restart in the database', async t => {
  const dataDir = mkdtempSync(join(tmpdir(), 'hanzi-db-'));
  const webDir = join(dataDir, 'web');
  mkdirSync(webDir);
  writeFileSync(join(webDir, 'index.html'), '<!doctype html><title>小熊写字</title>');
  let modelCalls = 0;
  const fetchImpl = async url => {
    if (url === model.apiUrl) { modelCalls++; return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(jiang) } }] })); }
    return new Response(JSON.stringify(strokeJson));
  };
  const start = () => new Promise(resolve => {
    const hanzi = createHanzi({ token, model, dataDir, webDir, fetchImpl });
    const server = createGateway({ token, hanzi });
    server.listen(0, '127.0.0.1', () => resolve({ hanzi, server, base: `http://127.0.0.1:${server.address().port}` }));
  });
  const stop = run => new Promise(resolve => run.server.close(() => { run.server.closeAllConnections(); run.hanzi.close(); resolve(); }));
  const ask = (run, word) => fetch(`${run.base}/v1/hanzi/detail`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify({ word }) });
  t.after(() => rmSync(dataDir, { recursive: true, force: true }));

  const first = await start();
  assert.equal((await ask(first, '江')).status, 200);
  assert.equal(modelCalls, 1);
  await stop(first);

  const second = await start();                       // same dataDir: a "restarted" server
  const reply = await ask(second, '江');
  assert.equal(reply.status, 200);
  assert.equal((await reply.json()).word, '江');
  assert.equal(modelCalls, 1);                        // served from the database, model untouched
  await stop(second);
});

test('stroke data is fetched once, validated and cached on disk', async t => {
  const { base, calls } = await setup(t);
  const url = `${base}/hanzi/strokes/${encodeURIComponent('江')}.json`;
  const first = await fetch(url);
  assert.equal(first.status, 200);
  assert.deepEqual(await first.json(), strokeJson);
  assert.equal((await fetch(url)).status, 200);
  assert.equal(calls.strokes.length, 1);
  assert.equal((await fetch(`${base}/hanzi/strokes/a.json`)).status, 400);
  assert.equal((await fetch(`${base}/hanzi/strokes/${encodeURIComponent('江水')}.json`)).status, 400);
});

test('missing stroke data is a 404, malformed data is not cached', async t => {
  const missing = await setup(t, { strokes: null });
  assert.equal((await fetch(`${missing.base}/hanzi/strokes/${encodeURIComponent('江')}.json`)).status, 404);
  const broken = await setup(t, { strokes: { strokes: ['M 1 1 Z'], medians: [] } });
  assert.equal((await fetch(`${broken.base}/hanzi/strokes/${encodeURIComponent('江')}.json`)).status, 502);
});

test('the page is served without escaping its folder', async t => {
  const { base } = await setup(t);
  const page = await fetch(`${base}/hanzi/`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type'), /text\/html/);
  assert.match(page.headers.get('content-security-policy'), /default-src 'self'/);
  const session = page.headers.get('set-cookie')?.split(';', 1)[0];
  assert.match(session, /^hanzi_session=/);
  const autoLookup = await fetch(`${base}/v1/hanzi/lookup`, { method: 'POST', headers: { 'Content-Type': 'application/json', Cookie: session }, body: JSON.stringify({ text: '江' }) });
  assert.equal(autoLookup.status, 200);
  assert.equal((await fetch(`${base}/hanzi`, { redirect: 'manual' })).status, 301);
  assert.equal((await fetch(`${base}/hanzi/%2e%2e/secret.txt`)).status, 404);
  assert.equal((await fetch(`${base}/hanzi/..%2fsecret.txt`)).status, 404);
  assert.equal((await fetch(`${base}/hanzi/%E0%A4%A.html`)).status, 404);
});

test('model replies are cleaned up', () => {
  const reply = validateLookupReply(JSON.stringify({ word: '妈妈', chars: [{ char: '妈', pinyin: 'mā', words: ['妈妈', 'mama', '姨妈'] },
    { char: '妈' }, { char: 'ab' }], alternatives: [{ char: '吗', pinyin: 'ma', hint: '如 好吗的吗' }, { char: '妈' }] }));
  assert.equal(reply.word, '妈妈');
  assert.equal(reply.chars.length, 1);
  assert.deepEqual(reply.chars[0].words, ['妈妈', '姨妈']);
  assert.deepEqual(reply.alternatives, [{ char: '吗', pinyin: 'ma', hint: '好吗的吗' }]);
  assert.equal(validateLookupReply(JSON.stringify({ chars: [{ char: '如' }], alternatives: [{ char: '茹', hint: '如果的如' }] })).alternatives[0].hint, '如果的如');
  assert.equal(validateLookupReply(JSON.stringify({ word: '长江', chars: [{ char: '江' }] })).word, '江');
  assert.equal(validateLookupReply(JSON.stringify({ chars: [], message: '没听清楚' })).message, '没听清楚');
  assert.throws(() => validateLookupReply(JSON.stringify({ chars: [] })));
  assert.throws(() => validateLookupReply('not json'));
  assert.equal(validStrokeData(strokeJson), true);
  assert.equal(validStrokeData({ strokes: [], medians: [] }), false);
  assert.equal(normalizeQuery('  妈妈 的  妈 '), '妈妈 的 妈');
  assert.equal(normalizeQuery(42), null);
});
