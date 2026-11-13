// 小熊老师网页的端到端检查：起真实的服务端，上游（模型、火山语音识别、火山语音合成）用本机替身，
// 再用 Chromium 带一段假麦克风声音把整个对话跑一遍：
//   连接设备 → 添加孩子 → 点“开始” → 开口说话（实时字幕、定稿）→ 小熊分段讲解，白板跟着语音一步步画
//   → 点小熊打断 → 打字提问 → 各种白板元素 → 竖屏和手机尺寸的布局 → 服务端断开后的提示
//   → 小熊讲到一半孩子开口打断 → 服务端没配语音时只用打字。
// 替身只验证页面和协议，不代表真实模型、识别和合成的效果。
// 用法：node scripts/teacher-web/check.mjs [截图目录]      由 scripts/teacher-web.sh 调用
import http from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const root = fileURLToPath(new URL('../../', import.meta.url));
const require = createRequire(import.meta.url);
const { WebSocketServer } = createRequire(join(root, 'server/package.json'))('ws');
let chromium;
try { ({ chromium } = require('playwright')); }
catch { ({ chromium } = createRequire(join(root, 'scripts/hanzi-browsers/package.json'))('playwright')); }

const out = process.argv[2] || join(tmpdir(), `teacher-web-${Date.now()}`);
const work = mkdtempSync(join(tmpdir(), 'teacher-web-work-'));
mkdirSync(out, { recursive: true });
const secret = 'teacher-web-check-parent-secret-0001';
const listen = async server => { server.listen(0, '127.0.0.1'); await once(server, 'listening'); return server.address().port; };

// ---------- stand-in upstreams ----------

const HEARD = '教我算38加27';
const lessons = {
  add: [
    { speech: '好呀，我们一起来算三十八加二十七。', board: [{ op: 'clear' }, { op: 'add', el: { id: 't1', type: 'text', text: '38 + 27 = ?', style: 'title' } }] },
    { speech: '先写成竖式，个位对齐个位，十位对齐十位。', board: [{ op: 'add', el: { id: 'v1', type: 'vertical', a: 38, b: 27, operator: '+', reveal: 0, focus: 0 } }] },
    { speech: '个位上八加七等于十五，写五，向十位进一。', board: [{ op: 'update', id: 'v1', set: { reveal: 1, focus: 0 } }] },
    { speech: '你来试试：十位上三加二，再加进上来的一，等于几？', board: [{ op: 'update', id: 'v1', set: { focus: 1 } }], await: true }
  ],
  gallery: [
    { speech: '这是数轴，从八往后跳五格。', board: [{ op: 'clear' }, { op: 'add', el: { id: 't1', type: 'text', text: '8 + 5 = 13', style: 'title' } },
      { op: 'add', el: { id: 'n1', type: 'number_line', from: 0, to: 20, step: 1, marks: [8], jumps: [{ from: 8, to: 13, label: '+5' }] } }] },
    { speech: '三个四，可以画成三组点子。', board: [{ op: 'add', el: { id: 'd1', type: 'dots', groups: 3, per: 4, highlight: 1, label: '3 个 4 是 12' } }] },
    { speech: '小红比小明多几本，用线段图看得最清楚。', board: [{ op: 'add', el: { id: 'b1', type: 'bar', total: '一共 ? 本',
      rows: [{ label: '小明', parts: [{ value: 12, label: '12 本' }] }, { label: '小红', parts: [{ value: 12, label: '' }, { value: null, label: '多 ?' }] }] } }] },
    { speech: '这个钟面是三点半。', board: [{ op: 'add', el: { id: 'c1', type: 'clock', hour: 3, minute: 30, label: '3:30' } }] },
    { speech: '退位减法的竖式是这样的。', board: [{ op: 'add', el: { id: 'v2', type: 'vertical', a: 52, b: 17, operator: '-', reveal: 2, focus: -1 } },
      { op: 'add', el: { id: 't2', type: 'text', text: '52 − 17 = 35', style: 'answer' } }, { op: 'add', el: { id: 't3', type: 'text', text: '个位不够减，向十位借一', style: 'hint' } }] }
  ],
  other: [{ speech: '今天有一项数学作业，口算本第十二页，还没开始做。', board: [] }, { speech: '要不要现在一起看看？', board: [], await: true }]
};

const modelRequests = [];
const model = http.createServer(async (req, res) => {
  let body = ''; for await (const chunk of req) body += chunk;
  const request = JSON.parse(body);
  modelRequests.push(request);
  const said = request.messages.at(-1).content;
  const lesson = /所有图/.test(said) ? lessons.gallery : /38/.test(said) ? lessons.add : lessons.other;
  res.writeHead(200, { 'Content-Type': 'text/event-stream' });
  for (const segment of lesson) {
    const line = `${JSON.stringify(segment)}\n`;
    for (let i = 0; i < line.length; i += 24) { // token-sized pieces
      res.write(`data: ${JSON.stringify({ choices: [{ delta: { content: line.slice(i, i + 24) } }] })}\n\n`);
      await new Promise(resolve => setTimeout(resolve, 8));
    }
  }
  res.end('data: [DONE]\n\n');
});

/** How long the stand-in TTS makes a sentence, in seconds. */
const spokenSeconds = text => Math.max(0.8, [...text].length * 0.13);
const ttsRequests = [];
const tts = http.createServer(async (req, res) => {
  let body = ''; for await (const chunk of req) body += chunk;
  const { req_params: { text, audio_params: { sample_rate: rate } } } = JSON.parse(body);
  ttsRequests.push(text);
  const samples = Math.round(spokenSeconds(text) * rate), pcm = Buffer.alloc(samples * 2);
  for (let i = 0; i < samples; i++) { // a soft tone with a syllable rhythm
    const envelope = 0.5 + 0.5 * Math.sin(2 * Math.PI * 3 * i / rate), fade = Math.min(1, i / 800, (samples - i) / 800);
    pcm.writeInt16LE(Math.round(Math.sin(2 * Math.PI * 220 * i / rate) * 6000 * envelope * fade), i * 2);
  }
  res.writeHead(200, { 'Content-Type': 'application/json' });
  for (let offset = 0; offset < pcm.length; offset += 4801) { // odd-sized chunks split a sample, like a real stream can
    res.write(`${JSON.stringify({ code: 0, data: pcm.subarray(offset, offset + 4801).toString('base64') })}\n`);
    await new Promise(resolve => setTimeout(resolve, 10));
  }
  res.end(`${JSON.stringify({ code: 20000000, message: 'ok' })}\n`);
});

const asrServer = http.createServer();
const asrSessions = [];
new WebSocketServer({ server: asrServer }).on('connection', ws => {
  const session = { audioBytes: 0, frames: 0 };
  asrSessions.push(session);
  const reply = (text, last) => {
    const payload = gzipSync(Buffer.from(JSON.stringify({ result: { text } })));
    const frame = Buffer.alloc(12 + payload.length);
    Buffer.from([0x11, last ? 0x93 : 0x91, 0x11, 0]).copy(frame, 0);
    frame.writeInt32BE(last ? -session.frames : session.frames, 4); frame.writeUInt32BE(payload.length, 8); payload.copy(frame, 12);
    ws.send(frame);
  };
  ws.on('message', data => {
    if (data[1] >> 4 !== 0b0010) return; // the first frame is the request, the rest are audio
    session.frames += 1; session.audioBytes += data.length;
    if (session.frames === 6) reply(HEARD.slice(0, 3), false);
    if (data[1] & 0b0010) reply(HEARD, true);
  });
});

/** A fake microphone: quiet room, then one sentence-like burst (harmonics with a syllable rhythm), then quiet. */
function microphoneWav(path, starts, { speech = 1.6, length = 45, rate = 48000 } = {}) {
  const total = Math.round(length * rate), data = Buffer.alloc(total * 2);
  let phase = 0;
  for (let i = 0; i < total; i++) {
    const start = starts.findLast(at => at <= i / rate) ?? Infinity, t = i / rate - start;
    let value = (Math.random() - 0.5) * 0.002;
    if (t >= 0 && t < speech) {
      phase += 2 * Math.PI * (170 + 30 * Math.sin(2 * Math.PI * 2.5 * t)) / rate;
      const syllable = 0.55 + 0.45 * Math.sin(2 * Math.PI * 4 * t - Math.PI / 2), edge = Math.min(1, t / 0.03, (speech - t) / 0.05);
      value += (Math.sin(phase) + 0.6 * Math.sin(2 * phase) + 0.4 * Math.sin(3 * phase) + 0.25 * Math.sin(5 * phase)) * 0.22 * syllable * edge;
    }
    data.writeInt16LE(Math.round(Math.max(-1, Math.min(1, value)) * 32767), i * 2);
  }
  const header = Buffer.alloc(44);
  header.write('RIFF', 0); header.writeUInt32LE(36 + data.length, 4); header.write('WAVEfmt ', 8); header.writeUInt32LE(16, 16);
  header.writeUInt16LE(1, 20); header.writeUInt16LE(1, 22); header.writeUInt32LE(rate, 24); header.writeUInt32LE(rate * 2, 28);
  header.writeUInt16LE(2, 32); header.writeUInt16LE(16, 34); header.write('data', 36); header.writeUInt32LE(data.length, 40);
  writeFileSync(path, Buffer.concat([header, data]));
}

// ---------- run ----------

const failures = [];
const check = (ok, what, detail) => {
  console.log(`${ok ? '  ok  ' : '  FAIL'} ${what}`);
  if (!ok) { failures.push(what); if (detail !== undefined) console.log('       ', JSON.stringify(detail)); }
};
const freePort = async () => { const probe = http.createServer(); const port = await listen(probe); await new Promise(resolve => probe.close(resolve)); return port; };
const servers = [], browsers = [];
try {
  const [modelPort, ttsPort, asrPort] = [await listen(model), await listen(tts), await listen(asrServer)];
  const upstream = { MODEL_API_URL: `http://127.0.0.1:${modelPort}/v1/chat/completions`, MODEL_API_KEY: 'stand-in', MODEL_NAME: 'stand-in', TEACHER_MODEL_NAME: '' };
  const speechServices = { VOLC_ASR_API_KEY: 'stand-in', VOLC_ASR_STREAM_URL: `ws://127.0.0.1:${asrPort}`, VOLC_ASR_URL: `ws://127.0.0.1:${asrPort}`,
    VOLC_TTS_API_KEY: 'stand-in', VOLC_TTS_SPEAKER: 'stand-in', VOLC_TTS_URL: `http://127.0.0.1:${ttsPort}/tts`, VOLC_TTS_RESOURCE_ID: '' };
  const noSpeech = { VOLC_ASR_API_KEY: '', VOLC_TTS_API_KEY: '', VOLC_TTS_SPEAKER: '' };
  let log = '';
  /** Starts the real gateway on a free port with its own data directory. */
  async function gateway(name, extra) {
    const port = await freePort();
    const child = spawn(process.execPath, [join(root, 'server/src/index.mjs')], { stdio: ['ignore', 'pipe', 'pipe'],
      env: { ...process.env, HOST: '127.0.0.1', PORT: String(port), DATA_DIR: join(work, name), TUTOR_DEVICE_TOKEN: 'teacher-web-check-device-token-0001',
        PARENT_BOOTSTRAP_TOKEN: secret, VOICE_MOCK: 'false', ...upstream, ...extra } });
    child.stdout.on('data', chunk => { log += chunk; }); child.stderr.on('data', chunk => { log += chunk; });
    servers.push(child);
    const url = `http://127.0.0.1:${port}`;
    for (let i = 0; i < 50; i++) { if (await fetch(`${url}/health`).then(r => r.ok, () => false)) return { url, child }; await new Promise(r => setTimeout(r, 100)); }
    throw new Error(`server did not start:\n${log}`);
  }
  const { url: base, child: server } = await gateway('data', speechServices);

  // Homework for the learner summary, added the way the parent app would.
  const json = async (method, path, token, body) => (await fetch(base + path, { method,
    headers: { 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) }, body: body && JSON.stringify(body) })).json();

  /** Chromium whose microphone plays a file: one sentence-like burst at each of `starts` seconds after the mic opens. */
  async function launch(name, starts) {
    const wav = join(work, `${name}.wav`);
    microphoneWav(wav, starts);
    const launched = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', `--use-file-for-fake-audio-capture=${wav}%noloop`] });
    browsers.push(launched);
    return launched;
  }
  const errors = [];
  const newPage = async (browser, viewport, storage) => {
    const context = await browser.newContext({ viewport, deviceScaleFactor: 2, locale: 'zh-CN', hasTouch: true, storageState: storage });
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(String(error)));
    page.on('console', message => {
      const url = message.location()?.url ?? '';
      if (message.type() !== 'error' || expectedErrors.some(part => url.includes(part) || message.text().includes(part))) return;
      errors.push(`${message.text()} ${url}`);
    });
    return page;
  };
  /** Console noise the scenarios cause on purpose: a wrong pairing code, and the server going away. */
  const expectedErrors = ['/v1/devices/pair'];
  /** Connects the page as a parent device with one child, up to the “开始” step. */
  async function connect(page, url) {
    await page.goto(`${url}/teacher/`);
    await page.locator('#step-pair').waitFor();
    await page.locator('summary').click();
    await page.locator('#secret').fill(secret);
    await page.locator('#secret-form button').click();
    await page.locator('#step-add-child').waitFor();
    await page.locator('#child-name').fill('林林');
    await page.locator('#child-form button').click();
    await page.locator('#step-start').waitFor();
  }
  const browser = await launch('one-sentence', [3]);
  const shot = (page, name) => page.screenshot({ path: join(out, `${name}.png`) });
  const overflow = page => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
  /** Records each caption with the time it appeared and what the board held then. */
  const watchCaptions = page => page.evaluate(() => {
    window.captions = [];
    const note = () => {
      const text = document.getElementById('caption').textContent;
      if (text && window.captions.at(-1)?.text !== text) {
        window.captions.push({ text, at: performance.now(), board: [...document.querySelectorAll('.b-item')].map(n => n.dataset.id),
          result: [...document.querySelectorAll('.v-result')].map(n => n.textContent).join('') });
      }
    };
    new MutationObserver(note).observe(document.getElementById('caption'), { childList: true, characterData: true, subtree: true });
  });

  // 1. Connect the device and add a child (iPad landscape).
  console.log('连接和开始');
  const page = await newPage(browser, { width: 1180, height: 820 });
  await page.goto(`${base}/teacher/`);
  await page.locator('#step-pair').waitFor();
  await page.locator('#pair-code').fill('000000');
  await page.locator('#pair-form button').click();
  await page.locator('#sheet-error').waitFor();
  check((await page.locator('#sheet-error').textContent()).includes('配对码不对'), '错误的配对码有明确提示');
  await shot(page, '01-连接');
  await page.locator('summary').click();
  await page.locator('#secret').fill(secret);
  await page.locator('#secret-form button').click();
  await page.locator('#step-add-child').waitFor();
  await page.locator('#child-name').fill('林林');
  await page.locator('#child-form button').click();
  await page.locator('#step-start').waitFor();
  check((await page.locator('#start-title').textContent()) === '林林，我们开始吧', '添加孩子后到“开始”这一步');
  await shot(page, '02-开始');
  const token = await page.evaluate(() => localStorage.getItem('teacher.token'));
  const me = await json('GET', '/v1/me', token);
  await json('POST', '/v1/homework', token, { items: [{ id: crypto.randomUUID(), childId: me.children[0].id, subject: 'MATH', date: me.family.today, content: '口算本第 12 页', mode: 'OFFLINE' }] });

  // 2. Start: the mic opens, the child speaks, the teacher answers in segments.
  console.log('语音对话');
  await watchCaptions(page);
  await page.locator('#start').click();
  await page.locator('#status', { hasText: '我在听' }).waitFor({ timeout: 10_000 });
  check(await page.locator('#mute').isVisible(), '麦克风已打开（显示静音按钮）');
  await shot(page, '03-在听');
  await page.locator('#orb[data-phase="hearing"]').waitFor({ timeout: 15_000 });
  await page.locator('#heard-text', { hasText: HEARD.slice(0, 3) }).waitFor({ timeout: 10_000 });
  check(true, '说话时出现实时字幕');
  await page.locator('#heard-text', { hasText: HEARD }).waitFor({ timeout: 10_000 });
  await page.locator('.b-vertical').waitFor({ timeout: 10_000 });
  await page.locator('#orb[data-phase="speaking"]').waitFor();
  await shot(page, '04-讲解中');
  await page.locator('#your-turn').waitFor({ timeout: 30_000 });
  await shot(page, '05-等孩子回答');
  const captions = await page.evaluate(() => window.captions);
  check(captions.length === 4 && captions.every((c, i) => c.text === lessons.add[i].speech), '四段话按顺序出现', captions.map(c => c.text));
  check(asrSessions[0]?.audioBytes > 16000 * 2 * 0.8, `识别服务收到了这句话的音频（${((asrSessions[0]?.audioBytes ?? 0) / 32000).toFixed(1)} 秒）`);
  // Each segment stays until its audio has been heard, so the gaps follow the spoken lengths.
  const gaps = captions.slice(1).map((c, i) => (c.at - captions[i].at) / 1000), expected = lessons.add.slice(0, 3).map(s => spokenSeconds(s.speech));
  check(gaps.every((gap, i) => gap > expected[i] * 0.85 && gap < expected[i] + 1.5), `下一段等上一段的语音播完才开始（间隔 ${gaps.map(g => g.toFixed(1)).join('、')} 秒，语音 ${expected.map(g => g.toFixed(1)).join('、')} 秒）`);
  check(JSON.stringify(captions.map(c => c.board)) === JSON.stringify([['t1'], ['t1', 'v1'], ['t1', 'v1'], ['t1', 'v1']]) && captions[1].result === '' && captions[2].result === '5',
    '白板跟着语音走：说到竖式才出现竖式，说到个位才写出 5');
  const first = modelRequests[0];
  check(/林林，2年级/.test(first.messages[1].content) && /口算本第 12 页（还没做）/.test(first.messages[1].content), '模型收到了学情（孩子、今天的作业）');
  check(first.messages.at(-1).content.includes(`孩子说：${HEARD}`), '模型收到了识别出的这句话');

  // 3. Tap the bear to interrupt, then type.
  console.log('打断和打字');
  await page.locator('#keyboard').click();
  await page.locator('#draft').fill('展示所有图');
  await page.locator('#draft').press('Enter');
  await page.locator('.b-number-line').waitFor({ timeout: 10_000 });
  const before = (await page.evaluate(() => window.captions)).length;
  await page.locator('#orb').click();
  await page.locator('#status', { hasText: '我在听' }).waitFor();
  await page.waitForTimeout(2500);
  const afterTap = await page.evaluate(() => ({ captions: window.captions.length, caption: document.getElementById('caption').textContent, items: document.querySelectorAll('.b-item').length }));
  check(afterTap.captions === before && afterTap.caption === '' && afterTap.items === 2, '点小熊打断后不再继续讲，白板保留已画的内容');
  await page.locator('#draft').fill('今天有什么作业');
  await page.locator('#draft').press('Enter');
  await page.locator('#your-turn').waitFor({ timeout: 20_000 });
  check((await page.locator('#caption').textContent()) === lessons.other[1].speech, '打字提问得到回答');
  check(await overflow(page) <= 0, 'iPad 横屏没有横向溢出');

  // 4. Every board element, on a tall page so one screenshot shows them all; then portrait and phone.
  console.log('白板元素和各尺寸');
  const storage = await page.context().storageState();
  for (const [name, viewport] of [['06-全部白板元素', { width: 1180, height: 1700 }], ['07-iPad竖屏', { width: 820, height: 1180 }], ['08-手机', { width: 390, height: 844 }]]) {
    const view = await newPage(browser, viewport, storage);
    await view.goto(`${base}/teacher/`);
    await view.locator('#start').click();
    await view.locator('#status', { hasText: '我在听' }).waitFor({ timeout: 10_000 });
    await view.locator('#mute').click(); // the fake mic would start a sentence of its own
    await view.locator('.suggestion').first().waitFor();
    if (name.startsWith('06')) { await view.locator('#keyboard').click(); await view.locator('#draft').fill('展示所有图'); await view.locator('#draft').press('Enter'); await view.locator('#keyboard').click(); }
    else await view.locator('.suggestion').first().click();
    await view.locator(name.startsWith('06') ? '.b-text-hint' : '#your-turn').waitFor({ timeout: 40_000 });
    await view.waitForTimeout(900);
    await shot(view, name);
    check(await overflow(view) <= 0, `${name.slice(3)}没有横向溢出`);
    const layout = await view.evaluate(() => {
      const rect = id => document.getElementById(id).getBoundingClientRect();
      const board = rect('board'), panel = rect('panel'), wide = innerWidth > innerHeight;
      const inside = [...document.querySelectorAll('.b-item > *')].every(n => { const r = n.getBoundingClientRect(); return r.left >= board.left - 1 && r.right <= board.right + 1; });
      return { apart: wide ? panel.left >= board.right : panel.top >= board.bottom, fits: panel.bottom <= innerHeight + 1 && panel.right <= innerWidth + 1, boardHeight: board.height, inside,
        types: [...new Set([...document.querySelectorAll('.b-item > *')].map(n => n.classList[0]))].length };
    });
    check(layout.apart && layout.fits, `${name.slice(3)}：小熊和字幕不盖住白板，也不出屏`);
    check(layout.inside, `${name.slice(3)}：白板内容不超出白板`);
    check(layout.boardHeight > 240, `${name.slice(3)}：白板高度够用（${Math.round(layout.boardHeight)}px）`);
    if (name.startsWith('06')) check(layout.types === 6, '六种白板元素都画出来了');
    await view.context().close();
  }
  // 5. The server goes away mid-conversation.
  console.log('断线');
  expectedErrors.push('WebSocket', 'ERR_CONNECTION');
  server.kill();
  await page.locator('#retry').waitFor({ timeout: 10_000 });
  check((await page.locator('#status').textContent()) === '和小熊老师的连接断开了。' && await page.locator('.suggestion').first().isDisabled().catch(() => true), '服务端断开后提示断线，并给出“再试一次”');
  await page.locator('#draft').fill('还在吗');
  await page.locator('#draft').press('Enter');
  check((await page.locator('#draft').inputValue()) === '还在吗', '断线时打的字不会丢');
  await shot(page, '09-断线');
  await browser.close();

  // 6. The child speaks while the bear is still explaining: the reply stops and the new sentence is answered.
  console.log('开口打断');
  const second = await gateway('data-interrupt', speechServices);
  const talkative = await launch('two-sentences', [3, 8.6]);
  const interrupt = await newPage(talkative, { width: 1180, height: 820 });
  await connect(interrupt, second.url);
  await watchCaptions(interrupt);
  modelRequests.length = 0;
  await interrupt.locator('#start').click();
  await interrupt.locator('#orb[data-phase="speaking"]').waitFor({ timeout: 20_000 });
  await interrupt.locator('#orb[data-phase="hearing"]').waitFor({ timeout: 20_000 });
  const cut = await interrupt.evaluate(() => ({ captions: window.captions.map(c => c.text), caption: document.getElementById('caption').textContent }));
  check(cut.captions.length >= 1 && cut.captions.length < 4 && cut.caption === '', `小熊讲到第 ${cut.captions.length} 段时孩子开口，讲解立刻停下`, cut);
  await interrupt.locator('#your-turn').waitFor({ timeout: 40_000 });
  const all = await interrupt.evaluate(() => window.captions.map(c => c.text));
  const heardBefore = lessons.add.slice(0, cut.captions.length).map(s => s.speech);
  check(JSON.stringify(all) === JSON.stringify([...heardBefore, ...lessons.add.map(s => s.speech)]), '第二句话得到完整的新回答', all);
  const retold = modelRequests[1]?.messages ?? [];
  check(retold.at(-2)?.content === `${heardBefore.join('')}（说到这里被孩子打断了）`, '模型知道上一次只讲到哪里', retold.at(-2)?.content);
  const seen = JSON.parse(/当前白板：(.*)\n/.exec(retold.at(-1)?.content ?? '')?.[1] ?? '[]');
  check(seen.length === Math.min(2, cut.captions.length) && !seen.some(el => el.reveal > (cut.captions.length >= 3 ? 1 : 0)), '模型看到的白板和孩子看到的一致', seen);
  await talkative.close();
  second.child.kill();

  // 7. No speech services on the server: typing only, each segment stays long enough to read.
  console.log('没有配置语音');
  const silent = await gateway('data-silent', noSpeech);
  const quiet = await launch('quiet', []);
  const typed = await newPage(quiet, { width: 1180, height: 820 });
  await connect(typed, silent.url);
  await watchCaptions(typed);
  await typed.locator('#start').click();
  await typed.locator('#status', { hasText: '打字和小熊说话吧' }).waitFor({ timeout: 10_000 });
  check(!(await typed.locator('#mute').isVisible()), '没有语音识别时不显示麦克风按钮');
  const spokenBefore = ttsRequests.length;
  await typed.locator('.suggestion').first().click();
  await typed.locator('#your-turn').waitFor({ timeout: 40_000 });
  const silentCaptions = await typed.evaluate(() => window.captions);
  const reading = silentCaptions.slice(1).map((c, i) => (c.at - silentCaptions[i].at) / 1000);
  check(silentCaptions.length === 4 && reading.every(gap => gap >= 1.4), `没有声音时每段停留够读完（${reading.map(g => g.toFixed(1)).join('、')} 秒）`);
  check(ttsRequests.length === spokenBefore, '没有调用语音合成');
  await shot(typed, '10-只打字');

  check(errors.length === 0, '浏览器控制台没有报错', errors);
  if (log.replace(/\(node:\d+\) ExperimentalWarning.*\n.*\n/g, '').replace(/LittleBear gateway listening.*\n/g, '').trim()) console.log(`服务端输出：\n${log.trim()}`);
  check(ttsRequests.length >= 8, `语音合成按段调用（${ttsRequests.length} 次）`);
} catch (error) {
  failures.push(String(error?.stack ?? error));
  console.error(error);
} finally {
  for (const launched of browsers) await launched.close().catch(() => {});
  for (const child of servers) child.kill();
  for (const s of [model, tts, asrServer]) { s.closeAllConnections?.(); s.close(); }
  rmSync(work, { recursive: true, force: true });
}
console.log(failures.length ? `\n${failures.length} 项没通过` : '\n全部通过');
console.log(`截图：${out}`);
process.exit(failures.length ? 1 : 0);
