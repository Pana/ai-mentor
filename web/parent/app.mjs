// 小熊伴学 · 家长管理网页: sign in with a phone number, then manage the family (children, parents and invite codes,
// child-device pairing codes, connected devices, the signed-in account). Same API as the parent apps (server/README.md).
// This browser is a parent device of its own: its credential is kept in localStorage and revoked on sign-out.

const $ = selector => document.querySelector(selector);
const storage = {
  get(key) { try { return localStorage.getItem(`parent.${key}`); } catch { return null; } },
  set(key, value) { try { value == null ? localStorage.removeItem(`parent.${key}`) : localStorage.setItem(`parent.${key}`, value); } catch { /* private mode */ } }
};

const messages = {
  invalid_phone: '请填写 11 位手机号。',
  weak_password: '密码至少 8 位。',
  phone_taken: '这个手机号已经注册过了，请直接登录。',
  invalid_login: '手机号或密码不对。',
  wrong_password: '原密码不对。',
  too_many_attempts: '密码错误次数太多，请 15 分钟后再试。',
  rate_limited: '尝试太频繁了，请过一会儿再试。',
  invalid_invite: '邀请码不对、已经用过或已过期，请家人重新生成。',
  already_bound: '已经设置过登录账号了。',
  cannot_remove_self: '不能把自己移出家庭。',
  api_not_configured: '服务器没有配置家长密钥，请用手机号登录。',
  network: '连不上服务器，请检查网络。'
};

class ApiError extends Error {
  constructor(status, code) { super(code); this.status = status; this.code = code; }
  get text() {
    if (messages[this.code]) return messages[this.code];
    if (this.status === 401) return '登录已失效，请重新登录。';
    if (this.status === 403) return '这个账号没有权限做这件事。';
    if (this.status === 404) return '内容已经不存在了，刷新页面再试。';
    if (this.status === 429) return '尝试太频繁了，请过一会儿再试。';
    if (this.status >= 500) return '服务器暂时出错，请稍后再试。';
    return '填写的内容不符合要求，请检查后再试。';
  }
}

let token = storage.get('token');

async function api(method, path, body) {
  let response;
  try {
    response = await fetch(path, { method, cache: 'no-store',
      headers: { ...(token ? { Authorization: `Bearer ${token}` } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}) },
      body: body ? JSON.stringify(body) : undefined });
  } catch { throw new ApiError(0, 'network'); }
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new ApiError(response.status, data.error ?? '');
    // The credential stopped working (signed out elsewhere, removed from the family, password changed): back to sign-in.
    if (response.status === 401 && token && !['invalid_login', 'wrong_password'].includes(error.code)) {
      forget();
      showAuth('登录已失效，请重新登录。');
    }
    throw error;
  }
  return data;
}

// crypto.randomUUID needs a secure context; a LAN http:// address is not one.
function uuid() {
  if (crypto.randomUUID) try { return crypto.randomUUID(); } catch { /* insecure context */ }
  const b = crypto.getRandomValues(new Uint8Array(16));
  b[6] = (b[6] & 0x0f) | 0x40; b[8] = (b[8] & 0x3f) | 0x80;
  const h = [...b].map(x => x.toString(16).padStart(2, '0')).join('');
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}
function deviceName() {
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? 'Edge' : /Firefox\//.test(ua) ? 'Firefox' : /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : '浏览器';
  return `网页（${browser}）`;
}
const digits = value => value.replace(/\D/g, '');
const spaced = code => (code.length === 8 ? `${code.slice(0, 4)} ${code.slice(4)}` : code);

// ---------- notices ----------
let noticeTimer;
function notice(text, kind = 'error') {
  const box = $('#notice');
  box.textContent = text; box.className = `notice ${kind}`; box.hidden = !text;
  clearTimeout(noticeTimer);
  if (text && kind === 'ok') noticeTimer = setTimeout(() => { box.hidden = true; }, 3000);
}
/** Runs an action; its error goes to the page notice. Returns false when it failed. */
async function attempt(action) {
  try { await action(); return true; } catch (error) { if (error instanceof ApiError) notice(error.text); else { console.error(error); notice('出了点问题，请刷新页面再试。'); } return false; }
}

// ---------- sign in ----------
let mode = 'login';
function setMode(next) {
  mode = next;
  for (const tab of document.querySelectorAll('.tabs [role=tab]')) tab.setAttribute('aria-selected', String(tab.dataset.mode === mode));
  const form = $('#auth-form');
  form.querySelector('.register-only').hidden = mode !== 'register';
  for (const name of ['confirm', 'name']) form.elements[name].required = mode === 'register';
  form.elements.password.autocomplete = mode === 'register' ? 'new-password' : 'current-password';
  form.querySelector('button[type=submit]').textContent = mode === 'register' ? '注册' : '登录';
}

function begin(grant) {
  if (grant.role !== 'parent') throw new ApiError(403, '');
  token = grant.deviceToken;
  storage.set('token', token);
  showHome();
}
function forget() { token = null; storage.set('token', null); }

function showAuth(message = '') {
  $('#home').hidden = true; $('#sign-out').hidden = true; $('#auth').hidden = false;
  $('#who').textContent = '家长管理';
  $('#insecure').hidden = location.protocol === 'https:' || ['localhost', '127.0.0.1', '[::1]'].includes(location.hostname);
  notice(message);
}

$('#auth-form').addEventListener('submit', async event => {
  event.preventDefault();
  const form = event.currentTarget, f = form.elements, button = form.querySelector('button[type=submit]');
  const phone = digits(f.phone.value);
  if (phone.length !== 11) return notice(messages.invalid_phone);
  if (mode === 'register') {
    if (f.password.value.length < 8) return notice(messages.weak_password);
    if (f.password.value !== f.confirm.value) return notice('两次输入的密码不一样。');
    const code = digits(f.invite.value);
    if (code && code.length !== 8) return notice('邀请码是 8 位数字。');
  }
  button.disabled = true;
  await attempt(async () => {
    const device = { deviceId: uuid(), deviceName: deviceName() };
    const code = digits(f.invite.value);
    const grant = mode === 'register'
      ? await api('POST', '/v1/accounts/register', { phone, password: f.password.value, name: f.name.value.trim(), inviteCode: code || null, ...device })
      : await api('POST', '/v1/accounts/login', { phone, password: f.password.value, ...device });
    form.reset();
    begin(grant);
  });
  button.disabled = false;
});

$('#secret-form').addEventListener('submit', async event => {
  event.preventDefault();
  const form = event.currentTarget;
  await attempt(async () => {
    begin(await api('POST', '/v1/devices/bootstrap', { token: form.elements.secret.value.trim(), deviceId: uuid(), name: deviceName() }));
    form.reset();
  });
});

for (const tab of document.querySelectorAll('.tabs [role=tab]')) tab.addEventListener('click', () => setMode(tab.dataset.mode));

$('#sign-out').addEventListener('click', async () => {
  if (!await confirmDialog('退出登录？', '退出后需要用手机号和密码重新登录。', '退出')) return;
  try { await api('DELETE', '/v1/devices/self'); } catch { /* offline: just forget the credential */ }
  forget();
  showAuth();
});

// ---------- dialogs ----------
/** Opens a form dialog; `action(form)` runs on 保存 and the dialog stays open with the error shown if it fails. */
function openForm(id, fill, action) {
  const dialog = $(`#${id}`), form = dialog.querySelector('form');
  form.reset();
  let error = form.querySelector('[data-error]');
  if (!error) { error = Object.assign(document.createElement('p'), { className: 'dialog-error' }); error.dataset.error = ''; form.querySelector('menu').before(error); }
  error.hidden = true;
  fill?.(form);
  form.onsubmit = async event => {
    if (event.submitter?.value !== 'ok') return;
    event.preventDefault();
    error.hidden = true;
    event.submitter.disabled = true;
    try { await action(form); dialog.close(); }
    catch (e) { error.textContent = e instanceof ApiError ? e.text : e.message; error.hidden = false; }
    finally { event.submitter.disabled = false; }
  };
  dialog.showModal();
}
function confirmDialog(title, message, actionLabel) {
  const dialog = $('#confirm-dialog');
  dialog.querySelector('[data-title]').textContent = title;
  dialog.querySelector('[data-message]').textContent = message;
  dialog.querySelector('[data-action]').textContent = actionLabel;
  dialog.returnValue = '';
  dialog.showModal();
  return new Promise(resolve => dialog.addEventListener('close', () => resolve(dialog.returnValue === 'ok'), { once: true }));
}

// ---------- family ----------
let me = null;

function row(main, detail, buttons = []) {
  const li = document.createElement('li');
  const text = document.createElement('div');
  text.className = 'row-text';
  const strong = document.createElement('span'); strong.textContent = main; text.append(strong);
  if (detail) { const small = document.createElement('small'); small.textContent = detail; text.append(small); }
  li.append(text);
  for (const [label, onClick, danger] of buttons) {
    const button = document.createElement('button');
    button.type = 'button'; button.className = `link${danger ? ' danger' : ''}`; button.textContent = label;
    button.addEventListener('click', onClick);
    li.append(button);
  }
  return li;
}
function empty(text) { const li = document.createElement('li'); li.className = 'empty'; li.textContent = text; return li; }

async function load() {
  const [meReply, parents, devices] = await Promise.all([api('GET', '/v1/me'), api('GET', '/v1/family/parents'), api('GET', '/v1/devices')]);
  me = meReply;
  if (me.device.role !== 'parent') { forget(); showAuth('这个凭证不是家长的。'); return; }
  $('#who').textContent = me.account ? `${me.account.name} · 家长管理` : '家长管理';
  renderChildren(me.children);
  renderParents(parents);
  renderDevices(devices.devices);
  renderAccount(me.account);
}

function renderChildren(children) {
  const list = $('#children');
  list.replaceChildren(...(children.length ? children.map(child => row(child.name, `${child.grade} 年级`, [
    ['修改', () => editChild(child)],
    ['删除', () => deleteChild(child), true]
  ])) : [empty('还没有孩子。')]));
}
function editChild(child) {
  openForm('child-dialog', form => {
    form.querySelector('[data-title]').textContent = child ? '修改孩子' : '添加孩子';
    if (child) { form.elements.name.value = child.name; form.elements.grade.value = String(child.grade); }
  }, async form => {
    const name = form.elements.name.value.trim();
    if (!name) throw new Error('请填写昵称。');
    await api('PUT', `/v1/children/${child?.id ?? uuid()}`, { name, grade: Number(form.elements.grade.value) });
    await load();
  });
}
async function deleteChild(child) {
  if (!await confirmDialog(`删除${child.name}的全部数据？`, '会删除这个孩子的作业、照片、录音、录像、批改和奖励，不能恢复。', '删除')) return;
  await attempt(async () => { await api('DELETE', `/v1/children/${child.id}`); await load(); notice(`已删除${child.name}。`, 'ok'); });
}
$('#add-child').addEventListener('click', () => editChild(null));

function renderParents({ parents, unboundDevices }) {
  $('#parents').replaceChildren(...parents.map(p => row(p.self ? `${p.name}（我）` : p.name, p.phone,
    p.self ? [] : [['移出', () => removeParent(p), true]])));
  if (!parents.length) $('#parents').replaceChildren(empty('还没有家长用手机号注册。'));
  $('#unbound').hidden = !unboundDevices;
  $('#unbound').textContent = `另有 ${unboundDevices} 台家长设备用家长密钥连接，没有登录账号。`;
}
async function removeParent(parent) {
  if (!await confirmDialog(`把${parent.name}移出家庭？`, '对方的手机会退出登录，账号会被删除。孩子和作业不受影响。', '移出')) return;
  await attempt(async () => { await api('DELETE', `/v1/family/parents/${parent.id}`); await load(); notice(`已把${parent.name}移出家庭。`, 'ok'); });
}

let inviteText = '';
$('#make-invite').addEventListener('click', () => attempt(async () => {
  const { code } = await api('POST', '/v1/family/invites', {});
  $('#invite-code').textContent = spaced(code);
  $('#invite').hidden = false;
  $('#make-invite').textContent = '重新生成邀请码';
  inviteText = `我在用小熊伴学管孩子的作业。注册时填邀请码 ${code}（24 小时内有效）就能加入我们家。服务器：${location.origin}`;
}));
$('#copy-invite').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText(inviteText); notice('已复制，可以发给家人。', 'ok'); }
  catch { notice(inviteText, 'info'); } // No clipboard on an insecure page: show the text so it can be copied by hand.
});

$('#make-pairing').addEventListener('click', () => attempt(async () => {
  const { code } = await api('POST', '/v1/devices/pairing-codes', {});
  $('#pairing-code').textContent = code;
  $('#pairing').hidden = false;
  $('#make-pairing').textContent = '重新生成';
}));

function renderDevices(devices) {
  $('#devices').replaceChildren(...devices.map(d => {
    const kind = d.role === 'parent' ? '家长' : '孩子';
    const detail = [kind, d.accountName, d.self ? '这台设备' : null].filter(Boolean).join(' · ');
    return row(d.name || (d.role === 'parent' ? '家长设备' : '孩子设备'), detail, d.self ? [] : [['断开', () => revoke(d), true]]);
  }));
}
async function revoke(device) {
  if (!await confirmDialog(`断开${device.name || '这台设备'}？`, '断开后这台设备要重新登录或配对才能用。', '断开')) return;
  await attempt(async () => { await api('DELETE', `/v1/devices/${device.id}`); await load(); });
}

function renderAccount(account) {
  const box = $('#account');
  box.replaceChildren();
  if (account) {
    const list = document.createElement('ul');
    list.className = 'rows';
    list.append(row('手机号', account.phone), row('称呼', account.name, [['修改', () => openForm('name-dialog', f => { f.elements.name.value = account.name; },
      async f => { await api('PUT', '/v1/account', { name: f.elements.name.value.trim() }); await load(); })]]));
    const password = Object.assign(document.createElement('button'), { type: 'button', className: 'link', textContent: '修改密码' });
    password.addEventListener('click', () => openForm('password-dialog', null, async f => {
      if (f.elements.new.value !== f.elements.confirm.value) throw new Error('两次输入的新密码不一样。');
      await api('POST', '/v1/account/password', { oldPassword: f.elements.old.value, newPassword: f.elements.new.value });
      notice('密码已修改。', 'ok');
    }));
    box.append(list, password);
  } else {
    const hint = Object.assign(document.createElement('p'), { className: 'hint', textContent: '这个网页是用家长密钥连接的。设置手机号和密码后，以后直接用手机号登录。' });
    const bind = Object.assign(document.createElement('button'), { type: 'button', className: 'link', textContent: '设置手机号登录' });
    bind.addEventListener('click', () => openForm('bind-dialog', null, async f => {
      const phone = digits(f.elements.phone.value);
      if (phone.length !== 11) throw new Error(messages.invalid_phone);
      if (f.elements.password.value !== f.elements.confirm.value) throw new Error('两次输入的密码不一样。');
      await api('POST', '/v1/accounts/bind', { phone, password: f.elements.password.value, name: f.elements.name.value.trim() });
      await load();
    }));
    box.append(hint, bind);
  }
}

function showHome() {
  $('#auth').hidden = true; $('#home').hidden = false; $('#sign-out').hidden = false; $('#insecure').hidden = true;
  notice('');
  attempt(load);
}

setMode('login');
if (token) showHome(); else showAuth();
