/**
 * 把 illustrate.mjs 画好、看过的配图放进仓库，随代码发布：
 *   - SVG 拷到 web/poems/art/<诗id>/<n>.svg（读诗页面的静态文件，和页面同源）
 *   - 配图清单写到 server/src/poems-art.json：{ "<诗id>": { "key": 诗文摘要, "scenes": [{ "lines": [句子下标], "caption": "诗句", "v": 图的摘要 }] } }
 *     第 n 张图是 scenes[n-1]；lines 是 poemSentences() 分出来的句子下标；v 加在图片网址后面，重画后浏览器不会用旧缓存。
 *
 *   node scripts/poems/publish-art.mjs              # 从 server/data/poem-art 发布
 *   node scripts/poems/publish-art.mjs --from 目录
 *
 * 只发布诗文没改过的（meta.json 里的摘要和现在的课本/考级原文一致）；web/poems/art/ 每次整个重写，不在清单里的旧图会删掉。
 * 不拷 PNG 和 meta.json（花费、分镜描述这些只留在本地）。
 */
import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { loadLevelPoems, loadSchoolPoems, poemDigest, poemSentences } from '../../server/src/poems.mjs';

const repo = fileURLToPath(new URL('../..', import.meta.url));
const args = process.argv.slice(2);
const at = args.indexOf('--from');
const from = at >= 0 && args[at + 1] ? args[at + 1] : join(repo, 'server/data/poem-art');
const artDir = join(repo, 'web/poems/art');
const manifestPath = join(repo, 'server/src/poems-art.json');

const school = loadSchoolPoems();
const poems = new Map([...school, ...loadLevelPoems(undefined, school).own].map(p => [p.id, p]));
if (!existsSync(from)) { console.error(`没有 ${from}，先用 illustrate.mjs 画。`); process.exit(1); }

// 支持位图与 SVG；同一分镜同时存在多种格式时优先位图（webp > jpg > jpeg > png > svg）。
const exts = ['webp', 'jpg', 'jpeg', 'png', 'svg'];
const findImage = (dir, n) => {
  for (const ext of exts) {
    const file = join(dir, `${n}.${ext}`);
    if (existsSync(file)) return { file, ext };
  }
  return null;
};

const manifest = {};
const skipped = [];
for (const id of readdirSync(from).sort()) {
  const metaFile = join(from, id, 'meta.json');
  if (!existsSync(metaFile)) continue;
  const meta = JSON.parse(readFileSync(metaFile, 'utf8'));
  const poem = poems.get(id);
  if (!poem) { skipped.push(`${id}：课本和考级里没有这首了`); continue; }
  if (meta.textKey !== poemDigest(poem)) { skipped.push(`${id} ${poem.title}：诗文改过了，要重画（--redo ${id}）`); continue; }
  const scenes = meta.plan?.scenes ?? [];
  const count = poemSentences(poem).length;
  const found = scenes.map((_, i) => findImage(join(from, id), i + 1));
  if (!scenes.length || scenes.length !== meta.images || !found.every(Boolean)
    || scenes.some(s => !Array.isArray(s.lines) || s.lines.some(n => !Number.isInteger(n) || n < 0 || n >= count))) {
    skipped.push(`${id} ${poem.title}：分镜和图片对不上`); continue;
  }
  const version = file => createHash('sha256').update(readFileSync(file)).digest('hex').slice(0, 8);
  manifest[id] = {
    key: meta.textKey,
    scenes: scenes.map((s, i) => ({
      lines: s.lines, caption: s.caption, v: version(found[i].file),
      ...(found[i].ext !== 'svg' ? { ext: found[i].ext } : {})
    })),
    files: found
  };
}

rmSync(artDir, { recursive: true, force: true });
let images = 0;
for (const [id, entry] of Object.entries(manifest)) {
  mkdirSync(join(artDir, id), { recursive: true });
  entry.files.forEach(({ file, ext }, i) => { copyFileSync(file, join(artDir, id, `${i + 1}.${ext}`)); images++; });
  delete entry.files;
}
// 一首一行，重画某首时 diff 只动那一行。
writeFileSync(manifestPath, `{\n${Object.entries(manifest).map(([id, entry]) => `${JSON.stringify(id)}: ${JSON.stringify(entry)}`).join(',\n')}\n}\n`);

console.log(`发布了 ${Object.keys(manifest).length} 首、${images} 张图 → web/poems/art/，清单 → server/src/poems-art.json`);
if (skipped.length) console.log(`跳过 ${skipped.length} 首：\n  ${skipped.join('\n  ')}`);
