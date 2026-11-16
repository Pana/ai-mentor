import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createGateway } from '../src/gateway.mjs';
import { createHanzi, lookupBody, detailBody, validateLookupReply, validStrokeData, normalizeQuery, normalizeDetailWord, radicalOf, withRadicals } from '../src/hanzi.mjs';
import { openDatabase } from '../src/db.mjs';

const token = 'device-test-token-not-a-secret-12345';
const model = { apiUrl: 'https://model.test/chat/completions', apiKey: 'k', model: 'm', jsonMode: true };
// 江 has six strokes; upstream marks the wrong radical strokes on purpose, the server must use its own table.
const strokeJson = { strokes: ['M 1 1 Z', 'M 2 2 Z', 'M 3 3 Z', 'M 4 4 Z', 'M 5 5 Z', 'M 6 6 Z'],
  medians: [[[1, 1]], [[2, 2]], [[3, 3]], [[4, 4]], [[5, 5]], [[6, 6]]], radStrokes: [3, 4, 5] };
// The model is no longer asked for the radical; a stray (wrong) one in its reply must not reach the child.
const jiang = { word: '江', chars: [{ char: '江', pinyin: 'jiāng', radical: '工', radical_name: '工字旁', radical_meaning: '',
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
      const content = replies.length ? replies.shift() : reply;   // a string is sent as the raw reply text
      return new Response(JSON.stringify({ choices: [{ message: { content: typeof content === 'string' ? content : JSON.stringify(content) } }] }));
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
  assert.doesNotMatch(calls.model[0].messages[0].content, /radical/);
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

test('lookup and detail retry once on a blank or malformed reply, then give up', async t => {
  const broken = '{"word":"江","chars":[{"char":"江","tip":"三点水加工}],"alternatives":[]}';
  for (const bad of ['  ', broken]) {
    const retried = await setup(t, { replies: [bad, jiang] });
    assert.equal((await retried.lookup({ text: '三点水的江' })).status, 200);
    assert.equal((await retried.detail({ word: '河' })).status, 502);   // 江 ≠ 河 twice: swapped, gives up
    assert.equal(retried.calls.model.length, 4);
  }
  const stubborn = await setup(t, { replies: [broken, broken] });
  assert.equal((await stubborn.lookup({ text: '三点水的江' })).status, 502);
  assert.equal(stubborn.calls.model.length, 2);
  const detailed = await setup(t, { replies: [broken, jiang] });
  assert.equal((await detailed.detail({ word: '江' })).status, 200);
  assert.equal(detailed.calls.model.length, 2);
});

test('thinking is switched only when configured, and the lookup prompt carries the correction rules', () => {
  const base = { model: 'm', jsonMode: true };
  assert.deepEqual(lookupBody('江', { ...base, thinking: 'disabled' }).thinking, { type: 'disabled' });
  assert.deepEqual(detailBody('江', { ...base, thinking: 'enabled' }).thinking, { type: 'enabled' });
  assert.equal('thinking' in lookupBody('江', { ...base, thinking: 'none' }), false);
  assert.equal('thinking' in detailBody('江', base), false);
  assert.deepEqual(lookupBody('江', base).response_format, { type: 'json_object' });
  const prompt = lookupBody('江', base).messages[0].content;
  assert.match(prompt, /蓝天的兰/);
  assert.match(prompt, /上面小下面土/);
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
  assert.deepEqual(await first.json(), { strokes: strokeJson.strokes, medians: strokeJson.medians, radStrokes: [0, 1, 2],
    radical: '氵', radicalName: '三点水', radicalMeaning: '和水有关' });
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

test('stroke data never colours strokes it does not have', async t => {
  const short = await setup(t, { strokes: { strokes: ['M 1 1 Z', 'M 2 2 Z'], medians: [[[1, 1]], [[2, 2]]], radStrokes: [0] } });
  const body = await (await fetch(`${short.base}/hanzi/strokes/${encodeURIComponent('江')}.json`)).json();
  assert.deepEqual(body.radStrokes, []);
  assert.equal(body.radical, '氵');
});

test('answers cached before the radical table get the table radical', async t => {
  const dataDir = mkdtempSync(join(tmpdir(), 'hanzi-old-'));
  t.after(() => rmSync(dataDir, { recursive: true, force: true }));
  const old = { word: '江', chars: [{ char: '江', pinyin: 'jiāng', radical: '工', radicalName: '工字旁', radicalMeaning: '' }], alternatives: [], message: '' };
  const db = openDatabase(join(dataDir, 'littlebear.db'));
  db.prepare('INSERT INTO hanzi_answers (query, answer, created_at) VALUES (?, ?, ?)').run('江', JSON.stringify(old), new Date().toISOString());
  db.close();
  const hanzi = createHanzi({ token, model, dataDir, webDir: dataDir, fetchImpl: async () => { throw new Error('no network'); } });
  const server = createGateway({ token, hanzi });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(() => { hanzi.close(); resolve(); }); server.closeAllConnections(); }));
  const reply = await fetch(`http://127.0.0.1:${server.address().port}/v1/hanzi/detail`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify({ word: '江' }) });
  const { chars: [jiangChar] } = await reply.json();
  assert.deepEqual([jiangChar.radical, jiangChar.radicalName, jiangChar.radicalMeaning], ['氵', '三点水', '和水有关']);
});

test('radicals come from the local table, in the textbook form', () => {
  assert.deepEqual(radicalOf('问'), { radical: '门', radicalName: '门字框', radicalMeaning: '和门有关', strokes: [0, 1, 2] });
  assert.equal(radicalOf('夏').radical, '夂');                           // the dictionary's Kangxi 夊, written as in textbooks
  assert.deepEqual(radicalOf('修').strokes, [0, 1]);                      // 亻 found inside 攸
  assert.deepEqual([radicalOf('年').radical, radicalOf('年').strokes], ['丿', [0]]);   // corrected to 《新华字典》
  assert.equal(radicalOf('大').radicalName, '本身就是部首');
  assert.deepEqual(radicalOf('大').strokes, [0, 1, 2]);
  assert.equal(radicalOf('阳').radicalName, '左耳刀');
  assert.equal(radicalOf('那').radicalName, '右耳刀');
  assert.equal(radicalOf('a'), null);
  assert.equal(radicalOf('constructor'), null);
  const reply = withRadicals({ word: '江𠀀', chars: [{ char: '江', radical: '工' }, { char: '𠀀', radical: '一' }] });
  assert.equal(reply.chars[0].radical, '氵');
  assert.equal(reply.chars[1].radical, undefined);                        // not in the table: no radical rather than a guess
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
