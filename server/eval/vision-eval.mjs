/**
 * Runs homework photos through the candidate vision models and writes a report to review by hand.
 * Usage (from server/): npm run eval:vision [-- <photos dir>] [--out <dir>] [--models a,b] [--limit n] [--dry-run]
 *
 * Photos: JPEG or PNG files, any names (the extension is not needed), default data/vision-eval/photos.
 * Models: eval/vision-models.json. Each one's key is read from the environment variable named in its `keyEnv`
 * (put it in .env); models without a key are skipped.
 * Output: <out>/report.html and <out>/results.json, default data/vision-eval. Both contain the child's homework.
 * data/ is not committed, so keep photos and reports there.
 *
 * --dry-run lists which photos would be sent to which vendor and stops, without sending anything.
 */
import { mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join, relative, resolve } from 'node:path';
import { imageInfo, runEval, summarize } from './vision-read.mjs';
import { renderReport } from './vision-report.mjs';

const maxBytes = 8_000_000;
const args = process.argv.slice(2);
const options = { photos: 'data/vision-eval/photos', out: 'data/vision-eval', models: null, limit: Infinity, dryRun: false };
for (let i = 0; i < args.length; i++) {
  if (args[i] === '--dry-run') options.dryRun = true;
  else if (args[i] === '--out') options.out = args[++i];
  else if (args[i] === '--models') options.models = (args[++i] ?? '').split(',').map(name => name.trim()).filter(Boolean);
  else if (args[i] === '--limit') options.limit = Number(args[++i]);
  else if (args[i].startsWith('--')) { console.error(`不认识的参数：${args[i]}`); process.exit(1); }
  else options.photos = args[i];
}
if (!options.out || (options.models && !options.models.length) || !(options.limit >= 1)) { console.error('--out、--models、--limit 后面要跟一个值。'); process.exit(1); }

// A model's address is either written out or, for the vendor the server already uses, taken from the same .env pair as its key.
const configured = JSON.parse(readFileSync(new URL('./vision-models.json', import.meta.url), 'utf8')).models
  .map(model => ({ ...model, apiUrl: model.apiUrl ?? process.env[model.apiUrlEnv], apiKey: process.env[model.keyEnv] }));
const wanted = configured.filter(model => !options.models || options.models.includes(model.name));
const models = wanted.filter(model => model.apiUrl && model.apiKey);
const noKey = wanted.filter(model => !model.apiUrl || !model.apiKey);

let names;
try { names = readdirSync(options.photos).filter(name => !name.startsWith('.')).sort(); }
catch { console.error(`找不到照片目录 ${options.photos}。把作业照片（JPEG 或 PNG）放进去再运行。`); process.exit(1); }
const photos = [], skipped = [];
for (const name of names) {
  const path = join(options.photos, name);
  if (!statSync(path).isFile()) continue;
  const bytes = readFileSync(path), info = imageInfo(bytes);
  if (!info) skipped.push(`${name}（不是 JPEG 或 PNG）`);
  else if (bytes.length > maxBytes) skipped.push(`${name}（超过 ${maxBytes / 1e6} MB）`);
  else if (photos.length < options.limit) photos.push({ name, path, bytes, ...info });
}

const megabytes = (photos.reduce((total, photo) => total + photo.bytes.length, 0) / 1e6).toFixed(1);
console.log(`照片：${photos.length} 张，共 ${megabytes} MB（${options.photos}）`);
if (skipped.length) console.log(`跳过：${skipped.join('，')}`);
for (const model of models) console.log(`会发给：${model.name}（${model.model}，${new URL(model.apiUrl).host}）`);
for (const model of noKey) console.log(`不会发给：${model.name}，没有设置 ${[!model.apiKey && model.keyEnv, !model.apiUrl && model.apiUrlEnv].filter(Boolean).join(' 和 ')}`);
console.log(`一共 ${photos.length * models.length} 个请求。`);
if (options.dryRun) process.exit(0);
if (!photos.length || !models.length) { console.error(photos.length ? '没有可用的模型：在 .env 里填上面列出的密钥。' : '没有可用的照片。'); process.exit(1); }

const startedAt = new Date();
const run = await runEval({ photos, models, onResult: result => process.stdout.write(result.ok ? '✓' : '✗') });
console.log();
const summary = summarize(run, models);
const runId = `${startedAt.toISOString().slice(0, 19)}-${photos.length}x${models.length}`;

mkdirSync(options.out, { recursive: true });
const reportPath = join(options.out, 'report.html');
writeFileSync(join(options.out, 'results.json'), JSON.stringify({ runId, models: models.map(({ apiKey, apiUrl, ...model }) => ({ ...model, host: new URL(apiUrl).host })), summary, photos: run.photos }, null, 1));
writeFileSync(reportPath, renderReport({ runId, startedAt: `${startedAt.toISOString().slice(0, 16).replace('T', ' ')} UTC`, models, run, summary,
  src: photo => relative(resolve(options.out), resolve(photo.path)).split(/[\\/]/).map(encodeURIComponent).join('/') }));

console.log('| 模型 | 成功 | 题数 | 平均耗时 | 每张约 | 判错 | 与多数不同 |');
console.log('| --- | --- | --- | --- | --- | --- | --- |');
for (const s of summary) {
  console.log(`| ${s.name} | ${s.ok}/${s.photos} | ${s.items} | ${s.meanMs === null ? '—' : `${(s.meanMs / 1000).toFixed(1)} 秒`} | ${s.costPerPhoto === null ? '—' : `¥${s.costPerPhoto}`} | ${s.judged ? `${s.misjudged}/${s.judged}` : '—'} | ${models.length > 2 ? s.outliers : '—'} |`);
}
console.log(`报告：${reportPath}（用浏览器打开，逐张标注读错的地方）`);
