import { TeacherSession } from './session.mjs';
import { Whiteboard } from './board.mjs';

// 小熊老师 web page: connect this browser as a device (pairing code, or the parent secret), pick the child,
// then one tap starts the conversation. The conversation itself lives in session.mjs; this file is the UI.

const $ = id => document.getElementById(id);
const store = {
  get(key) { try { return localStorage.getItem(`teacher.${key}`); } catch { return null; } },
  set(key, value) { try { value == null ? localStorage.removeItem(`teacher.${key}`) : localStorage.setItem(`teacher.${key}`, value); } catch { /* private mode */ } }
};

// ---------- API ----------

const messages = {
  invalid_code: '配对码不对或已经过期，请家长重新生成。',
  unauthorized: '密钥不对。',
  rate_limited: '试得太多了，等一分钟再试。',
  api_not_configured: '服务器还没有设置家长密钥。',
  invalid_input: '填写的内容不符合要求。'
};
class ApiError extends Error { constructor(status, code) { super(code); this.status = status; this.code = code; } }

async function api(method, path, { token, body } = {}) {
  let response;
  try {
    response = await fetch(path, { method, headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}),
      ...(body ? { 'Content-Type': 'application/json' } : {}) }, body: body ? JSON.stringify(body) : undefined });
  } catch { throw new ApiError(0, 'network'); }
  const value = await response.json().catch(() => ({}));
  if (!response.ok) throw new ApiError(response.status, value.error ?? '');
  return value;
}
const describe = error => (error instanceof ApiError && messages[error.code]) || (error?.code === 'network' ? '连不上服务器，请检查网络。' : '出了点问题，请再试一次。');

/** crypto.randomUUID needs HTTPS; this also works on a plain-HTTP home network address. */
function uuid() {
  if (crypto.randomUUID) return crypto.randomUUID();
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const hex = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

// ---------- setup: device, child ----------

let token = store.get('token'), role = '', children = [], child = null;
const steps = ['loading', 'pair', 'add-child', 'pick', 'start'];

function show(step, error = '') {
  for (const name of steps) $(`step-${name}`).hidden = name !== step;
  $('sheet-error').hidden = !error;
  $('sheet-error').textContent = error;
  $('overlay').hidden = false;
  $(`step-${step}`).querySelector('input, button')?.focus({ preventScroll: true });
}

async function boot() {
  if (!token) return show('pair');
  show('loading');
  let me;
  try { me = await api('GET', '/v1/me', { token }); }
  catch (error) {
    if (error.status === 401) { store.set('token', null); token = null; return show('pair', '这台设备的连接已失效，请重新连接。'); }
    return show('pair', describe(error));
  }
  role = me.device.role; children = me.children;
  if (!children.length) return role === 'parent' ? show('add-child') : show('pair', '家里还没有添加孩子，请家长先在家长端添加。');
  const remembered = children.find(c => c.id === store.get('child'));
  if (remembered || children.length === 1) return choose(remembered ?? children[0]);
  pick();
}

function pick() {
  $('children').replaceChildren(...children.map(c => {
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'secondary';
    const avatar = document.createElement('span'); avatar.className = 'avatar'; avatar.textContent = [...c.name][0] ?? '';
    button.append(avatar, `${c.name} · ${c.grade} 年级`);
    button.addEventListener('click', () => choose(c));
    return button;
  }));
  show('pick');
}

function choose(selected) {
  child = selected;
  store.set('child', child.id);
  $('who').textContent = `和${child.name}一起学`;
  $('avatar').textContent = [...child.name][0] ?? '';
  $('start-title').textContent = `${child.name}，我们开始吧`;
  show('start');
}

async function connect(form, request) {
  const button = form.querySelector('button');
  button.disabled = true;
  try {
    const grant = await request();
    token = grant.deviceToken;
    store.set('token', token);
    form.reset();
    await boot();
  } catch (error) { show('pair', describe(error)); }
  finally { button.disabled = false; }
}
const deviceName = () => `网页 · ${/iPad|Macintosh/.test(navigator.userAgent) && navigator.maxTouchPoints > 1 ? 'iPad' : /iPhone/.test(navigator.userAgent) ? 'iPhone' : '浏览器'}`;

$('pair-form').addEventListener('submit', event => {
  event.preventDefault();
  const code = $('pair-code').value.trim();
  if (!/^\d{6}$/.test(code)) return show('pair', '配对码是 6 位数字。');
  connect(event.target, () => api('POST', '/v1/devices/pair', { body: { code, deviceId: uuid(), name: deviceName() } }));
});
$('secret-form').addEventListener('submit', event => {
  event.preventDefault();
  connect(event.target, () => api('POST', '/v1/devices/bootstrap', { body: { token: $('secret').value.trim(), deviceId: uuid(), name: deviceName() } }));
});
$('child-form').addEventListener('submit', async event => {
  event.preventDefault();
  try {
    await api('PUT', `/v1/children/${uuid()}`, { token, body: { name: $('child-name').value.trim(), grade: Number($('child-grade').value) } });
    await boot();
  } catch (error) { show('add-child', describe(error)); }
});

// ---------- conversation ----------

const session = new TeacherSession();
const board = new Whiteboard($('board'), $('board-content'));
let typing = false, wakeLock = null;

const statusText = state => ({
  idle: '', connecting: '正在叫小熊老师…',
  listening: state.muted ? '麦克风关着，可以打字' : state.voiceInput ? '我在听，说吧' : '打字和小熊说话吧',
  hearing: '听着呢…', thinking: '让我想一想…', speaking: '点我可以打断', ended: '下次见', failed: state.failure
}[state.phase] ?? '');

function render(state) {
  $('orb').dataset.phase = state.phase;
  $('status').textContent = statusText(state);
  $('status').dataset.tone = state.phase;
  $('your-turn').hidden = !(state.awaiting && state.phase === 'listening');
  $('caption').hidden = !state.caption;
  if ($('caption').textContent !== state.caption) $('caption').textContent = state.caption;
  $('heard').hidden = !state.heard;
  $('heard-text').textContent = state.heard;
  $('notice').hidden = !state.notice;
  $('notice').textContent = state.notice;
  $('retry').hidden = state.phase !== 'failed';
  $('mute').hidden = !state.voiceInput;
  $('mute').setAttribute('aria-pressed', String(state.muted));
  $('mute').setAttribute('aria-label', state.muted ? '打开麦克风' : '关闭麦克风');
  const ready = session.canTalk;
  for (const button of document.querySelectorAll('.suggestion')) button.disabled = !ready;
  $('input-bar').querySelector('button').disabled = !ready;
}
session.onChange = render;
session.onBoard = ops => board.apply(ops);
session.onLevel = level => $('orb').style.setProperty('--level', level.toFixed(2));

async function keepAwake() {
  try { wakeLock = await navigator.wakeLock?.request('screen'); } catch { /* not allowed right now */ }
}
document.addEventListener('visibilitychange', () => {
  if (document.visibilityState === 'visible' && session.canTalk && wakeLock?.released !== false) keepAwake();
});

function start() {
  if (!token || !child) return boot();
  board.clear();
  $('overlay').hidden = true;
  session.start({ token, childId: child.id }); // inside the tap: unlocks sound
  keepAwake();
}
$('start').addEventListener('click', start);
$('retry').addEventListener('click', start);
$('orb').addEventListener('click', () => session.interrupt());
$('mute').addEventListener('click', () => session.setMuted(!session.state.muted));
$('suggestions').addEventListener('click', event => {
  const button = event.target.closest('.suggestion');
  if (button) session.say(button.textContent);
});

$('keyboard').addEventListener('click', () => {
  typing = !typing;
  $('input-bar').hidden = !typing;
  $('keyboard').setAttribute('aria-pressed', String(typing));
  if (typing) $('draft').focus();
});
$('input-bar').addEventListener('submit', event => {
  event.preventDefault();
  if (session.say($('draft').value)) $('draft').value = ''; // keep the text when the connection is down
});

// ---------- parent settings ----------

$('settings').addEventListener('click', () => {
  $('settings-info').textContent = child ? `这台设备已连接，当前是${child.name}（${child.grade} 年级）。` : '这台设备还没有连接。';
  $('switch-child').hidden = children.length < 2;
  $('settings-dialog').showModal();
});
$('close-settings').addEventListener('click', () => $('settings-dialog').close());
$('switch-child').addEventListener('click', () => {
  $('settings-dialog').close();
  session.stop();
  board.clear();
  pick();
});
$('disconnect').addEventListener('click', () => {
  session.stop();
  for (const key of ['token', 'child']) store.set(key, null);
  location.reload();
});

// The on-screen keyboard covers the bottom of the page on iPad; keep the whole app in the part that is visible.
const viewport = window.visualViewport;
if (viewport) {
  const fit = () => {
    if (Math.abs(viewport.scale - 1) > 0.01) return; // pinch-zoomed: leave the page alone
    document.documentElement.style.setProperty('--app-height', `${viewport.height}px`);
    scrollTo(0, 0);
  };
  viewport.addEventListener('resize', fit);
}

addEventListener('pagehide', () => session.stop());
render(session.state);
boot();
