#!/usr/bin/env node
/**
 * 生成 server/src/hanzi-radicals.json：每个字的部首和部首占第几笔。
 * 字典页和田字格的“部首变色”都只认这张表，不再用模型回答的部首，两边就不会对不上。
 *
 * 来源是 Make Me a Hanzi 的 dictionary.txt（LGPL-3.0，笔顺数据 hanzi-writer-data 也出自这个项目），
 * 用它的 radical 字段，再用 decomposition + matches（每一笔属于哪个部件）算出部首的笔画。
 * 少数字的部首和小学课本（《新华字典》）不同，或者算不出笔画，在 OVERRIDES 里手工改。
 *
 *   node scripts/hanzi-radicals.mjs                  # 下载固定版本的 dictionary.txt
 *   node scripts/hanzi-radicals.mjs dictionary.txt   # 用本地文件
 */
import { readFileSync, writeFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

const COMMIT = 'bddc96d41bef78427ed0e034e9f7e31d71fd1b92';
const SOURCE = `https://raw.githubusercontent.com/skishore/makemeahanzi/${COMMIT}/dictionary.txt`;
const OUT = fileURLToPath(new URL('../server/src/hanzi-radicals.json', import.meta.url));

/** 字典里康熙部首的写法 → 课本里的写法。 */
const DISPLAY = {
  '⺼': '月', '夊': '夂', '罓': '罒', '⺳': '罒', '㔾': '卩', '⺊': '卜', '⺍': '⺌', '⺀': '冫', '艸': '艹', '辵': '辶',
  '釒': '钅', '糹': '纟', '訁': '讠', '飠': '饣', '龶': '王', '靑': '青', '镸': '长', '尣': '尢', '歺': '歹', '氺': '水'
};

/** 部件里可能出现的写法：部首写成偏旁，部件却写成整字（或反过来）时也认得出。 */
const SAME = [
  ['氵', '水', '氺'], ['亻', '人'], ['扌', '手'], ['忄', '心', '⺗'], ['灬', '火'], ['讠', '言', '訁'], ['钅', '金', '釒'],
  ['饣', '食', '飠'], ['纟', '糸', '糹'], ['礻', '示'], ['衤', '衣'], ['罒', '网', '罓', '⺳'], ['月', '⺼', '肉'], ['艹', '艸'],
  ['辶', '辵'], ['犭', '犬'], ['刂', '刀'], ['⺈', '刀'], ['阝', '阜', '邑'], ['夂', '夊'], ['王', '玉', '龶'], ['卩', '㔾'],
  ['卜', '⺊'], ['⺌', '⺍', '小'], ['冫', '⺀'], ['爫', '爪'], ['⺮', '竹'], ['耂', '老'], ['牜', '牛'], ['𧾷', '足'],
  ['长', '镸'], ['青', '靑'], ['尢', '尣'], ['歹', '歺'], ['覀', '西', '襾'], ['彐', '⺕'], ['龸', '⺌']
];

/**
 * 手工修正：字 → [部首, 部首的笔画序号]。笔画序号按 hanzi-writer-data 的笔顺，从 0 开始；
 * 序号为 null 表示照常从字典算（只改部首写法时用）。
 */
const OVERRIDES = {
  // 字典按康熙部首（或标错了），课本按《新华字典》
  年: ['丿', [0]], 来: ['一', [0]], 平: ['一', [0]], 更: ['一', [0]], 干: ['干', [0, 1, 2]],
  类: ['米', [0, 1, 2, 3, 4, 5]], 采: ['爫', [0, 1, 2, 3]], 习: ['乙', [0]], 并: ['丷', [0, 1]]
};

const parent = new Map();
for (const group of SAME) for (const c of group) parent.set(c, group);
const variants = r => new Set([r, DISPLAY[r] ?? r, ...(parent.get(r) ?? []), ...(parent.get(DISPLAY[r]) ?? [])]);

const ternary = new Set(['⿲', '⿳']);
const isIdc = c => c >= '⿰' && c <= '⿻';

/** 把 IDS 拆成树：叶子是部件，内部节点是结构符。 */
function parseIds(ids) {
  const chars = [...ids];
  let i = 0;
  const node = () => {
    const c = chars[i++];
    if (c === undefined) throw new Error('short');
    if (!isIdc(c)) return { leaf: c };
    const n = ternary.has(c) ? 3 : 2;
    return { op: c, kids: Array.from({ length: n }, node) };
  };
  const tree = node();
  return tree;
}

/** 找出所有叶子：[路径, 部件]。 */
function leaves(tree, path = [], out = []) {
  if (tree.leaf) out.push([path, tree.leaf]);
  else tree.kids.forEach((k, j) => leaves(k, [...path, j], out));
  return out;
}

const startsWith = (path, prefix) => prefix.every((p, j) => path[j] === p);

/** 部首笔画：字典的 matches 记录每一笔落在哪个部件上。找不到时返回 null。 */
function radicalStrokes(entry, radical, dict, depth = 0) {
  const total = entry.matches.length;
  if (variants(radical).has(entry.character)) return [...Array(total).keys()];
  let tree;
  try { tree = parseIds(entry.decomposition); } catch { return null; }
  const want = variants(radical);
  const found = leaves(tree).filter(([, c]) => want.has(c));
  if (found.length) {
    // 同一个部件出现几次时（林、森），取最先写的那个
    const [path] = found[0];
    const strokes = entry.matches.flatMap((m, k) => (m && startsWith(m, path) ? [k] : []));
    if (strokes.length) return strokes;
  }
  if (depth > 2) return null;
  // 部首藏在更小的部件里（修 = 攸 + 彡，亻在攸里）：展开那个部件；
  // 两边笔画数不同时，部首在部件的开头或结尾才按位置对上。
  for (const [path, c] of leaves(tree)) {
    const sub = dict.get(c);
    if (!sub || sub.character === entry.character) continue;
    const inner = radicalStrokes(sub, radical, dict, depth + 1);
    if (!inner || !inner.length) continue;
    const mine = entry.matches.flatMap((m, k) => (m && startsWith(m, path) ? [k] : []));
    if (!mine.length) continue;
    const n = sub.matches.length;
    if (mine.length === n) return inner.map(k => mine[k]);
    const prefix = inner.every((k, j) => k === j);
    const suffix = inner.every((k, j) => k === n - inner.length + j);
    if (prefix && inner.length < mine.length) return mine.slice(0, inner.length);
    if (suffix && inner.length < mine.length) return mine.slice(mine.length - inner.length);
  }
  return null;
}

async function main() {
  const text = process.argv[2] ? readFileSync(process.argv[2], 'utf8') : await (await fetch(SOURCE)).text();
  const entries = text.trim().split('\n').map(line => JSON.parse(line));
  const dict = new Map(entries.map(e => [e.character, e]));
  const table = {};
  const missing = [];
  for (const e of entries) {
    if (!e.radical || !Array.isArray(e.matches)) continue;
    const override = OVERRIDES[e.character];
    const radical = override?.[0] ?? DISPLAY[e.radical] ?? e.radical;
    const strokes = override?.[1] ?? radicalStrokes(e, e.radical, dict) ?? radicalStrokes(e, radical, dict);
    if (!strokes) missing.push(e.character);
    table[e.character] = strokes ? [radical, strokes] : [radical];
  }
  for (const c of Object.keys(OVERRIDES)) if (!table[c]) table[c] = OVERRIDES[c];
  const keys = Object.keys(table).sort();
  const body = `{\n${keys.map(k => `${JSON.stringify(k)}:${JSON.stringify(table[k])}`).join(',\n')}\n}\n`;
  writeFileSync(OUT, body);
  console.log(`${keys.length} 个字，${missing.length} 个算不出部首笔画（只显示部首、不变色）`);
  if (process.env.VERBOSE) console.log(missing.join(''));
}

await main();
