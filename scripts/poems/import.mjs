#!/usr/bin/env node
/**
 * 把 chinese-poetry（https://github.com/chinese-poetry/chinese-poetry，MIT）的唐诗、宋诗、宋词导入成
 * 服务端用的诗库 poems.db（SQLite）。课本古诗不在这里，在 server/src/poems-school.json。
 *
 *   git clone --depth 1 https://github.com/chinese-poetry/chinese-poetry
 *   node scripts/poems/import.mjs ../chinese-poetry                 # 写到 server/data/poems.db
 *   node scripts/poems/import.mjs ../chinese-poetry --out /path/poems.db
 *
 * 用到仓库里的：全唐诗/（poet.tang.*、poet.song.*、authors.*、唐诗三百首.json）、宋词/（ci.song.*、author.song.json、
 * 宋词三百首.json）、蒙学/qianjiashi.json 和 水墨唐诗/（这几本选集只用来标出名篇、排在前面）。
 * rank/ 里的搜索结果数不用：数值很乱（《静夜思》排在七千名开外，前面全是“句”这类残篇）。
 * 全唐诗和宋诗是繁体，用 macOS 自带的 ICU 转成简体（hant2hans.swift），所以这个脚本只能在 Mac 上跑；
 * 生成的 poems.db 再拷到服务器的 DATA_DIR。
 */
import { readFileSync, readdirSync, existsSync, rmSync, renameSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';

const args = process.argv.slice(2);
const outIndex = args.indexOf('--out');
const out = outIndex >= 0 ? args[outIndex + 1] : fileURLToPath(new URL('../../server/data/poems.db', import.meta.url));
const root = args.find((a, i) => !a.startsWith('--') && i !== outIndex + 1);
if (!root || !existsSync(join(root, '全唐诗'))) {
  console.error('用法：node scripts/poems/import.mjs <chinese-poetry 目录> [--out poems.db]');
  process.exit(1);
}

const readJson = path => JSON.parse(readFileSync(path, 'utf8'));
const numbered = (dir, prefix) => readdirSync(dir)
  .map(name => ({ name, n: new RegExp(`^${prefix.replace('.', '\\.')}\\.(\\d+)\\.json$`).exec(name)?.[1] }))
  .filter(f => f.n != null).sort((a, b) => a.n - b.n);
const oneLine = s => (typeof s === 'string' ? s : '').replace(/\s+/g, ' ').trim();

/** 唐诗三百首里不可靠的标签（年级、学段、朝代都标得不准），不导入。 */
const DROP_TAGS = new Set(['唐诗三百首', '宋词三百首', '小学古诗', '初中古诗', '高中古诗', '隋・唐・五代', '咏物诗']);
const dropTag = tag => DROP_TAGS.has(tag) || /年级|册/.test(tag);

const poems = [];
const authors = new Map();
const addAuthor = (name, dynasty, intro, traditional) => {
  const key = `${dynasty}|${name}`;
  if (!authors.has(key)) authors.set(key, { name, dynasty, intro: oneLine(intro).slice(0, 2000), traditional });
};

// 唐诗、宋诗（繁体）
const tang300 = new Map(readJson(join(root, '全唐诗/唐诗三百首.json')).map(p => [p.id, p.tags ?? []]));
for (const [prefix, dynasty] of [['poet.tang', '唐'], ['poet.song', '宋']]) {
  for (const { name } of numbered(join(root, '全唐诗'), prefix)) {
    for (const p of readJson(join(root, '全唐诗', name))) {
      const tags = tang300.has(p.id) ? ['唐诗三百首', ...tang300.get(p.id).filter(t => !dropTag(t))] : [];
      poems.push({ title: oneLine(p.title), author: oneLine(p.author), dynasty, paragraphs: p.paragraphs ?? [], tags, traditional: true });
    }
  }
  for (const a of readJson(join(root, `全唐诗/authors.${prefix.split('.')[1]}.json`))) addAuthor(oneLine(a.name), dynasty, a.desc, true);
}

// 宋词（简体，标题就是词牌）
const ci300 = new Map(readJson(join(root, '宋词/宋词三百首.json')).map(p => [`${p.rhythmic}|${p.author}|${p.paragraphs?.[0]}`, p.tags ?? []]));
for (const { name } of numbered(join(root, '宋词'), 'ci.song')) {
  for (const p of readJson(join(root, '宋词', name))) {
    const key = `${p.rhythmic}|${p.author}|${p.paragraphs?.[0]}`;
    const tags = ci300.has(key) ? ['宋词三百首', ...ci300.get(key).filter(t => !dropTag(t))] : [];
    poems.push({ title: oneLine(p.rhythmic), author: oneLine(p.author), dynasty: '宋', form: '词', paragraphs: p.paragraphs ?? [], tags, traditional: false });
  }
}
for (const a of readJson(join(root, '宋词/author.song.json'))) addAuthor(oneLine(a.name), '宋', a.description, false);

// 另外两本选集只用来标记名篇：《千家诗》（繁体，作者写成“（唐）孟浩然”）、《水墨唐诗》（简体）。
const picks = [];
for (const group of readJson(join(root, '蒙学/qianjiashi.json')).content ?? []) {
  for (const p of group.content ?? []) {
    picks.push({ book: '千家诗', title: oneLine(p.chapter), author: oneLine(p.author).replace(/^（.*?）/, ''), first: oneLine(p.paragraphs?.[0]), traditional: true });
  }
}
for (const p of readJson(join(root, '水墨唐诗/shuimotangshi.json'))) {
  picks.push({ book: '水墨唐诗', title: oneLine(p.title), author: oneLine(p.author), first: oneLine(p.paragraphs?.[0]), traditional: false });
}

// 繁转简：所有要转的字段一行一个，交给 hant2hans.swift 一次转完。
const fields = [];
for (const p of poems) {
  p.paragraphs = p.paragraphs.map(oneLine).filter(Boolean);
  if (p.traditional) fields.push(p.title, p.author, ...p.paragraphs);
}
for (const a of authors.values()) if (a.traditional) fields.push(a.name, a.intro);
for (const p of picks) if (p.traditional) fields.push(p.title, p.author, p.first);
console.log(`繁转简 ${fields.length} 行……`);
const converted = spawnSync('swift', [fileURLToPath(new URL('hant2hans.swift', import.meta.url))],
  { input: fields.join('\n') + '\n', maxBuffer: 1 << 30, encoding: 'utf8' });
if (converted.status !== 0) { console.error(converted.stderr); process.exit(1); }
const lines = converted.stdout.split('\n');
if (lines.length - 1 !== fields.length) { console.error(`转换前后行数不同：${fields.length} → ${lines.length - 1}`); process.exit(1); }

/** ICU 按字转换漏掉或转错的，按词修正。 */
const FIXES = [['嶽', '岳'], ['干隆', '乾隆'], ['干元', '乾元'], ['干象', '乾象'], ['干宁', '乾宁'], ['干符', '乾符'], ['干封', '乾封']];
const fix = s => FIXES.reduce((t, [from, to]) => t.replaceAll(from, to), s);
let k = 0;
const next = () => fix(lines[k++]);
for (const p of poems) {
  if (!p.traditional) continue;
  p.title = next(); p.author = next(); p.paragraphs = p.paragraphs.map(next);
}
for (const a of authors.values()) {
  if (!a.traditional) continue;
  a.name = next(); a.intro = next();
}
for (const p of picks) {
  if (!p.traditional) continue;
  p.title = next(); p.author = next(); p.first = next();
}

/** 按句子字数粗分体裁：四句叫绝句、八句叫律诗、其他叫古诗（不看平仄，所以只是大致的分类）。 */
const formOf = paragraphs => {
  const clauses = paragraphs.join('').split(/[，。？！；、]/).map(c => c.replace(/[^\p{Script=Han}]/gu, '')).filter(Boolean);
  if (!clauses.length) return '其他';
  const size = clauses[0].length;
  if (!clauses.every(c => c.length === size) || ![5, 7].includes(size)) return '杂言诗';
  const word = size === 5 ? '五言' : '七言';
  return clauses.length === 4 ? `${word}绝句` : clauses.length === 8 ? `${word}律诗` : `${word}古诗`;
};

/** 全唐诗里括号里的都是校勘注（“一作……”“甲本作……”“按：……”），给孩子看的正文和标题里去掉。 */
const stripNotes = s => s.replace(/（[^（）]*）/g, '').replace(/\s+/g, ' ').trim();
/** 没配对的“（”或“〖”后面是跨行的出处说明，从那里截断，后面的行都不要。 */
function bodyOf(paragraphs) {
  const lines = [];
  for (const raw of paragraphs) {
    const line = stripNotes(raw);
    const cut = line.search(/[（〖]/);
    const kept = cut >= 0 ? line.slice(0, cut).trim() : line;
    if (/\p{Script=Han}/u.test(kept)) lines.push(kept);
    if (cut >= 0) break;
  }
  return lines;
}
for (const p of poems) {
  p.title = stripNotes(p.title).replace(/（.*$/, '').trim();
  p.paragraphs = bodyOf(p.paragraphs);
}
const kept = poems.filter(p => p.title && p.paragraphs.length && p.paragraphs.join('').length <= 6000);
for (const p of kept) {
  // 唐诗三百首的标签里有更准的体裁（乐府、五言律诗……），有就用它的。
  p.form ??= p.tags.find(t => /^(五言|七言)(绝句|律诗|古诗)$|^乐府$/.test(t)) ?? formOf(p.paragraphs);
  p.tags = p.tags.filter(t => t !== p.form);
}

// 名篇：选集里的诗按“作者 + 标题”或“作者 + 第一句”对上（选集的标题和字句常和全唐诗不同，比如《春晓》在千家诗里叫《春眠》）。
const han = s => s.replace(/[^\p{Script=Han}]/gu, '');
const byTitle = new Map(), byFirst = new Map();
for (const p of kept) {
  for (const [map, key] of [[byTitle, `${p.author}|${han(p.title)}`], [byFirst, `${p.author}|${han(p.paragraphs[0])}`]]) {
    if (!map.has(key)) map.set(key, p);
  }
}
let matched = 0;
for (const pick of picks) {
  const p = byTitle.get(`${pick.author}|${han(pick.title)}`) ?? byFirst.get(`${pick.author}|${han(pick.first)}`);
  if (!p) continue;
  matched++;
  if (!p.tags.includes(pick.book)) p.tags.unshift(pick.book);
}
console.log(`千家诗、水墨唐诗对上了 ${matched}/${picks.length} 首`);

/**
 * 排序用的名气：收进几本选集（每本 1000 分）+ 作者有几首诗进了选集（每首 10 分，最多 990）。
 * 只有一句的残篇、题目叫“句”“失题”的往后放。
 */
const BOOKS = ['唐诗三百首', '宋词三百首', '千家诗', '水墨唐诗'];
const authorPicks = new Map();
for (const p of kept) {
  p.books = p.tags.filter(t => BOOKS.includes(t)).length;
  if (p.books) authorPicks.set(`${p.dynasty}|${p.author}`, (authorPicks.get(`${p.dynasty}|${p.author}`) ?? 0) + 1);
}
for (const p of kept) {
  const fragment = p.paragraphs.length < 2 || /^(句|失题|断句)/.test(p.title);
  p.popularity = p.books * 1000 + Math.min(authorPicks.get(`${p.dynasty}|${p.author}`) ?? 0, 99) * 10 + (fragment ? 0 : 5);
}

const tmp = `${out}.tmp`;
mkdirSync(dirname(out), { recursive: true });
rmSync(tmp, { force: true });
const db = new DatabaseSync(tmp);
db.exec(`
  CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  CREATE TABLE poems (id INTEGER PRIMARY KEY, title TEXT NOT NULL, author TEXT NOT NULL, dynasty TEXT NOT NULL,
    form TEXT NOT NULL, tags TEXT NOT NULL, body TEXT NOT NULL, popularity INTEGER NOT NULL);
  CREATE TABLE authors (name TEXT NOT NULL, dynasty TEXT NOT NULL, intro TEXT NOT NULL, poems INTEGER NOT NULL,
    popularity INTEGER NOT NULL, PRIMARY KEY (dynasty, name));
`);
kept.sort((a, b) => b.popularity - a.popularity);
const insert = db.prepare('INSERT INTO poems (title, author, dynasty, form, tags, body, popularity) VALUES (?, ?, ?, ?, ?, ?, ?)');
db.exec('BEGIN');
// tags 前后带空格存（" 送别 思乡 "），查询用 LIKE '% 送别 %'；body 一行一联。
for (const p of kept) insert.run(p.title, p.author, p.dynasty, p.form, p.tags.length ? ` ${p.tags.join(' ')} ` : '', p.paragraphs.join('\n'), p.popularity);
const stats = new Map();
for (const p of kept) {
  const key = `${p.dynasty}|${p.author}`;
  const s = stats.get(key) ?? { poems: 0, popularity: 0 };
  s.poems++; s.popularity = Math.max(s.popularity, p.popularity);
  stats.set(key, s);
}
const insertAuthor = db.prepare('INSERT OR IGNORE INTO authors (name, dynasty, intro, poems, popularity) VALUES (?, ?, ?, ?, ?)');
for (const [key, s] of stats) {
  const [dynasty, name] = key.split('|');
  insertAuthor.run(name, dynasty, authors.get(key)?.intro ?? '', s.poems, s.popularity);
}
db.exec('COMMIT');
db.exec(`
  CREATE INDEX poems_author ON poems (author, popularity DESC);
  CREATE INDEX poems_browse ON poems (dynasty, form, popularity DESC);
  CREATE INDEX poems_popular ON poems (popularity DESC);
  CREATE INDEX authors_popular ON authors (dynasty, popularity DESC);
`);
// 不建全文索引：trigram 索引会让文件从几十 MB 变成三百多 MB，而按名气顺序 LIKE 扫一遍只要几十毫秒。
const head = spawnSync('git', ['-C', root, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).stdout.trim();
const putMeta = db.prepare('INSERT INTO meta (key, value) VALUES (?, ?)');
putMeta.run('source', `chinese-poetry ${head || 'unknown'}`);
putMeta.run('imported_at', new Date().toISOString());
putMeta.run('poems', String(kept.length));
db.exec('VACUUM');
db.close();
renameSync(tmp, out);
console.log(`写好了 ${out}：${kept.length} 首诗、${stats.size} 位作者`);
