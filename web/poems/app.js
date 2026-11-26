/* 小熊读诗：课本古诗按年级排好；诗库按朝代、体裁、选集、题材、诗人查找；每首诗可以请小熊“讲一讲”。
   数据来自 /v1/poems/*（公开只读），讲解来自 POST /v1/poems/explain（同源页面的会话或设备凭证）。
   讲过的诗服务端会存下来，下次打开直接带着讲解和拼音。 */
'use strict';

const $ = sel => document.querySelector(sel);
const view = $('#view');
const isHan = c => /^\p{Script=Han}$/u.test(c);
const GRADES = ['一', '二', '三', '四', '五', '六'];

const store = {
  get(key, fallback) { try { const v = localStorage.getItem(`poems.${key}`); return v == null ? fallback : JSON.parse(v); } catch { return fallback; } },
  set(key, value) { try { localStorage.setItem(`poems.${key}`, JSON.stringify(value)); } catch { /* 无痕模式：不记也行 */ } }
};

// 家长可以用 /poems/#token=... 打开一次（跨地址访问时），凭证存到本机后从地址栏去掉。
(function tokenFromHash() {
  const match = /(?:^#|&)token=([^&]+)/.exec(location.hash);
  if (!match) return;
  store.set('token', decodeURIComponent(match[1]));
  history.replaceState(null, '', location.pathname + location.search + '#/');
})();

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

async function api(path, options = {}) {
  const token = store.get('token', '');
  const response = await fetch(path, { ...options, credentials: 'same-origin',
    headers: { ...(options.body ? { 'Content-Type': 'application/json' } : {}), ...(token ? { Authorization: `Bearer ${token}` } : {}) } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok) throw Object.assign(new Error(body.error || 'server'), { status: response.status });
  return body;
}

const status = (text, error = false) => el('div', { class: `status${error ? ' error' : ''}` }, text);
const waiting = text => el('div', { class: 'waiting' }, el('span', { class: 'dots', 'aria-hidden': 'true' }, el('span'), el('span'), el('span')), text);

// ---------- 朗读 ----------
let voice = null;
function pickVoice() {
  const voices = speechSynthesis?.getVoices?.() ?? [];
  voice = voices.find(v => v.lang === 'zh-CN' && /Tingting|婷婷|Xiaoxiao|晓晓/.test(v.name)) ?? voices.find(v => v.lang === 'zh-CN') ?? voices.find(v => v.lang?.startsWith('zh')) ?? null;
}
if ('speechSynthesis' in window) { pickVoice(); speechSynthesis.addEventListener?.('voiceschanged', pickVoice); }
let speakRun = 0;
function stopSpeaking() {
  speakRun++;
  if ('speechSynthesis' in window) speechSynthesis.cancel();
  if (player) { player.audio.pause(); player.done(); player = null; }
  document.querySelectorAll('.line.reading').forEach(n => n.classList.remove('reading'));
}

// 云端语音读诗：一段（题目、每一句）一个 mp3，服务端合成一次就存下来。边放这一段边取下一段。
let player = null;
// 一小段静音：在点击里先放它，iPad 的 Safari 才允许之后（等网络回来再）放声音。
const silence = (() => {
  const header = new DataView(new ArrayBuffer(44)); const text = (o, t) => [...t].forEach((c, i) => header.setUint8(o + i, c.charCodeAt(0)));
  const samples = 800;
  text(0, 'RIFF'); header.setUint32(4, 36 + samples * 2, true); text(8, 'WAVEfmt '); header.setUint32(16, 16, true);
  header.setUint16(20, 1, true); header.setUint16(22, 1, true); header.setUint32(24, 8000, true); header.setUint32(28, 16000, true);
  header.setUint16(32, 2, true); header.setUint16(34, 16, true); text(36, 'data'); header.setUint32(40, samples * 2, true);
  return URL.createObjectURL(new Blob([header, new Uint8Array(samples * 2)], { type: 'audio/wav' }));
})();
async function fetchAudio(id, part) {
  const token = store.get('token', '');
  const response = await fetch(`/v1/poems/audio?id=${encodeURIComponent(id)}&part=${part}`, { credentials: 'same-origin',
    headers: token ? { Authorization: `Bearer ${token}` } : {} });
  if (!response.ok) throw Object.assign(new Error('audio'), { status: response.status });
  return URL.createObjectURL(await response.blob());
}
/**
 * 用云端语音读一首诗，读到第 i 段时调用 onPart(i)，读的过程中调用 onProgress(i, 0–1)（配图按它在一行中间换图）。
 * 第一段就取不到时返回 false（调用方改用系统语音）；中途被打断或出错就停下。必须在点击里同步调用（见 silence）。
 */
async function playPoem(poem, onPart, onProgress = () => {}) {
  stopSpeaking();
  const run = speakRun;
  const audio = new Audio(silence);
  audio.play().catch(() => {});
  const count = poem.lines.length + 1;
  let next = fetchAudio(poem.id, 0);
  for (let i = 0; i < count; i++) {
    let url;
    try { url = await next; } catch { return i > 0; }
    if (run !== speakRun) { URL.revokeObjectURL(url); return true; }
    next = i + 1 < count ? fetchAudio(poem.id, i + 1) : null;
    next?.catch(() => {});
    onPart(i);
    const ok = await new Promise(resolve => {
      player = { audio, done: () => resolve(false) };
      audio.ontimeupdate = () => { if (audio.duration > 0) onProgress(i, audio.currentTime / audio.duration); };
      audio.onended = () => resolve(true);
      audio.onerror = () => resolve(false);
      audio.src = url;
      audio.play().catch(() => resolve(false));
    });
    URL.revokeObjectURL(url);
    if (!ok || run !== speakRun) return true;
  }
  player = null;
  audio.ontimeupdate = null;
  onPart(-1);
  return true;
}
/** 依次读出 parts，每段开始时调用 onPart(i)。被新的朗读打断就停。 */
function speakParts(parts, { rate = 0.85, onPart = () => {} } = {}) {
  if (!('speechSynthesis' in window)) return Promise.resolve();
  stopSpeaking();
  const run = speakRun;
  return parts.reduce((chain, text, i) => chain.then(() => new Promise(resolve => {
    if (run !== speakRun) return resolve();
    onPart(i);
    const u = new SpeechSynthesisUtterance(text);
    u.lang = 'zh-CN'; u.rate = rate; if (voice) u.voice = voice;
    u.onend = u.onerror = () => setTimeout(resolve, 250);
    speechSynthesis.speak(u);
  })), Promise.resolve()).then(() => { if (run === speakRun) onPart(-1); });
}
const sayButton = (text, label = '读一读') => el('button', { class: 'say', type: 'button', 'aria-label': label, onclick: () => speakParts([text], { rate: 0.95 }) }, '🔊');

// ---------- 路由 ----------
let home = null;   // /v1/poems/home 的结果
function route() {
  stopSpeaking();
  const hash = location.hash.replace(/^#/, '') || '/';
  const [path, query = ''] = hash.split('?');
  const params = new URLSearchParams(query);
  const parts = path.split('/').filter(Boolean).map(decodeURIComponent);
  document.querySelectorAll('#tabs a').forEach(a => a.classList.toggle('on',
    a.dataset.tab === (parts[0] === 'library' || parts[0] === 'authors' || parts[0] === 'author' ? 'library' : parts[0] === 'poem' ? '' : 'school')));
  if (parts[0] === 'poem' && parts[1]) return showPoem(parts[1]);
  if (parts[0] === 'library') return showLibrary(params);
  if (parts[0] === 'authors') return showAuthors(params);
  if (parts[0] === 'author' && parts[1]) return showAuthor(parts[1], params.get('d') || '');
  if (params.has('level')) return showLevel(Number(params.get('level')) || store.get('level', 1));
  return showSchool(Number(params.get('grade')) || store.get('grade', 2));
}
window.addEventListener('hashchange', () => { route(); window.scrollTo(0, 0); });
const go = hash => { location.hash = hash; };

async function loadHome() {
  if (!home) home = await api('/v1/poems/home');
  return home;
}

// ---------- 课本古诗 ----------
async function showSchool(grade) {
  view.replaceChildren(waiting('正在打开……'));
  let data;
  try { data = await loadHome(); } catch { return view.replaceChildren(status('打不开诗词服务，请稍后再试。', true)); }
  store.set('grade', grade);
  const books = data.school.filter(b => b.grade === grade);
  view.replaceChildren(schoolBar(data, grade), ...(books.length ? books.map(b => el('section', { class: 'card term' },
    el('h2', {}, `${GRADES[b.grade - 1]}年级${b.term}册`, el('small', {}, `${b.poems.length} 首`)),
    el('ul', { class: 'list' }, b.poems.map(p => el('li', {}, poemItem(p)))))) : [status(data.school.length ? '这个年级还没有整理好的古诗。' : '课本古诗还没有整理好。')]));
}

/** 一到六年级，再加上“考级”（学校的古诗考级清单，有的时候才显示）。 */
function schoolBar(data, grade, level = 0) {
  const chip = (on, href, text) => el('a', { class: `chip${on ? ' on' : ''}`, href, role: 'tab', 'aria-selected': String(on) }, text);
  return el('div', { class: 'grades', role: 'tablist' },
    ...GRADES.map((g, i) => chip(!level && i + 1 === grade, `#/?grade=${i + 1}`, `${g}年级`)),
    ...(data.levels?.length ? [chip(!!level, `#/?level=${store.get('level', 1)}`, '考级')] : []));
}

// ---------- 古诗考级 ----------
async function showLevel(level) {
  view.replaceChildren(waiting('正在打开……'));
  let data;
  try { data = await loadHome(); } catch { return view.replaceChildren(status('打不开诗词服务，请稍后再试。', true)); }
  const levels = data.levels ?? [];
  if (!levels.some(l => l.level === level)) level = levels[0]?.level ?? 1;
  store.set('level', level);
  const current = levels.find(l => l.level === level);
  const tabs = el('div', { class: 'chips', role: 'tablist' }, levels.map(l =>
    el('a', { class: `chip${l.level === level ? ' on' : ''}`, href: `#/?level=${l.level}`, role: 'tab', 'aria-selected': String(l.level === level) }, `${GRADES[l.level - 1]}级`)));
  view.replaceChildren(schoolBar(data, 0, level), ...(current ? [el('section', { class: 'card term' },
    el('h2', {}, `古诗考级 · ${GRADES[level - 1]}级`, el('small', {}, `${current.poems.length} 首`)),
    tabs,
    el('p', { class: 'muted level-tip' }, '学校发的古诗考级清单（2026.08 版）。标着年级的是课本里也有的。'),
    el('ul', { class: 'list' }, current.poems.map(p => el('li', {}, poemItem(p, { showGrade: true })))))] : [status('古诗考级清单还没有整理好。')]));
}

function poemItem(p, { showGrade = false, showLevel = false } = {}) {
  const badges = [];
  if (p.level && showLevel) badges.push(el('span', { class: 'badge' }, `考级${GRADES[p.level - 1]}级`));
  if (p.school?.kind && p.school.kind !== '课文') badges.push(el('span', { class: 'badge' }, p.school.kind));
  if (p.school && showGrade) badges.push(el('span', { class: 'badge' }, `${GRADES[p.school.grade - 1]}年级${p.school.term}`));
  for (const b of p.books ?? []) if (b !== '水墨唐诗') badges.push(el('span', { class: 'badge done' }, b));
  return el('a', { class: 'item', href: `#/poem/${encodeURIComponent(p.id)}` },
    el('span', { class: 'item-title' }, p.title, ...badges),
    el('span', { class: 'item-meta' }, [p.dynasty && `〔${p.dynasty}〕`, p.author, p.form && ` · ${p.form}`].filter(Boolean).join('')),
    el('span', { class: 'item-first' }, p.first));
}

// ---------- 诗库 ----------
function libraryHash(params) {
  const clean = new URLSearchParams([...params].filter(([k, v]) => v && k !== 'offset'));
  const text = clean.toString();
  return `#/library${text ? `?${text}` : ''}`;
}

async function showLibrary(params) {
  view.replaceChildren(waiting('正在打开诗库……'));
  let data;
  try { data = await loadHome(); } catch { return view.replaceChildren(status('打不开诗词服务，请稍后再试。', true)); }
  const lib = data.library;
  const input = el('input', { type: 'search', enterkeyhint: 'search', placeholder: '诗名、诗句或诗人，比如：明月', 'aria-label': '找诗', value: params.get('q') || '' });
  const form = el('form', { class: 'search', autocomplete: 'off', onsubmit: event => {
    event.preventDefault(); input.blur();
    const next = new URLSearchParams(params); next.set('q', input.value.trim()); go(libraryHash(next));
  } }, input, el('button', { class: 'go', type: 'submit' }, '找'));

  const filterRow = (label, key, values, { limit = Infinity } = {}) => {
    if (!values?.length) return null;
    const current = params.get(key) || '';
    const link = (value, text) => {
      const next = new URLSearchParams(params);
      if (value) next.set(key, value); else next.delete(key);
      return el('a', { class: `chip${current === value ? ' on' : ''}`, href: libraryHash(next) }, text);
    };
    const shown = values.length > limit && !values.slice(0, limit).includes(current) && current ? [...values.slice(0, limit), current] : values.slice(0, limit);
    const row = el('div', { class: 'chips' }, el('span', { class: 'chips-label' }, label), link('', '全部'), shown.map(v => link(v, v)));
    if (values.length > shown.length) {
      row.append(el('button', { class: 'chip more', type: 'button', onclick: event => {
        event.currentTarget.replaceWith(...values.filter(v => !shown.includes(v)).map(v => link(v, v)));
      } }, '更多…'));
    }
    return row;
  };

  const top = el('section', { class: 'card filters' }, form);
  if (lib) {
    top.append(
      filterRow('朝代', 'dynasty', lib.dynasties),
      filterRow('体裁', 'form', lib.forms),
      filterRow('选集', 'book', lib.books),
      filterRow('题材', 'tag', lib.tags, { limit: 12 }),
      el('div', { class: 'chips' }, el('span', { class: 'chips-label' }, '诗人'),
        params.get('author') ? el('a', { class: 'chip on', href: libraryHash(new URLSearchParams([...params].filter(([k]) => k !== 'author'))) }, `${params.get('author')} ✕`) : null,
        el('a', { class: 'chip', href: `#/authors${params.get('dynasty') ? `?dynasty=${encodeURIComponent(params.get('dynasty'))}` : ''}` }, '按诗人找 →')));
  }
  const results = el('div', { class: 'filters' });
  view.replaceChildren(top, results);
  if (!lib) results.append(status('诗库还没有导入，现在只有课本古诗。'));
  await loadResults(params, results, 0);
}

async function loadResults(params, box, offset) {
  const q = new URLSearchParams(params); if (offset) q.set('offset', offset);
  const loading = waiting('正在找……');
  box.append(loading);
  let found;
  try { found = await api(`/v1/poems/search?${q}`); } catch { loading.replaceWith(status('没找到，可能是网络不好，再试一次吧。', true)); return; }
  loading.remove();
  if (!offset && found.school.length) {
    box.append(el('p', { class: 'section-label' }, found.school.some(p => p.level) ? '课本和考级里的' : '课本里的'),
      el('ul', { class: 'list' }, found.school.map(p => el('li', {}, poemItem(p, { showGrade: true, showLevel: true })))));
  }
  if (!offset && found.school.length && found.poems.length) box.append(el('p', { class: 'section-label' }, '诗库里的'));
  if (found.poems.length) box.append(el('ul', { class: 'list' }, found.poems.map(p => el('li', {}, poemItem(p)))));
  if (!offset && !found.school.length && !found.poems.length) box.append(status('没有找到这样的诗，换个词试试。'));
  if (found.more) {
    const more = el('button', { class: 'load-more', type: 'button', onclick: () => { more.remove(); loadResults(params, box, offset + found.poems.length); } }, '再看 30 首');
    box.append(more);
  }
}

async function showAuthors(params) {
  const dynasty = params.get('dynasty') || '';
  view.replaceChildren(waiting('正在打开……'));
  let data;
  try { data = await loadHome(); } catch { return view.replaceChildren(status('打不开诗词服务，请稍后再试。', true)); }
  const dynasties = data.library?.dynasties ?? [];
  const input = el('input', { type: 'search', enterkeyhint: 'search', placeholder: '诗人的名字', 'aria-label': '找诗人', value: params.get('q') || '' });
  const list = el('div', { class: 'authors' });
  const card = el('section', { class: 'card filters' },
    el('button', { class: 'back', type: 'button', onclick: () => history.back() }, '‹ 返回'),
    el('form', { class: 'search', autocomplete: 'off', onsubmit: event => {
      event.preventDefault(); const next = new URLSearchParams(params); next.set('q', input.value.trim()); go(`#/authors?${next}`);
    } }, input, el('button', { class: 'go', type: 'submit' }, '找')),
    el('div', { class: 'chips' }, el('span', { class: 'chips-label' }, '朝代'),
      ['', ...dynasties].map(d => el('a', { class: `chip${d === dynasty ? ' on' : ''}`, href: `#/authors${d ? `?dynasty=${encodeURIComponent(d)}` : ''}` }, d || '全部'))),
    list);
  view.replaceChildren(card);
  const load = async offset => {
    const q = new URLSearchParams(params); if (offset) q.set('offset', offset);
    let found;
    try { found = await api(`/v1/poems/authors?${q}`); } catch { list.append(status('打不开诗人列表。', true)); return; }
    list.append(...found.authors.map(a => el('a', { href: `#/author/${encodeURIComponent(a.name)}?d=${encodeURIComponent(a.dynasty)}` },
      a.name, el('small', {}, `${a.dynasty} · ${a.poems}首`))));
    if (!offset && !found.authors.length) list.append(status('没有找到这位诗人。'));
    if (found.more) {
      const more = el('button', { class: 'load-more', type: 'button', onclick: () => { more.remove(); load(offset + found.authors.length); } }, '更多诗人');
      list.append(more);
    }
  };
  await load(0);
}

async function showAuthor(name, dynasty) {
  view.replaceChildren(waiting('正在打开……'));
  const info = await api(`/v1/poems/author?${new URLSearchParams({ name, dynasty })}`).catch(() => null);
  const results = el('div', { class: 'filters' });
  view.replaceChildren(
    el('button', { class: 'back', type: 'button', onclick: () => history.back() }, '‹ 返回'),
    el('section', { class: 'card' },
      el('h2', {}, `${name}${dynasty ? `〔${dynasty}〕` : ''}`, info ? el('small', { class: 'muted' }, ` · 诗库里有 ${info.poems} 首`) : null),
      info?.intro ? el('details', { class: 'intro' }, el('summary', {}, '古书里的介绍（文言，给家长看）'), el('p', {}, info.intro)) : null),
    results);
  await loadResults(new URLSearchParams({ author: name, ...(dynasty ? { dynasty } : {}) }), results, 0);
}

// ---------- 一首诗 ----------
// rows：每一行的拼音（来自讲解，或单独标的），没有时是 null。
const poemState = { poem: null, explanation: null, rows: null, pinyin: store.get('pinyin', true) };

async function showPoem(id) {
  view.replaceChildren(waiting('正在打开……'));
  let poem;
  try { poem = await api(`/v1/poems/poem/${encodeURIComponent(id)}`); } catch (error) {
    return view.replaceChildren(status(error.status === 404 ? '没有这首诗。' : '打不开这首诗，请稍后再试。', true));
  }
  poemState.poem = poem; poemState.explanation = poem.explanation; poemState.rows = poem.pinyin ?? null;
  const linesBox = el('div', { class: 'poem-lines', lang: 'zh-CN' });
  const gallery = poem.art?.length ? makeGallery(poem) : null;
  const pickedBar = el('div', { class: 'picked-bar', hidden: true });
  const pinyinButton = el('button', { class: 'btn', type: 'button', 'aria-pressed': String(poemState.pinyin), onclick: () => {
    poemState.pinyin = !poemState.pinyin; store.set('pinyin', poemState.pinyin);
    pinyinButton.setAttribute('aria-pressed', String(poemState.pinyin)); renderLines(linesBox);
    if (poemState.pinyin) loadPinyin(linesBox, pinyinButton);
  } }, '拼音');
  const readButton = el('button', { class: 'btn', type: 'button', onclick: async () => {
    const highlight = i => {
      linesBox.querySelectorAll('.line').forEach((n, k) => n.classList.toggle('reading', k === i - 1));
      if (i >= 0) gallery?.follow(i - 1, 0);
    };
    const parts = [`${poem.title}，${poem.dynasty ? poem.dynasty + '，' : ''}${poem.author}`, ...poem.lines];
    if (!poem.speakable) return speakParts(parts, { onPart: highlight });
    readButton.textContent = '🔊 准备中…';
    const played = await playPoem(poem, i => { readButton.textContent = '🔊 读诗'; highlight(i); },
      (i, progress) => { if (i > 0) gallery?.follow(i - 1, progress); });
    readButton.textContent = '🔊 读诗';
    if (!played) speakParts(parts, { onPart: highlight });
  } }, '🔊 读诗');
  const explainBox = el('div', { class: 'explain' });
  const explainButton = el('button', { class: 'btn primary', type: 'button', onclick: () => loadExplanation(explainBox, explainButton, linesBox) }, '🐻 小熊讲一讲');

  const notes = [];
  if (poem.textbookId) {
    const exam = poem.textbookId.startsWith('k');
    notes.push(el('p', { class: 'note' }, `诗库里的字句来自古籍，和${exam ? '考级清单' : '课本'}可能不同。`,
      el('a', { href: `#/poem/${poem.textbookId}` }, exam ? '看考级版 →' : '看课本版 →')));
  }
  if (poem.level) notes.push(el('p', { class: 'note' }, el('a', { href: `#/?level=${poem.level}` }, `古诗考级 · ${GRADES[poem.level - 1]}级`),
    poem.note ? ` · ${poem.note}` : ''));
  if (poem.school) notes.push(el('p', { class: 'note' }, `${GRADES[poem.school.grade - 1]}年级${poem.school.term}册${poem.school.kind === '课文' ? '' : ` · ${poem.school.kind}`}`));

  view.replaceChildren(
    el('button', { class: 'back', type: 'button', onclick: () => history.length > 1 ? history.back() : go('#/') }, '‹ 返回'),
    el('article', { class: `card poem${gallery ? ' with-art' : ''}` },
      gallery?.node,
      el('div', { class: 'poem-text' },
      el('h1', { class: 'poem-title' }, poem.title),
      el('p', { class: 'poem-meta' }, poem.dynasty ? `〔${poem.dynasty}〕` : '',
        el('a', { href: `#/author/${encodeURIComponent(poem.author)}?d=${encodeURIComponent(poem.dynasty || '')}` }, poem.author),
        poem.form ? ` · ${poem.form}` : ''),
      linesBox, pickedBar,
      el('div', { class: 'poem-tools' }, readButton, pinyinButton, poem.explainable && !poem.explanation ? explainButton : null),
      !poem.explainable ? el('p', { class: 'note' }, '这首诗太长了，小熊暂时还讲不了。') : null,
      notes)),
    explainBox);
  renderLines(linesBox);
  if (poemState.pinyin) loadPinyin(linesBox, pinyinButton);
  linesBox.addEventListener('click', event => {
    pickChar(event, linesBox, pickedBar);
    // 点到哪个字，就翻到画那一句的图。
    const node = event.target.closest('.ch');
    if (node && gallery) gallery.show(gallery.sceneAt(Number(node.dataset.line), Number(node.dataset.at)));
  });
  if (poem.explanation) renderExplanation(explainBox, poem.explanation, linesBox);
}

/**
 * 课本诗的配图：一张一屏，左右滑动，下面的小圆点也能点。每张图从 art[n].line 行的 art[n].at 处开始（服务端按句算好），
 * 点字、读诗时 follow/show 翻到对应的那张。
 */
function makeGallery(poem) {
  const art = poem.art;
  const smooth = () => matchMedia('(prefers-reduced-motion: reduce)').matches ? 'auto' : 'smooth';
  const track = el('div', { class: 'art-track' }, art.map((a, n) =>
    el('img', { src: a.src, alt: `第 ${n + 1} 幅画：${a.caption}`, width: 800, height: 600, decoding: 'async', draggable: 'false' })));
  const dots = art.length > 1 ? el('div', { class: 'art-dots' }, art.map((a, n) =>
    el('button', { type: 'button', 'aria-label': `第 ${n + 1} 幅：${a.caption}`, onclick: () => show(n) }))) : null;
  let current = -1, followed = -1;
  // 程序翻页的平滑滚动途中，滚动位置还在半路，不按它改圆点（否则会闪一下）；到了或过一会儿再跟着手指走。
  let target = null, targetTimer = 0;
  const mark = n => {
    if (n === current) return;
    current = n;
    dots?.querySelectorAll('button').forEach((b, k) => b.setAttribute('aria-current', String(k === n)));
  };
  function show(n) {
    if (n < 0 || n >= art.length) return;
    target = n; clearTimeout(targetTimer); targetTimer = setTimeout(() => { target = null; }, 1000);
    track.scrollTo({ left: n * track.clientWidth, behavior: smooth() });
    mark(n);
  }
  /** 第 line 行、at 处（0–1）对应的是哪张图：开始位置不晚于它的最后一张。 */
  function sceneAt(line, at) {
    let found = 0;
    art.forEach((a, n) => { if (a.line < line || (a.line === line && a.at <= at + 1e-6)) found = n; });
    return found;
  }
  // 读诗时只在该换图的时候翻，孩子自己滑走了也不会每一下都被拉回来。
  function follow(line, at) {
    const n = line < 0 ? 0 : sceneAt(line, at);
    if (n !== followed) { followed = n; show(n); }
  }
  track.addEventListener('scroll', () => {
    if (!track.clientWidth) return;
    const at = track.scrollLeft / track.clientWidth;
    if (target !== null) { if (Math.abs(at - target) > .02) return; target = null; }
    mark(Math.round(at));
  }, { passive: true });
  mark(0);
  const node = el('figure', { class: 'art', 'aria-label': `《${poem.title}》的配图，共 ${art.length} 幅` }, track, dots);
  return { node, show, follow, sceneAt };
}

/** 没讲过的诗打开时还没有拼音：单独请小熊标一下（几秒），标好的服务端会存下来。 */
async function loadPinyin(linesBox, button) {
  const { poem } = poemState;
  if (poemState.rows || !poem.pinyinable || poemState.loadingPinyin === poem.id) return;
  poemState.loadingPinyin = poem.id;
  button.textContent = '拼音…'; button.setAttribute('aria-busy', 'true');
  try {
    const { pinyin } = await api('/v1/poems/pinyin', { method: 'POST', body: JSON.stringify({ id: poem.id }) });
    if (poemState.poem === poem && !poemState.rows) { poemState.rows = pinyin; renderLines(linesBox); }
  } catch { /* 标不了就不显示拼音 */ } finally {
    if (poemState.loadingPinyin === poem.id) poemState.loadingPinyin = null;
    button.textContent = '拼音'; button.removeAttribute('aria-busy');
  }
}

/** 诗句：每个汉字一个可以点的 span，有拼音时套上 ruby。 */
function renderLines(box) {
  const { poem } = poemState;
  const pinyin = poemState.rows;
  box.classList.toggle('with-pinyin', poemState.pinyin && !!pinyin);
  box.replaceChildren(...poem.lines.map((line, i) => {
    const syllables = pinyin?.[i] ?? null;
    let k = 0, pos = 0;
    // 一句一个不断行的块：屏幕窄时只在逗号、句号后面换行，不会把“入海流”拆开。
    const clauses = line.match(/[^，。？！；、]+[，。？！；、]*/g) ?? [line];
    return el('div', { class: 'line' }, clauses.map(clause => el('span', { class: 'clause' }, [...clause].map(c => {
      const at = pos / line.length;
      pos += c.length;
      if (!isHan(c)) return c;
      const py = syllables?.[k++];
      const node = el('span', { class: 'ch', 'data-ch': c, 'data-line': i, 'data-at': at.toFixed(3) }, c);
      return py ? el('ruby', {}, node, el('rt', {}, py)) : node;
    }))));
  }));
}

function pickChar(event, box, bar) {
  const node = event.target.closest('.ch');
  box.querySelectorAll('.ch.picked').forEach(n => n.classList.remove('picked'));
  if (!node) { bar.hidden = true; return; }
  node.classList.add('picked');
  const c = node.dataset.ch;
  bar.replaceChildren(el('a', { href: `/hanzi/#q=${encodeURIComponent(c)}` }, `✍︎ 学写「${c}」`));
  bar.hidden = false;
}

async function loadExplanation(box, button, linesBox) {
  button.disabled = true;
  box.replaceChildren(el('section', { class: 'card' }, waiting('小熊正在读这首诗，想想怎么讲……（第一次要等半分钟左右）')));
  try {
    const explanation = await api('/v1/poems/explain', { method: 'POST', body: JSON.stringify({ id: poemState.poem.id }) });
    poemState.explanation = explanation;
    if (explanation.pinyin?.some(Boolean)) poemState.rows = explanation.pinyin;
    button.remove();
    renderLines(linesBox);
    renderExplanation(box, explanation, linesBox);
  } catch (error) {
    button.disabled = false;
    const text = { unauthorized: '还没连上小熊（请从服务端地址打开这个页面）。', model_not_configured: '服务端还没有配置模型，暂时讲不了。',
      rate_limited: '问的人有点多，过一会儿再试吧。', poem_too_long: '这首诗太长了，小熊暂时还讲不了。' }[error.message] ?? '小熊这次没讲好，再点一次试试。';
    box.replaceChildren(el('section', { class: 'card' }, status(text, true)));
  }
}

function renderExplanation(box, ex, linesBox) {
  const { poem } = poemState;
  const section = (cls, icon, title, speakText, ...content) => el('section', { class: `card ex ${cls}` },
    el('h2', {}, `${icon} ${title}`, speakText ? sayButton(speakText) : null), ...content);
  const highlight = word => {
    linesBox.querySelectorAll('.ch.mark').forEach(n => n.classList.remove('mark'));
    if (!word) return;
    for (const line of linesBox.querySelectorAll('.line')) {
      const chars = [...line.querySelectorAll('.ch')];
      const text = chars.map(n => n.dataset.ch).join('');
      for (let at = text.indexOf(word); at >= 0; at = text.indexOf(word, at + 1)) {
        for (let k = at; k < at + [...word].length; k++) chars[k]?.classList.add('mark');
      }
    }
  };
  const words = ex.words?.length ? el('div', { class: 'words' }, ex.words.map(w => el('button', { class: 'word', type: 'button', onclick: event => {
    const on = !event.currentTarget.classList.contains('on');
    box.querySelectorAll('.word.on').forEach(n => n.classList.remove('on'));
    event.currentTarget.classList.toggle('on', on);
    highlight(on ? w.word : '');
    if (on) linesBox.scrollIntoView({ behavior: 'smooth', block: 'center' });
  } }, el('b', {}, w.word, w.pinyin ? el('small', {}, w.pinyin) : null), el('span', {}, w.meaning)))) : null;

  box.replaceChildren(
    section('scene', '🎨', '诗里的画面', ex.scene, el('p', {}, ex.scene),
      // 有配图的课本诗，画在诗的上面；其他诗先留个位置。
      poemState.poem?.art?.length ? null : el('div', { class: 'picture', 'aria-hidden': 'true' }, '这里以后会有一幅画')),
    section('', '📖', '一句一句读懂', ex.lines.join(''),
      el('ol', { class: 'meanings' }, poem.lines.map((line, i) => el('li', {}, el('span', { class: 'orig' }, line), el('span', { class: 'mean' }, ex.lines[i]))))),
    words ? section('', '🔍', '难懂的字词', '', words) : null,
    ex.feeling ? section('', '💭', '诗人想告诉我们', ex.feeling, el('p', {}, ex.feeling)) : null,
    ex.story ? section('', '📜', '写诗的小故事', ex.story, el('p', {}, ex.story)) : null,
    ex.poet ? section('', '👤', `认识${poem.author}`, ex.poet, el('p', {}, ex.poet),
      el('p', { class: 'note' }, el('a', { href: `#/author/${encodeURIComponent(poem.author)}?d=${encodeURIComponent(poem.dynasty || '')}` }, `看看${poem.author}的其他诗 →`))) : null);
}

route();
