import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, readdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { createGateway } from '../src/gateway.mjs';
import { createPoems, loadSchoolPoems, loadLevelPoems, validateExplanation, validatePinyin, explainKey, explainBody, pinyinBody, poemDigest } from '../src/poems.mjs';

const token = 'device-test-token-not-a-secret-12345';
const model = { apiUrl: 'https://model.test/chat/completions', apiKey: 'k', model: 'm', jsonMode: true };

const school = [
  { grade: 1, term: '下', kind: '课文', title: '静夜思', author: '李白', dynasty: '唐', lines: ['床前明月光，疑是地上霜。', '举头望明月，低头思故乡。'] },
  { grade: 2, term: '上', kind: '课文', title: '登鹳雀楼', author: '王之涣', dynasty: '唐', lines: ['白日依山尽，黄河入海流。', '欲穷千里目，更上一层楼。'] },
  { grade: 2, term: '上', kind: '日积月累', title: '梅花', author: '王安石', dynasty: '宋', lines: ['墙角数枝梅，凌寒独自开。', '遥知不是雪，为有暗香来。'] }
];

const levelList = [
  { level: 1, title: '静夜思', author: '李白', dynasty: '唐', lines: ['床前明月光，疑是地上霜。', '举头望明月，低头思故乡。'] },
  { level: 1, title: '如梦令', author: '李清照', dynasty: '宋', lines: ['常记溪亭日暮，沉醉不知归路。', '兴尽晚回舟，误入藕花深处。', '争渡，争渡，惊起一滩鸥鹭。'], note: '考级版' },
  { level: 2, title: '如梦令', author: '李清照', dynasty: '宋', lines: ['昨夜雨疏风骤，浓睡不消残酒。', '试问卷帘人，却道海棠依旧。', '知否，知否，应是绿肥红瘦。'] }
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
  insert.run('如梦令', '李清照', '宋', '词', '', '昨夜雨疏风骤。浓睡不消残酒。\n试问卷帘人，却道海棠依旧。\n知否。知否。应是绿肥红瘦。', 10);
  insert.run('如梦令', '李清照', '宋', '词', '', '常记溪亭日暮。沈醉不知归路。\n兴尽晚回舟，误入藕花深处。\n争渡。争渡。惊起一滩鸥鹭。', 10);
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

async function setup(t, { replies = [], library = true, schoolList = school, levels = levelList, shippedFile = {}, artFile = {}, tts = null } = {}) {
  const dataDir = mkdtempSync(join(tmpdir(), 'poems-'));
  const webDir = join(dataDir, 'web');
  mkdirSync(webDir);
  writeFileSync(join(webDir, 'index.html'), '<!doctype html><title>小熊读诗</title>');
  const schoolPath = join(dataDir, 'school.json');
  writeFileSync(schoolPath, JSON.stringify(schoolList));
  const levelsPath = join(dataDir, 'levels.json');
  writeFileSync(levelsPath, JSON.stringify(levels));
  if (library) makeLibrary(join(dataDir, 'poems.db'));
  const explanationsPath = join(dataDir, 'explanations.json');
  writeFileSync(explanationsPath, JSON.stringify(typeof shippedFile === 'function' ? shippedFile(loadSchoolPoems(schoolPath)) : shippedFile));
  const artPath = join(dataDir, 'art.json');
  writeFileSync(artPath, JSON.stringify(typeof artFile === 'function' ? artFile(loadSchoolPoems(schoolPath)) : artFile));
  const calls = [];
  const fetchImpl = async (url, init) => {
    calls.push(JSON.parse(init.body));
    const content = replies.shift();
    return new Response(JSON.stringify({ choices: [{ message: { content: typeof content === 'string' ? content : JSON.stringify(content) } }] }));
  };
  const poems = createPoems({ token, model, dataDir, schoolPath, levelsPath, explanationsPath, artPath, tts, webDir, fetchImpl });
  const server = createGateway({ token, poems });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(() => new Promise(resolve => { server.close(() => { poems.close(); rmSync(dataDir, { recursive: true, force: true }); resolve(); }); server.closeAllConnections(); }));
  const base = `http://127.0.0.1:${server.address().port}`;
  const get = async path => { const r = await fetch(`${base}${path}`); return { status: r.status, body: await r.json() }; };
  const explain = (id, auth = token) => fetch(`${base}/v1/poems/explain`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(auth ? { Authorization: `Bearer ${auth}` } : {}) }, body: JSON.stringify({ id }) });
  const post = (path, body, auth = token) => fetch(`${base}${path}`, { method: 'POST',
    headers: { 'Content-Type': 'application/json', ...(auth ? { Authorization: `Bearer ${auth}` } : {}) }, body: JSON.stringify(body) });
  return { base, calls, get, explain, post, dataDir };
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
  assert.deepEqual(body.poems.map(p => p.author), ['苏轼', '李清照', '李清照']);
  // LIKE 的通配符按普通字符找。
  ({ body } = await get(`/v1/poems/search?q=${encodeURIComponent('%_')}`));
  assert.deepEqual(body.poems.map(p => p.title), ['句']);
  ({ body } = await get(`/v1/poems/search?author=${encodeURIComponent('李白')}`));
  assert.deepEqual([body.school.length, body.poems.length], [1, 1]);
});

test('level poems reuse identical textbook poems and number the rest by level', () => {
  const dir = mkdtempSync(join(tmpdir(), 'poems-levels-'));
  try {
    writeFileSync(join(dir, 's.json'), JSON.stringify(school));
    writeFileSync(join(dir, 'l.json'), JSON.stringify(levelList));
    const { levels, own } = loadLevelPoems(join(dir, 'l.json'), loadSchoolPoems(join(dir, 's.json')));
    assert.deepEqual(levels.map(l => [l.level, l.poems.map(p => p.id)]), [[1, ['s1b01', 'k1a01']], [2, ['k2a01']]]);
    assert.deepEqual(own.map(p => [p.id, p.level, p.note]), [['k1a01', 1, '考级版'], ['k2a01', 2, '']]);
    writeFileSync(join(dir, 'bad.json'), JSON.stringify([{ level: 7, title: 'x', author: 'y', lines: ['a'] }]));
    assert.throws(() => loadLevelPoems(join(dir, 'bad.json')), /第 1 条/);
    assert.deepEqual(loadLevelPoems(join(dir, 'missing.json')), { levels: [], own: [] });
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('home lists the levels; level poems open, are found first, and library versions link to them', async t => {
  const { get } = await setup(t);
  const { body: home } = await get('/v1/poems/home');
  assert.deepEqual(home.levels.map(l => [l.level, l.poems.map(p => [p.id, p.school?.grade ?? null, p.level ?? null])]),
    [[1, [['s1b01', 1, null], ['k1a01', null, 1]]], [2, [['k2a01', null, 2]]]]);
  const { status, body: poem } = await get('/v1/poems/poem/k2a01');
  assert.equal(status, 200);
  assert.equal(poem.level, 2);
  assert.equal(poem.explainable, true);
  const { body: found } = await get(`/v1/poems/search?q=${encodeURIComponent('如梦令')}`);
  assert.deepEqual(found.school.map(p => p.id), ['k1a01', 'k2a01']);
  // 同题的两首《如梦令》各自连到考级里对应的那首。
  const links = await Promise.all(found.poems.map(p => get(`/v1/poems/poem/${p.id}`)));
  assert.deepEqual(links.map(r => [r.body.lines[0].slice(0, 4), r.body.textbookId]).sort(), [['常记溪亭', 'k1a01'], ['昨夜雨疏', 'k2a01']]);
  // 只有一首同题的照旧连到课本版，开头不同也一样（全唐诗是“床前看月光”）。
  const { body: library } = await get(`/v1/poems/search?dynasty=${encodeURIComponent('唐')}&q=${encodeURIComponent('床前')}`);
  assert.equal((await get(`/v1/poems/poem/${library.poems[0].id}`)).body.textbookId, 's1b01');
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

const rowsFor = lines => lines.map(line => [...line].filter(c => /\p{Script=Han}/u.test(c)).map(() => 'mā'));

test('shipped explanations are served without asking the model, but only while the poem text matches', async t => {
  const explanation = goodExplanation(school[0].lines);
  const { get, explain, calls } = await setup(t, { shippedFile: list => ({
    s1b01: { key: explainKey(list[0]), title: '静夜思', explanation },
    s2a01: { key: 'v1|s2a01|old-digest', title: '登鹳雀楼', explanation: goodExplanation(school[1].lines) } }) });
  const { body } = await get('/v1/poems/poem/s1b01');
  assert.equal(body.explanation.scene, explanation.scene);
  assert.deepEqual(body.pinyin, explanation.pinyin);
  assert.equal((await explain('s1b01')).status, 200);
  assert.equal(calls.length, 0);
  // 诗文改过（摘要对不上）的旧条目不用。
  const stale = (await get('/v1/poems/poem/s2a01')).body;
  assert.equal(stale.explanation, null);
  assert.equal(stale.pinyin, null);
});

test('pinyin is asked once, retried when a row is off, saved, and comes with the poem afterwards', async t => {
  const lines = ['床前看月光，疑是地上霜。', '举头望山月，低头思故乡。'];
  const half = { pinyin: [rowsFor(lines)[0], ['bad']] };
  const { get, post, calls } = await setup(t, { replies: [half, { pinyin: rowsFor(lines) }] });
  assert.equal((await post('/v1/poems/pinyin', { id: 'p1' }, '')).status, 401);
  const first = (await get('/v1/poems/poem/p1')).body;
  assert.equal(first.pinyin, null);
  assert.equal(first.pinyinable, true);
  const response = await post('/v1/poems/pinyin', { id: 'p1' });
  assert.equal(response.status, 200);
  assert.deepEqual((await response.json()).pinyin, rowsFor(lines));
  assert.equal(calls.length, 2);
  assert.match(calls[0].messages[0].content, /逐字标拼音/);
  assert.equal((await post('/v1/poems/pinyin', { id: 'p1' })).status, 200);
  assert.equal(calls.length, 2);
  assert.deepEqual((await get('/v1/poems/poem/p1')).body.pinyin, rowsFor(lines));
});

test('pinyin keeps the better reply when both have an off row, and comes from the explanation when there is one', async t => {
  const lines = school[0].lines;
  const { post, explain, calls } = await setup(t, { replies: [{ pinyin: [null, null] }, { pinyin: [rowsFor(lines)[0], ['x']] }, goodExplanation(school[1].lines)] });
  assert.deepEqual((await (await post('/v1/poems/pinyin', { id: 's1b01' })).json()).pinyin, [rowsFor(lines)[0], null]);
  assert.equal(calls.length, 2);
  assert.equal((await explain('s2a01')).status, 200);
  assert.deepEqual((await (await post('/v1/poems/pinyin', { id: 's2a01' })).json()).pinyin, rowsFor(school[1].lines));
  assert.equal(calls.length, 3);
});

test('pinyin replies are checked row by row', () => {
  const poem = { lines: ['白日依山尽，', '黄河入海流。'] };
  assert.deepEqual(validatePinyin(JSON.stringify({ pinyin: [['bái', 'rì', 'yī', 'shān', 'jìn'], ['huáng', 'hé']] }), poem), [['bái', 'rì', 'yī', 'shān', 'jìn'], null]);
  assert.throws(() => validatePinyin('{"pinyin":[]}', poem));
  assert.throws(() => validatePinyin('not json', poem));
  assert.equal(pinyinBody({ ...poem, title: 't', author: 'a', dynasty: '唐' }, { ...model, jsonMode: true }).response_format.type, 'json_object');
});

test('read-aloud audio is made once per line, saved, and needs the token and a voice', async t => {
  const said = [];
  const tts = { voice: 'test-voice', async *synthesize(text) { said.push(text); yield Buffer.from(`mp3:${text}`); } };
  const { base, get, dataDir } = await setup(t, { tts });
  const audio = (part, auth = token) => fetch(`${base}/v1/poems/audio?id=s1b01&part=${part}`, { headers: auth ? { Authorization: `Bearer ${auth}` } : {} });
  assert.equal((await get('/v1/poems/poem/s1b01')).body.speakable, true);
  assert.equal((await audio(1, '')).status, 401);
  let response = await audio(0);
  assert.equal(response.headers.get('content-type'), 'audio/mpeg');
  assert.equal(await response.text(), 'mp3:静夜思，唐，李白');
  response = await audio(2);
  assert.equal(await response.text(), 'mp3:举头望明月，低头思故乡。');
  assert.equal(await (await audio(2)).text(), 'mp3:举头望明月，低头思故乡。');
  assert.deepEqual(said, ['静夜思，唐，李白', '举头望明月，低头思故乡。']);
  assert.equal(readdirSync(join(dataDir, 'poem-audio')).length, 2);
  assert.equal((await audio(3)).status, 404);
  assert.equal((await audio(-1)).status, 404);
});

test('without a voice the page falls back to the browser and audio says so', async t => {
  const { base, get } = await setup(t);
  assert.equal((await get('/v1/poems/poem/s1b01')).body.speakable, false);
  assert.equal((await fetch(`${base}/v1/poems/audio?id=s1b01&part=1`, { headers: { Authorization: `Bearer ${token}` } })).status, 503);
});

test('pinyin split by clause instead of by line is put back on the lines', () => {
  const poem = { lines: ['湖光秋月两相和，潭面无风镜未磨。', '遥望洞庭山水翠，白银盘里一青螺。'] };
  const clauses = [['hú', 'guāng', 'qiū', 'yuè', 'liǎng', 'xiāng', 'hé'], ['tán', 'miàn', 'wú', 'fēng', 'jìng', 'wèi', 'mó'],
    ['yáo', 'wàng', 'dòng', 'tíng', 'shān', 'shuǐ', 'cuì'], ['bái', 'yín', 'pán', 'lǐ', 'yì', 'qīng', 'luó']];
  assert.deepEqual(validatePinyin(JSON.stringify({ pinyin: clauses }), poem), [clauses[0].concat(clauses[1]), clauses[2].concat(clauses[3])]);
  // 总数不对就不硬分，对不上的行照旧不显示。
  assert.throws(() => validatePinyin(JSON.stringify({ pinyin: clauses.slice(0, 3) }), poem));
});

test('textbook poems come with their pictures, placed by sentence', async t => {
  const svg = '<svg viewBox="0 0 800 600" xmlns="http://www.w3.org/2000/svg"><rect width="800" height="600"/></svg>';
  const { base, get, dataDir } = await setup(t, { artFile: poems => ({
    // 静夜思：四句四张，一行两张。
    s1b01: { key: poemDigest(poems[0]), scenes: [0, 1, 2, 3].map(i => ({ lines: [i], caption: `第${i + 1}句`, v: 'abc12345' })) },
    // 诗文改过（摘要对不上）的不用。
    s2a01: { key: '0000000000000000', scenes: [{ lines: [0, 1, 2, 3], caption: '整首' }] }
  }) });
  mkdirSync(join(dataDir, 'web/art/s1b01'), { recursive: true });
  writeFileSync(join(dataDir, 'web/art/s1b01/1.svg'), svg);

  const { body } = await get('/v1/poems/poem/s1b01');
  assert.deepEqual(body.art.map(a => [a.line, a.at]), [[0, 0], [0, 0.5], [1, 0], [1, 0.5]]);
  assert.equal(body.art[0].src, '/poems/art/s1b01/1.svg?v=abc12345');
  assert.equal(body.art[1].caption, '第2句');
  assert.deepEqual((await get('/v1/poems/poem/s2a01')).body.art, []);
  assert.deepEqual((await get('/v1/poems/poem/s2a02')).body.art, []);

  const image = await fetch(`${base}${body.art[0].src}`);
  assert.equal(image.headers.get('content-type'), 'image/svg+xml');
  assert.match(image.headers.get('cache-control'), /max-age/);
  assert.match(image.headers.get('content-security-policy'), /default-src 'none'/);
  assert.equal(await image.text(), svg);
});

test('raster poem art (jpg/webp/png) is served with the matching extension and mime type', async t => {
  const jpg = Buffer.from([0xff, 0xd8, 0xff, 0xd9]);
  const { base, get, dataDir } = await setup(t, { artFile: poems => ({
    s1b01: { key: poemDigest(poems[0]), scenes: [
      { lines: [0, 1], caption: '前两句', v: '11223344', ext: 'jpg' },
      { lines: [2, 3], caption: '后两句', v: '55667788', ext: 'webp' }
    ] }
  }) });
  mkdirSync(join(dataDir, 'web/art/s1b01'), { recursive: true });
  writeFileSync(join(dataDir, 'web/art/s1b01/1.jpg'), jpg);

  const { body } = await get('/v1/poems/poem/s1b01');
  assert.equal(body.art[0].src, '/poems/art/s1b01/1.jpg?v=11223344');
  assert.equal(body.art[1].src, '/poems/art/s1b01/2.webp?v=55667788');
  const image = await fetch(`${base}${body.art[0].src}`);
  assert.equal(image.status, 200);
  assert.equal(image.headers.get('content-type'), 'image/jpeg');
  assert.equal(image.headers.get('content-security-policy'), null);
});
