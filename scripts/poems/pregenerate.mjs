/**
 * 事先生成课本古诗和考级里补的诗的讲解（含拼音），写进 server/src/poems-explanations.json，随代码发布。
 *
 *   node --env-file=server/.env scripts/poems/pregenerate.mjs            # 只生成还没有的、或诗文改过的
 *   node --env-file=server/.env scripts/poems/pregenerate.mjs --redo s1a01,k1a02   # 重新生成这几首
 *
 * 模型配置和服务端一样（MODEL_API_URL、MODEL_API_KEY、MODEL_NAME，POEMS_MODEL_NAME 优先）。
 * 拼音有哪一行对不上（那一行不显示拼音）时最多再试两次。生成后请人过目，直接改这个文件就行；
 * 改了提示词要重新生成时，把 server/src/poems.mjs 里的 EXPLAIN_VERSION 加一再跑。
 */
import { existsSync, readFileSync, renameSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { explainKey, loadLevelPoems, loadSchoolPoems, requestExplanation } from '../../server/src/poems.mjs';

const out = fileURLToPath(new URL('../../server/src/poems-explanations.json', import.meta.url));
const redoArg = process.argv.indexOf('--redo');
const redo = new Set(redoArg > 0 ? (process.argv[redoArg + 1] || '').split(',').filter(Boolean) : []);

const model = { apiUrl: process.env.MODEL_API_URL, apiKey: process.env.MODEL_API_KEY,
  model: process.env.POEMS_MODEL_NAME || process.env.MODEL_NAME, jsonMode: process.env.MODEL_JSON_MODE !== 'false',
  thinking: process.env.POEMS_MODEL_THINKING || 'disabled' };
if (!model.apiUrl || !model.apiKey || !model.model) {
  console.error('缺少模型配置：用 node --env-file=server/.env 运行，或设置 MODEL_API_URL、MODEL_API_KEY、MODEL_NAME');
  process.exit(1);
}

const school = loadSchoolPoems();
const poems = [...school, ...loadLevelPoems(undefined, school).own];
const done = existsSync(out) ? JSON.parse(readFileSync(out, 'utf8')) : {};
const complete = e => e?.explanation?.pinyin?.every(Boolean);
const todo = poems.filter(p => redo.has(p.id) || done[p.id]?.key !== explainKey(p) || !complete(done[p.id]));
console.log(`${poems.length} 首，要生成 ${todo.length} 首`);

function save() {
  // 按课本、考级的顺序写，方便人对着看；不在清单里的旧条目去掉。
  const ordered = Object.fromEntries(poems.filter(p => done[p.id]).map(p => [p.id, done[p.id]]));
  writeFileSync(`${out}.tmp`, `${JSON.stringify(ordered, null, 2)}\n`);
  renameSync(`${out}.tmp`, out);
}

let finished = 0;
const problems = [];
async function work(poem) {
  let best = null;
  for (let attempt = 0; attempt < 3 && !complete(best); attempt++) {
    try {
      const explanation = await requestExplanation(poem, model);
      const rows = explanation.pinyin.filter(Boolean).length;
      if (!best || rows > best.explanation.pinyin.filter(Boolean).length) best = { key: explainKey(poem), title: poem.title, author: poem.author, explanation };
    } catch (error) {
      if (attempt === 2 && !best) problems.push(`${poem.id} ${poem.title}：${error.message}`);
    }
  }
  if (best) {
    done[poem.id] = best;
    save();
    if (!complete(best)) problems.push(`${poem.id} ${poem.title}：有 ${best.explanation.pinyin.filter(r => !r).length} 行拼音对不上`);
  }
  console.log(`[${++finished}/${todo.length}] ${poem.id} ${poem.title}${best ? '' : ' ✗'}`);
}

const queue = [...todo];
await Promise.all(Array.from({ length: 3 }, async () => { while (queue.length) await work(queue.shift()); }));
console.log(problems.length ? `\n要人看一下：\n${problems.join('\n')}` : '\n全部生成好了');
