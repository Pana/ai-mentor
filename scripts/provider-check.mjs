// Checks a real model vendor (e.g. DeepSeek) through the gateway with sample homework.
// Usage: node scripts/provider-check.mjs [path/to/.env]   (default: server/.env)
// Sends four requests (help, check, recognize with scripts/fixtures/homework.jpg, practice) and reports
// status, latency and the validated reply. The vendor API key is never printed.
import { readFileSync } from 'node:fs';
import { once } from 'node:events';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { createGateway } from '../server/src/gateway.mjs';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const envPath = process.argv[2] ?? join(root, 'server/.env');

function readEnv(path) {
  const env = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const match = line.match(/^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$/);
    if (match && !line.trim().startsWith('#')) env[match[1]] = match[2].replace(/^(['"])(.*)\1$/, '$2');
  }
  return env;
}

const env = readEnv(envPath);
for (const key of ['MODEL_API_URL', 'MODEL_API_KEY', 'MODEL_NAME']) {
  if (!env[key]) { console.error(`${key} is empty in ${envPath}`); process.exit(1); }
}
const token = env.TUTOR_DEVICE_TOKEN?.length >= 24 ? env.TUTOR_DEVICE_TOKEN : 'provider-check-local-token-0123456789';
const server = createGateway({ token, apiUrl: env.MODEL_API_URL, apiKey: env.MODEL_API_KEY, model: env.MODEL_NAME,
  jsonMode: env.MODEL_JSON_MODE !== 'false', visionModel: env.MODEL_VISION_NAME || '', imagesSupported: env.MODEL_SUPPORTS_IMAGES !== 'false' });
server.listen(0, '127.0.0.1');
await once(server, 'listening');
const url = `http://127.0.0.1:${server.address().port}/v1/tutor`;
console.log(`vendor: ${new URL(env.MODEL_API_URL).host}  model: ${env.MODEL_NAME}${env.MODEL_VISION_NAME ? `  vision: ${env.MODEL_VISION_NAME}` : ''}\n`);

const image = readFileSync(join(root, 'scripts/fixtures/homework.jpg')).toString('base64');
const task = { grade: 2, subject: 'MATH', textbook: '教材版本待确认', title: '小熊的橡果问题',
  instructions: '小熊有 24 颗橡果，又找到 18 颗。现在一共有多少颗？', history: [] };
const cases = [
  { name: 'help（求助）', body: { ...task, mode: 'help', answer: '', message: '我不知道个位怎么加' },
    expect: r => r.assessment === 'UNKNOWN' && !/42/.test(r.message) ? null : '提示里不应直接给出答案 42' },
  { name: 'check（检查，答案正确）', body: { ...task, mode: 'check', answer: '24 + 18 = 42', message: '请检查我的答案和步骤' },
    expect: r => r.assessment === 'CORRECT' ? null : `期望 CORRECT，实际 ${r.assessment}` },
  { name: 'check（检查，答案错误）', body: { ...task, mode: 'check', answer: '24 + 18 = 32', message: '请检查我的答案和步骤' },
    expect: r => r.assessment === 'INCORRECT' ? null : `期望 INCORRECT，实际 ${r.assessment}` },
  { name: 'recognize（拍照识题）', body: { ...task, mode: 'recognize', title: '', instructions: '', answer: '', message: '请识别照片中的作业要求', image },
    expect: r => r.subject === 'MATH' && /24/.test(r.instructions) ? null : '没有识别出数学题“24 + 18”' },
  { name: 'practice（生成练习）', body: { ...task, mode: 'practice', answer: '', message: '请围绕两位数进位加法生成一道适合2年级的练习' },
    expect: r => r.exercise?.hints?.length === 3 && r.exercise.answer ? null : '练习题不完整' }
];

let failures = 0;
for (const c of cases) {
  const started = Date.now();
  const response = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` }, body: JSON.stringify(c.body) });
  const seconds = ((Date.now() - started) / 1000).toFixed(1);
  const reply = await response.json();
  const problem = response.ok ? c.expect(reply) : `HTTP ${response.status} ${reply.error}`;
  if (problem) failures++;
  console.log(`${problem ? '✗' : '✓'} ${c.name}  ${seconds}s${problem ? `  — ${problem}` : ''}`);
  console.log(`  ${JSON.stringify(reply, null, 1).replace(/\n\s*/g, ' ').slice(0, 600)}\n`);
}
server.close();
console.log(failures ? `${failures} 项需要关注（格式失败会让 App 显示“无法识别”；判题或提示偏差需要调整提示词）。` : '全部通过。');
process.exit(failures ? 1 : 0);
