/* 小熊写字：说出想写的字 → 笔顺动画 + 拼音、部首、意思、组词。
   笔顺数据来自 hanzi-writer-data（服务端缓存在 /hanzi/strokes/），“想写哪个字”和释义来自 /v1/hanzi/lookup；
   字已经确定时（如直接输入单个字）详情走 /v1/hanzi/detail，不做语义解读。 */
'use strict';

const $ = sel => document.querySelector(sel);
const isHan = c => /^\p{Script=Han}$/u.test(c);
const SPEEDS = [{ label: '慢速', speed: 0.6, delay: 700 }, { label: '中速', speed: 1, delay: 450 }, { label: '快速', speed: 1.8, delay: 250 }];
const COLORS = { stroke: '#3b2a20', radical: '#e8601c', outline: '#ece0d4', highlight: '#ffb547', drawing: '#3b2a20' };

const store = {
  get(key, fallback) { try { const v = localStorage.getItem(`hanzi.${key}`); return v == null ? fallback : JSON.parse(v); } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(`hanzi.${key}`, JSON.stringify(value)); } catch { /* private mode: fine */ } }
};

const state = {
  result: null,     // {word, chars:[entry], alternatives, message}
  index: 0,         // selected entry in result.chars
  writer: null,
  data: null,       // stroke data of the selected char
  run: 0,           // bumps to cancel a running animation loop
  step: 0,          // next stroke for "下一笔"
  mode: 'idle',     // idle | play | step | quiz
  speed: store.get('speed', 1)
};

// ---------- 小工具 ----------
function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === 'class') node.className = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2), v);
    else if (v !== undefined && v !== null && v !== false) node.setAttribute(k, v === true ? '' : v);
  }
  for (const child of children.flat()) if (child != null && child !== false) node.append(child);
  return node;
}
const svgEl = (tag, attrs = {}) => {
  const node = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
  return node;
};
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));

function token() {
  return store.get('token', '');
}
// 家长可以用 /hanzi/#token=... 打开一次，凭证存到本机后从地址栏去掉。
function tokenFromHash() {
  const match = /(?:^#|&)token=([^&]+)/.exec(location.hash);
  if (!match) return;
  store.set('token', decodeURIComponent(match[1]));
  history.replaceState(null, '', location.pathname + location.search);
}
tokenFromHash();
window.addEventListener('hashchange', tokenFromHash);

// ---------- 朗读 ----------
let zhVoice = null;
function pickVoice() {
  if (!('speechSynthesis' in window)) return;
  const voices = speechSynthesis.getVoices();
  zhVoice = voices.find(v => /zh[-_]CN/i.test(v.lang) && /Tingting|婷婷|Xiaoxiao|晓晓/i.test(v.name))
    || voices.find(v => /zh[-_]CN/i.test(v.lang)) || voices.find(v => /^zh/i.test(v.lang)) || null;
}
if ('speechSynthesis' in window) { pickVoice(); speechSynthesis.addEventListener?.('voiceschanged', pickVoice); }
function speak(text) {
  if (!('speechSynthesis' in window) || !text) return;
  speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text);
  u.lang = 'zh-CN'; u.rate = 0.75;
  if (zhVoice) u.voice = zhVoice;
  speechSynthesis.speak(u);
}

// ---------- 语音输入 ----------
const AudioContextImpl = window.AudioContext || window.webkitAudioContext;
let recognizer = null;
let capture = null;
const hint = $('#ask-hint');
function setHint(text, error = false) { hint.textContent = text; hint.classList.toggle('error', error); }

function pcm16(chunks, inputRate, outputRate = 16_000) {
  const length = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const samples = new Float32Array(length);
  let offset = 0;
  for (const chunk of chunks) { samples.set(chunk, offset); offset += chunk.length; }
  const ratio = inputRate / outputRate;
  const output = new Int16Array(Math.max(0, Math.floor(samples.length / ratio)));
  for (let i = 0; i < output.length; i++) {
    const sample = Math.max(-1, Math.min(1, samples[Math.min(samples.length - 1, Math.floor(i * ratio))]));
    output[i] = sample < 0 ? sample * 0x8000 : sample * 0x7fff;
  }
  return output.buffer;
}

function releaseCapture(active) {
  active.processor.disconnect(); active.source.disconnect();
  active.stream.getTracks().forEach(track => track.stop());
  active.context.close().catch(() => {});
}

async function stopServerListening() {
  const active = capture;
  if (!active) return;
  capture = null; recognizer = null;
  $('#mic').classList.remove('listening');
  active.processor.onaudioprocess = null;
  const sampleRate = active.context.sampleRate;
  releaseCapture(active);
  if (Date.now() - active.startedAt < 300) { setHint('按住话筒说话，说完再松手。', true); return; }
  const body = pcm16(active.chunks, sampleRate);
  if (!body.byteLength) { setHint('没听到声音，再按住话筒试试。', true); return; }
  setHint('正在确认你说的内容……');
  let status = 0;
  try {
    const response = await fetch('/v1/hanzi/asr', { method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/octet-stream', ...(token() ? { Authorization: `Bearer ${token()}` } : {}) }, body });
    status = response.status;
    if (!response.ok) throw new Error(`asr_${response.status}`);
    const result = await response.json();
    if (result.text?.trim()) search(result.text);
    else setHint('没听清楚，再试一次吧。', true);
  } catch {
    if (status === 503) setHint('服务端还没有配置火山语音识别。', true);
    else if (status === 401) setHint('字典服务会话已失效，请刷新页面。', true);
    else setHint('火山语音识别暂时没回应，可以直接打字。', true);
  }
}

async function startServerListening() {
  const stream = await navigator.mediaDevices.getUserMedia({ audio: { channelCount: 1, echoCancellation: true, noiseSuppression: true } });
  state.run++; stopQuiz();                          // 孩子开口说新字了：旧字的动画和描写立刻停
  const context = new AudioContextImpl();
  await context.resume();
  const source = context.createMediaStreamSource(stream);
  const processor = context.createScriptProcessor(4096, 1, 1);
  const silent = context.createGain(); silent.gain.value = 0;
  const chunks = [];
  processor.onaudioprocess = event => chunks.push(new Float32Array(event.inputBuffer.getChannelData(0)));
  source.connect(processor); processor.connect(silent); silent.connect(context.destination);
  capture = { stream, context, source, processor, chunks, startedAt: Date.now() };
  recognizer = { stop: stopServerListening };
  $('#mic').classList.add('listening'); setHint('我在听，请说“春天的春”这样的说法……');
}

async function startListening() {
  if (recognizer) return;                              // 已经按住录音中，不重复启动
  if (navigator.mediaDevices?.getUserMedia && AudioContextImpl) {
    try { await startServerListening(); return; }
    catch { capture && releaseCapture(capture); capture = null; setHint('无法启动麦克风。Chrome 请使用 HTTPS 或 127.0.0.1，并允许麦克风权限。', true); return; }
  }
  setHint('当前浏览器不支持录音，请使用最新版 Chrome、Safari 或其他支持麦克风的浏览器。', true);
}

// ---------- 查询 ----------
const FILLER = /(我想写|我要写|我想知道|帮我查一下|帮我查|查一下|请问|怎么写|怎样写|如何写|的写法|这个字|这个词|呀|啊|呢|吧|吗[？?]?$)/g;
const OFFLINE_NOTICES = {
  no_token: '还没连接字典服务，现在只显示笔顺（家长可以在右上角 ⚙︎ 里设置）。',
  bad_token: '字典服务的凭证不对，现在只显示笔顺（家长可以在右上角 ⚙︎ 里改）。',
  busy: '查得太快啦，字典服务要歇一会儿，现在只显示笔顺。',
  server: '字典服务暂时没回应，现在只显示笔顺。',
  network: '连不上字典服务，现在只显示笔顺。'
};

function showStatus(content, kind = '') {
  const box = $('#status');
  box.className = `status ${kind}`;
  box.replaceChildren(...[].concat(content));
  box.hidden = false;
}

let searchSeq = 0;
/**
 * 尽量不等模型，先把要写的字猜出来显示，详情回来再由 enrich 补全：
 * - 单个汉字，或键盘输入/历史记录里的纯汉字词：字面就是目标，详情走 /v1/hanzi/detail；
 * - “妈妈的妈”“天空的空”这类说法：结尾“的”后的字几乎总是目标，先显示，再由 lookup 校正
 *   （识别错了模型会换字，enrich 发现字变了会整体重画）。
 * 猜不出（拼音、拆字等）才显示“正在找”等模型。语音来的多字词不能当字面目标（“木子李”是拆字说法）。
 */
function quickGuess(text, typed) {
  if (isHan(text)) return { word: text, useDetail: true };
  if (typed && /^\p{Script=Han}{1,8}$/u.test(text)) return { word: text, useDetail: true };
  const tail = /\p{Script=Han}的(\p{Script=Han})$/u.exec(text.replace(FILLER, '').replace(/\s+/g, ''))?.[1];
  return tail ? { word: tail, useDetail: false } : null;
}

async function search(raw, { typed = false } = {}) {
  const text = raw.replace(/\s+/g, ' ').trim().slice(0, 60);
  if (!text) return;
  $('#query').value = text;
  setHint('按住话筒说话，说完松手');
  const seq = ++searchSeq;
  $('#mic').classList.add('busy');
  const guess = quickGuess(text, typed);
  const instant = guess ? { word: guess.word, chars: [...new Set([...guess.word])].map(char => ({ char })), alternatives: [], message: '' } : null;
  if (instant) await show(instant);
  else showStatus([`正在找「${text}」`, el('span', { class: 'dots' })]);
  let reason = '';
  try {
    const savedToken = token();
    const response = await fetch(guess?.useDetail ? '/v1/hanzi/detail' : '/v1/hanzi/lookup', {
      method: 'POST', credentials: 'same-origin',
      headers: { 'Content-Type': 'application/json', ...(savedToken ? { Authorization: `Bearer ${savedToken}` } : {}) },
      body: JSON.stringify(guess?.useDetail ? { word: guess.word } : { text })
    });
    if (seq !== searchSeq) return;
    if (response.ok) {
      const result = await response.json();
      if (!result.chars.length) {
        if (!instant) { $('#result').hidden = true; showStatus(result.message || '没听出要写哪个字，换个说法试试？'); }
        return;
      }
      if (instant) enrich(result);
      else await show(result);
      return;
    }
    reason = response.status === 401 ? (savedToken ? 'bad_token' : 'no_token') : response.status === 429 ? 'busy' : 'server';
  } catch { reason = 'network'; }
  finally { if (seq === searchSeq) $('#mic').classList.remove('busy'); }
  if (seq !== searchSeq) return;
  if (instant) { showStatus(OFFLINE_NOTICES[reason], 'notice'); revealResult(); return; }   // 提示插在字的上面，会把田字格挤下去
  await showOffline(text, reason);
}

/** 字典详情回来了：补全已经显示的字，不重播笔顺动画；万一模型换字了才整体重画。 */
function enrich(result) {
  const sameWord = state.result && state.result.word === result.word && state.result.chars.length === result.chars.length;
  state.result = result;
  renderWord();
  renderAlternatives();
  remember(result.word);
  $('#status').hidden = true;
  if (sameWord && state.result.chars[state.index]) { renderInfo(state.result.chars[state.index], state.data); return; }
  select(0);
}

/** 字典服务不可用时：把话里的汉字直接当作要写的字，只显示笔顺。 */
async function showOffline(text, reason) {
  const chars = [...new Set([...text.replace(FILLER, '')].filter(isHan))].slice(0, 8);
  const why = OFFLINE_NOTICES[reason];
  if (!chars.length) { $('#result').hidden = true; showStatus(`${why.replace('现在只显示笔顺', '也没认出汉字')} 可以直接打出要写的字。`); return; }
  await show({ word: chars.join(''), chars: chars.map(char => ({ char })), alternatives: [], message: '' }, why);
}

async function show(result, notice = '') {
  state.result = result;
  if (notice) showStatus(notice, 'notice'); else $('#status').hidden = true;
  $('#result').hidden = false;
  renderWord();
  renderAlternatives();
  remember(result.word);
  revealResult();
  await select(0);
}

/** 触屏设备（手机、iPad，尤其横屏）上查询区会把田字格挤出第一屏：出结果时把字和田字格滚进视野，孩子不用自己往下翻。
    桌面用鼠标键盘时不动，免得连续打字查词时输入框被滚走。 */
function revealResult() {
  if ($('#result').hidden || !matchMedia('(pointer: coarse), (max-width: 860px)').matches) return;
  const top = $('#result').getBoundingClientRect().top;
  const padBottom = $('#pad').getBoundingClientRect().bottom;
  if (top >= 0 && padBottom <= innerHeight) return;
  // 有“只显示笔顺”这类提示时，放得下就连提示一起露出来
  const notice = $('#status');
  const showNotice = !notice.hidden && padBottom - notice.getBoundingClientRect().top + 12 <= innerHeight;
  const target = showNotice ? notice : $('#result');
  target.scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function renderWord() {
  const { word, chars } = state.result;
  const byChar = new Map(chars.map((c, i) => [c.char, i]));
  $('#word').replaceChildren(...[...word].map(ch => {
    const i = byChar.get(ch);
    return el('button', { type: 'button', class: `tile${i === state.index ? ' on' : ''}`, 'data-index': i, onclick: () => select(i) },
      el('span', { class: 'py' }, chars[i].pinyin || ''), el('span', { class: 'ch' }, glyph(ch)));
  }));
}

function renderAlternatives() {
  const alts = state.result.alternatives || [];
  const box = $('#alts');
  box.hidden = !alts.length;
  box.replaceChildren(el('span', { class: 'chips-label' }, '是不是想写：'),
    ...alts.map(a => el('button', { type: 'button', class: 'chip', onclick: () => search(a.hint || a.char) },
      el('b', {}, glyph(a.char)), `${a.pinyin}${a.hint ? ` · ${a.hint}` : ''}`)));
}

// ---------- 笔顺数据与书写 ----------
const strokeCache = new Map();
function loadStrokes(char) {
  if (!strokeCache.has(char)) {
    strokeCache.set(char, fetch(`/hanzi/strokes/${encodeURIComponent(char)}.json`)
      .then(r => (r.ok ? r.json() : null)).catch(() => null)
      .then(data => { if (!data) strokeCache.delete(char); return data; }));
  }
  return strokeCache.get(char);
}

/**
 * 用笔顺数据画出楷书字形。安卓手机和大多数国产浏览器没有楷体，CSS 里的“楷体”会退成宋体；
 * 笔顺数据本身就是楷书，画出来在所有设备上一样，也和田字格里写的字一致。
 * 数据到之前先用系统字体顶着；没有数据的字（个别偏旁、生僻字）就一直用系统字体。
 */
function glyph(char) {
  const span = el('span', { class: 'glyph', role: 'img', 'aria-label': char }, char);
  if (isHan(char)) loadStrokes(char).then(data => { if (data) span.replaceChildren(glyphSvg(data)); });
  return span;
}
function glyphSvg(data) {
  const svg = svgEl('svg', { viewBox: '0 0 100 100', 'aria-hidden': 'true' });
  const g = svgEl('g', { transform: HanziWriter.getScalingTransform(100, 100, 0).transform });
  for (const d of data.strokes) g.append(svgEl('path', { d }));
  svg.append(g);
  return svg;
}

function padSize() { return Math.round($('#pad').getBoundingClientRect().width) || 300; }

function createWriter(char) {
  const target = $('#writer');
  target.replaceChildren();
  const speed = SPEEDS[state.speed];
  state.writer = HanziWriter.create(target, char, {
    width: padSize(), height: padSize(), padding: Math.round(padSize() * 0.06), renderer: 'svg',
    showCharacter: false, showOutline: true,
    strokeColor: COLORS.stroke, radicalColor: $('#radical-toggle').checked ? COLORS.radical : null,
    outlineColor: COLORS.outline, highlightColor: COLORS.highlight, drawingColor: COLORS.drawing,
    drawingWidth: Math.max(14, Math.round(padSize() / 18)),
    strokeAnimationSpeed: speed.speed, delayBetweenStrokes: speed.delay, strokeHighlightSpeed: 2,
    showHintAfterMisses: 2, highlightOnComplete: true, leniency: 1.3,
    charDataLoader: (c, onLoad, onError) => loadStrokes(c).then(d => (d ? onLoad(d) : onError(new Error('no data'))))
  });
}

async function select(i) {
  const entry = state.result.chars[i];
  if (!entry) return;
  state.index = i;
  state.run++;
  stopQuiz();
  document.querySelectorAll('#word .tile').forEach(t => t.classList.toggle('on', Number(t.dataset.index) === i));
  renderInfo(entry, null);
  $('#steps').replaceChildren();
  $('#counter').textContent = '';
  const data = await loadStrokes(entry.char);
  if (state.result.chars[state.index] !== entry) return;
  state.data = data;
  renderInfo(entry, data);
  if (!data) {
    $('#writer').replaceChildren();
    state.writer = null;
    $('#counter').textContent = '这个字暂时没有笔顺数据';
    return;
  }
  renderSteps(data);
  createWriter(entry.char);
  play();
}

const total = () => state.data?.strokes.length || 0;
function setCounter(done, label = '') {
  const counter = $('#counter');
  counter.replaceChildren(label || '', label ? ' ' : '', '第 ', el('b', {}, String(done)), ` 笔 / 共 ${total()} 笔`);
  document.querySelectorAll('#steps button').forEach((b, k) => b.classList.toggle('on', k === done - 1));
}
function setMode(mode) {
  state.mode = mode;
  $('#pad').classList.toggle('quiz', mode === 'quiz');
  $('#trace').classList.toggle('active', mode === 'quiz');
  $('#next').classList.toggle('active', mode === 'step');
  $('#praise').hidden = true;
}
function stopQuiz() {
  if (state.mode === 'quiz' && state.writer) state.writer.cancelQuiz();
  setMode('idle');
}
const once = fn => new Promise(resolve => fn(resolve));

/** 一笔一笔连贯写完，同时更新“第几笔”和笔顺分解条。 */
async function play() {
  if (!state.writer) return;
  const run = ++state.run;
  stopQuiz();
  setMode('play');
  await state.writer.hideCharacter({ duration: 0 });
  for (let k = 0; k < total(); k++) {
    if (run !== state.run) return;
    setCounter(k + 1);
    await once(done => state.writer.animateStroke(k, { onComplete: done }));
    if (run !== state.run) return;
    await wait(SPEEDS[state.speed].delay);
  }
  if (run === state.run) { setMode('idle'); state.step = total(); }
}

async function nextStroke() {
  if (!state.writer) return;
  const run = ++state.run;
  if (state.mode !== 'step' || state.step >= total()) {
    stopQuiz();
    setMode('step');
    state.step = 0;
    await state.writer.hideCharacter({ duration: 0 });
  }
  const k = state.step++;
  setCounter(k + 1);
  await once(done => state.writer.animateStroke(k, { onComplete: done }));
  if (run === state.run && state.step >= total()) setCounter(total(), '写完啦');
}

function trace() {
  if (!state.writer) return;
  if (state.mode === 'quiz') { stopQuiz(); state.writer.showCharacter(); return; }
  state.run++;
  setMode('quiz');
  setCounter(1, '轮到你写：');
  state.writer.quiz({
    onCorrectStroke: s => { if (s.strokesRemaining) setCounter(s.strokeNum + 2, '写对了！接着写'); },
    onMistake: s => {
      setCounter(s.strokeNum + 1, '再看看');
      praise(s.mistakesOnStroke >= 2 ? '跟着亮起来的那一笔写' : '从起笔的地方开始写哦', true);
    },
    onComplete: ({ totalMistakes }) => {
      setMode('idle');
      setCounter(total(), '写完啦');
      const words = totalMistakes === 0 ? '太棒了，一笔都没错！' : totalMistakes <= 2 ? '写得真好！' : '写完啦，再练一遍会更好！';
      praise(words);
      speak(words);
    }
  });
}

let praiseTimer = 0;
function praise(text, tryAgain = false) {
  const box = $('#praise');
  box.textContent = text;
  box.classList.toggle('try', tryAgain);
  box.hidden = false;
  clearTimeout(praiseTimer);
  praiseTimer = setTimeout(() => { box.hidden = true; }, tryAgain ? 1800 : 3000);
}

/** 字典里的笔顺分解：第 k 格画出前 k 笔，第 k 笔标红。点一格就在大格子里把那一笔亮一下。 */
function renderSteps(data) {
  const size = 60;
  const { transform } = HanziWriter.getScalingTransform(size, size, 4);
  $('#steps-total').textContent = `共 ${data.strokes.length} 笔`;
  $('#steps').replaceChildren(...data.strokes.map((_, k) => {
    const svg = svgEl('svg', { viewBox: `0 0 ${size} ${size}`, 'aria-hidden': 'true' });
    for (const [x1, y1, x2, y2] of [[size / 2, 0, size / 2, size], [0, size / 2, size, size / 2]]) {
      svg.append(svgEl('line', { x1, y1, x2, y2, stroke: '#f2c6ba', 'stroke-width': 0.6, 'stroke-dasharray': '2 2' }));
    }
    const g = svgEl('g', { transform });
    data.strokes.slice(0, k + 1).forEach((d, j) => g.append(svgEl('path', { d, fill: j === k ? '#e5484d' : '#3b2a20' })));
    svg.append(g);
    return el('li', {}, el('button', { type: 'button', 'aria-label': `第 ${k + 1} 笔`, onclick: () => showStroke(k) }, svg), String(k + 1));
  }));
}

async function showStroke(k) {
  if (!state.writer) return;
  state.run++;
  stopQuiz();
  setMode('idle');
  setCounter(k + 1);
  await state.writer.showCharacter({ duration: 0 });
  state.writer.highlightStroke(k);
}

// ---------- 字的信息 ----------
function renderInfo(entry, data) {
  const fact = (k, v, sub) => el('div', { class: 'fact' }, el('div', { class: 'k' }, k), el('div', { class: 'v' }, v), sub ? el('div', { class: 'sub' }, sub) : null);
  const box = $('#info');
  const top = el('div', { class: 'info-top' },
    el('span', { class: 'big-ch' }, glyph(entry.char)),
    el('div', {}, el('div', { class: 'pinyin' }, entry.pinyin || ''),
      el('button', { type: 'button', class: 'btn small', onclick: () => speak(entry.char) }, '🔊 读一读')));
  const facts = el('div', { class: 'facts' },
    entry.radical ? fact('部首', [el('span', { class: 'rad' }, glyph(entry.radical)), entry.radicalName || ''], entry.radicalMeaning) : null,
    entry.structure ? fact('结构', entry.structure) : null,
    fact('笔画', data ? `${data.strokes.length} 画` : '…'));
  const parts = [top, facts];
  if (entry.meaning) parts.push(el('div', {}, el('p', { class: 'section-k' }, '意思'), el('p', { class: 'meaning' }, entry.meaning)));
  if (entry.words?.length) {
    parts.push(el('div', {}, el('p', { class: 'section-k' }, '组词（点一下听读音）'),
      el('div', { class: 'words' }, entry.words.map(w => el('button', { type: 'button', class: 'chip', onclick: () => speak(w) },
        [...w].map(c => (c === entry.char ? el('mark', {}, glyph(c)) : glyph(c))))))));
  }
  if (entry.tip) parts.push(el('div', { class: 'tip' }, el('span', { 'aria-hidden': 'true' }, '🐻'), el('span', {}, entry.tip)));
  if (!entry.pinyin && !entry.meaning) parts.push(el('p', { class: 'muted' }, '连上字典服务后，这里会显示拼音、部首、意思和组词。'));
  box.replaceChildren(...parts);
}

// ---------- 最近查过 ----------
function remember(word) {
  const list = [word, ...store.get('history', []).filter(w => w !== word)].slice(0, 12);
  store.set('history', list);
  renderHistory();
}
function renderHistory() {
  const list = store.get('history', []);
  const box = $('#history');
  box.hidden = !list.length;
  box.replaceChildren(el('span', { class: 'chips-label' }, '最近查过'),
    ...list.map(w => el('button', { type: 'button', class: 'chip', onclick: () => search(w, { typed: true }) }, w)));
}

// ---------- 设置 ----------
function openSettings(note = '') {
  $('#token').value = token();
  $('#settings-note').textContent = note;
  $('#settings').showModal();
}
$('#settings').addEventListener('close', () => {
  if ($('#settings').returnValue === 'save') store.set('token', $('#token').value.trim());
});

// ---------- 事件 ----------
// 按住话筒录音，松手结束；指针和键盘（Enter/空格按住）都支持。
const mic = $('#mic');
let heldPointer = null, heldKey = false;
mic.addEventListener('pointerdown', event => {
  if (event.pointerType === 'mouse' && event.button !== 0) return;
  if (heldPointer !== null) return;                    // 已有手指按着，忽略第二根
  heldPointer = event.pointerId;
  try { mic.setPointerCapture(event.pointerId); } catch { /* 松手事件照样会冒泡 */ }
  event.preventDefault();
  startListening();
});
const releaseHold = event => {
  if (event.pointerId !== heldPointer) return;
  heldPointer = null;
  recognizer?.stop();
};
mic.addEventListener('pointerup', releaseHold);
mic.addEventListener('pointercancel', releaseHold);
mic.addEventListener('keydown', event => {
  if (event.key !== 'Enter' && event.key !== ' ') return;
  event.preventDefault();
  if (event.repeat || heldKey) return;
  heldKey = true;
  startListening();
});
mic.addEventListener('keyup', event => {
  if (event.key !== 'Enter' && event.key !== ' ') return;
  if (!heldKey) return;
  heldKey = false;
  recognizer?.stop();
});
mic.addEventListener('contextmenu', event => event.preventDefault());   // 触屏长按别弹菜单
$('#search-form').addEventListener('submit', event => { event.preventDefault(); $('#query').blur(); search($('#query').value, { typed: true }); });
$('#examples').addEventListener('click', event => { if (event.target.matches('.chip')) search(event.target.textContent); });
$('#settings-btn').addEventListener('click', () => openSettings());
$('#play').addEventListener('click', play);
$('#next').addEventListener('click', nextStroke);
$('#trace').addEventListener('click', trace);
$('#speak-word').addEventListener('click', () => speak(state.result?.word));
$('#radical-toggle').addEventListener('change', event => state.writer?.updateColor('radicalColor', event.target.checked ? COLORS.radical : null));
const speedButton = $('#speed');
speedButton.textContent = SPEEDS[state.speed].label;
speedButton.addEventListener('click', () => {
  state.speed = (state.speed + 1) % SPEEDS.length;
  store.set('speed', state.speed);
  speedButton.textContent = SPEEDS[state.speed].label;
  if (state.data) { state.run++; stopQuiz(); createWriter(state.result.chars[state.index].char); play(); }
});
let resizeTimer = 0;
window.addEventListener('resize', () => {
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    if (!state.writer) return;
    const size = padSize();
    state.writer.updateDimensions({ width: size, height: size, padding: Math.round(size * 0.06) });
  }, 150);
});

renderHistory();
if (!navigator.mediaDevices?.getUserMedia || !AudioContextImpl) setHint('当前浏览器不支持录音，请使用最新版 Chrome、Safari 或其他支持麦克风的浏览器。', true);
