/**
 * Runs the fixed teacher questions against the configured model and writes a report.
 * Usage (from server/): npm run eval:teacher [-- report.md]
 * Uses MODEL_API_URL / MODEL_API_KEY / TEACHER_MODEL_NAME (or MODEL_NAME) / TEACHER_MODEL_THINKING from .env,
 * the same prompt, board validation and arithmetic check as the live teacher. Costs a few thousand tokens per case.
 */
import { writeFileSync } from 'node:fs';
import { Board, describeLearner, normalizeSegment, segmentLine, teacherPrompt } from '../src/board.mjs';
import { checkedSegments } from '../src/teacher.mjs';
import { normalizeArithmetic } from '../src/verify.mjs';
import { cases, learner } from './teacher-cases.mjs';

const model = { apiUrl: process.env.MODEL_API_URL, apiKey: process.env.MODEL_API_KEY,
  model: process.env.TEACHER_MODEL_NAME || process.env.MODEL_NAME, thinking: process.env.TEACHER_MODEL_THINKING || 'disabled' };
if (!model.apiUrl || !model.apiKey || !model.model) { console.error('MODEL_API_URL, MODEL_API_KEY and MODEL_NAME are required'); process.exit(1); }
const out = process.argv[2] || 'eval/teacher-report.md';

/** Model output lines that are not one JSON object each (the format the client relies on). */
function badLines(sseText) {
  let content = '';
  for (const line of sseText.split('\n')) {
    const payload = line.startsWith('data:') ? line.slice(5).trim() : '';
    if (!payload || payload === '[DONE]') continue;
    try { content += JSON.parse(payload).choices?.[0]?.delta?.content ?? ''; } catch { /* keep going */ }
  }
  const lines = content.split('\n');
  if (!sseText.includes('[DONE]')) lines.pop(); // the reply was cut at a question: the last line never finished
  return lines.map(l => l.trim()).filter(l => l && !(l.startsWith('{') && (() => { try { JSON.parse(l.replace(/,$/, '')); return true; } catch { return false; } })())).length;
}

function leaks(speech, answer) {
  if (answer === undefined) return false;
  const plain = normalizeArithmetic(speech);
  return new RegExp(`(=|剩下?|一共|总共|答案是|就是|有)${answer}(?!\\d)`).test(plain);
}

async function runTurn(state, text) {
  const messages = [
    { role: 'system', content: teacherPrompt },
    { role: 'system', content: `学情资料：\n${describeLearner(learner)}` },
    ...state.history,
    { role: 'user', content: `当前白板：${JSON.stringify(state.board.elements)}\n孩子说：${text}` }
  ];
  let sseText = '';
  const post = async (body, signal) => {
    const response = await fetch(model.apiUrl, { method: 'POST', signal,
      headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${model.apiKey}` }, body: JSON.stringify(body) });
    const decoder = new TextDecoder();
    return { ok: response.ok, status: response.status,
      body: (async function* () { for await (const chunk of response.body) { sseText += decoder.decode(chunk, { stream: true }); yield chunk; } })() };
  };
  const checks = [];
  const started = Date.now();
  let firstMs = null, rawOps = 0, keptOps = 0, long = 0, promised = 0;
  const segments = [];
  for await (const raw of checkedSegments(messages, post, model, undefined, { onCheck: c => checks.push(c) })) {
    firstMs ??= Date.now() - started;
    rawOps += Array.isArray(raw.board) ? raw.board.length : 0;
    const segment = normalizeSegment(raw, state.board);
    if (!segment) continue;
    keptOps += segment.board.length;
    if ([...segment.speech].length > 50) long++;
    // Says it is drawing now (not pointing at what is already there) but sends no op.
    if (/写出|写上|画上|画出来|标出|标上|我画|我写/.test(segment.speech) && !/画了|写了|列好|画好|写好/.test(segment.speech)
      && !segment.board.length) promised++;
    segments.push(segment);
  }
  const spoken = segments.map(s => s.speech).join('');
  // As the live teacher keeps it: each segment as the model wrote it, drawing included.
  state.history.push({ role: 'user', content: text }, { role: 'assistant', content: segments.map(segmentLine).join('\n') });
  return { text, segments, spoken, firstMs, totalMs: Date.now() - started, bad: badLines(sseText), dropped: rawOps - keptOps, long, promised, checks,
    awaits: segments.at(-1)?.await === true, types: [...new Set(state.board.elements.map(el => el.type))] };
}

async function runCase(c) {
  const state = { board: new Board(), history: [] };
  const turns = [];
  try { for (const text of c.turns) turns.push(await runTurn(state, text)); }
  catch (error) { return { c, turns, error: error.message }; }
  const first = turns[0];
  const problems = [];
  for (const t of turns) {
    if (!t.segments.length) problems.push('空回复');
    if (t.bad) problems.push(`${t.bad} 行不是 JSON`);
    if (t.dropped) problems.push(`丢弃 ${t.dropped} 个白板操作`);
    if (t.long) problems.push(`${t.long} 段超过 50 字`);
    if (t.promised) problems.push(`${t.promised} 段说要画却没画`);
    for (const check of t.checks) problems.push(`算错被拦：${check.wrong.map(w => `${w.claim}（应为 ${w.expected}）`).join('，')}${check.corrected ? '，已重讲' : '，放弃'}`);
  }
  const closed = turns.map(t => t.segments.some(s => s.end));
  if (c.ends && !closed.at(-1)) problems.push('孩子要走，小熊没有结束对话');
  if (closed.slice(0, c.ends ? -1 : undefined).some(Boolean)) problems.push('孩子没要走，小熊却结束了对话');
  if (c.kind === 'homework') {
    if (leaks(first.spoken, c.answer)) problems.push('第一轮说出了答案');
    if (!first.awaits) problems.push('第一轮没有停下来等孩子');
  }
  if (c.board && !turns.some(t => t.types.includes(c.board))) problems.push(`没有画${c.board}`);
  return { c, turns, problems };
}

const results = [];
const queue = [...cases];
await Promise.all(Array.from({ length: 4 }, async () => { while (queue.length) { const c = queue.shift(); const r = await runCase(c); results.push(r); process.stdout.write(r.error || r.problems.length ? '✗' : '✓'); } }));
console.log();
results.sort((a, b) => cases.indexOf(a.c) - cases.indexOf(b.c));

const firsts = results.flatMap(r => r.turns.map(t => t.firstMs)).filter(Number.isFinite).sort((a, b) => a - b);
const pct = p => firsts[Math.min(firsts.length - 1, Math.floor(p * firsts.length))];
const clean = results.filter(r => !r.error && !r.problems.length).length;
const lines = [`# 小熊老师评测`, '', `${new Date().toISOString().slice(0, 16).replace('T', ' ')} UTC · 模型 ${model.model} · thinking ${model.thinking} · ${cases.length} 个用例`, '',
  `- 无问题：${clean}/${results.length}`,
  `- 第一段出来（不含语音识别和合成）：中位 ${pct(0.5)} ms，P90 ${pct(0.9)} ms`,
  `- 验算拦截：${results.flatMap(r => r.turns.flatMap(t => t.checks)).length} 次`, '',
  '| 用例 | 类型 | 问题 | 首段 ms |', '| --- | --- | --- | --- |',
  ...results.map(r => `| ${r.c.id} | ${r.c.kind} | ${r.error ? `出错：${r.error}` : r.problems.join('；') || '—'} | ${r.turns.map(t => t.firstMs).join(' / ')} |`),
  '', '## 对话', ''];
for (const r of results) {
  lines.push(`### ${r.c.id}`, '');
  for (const t of r.turns) {
    lines.push(`- **孩子**：${t.text}`);
    for (const s of t.segments) lines.push(`  - ${s.speech}${s.board.length ? ` 〔${s.board.map(op => op.op === 'clear' ? 'clear' : `${op.op} ${op.el?.type ?? op.id}`).join('，')}〕` : ''}${s.await ? ' ⏸' : ''}${s.end ? ' ⏹' : ''}`);
  }
  lines.push('');
}
writeFileSync(out, lines.join('\n'));
console.log(lines.slice(0, 8).join('\n'));
console.log(`报告：${out}`);
