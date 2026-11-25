import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createGateway } from '../src/gateway.mjs';
import { createPoems, loadSchoolPoems, validateExplanation, explainKey, explainBody } from '../src/poems.mjs';

const token = 'device-test-token-not-a-secret-12345';
const model = { apiUrl: 'https://model.test/chat/completions', apiKey: 'k', model: 'm', jsonMode: true };

const school = [
  { grade: 1, term: '下', kind: '课文', title: '静夜思', author: '李白', dynasty: '唐', lines: ['床前明月光，疑是地上霜。', '举头望明月，低头思故乡。'] },
  { grade: 2, term: '上', kind: '课文', title: '登鹳雀楼', author: '王之涣', dynasty: '唐', lines: ['白日依山尽，黄河入海流。', '欲穷千里目，更上一层楼。'] },
  { grade: 2, term: '上', kind: '日积月累', title: '梅花', author: '王安石', dynasty: '宋', lines: ['墙角数枝梅，凌寒独自开。', '遥知不是雪，为有暗香来。'] }
];

/** 和 scripts/poems/import.mjs 写出来的表结构一样的小诗库。 */
function makeLibrary(path) {
  const db = new DatabaseSync(path);
  db.exec(`
    CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE poems (id INTEGER PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL, dynasty TEXT NOT NULL,
      form TEXT NOT NULL, tags TEXT NOT NULL, body TEXT NOT NULL, popularity INTEGER NOT NULL);
    CREATE TABLE authors (name TEXT NOT NULL, dynasty TEXT NOT NULL, intro TEXT NOT NULL, poems INTEGER NOT NULL,
      popularity INTEGER NOT NULL, PRIMARY KEY (dynasty, name));
    INSERT INTO meta VALUES ('poems', '4');
  `);
  const insert = db.prepare('INSERT INTO poems (title, author, dynasty, form, tags, body, popularity) VALUES (?, ?, ?, ?, ?, ?, ?)');
  insert.run('静夜思', '李白', '唐', '五言绝句', ' 唐诗三百首 千家诗 思乡 ', '床前看月光，疑是地上霜。\n举头望山月，低头思故乡。', 2000);
  insert.run('春晓', '孟浩然', '唐', '五言绝句', ' 唐诗三百首 春天 ', '春眠不觉晓，处处闻啼鸟。\n夜来风雨声，花落知多少。', 1500);
  insert.run('句', '无名氏', '唐', '杂言诗', '', '明月100%_好', 0);
  insert.run('水调歌头', '苏轼', '宋', '词', ' 宋词三百首 ', '明月几时有？把酒问青天。\n不知天上宫阙，今夕是何年。', 1800);
  db.prepare('INSERT INTO authors VALUES (?, ?, ?, ?, ?)').run('李白', '唐', '字太白。', 1, 2000);
  db.prepare('INSERT INTO authors VALUES (?, ?, ?, ?, ?)').run('苏轼', '宋', '字子瞻。', 1, 1800);
  db.close();
}

const goodExplanation = lines => ({
  pinyin: lines.map(line => [...line].filter(c => /\p{Script=Han}/u.test(c)).map(() => 'mā')),
  scene: '夜里，月光照在床前。', lines: lines.map(() => ({ meaning: '意思' })),
  words: [{ word: '疑', pinyin: 'yí', meaning: '好像' }, { word: '不存在', pinyin: '', meaning: '会被去掉' }],
  feeling: '想家。', story: '', poet: '唐朝诗人。'
});

async function setup(t, { replies = [], library = true, schoolList = school } = {}) {
  const dataDir = mkdtempSync(join(tmpdir(), 'poems-'));
  const webDir = join(dataDir, 'web');
  mkdirSync(webDir);
  writeFileSync(join(webDir, 'index.html'), '<!doctype html><title>小熊读诗</title>');
  const schoolPath = join(dataDir, 'school.json');
  writeFileSync(schoolPath, JSON.stringify(schoolList));
  if (library) makeLibrary(join(dataDir, 'poems.db'));
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push(JSON.parse(init.body));
    const content = replies.shift();
    return new Response(JSON.stringify({ choices: [{ message: { content: typeof content === 'string' ? content : JSON.stringify(content) } }] }));
  };
  const poems = createPoems({ token, model, dataDir, schoolPath, webDir, fetchImpl });
  const server = createGateway({ token, poems });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(() => { poems.close(); rmSync(dataDir, { recursive: true, force: true }); resolve(); }); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${server.address().port}`;
  const get = async path => { const r = await fetch(`${base}${path}`); return { status: r.status, body: await r.json() }; };
  const explain = (id, auth = token) => fetch(`${base}/v1/poems/explain`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(auth ? { Authorization: `Bearer ${auth}` } : {}) }, body: JSON.stringify({ id }) });
  return { base, calls, get, explain };
}

test('school poems get ids by grade, term and order', () => {
  const dir = mkdtempSync(join(tmpdir(), 'poems-school-'));
  try {
    writeFileSync(join(dir, 's.json'), JSON.stringify(school));
    assert.deepEqual(loadSchoolPoems(join(dir, 's.json')).map(p => p.id), ['s1b01', 's2a01', 's2a02']);
    writeFileSync(join(dir, 'bad.json'), JSON.stringify([{ grade: 7, term: '上', title: 'x', author: 'y', lines: ['a'] }]));
    assert.throws(() => loadSchoolPoems(join(dir, 'bad.json')), /第 1 条/);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('home lists school poems by book and the library facets', async t => {
  const { get } = await setup(t);
  const { status, body } = await get('/v1/poems/home');
  assert.equal(status, 200);
  assert.deepEqual(body.school.map(b => [b.grade, b.term, b.poems.length]), [[1, '下', 1], [2, '上', 2]]);
  assert.equal(body.school[1].poems[1].school.kind, '日积月累');
  assert.equal(body.library.poems, 4);
  assert.deepEqual(body.library.dynasties, ['唐', '宋']);
  assert.deepEqual(body.library.forms, ['五言绝句', '词', '杂言诗']);
  assert.ok(body.library.tags.includes('思乡') && !body.library.tags.includes('唐诗三百首'));
});

test('search puts textbook poems first and filters the library', async t => {
  const { get } = await setup(t);
  let { body } = await get(`/v1/poems/search?q=${encodeURIComponent('明月')}`);
  assert.deepEqual(body.school.map(p => p.title), ['静夜思']);
  assert.deepEqual(body.poems.map(p => p.title), ['水调歌头', '句']);
  ({ body } = await get(`/v1/poems/search?dynasty=${encodeURIComponent('唐')}&book=${encodeURIComponent('唐诗三百首')}`));
  assert.deepEqual(body.school, []);
  assert.deepEqual(body.poems.map(p => p.title), ['静夜思', '春晓']);
  assert.deepEqual(body.poems[0].books, ['唐诗三百首', '千家诗']);
  ({ body } = await get(`/v1/poems/search?book=${encodeURIComponent('唐诗三百首')}&tag=${encodeURIComponent('思乡')}`));
  assert.deepEqual(body.poems.map(p => p.title), ['静夜思']);
  ({ body } = await get(`/v1/poems/search?form=${encodeURIComponent('词')}`));
  assert.deepEqual(body.poems.map(p => p.author), ['苏轼']);
  // LIKE 的通配符按普通字符找。
  ({ body } = await get(`/v1/poems/search?q=${encodeURIComponent('%_')}`));
  assert.deepEqual(body.poems.map(p => p.title), ['句']);
  ({ body } = await get(`/v1/poems/search?author=${encodeURIComponent('李白')}`));
  assert.deepEqual([body.school.length, body.poems.length], [1, 1]);
});

test('authors and author pages come from the library', async t => {
  const { get } = await setup(t);
  assert.deepEqual((await get('/v1/poems/authors')).body.authors.map(a => a.name), ['李白', '苏轼']);
  assert.deepEqual((await get(`/v1/poems/authors?dynasty=${encodeURIComponent('宋')}`)).body.authors.map(a => a.name), ['苏轼']);
  assert.equal((await get(`/v1/poems/author?name=${encodeURIComponent('李白')}`)).body.intro, '字太白。');
  assert.equal((await get(`/v1/poems/author?name=${encodeURIComponent('杜甫')}`)).status, 404);
});

test('a library poem with a textbook version links to it', async t => {
  const { get } = await setup(t);
  const { body } = await get('/v1/poems/poem/p1');
  assert.deepEqual(body.lines, ['床前看月光，疑是地上霜。', '举头望山月，低头思故乡。']);
  assert.equal(body.textbookId, 's1b01');
  assert.equal(body.explanation, null);
  assert.equal(body.explainable, true);
  assert.equal((await get('/v1/poems/poem/s2a01')).body.school.grade, 2);
  for (const id of ['p99', 'x1', 'p1;DROP', 's9a01']) assert.equal((await get(`/v1/poems/poem/${id}`)).status, 404);
});

test('without poems.db only the textbook poems are there', async t => {
  const { get } = await setup(t, { library: false });
  assert.equal((await get('/v1/poems/home')).body.library, null);
  const { body } = await get(`/v1/poems/search?q=${encodeURIComponent('明月')}`);
  assert.deepEqual([body.school.length, body.poems.length], [1, 0]);
});

test('explain asks the model once, then serves the cached explanation with the poem', async t => {
  const lines = school[0].lines;
  const { explain, calls, get } = await setup(t, { replies: [goodExplanation(lines)] });
  const first = await explain('s1b01');
  assert.equal(first.status, 200);
  const body = await first.json();
  assert.deepEqual(body.lines, ['意思', '意思']);
  assert.deepEqual(body.words.map(w => w.word), ['疑']);
  assert.equal(body.pinyin[0].length, 10);
  // 诗文是服务端查出来交给模型的。
  assert.deepEqual(JSON.parse(calls[0].messages[1].content), { title: '静夜思', author: '李白', dynasty: '唐', lines });
  assert.equal((await explain('s1b01')).status, 200);
  assert.equal(calls.length, 1);
  assert.deepEqual((await get('/v1/poems/poem/s1b01')).body.explanation.scene, '夜里，月光照在床前。');
});

test('explain needs the token, a known id and a short poem', async t => {
  const long = { grade: 3, term: '上', title: '长诗', author: '某', dynasty: '唐', lines: Array.from({ length: 30 }, () => '一二三四五，六七八九十。') };
  const { explain, calls } = await setup(t, { schoolList: [...school, long] });
  assert.equal((await explain('s1b01', null)).status, 401);
  assert.equal((await explain('s1b01', 'wrong-token-wrong-token-wrong-token')).status, 401);
  assert.equal((await explain('p404')).status, 404);
  assert.equal((await explain('s3a01')).status, 413);
  assert.equal(calls.length, 0);
});

test('explain retries once when the lines do not match, then gives up', async t => {
  const lines = school[1].lines;
  const short = { ...goodExplanation(lines), lines: [{ meaning: '只有一句' }] };
  let ctx = await setup(t, { replies: [short, goodExplanation(lines)] });
  assert.equal((await ctx.explain('s2a01')).status, 200);
  assert.equal(ctx.calls.length, 2);
  ctx = await setup(t, { replies: ['not json', short] });
  const failed = await ctx.explain('s2a01');
  assert.equal(failed.status, 502);
  assert.equal((await failed.json()).error, 'invalid_model_reply');
});

test('explanations are cleaned: bad pinyin rows are dropped, words must be in the poem', () => {
  const poem = { id: 's1b01', title: '静夜思', author: '李白', lines: school[0].lines };
  const reply = goodExplanation(poem.lines);
  reply.pinyin[1] = ['jǔ', 'tóu'];
  const result = validateExplanation('```json\n' + JSON.stringify(reply) + '\n```', poem);
  assert.equal(result.pinyin[0].length, 10);
  assert.equal(result.pinyin[1], null);
  assert.deepEqual(result.words, [{ word: '疑', pinyin: 'yí', meaning: '好像' }]);
  assert.throws(() => validateExplanation(JSON.stringify({ ...reply, scene: '' }), poem), /scene/);
  assert.throws(() => validateExplanation('', poem));
});

test('the cache key changes with the poem text, and the prompt keeps the rules', () => {
  const poem = { id: 's1b01', title: '静夜思', author: '李白', dynasty: '唐', lines: school[0].lines };
  assert.notEqual(explainKey(poem), explainKey({ ...poem, lines: ['床前看月光，疑是地上霜。', poem.lines[1]] }));
  const body = explainBody(poem, { ...model, thinking: 'disabled' });
  assert.deepEqual(body.thinking, { type: 'disabled' });
  assert.match(body.messages[0].content, /不要编/);
  assert.equal(explainBody(poem, model).thinking, undefined);
});

test('the page is served without escaping its folder', async t => {
  const { base } = await setup(t);
  const page = await fetch(`${base}/poems/`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('set-cookie'), /poems_session=/);
  assert.equal((await fetch(`${base}/poems`, { redirect: 'manual' })).status, 301);
  assert.equal((await fetch(`${base}/poems/..%2Fschool.json`)).status, 404);
  // 页面发的会话能用来请求讲解。
  const cookie = page.headers.get('set-cookie').split(';')[0];
  const withSession = await fetch(`${base}/v1/poems/explain`, { method: 'POST', headers: { 'Content-Type': 'application/json', Cookie: cookie }, body: JSON.stringify({ id: 'nope' }) });
  assert.equal(withSession.status, 404);
});
