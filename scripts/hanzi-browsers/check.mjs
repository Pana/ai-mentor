// 小熊写字：每个浏览器内核 × 设备尺寸打开页面、查“蝴蝶”，检查
//   横向溢出和越界元素、查完后田字格在第一屏（触屏）、田字格大小、按钮高度、
//   “我来写”时才锁住田字格手势、设置弹窗不出屏、控制台没有报错。
// 由 scripts/hanzi-browsers.sh 调用：node check.mjs <页面地址> <截图目录> [webkit|chromium|firefox]
//
// 内核和真实浏览器的对应：
//   WebKit   ≈ iOS/iPadOS 上所有浏览器（Safari、Chrome、微信内置都用 WebKit）、macOS Safari
//   Chromium ≈ Android Chrome、Edge、三星浏览器、多数国产浏览器、Brave
//   Firefox  ≈ Firefox（Playwright 的 Firefox 不能模拟手机触屏，只按屏幕尺寸检查）
import { chromium, webkit, firefox, devices } from 'playwright';
import { mkdirSync } from 'node:fs';
import { join } from 'node:path';

const [base, out, only] = process.argv.slice(2);
if (!base || !out) { console.error('usage: node check.mjs <url> <shots-dir> [engine]'); process.exit(2); }
mkdirSync(out, { recursive: true });

const profiles = [
  ['iPhone SE', devices['iPhone SE']],
  ['iPhone 15 Pro', devices['iPhone 15 Pro']],
  ['iPhone 15 Pro Max 横屏', devices['iPhone 15 Pro Max landscape']],
  ['Galaxy S8 (360)', devices['Galaxy S8']],
  ['Galaxy S9+ (320)', { ...devices['Galaxy S9+'], viewport: { width: 320, height: 658 } }],
  ['Pixel 7', devices['Pixel 7']],
  ['iPad Mini', devices['iPad Mini']],
  ['iPad Pro 11 横屏', devices['iPad Pro 11 landscape']],
  ['桌面 1280', { viewport: { width: 1280, height: 800 } }]
];
const darkToo = new Set(['iPhone 15 Pro', 'Pixel 7']);
const engines = [['webkit', webkit], ['chromium', chromium], ['firefox', firefox]];

const results = [];
for (const [engineName, engine] of engines) {
  if (only && engineName !== only) continue;
  const browser = await engine.launch();
  for (const [name, profile] of profiles) {
    for (const scheme of darkToo.has(name) ? ['light', 'dark'] : ['light']) {
      const opts = { ...profile, colorScheme: scheme, locale: 'zh-CN' };
      if (engineName === 'firefox') { delete opts.isMobile; delete opts.deviceScaleFactor; opts.hasTouch = false; }
      const context = await browser.newContext(opts);
      const page = await context.newPage();
      const errors = [];
      page.on('pageerror', e => errors.push(String(e)));
      page.on('console', m => {
        if (m.type() !== 'error') return;
        const url = m.location()?.url || '';
        if (url.includes('/v1/hanzi/')) return;       // 字典服务没配模型时页面会提示“只显示笔顺”，这是预期内的
        errors.push(`${m.text()} ${url}`);
      });
      const issues = [];
      const tag = `${engineName} · ${name}${scheme === 'dark' ? ' · 深色' : ''}`;
      const file = join(out, tag.replace(/[^\w一-龥]+/g, '_'));
      try {
        await page.goto(base, { waitUntil: 'networkidle' });
        const overflow = () => page.evaluate(() => {
          const vw = document.documentElement.clientWidth;
          const bad = [...document.querySelectorAll('body *')].filter(e => {
            if (e.closest('.chips') && !e.matches('.chips')) return false;   // 示例条本来就横向滑动
            if (e.closest('svg') && !e.matches('svg')) return false;         // SVG 内部被 svg 视口裁剪；Firefox 会报未裁剪的几何框
            const r = e.getBoundingClientRect();
            return r.width && (r.right > vw + 0.5 || r.left < -0.5);
          }).map(e => e.tagName.toLowerCase() + (e.id ? `#${e.id}` : '') + (typeof e.className === 'string' && e.className ? `.${e.className.split(' ')[0]}` : ''));
          return { sw: document.documentElement.scrollWidth, vw, bad: bad.slice(0, 5) };
        });
        let o = await overflow();
        if (o.sw > o.vw) issues.push(`首页横向溢出 ${o.sw}>${o.vw}`);
        if (o.bad.length) issues.push(`首页越界: ${o.bad.join(',')}`);
        await page.screenshot({ path: `${file}_home.png` });

        await page.fill('#query', '蝴蝶');
        await page.press('#query', 'Enter');
        await page.waitForSelector('#writer svg', { timeout: 20000 });
        await page.waitForTimeout(1200);                // 等平滑滚动和详情回来
        o = await overflow();
        if (o.sw > o.vw) issues.push(`结果页横向溢出 ${o.sw}>${o.vw}`);
        if (o.bad.length) issues.push(`结果页越界: ${o.bad.join(',')}`);
        const vis = await page.evaluate(() => {
          const pad = document.querySelector('#pad').getBoundingClientRect();
          const small = [...document.querySelectorAll('#result button, .ask button')]
            .filter(b => b.offsetParent && !b.closest('.steps') && b.getBoundingClientRect().height < 32).length;
          return { top: Math.round(pad.top), bottom: Math.round(pad.bottom), width: Math.round(pad.width), vh: innerHeight, small,
            touch: matchMedia('(pointer: coarse), (max-width: 860px)').matches };
        });
        if (vis.touch && (vis.bottom > vis.vh || vis.top < 0)) issues.push(`查完后田字格不在第一屏 (top ${vis.top}, bottom ${vis.bottom}, 视口 ${vis.vh})`);
        if (vis.width < Math.min(240, vis.vh * 0.55)) issues.push(`田字格太小 ${vis.width}px`);
        if (vis.small) issues.push(`${vis.small} 个按钮高度 <32px`);
        await page.screenshot({ path: `${file}_result.png` });
        await page.screenshot({ path: `${file}_full.png`, fullPage: true });

        await page.click('#trace');
        const quiz = await page.$eval('#pad', p => [p.classList.contains('quiz'), getComputedStyle(p).touchAction]);
        if (!quiz[0] || quiz[1] !== 'none') issues.push(`我来写时田字格 touch-action=${quiz[1]}`);
        await page.click('#trace');
        if (await page.$eval('#pad', p => getComputedStyle(p).touchAction) === 'none') issues.push('平时田字格仍拦截滚动');

        await page.click('#settings-btn');
        const dlg = await page.$eval('#settings', d => { const r = d.getBoundingClientRect(); return { open: d.open, l: r.left, r: r.right, vw: innerWidth }; });
        if (!dlg.open || dlg.l < 0 || dlg.r > dlg.vw) issues.push(`设置弹窗异常 ${JSON.stringify(dlg)}`);
        await page.keyboard.press('Escape');
      } catch (e) { issues.push(`脚本失败: ${e.message.split('\n')[0]}`); }
      if (errors.length) issues.push(`控制台错误: ${errors.slice(0, 2).join(' | ')}`);
      results.push({ tag, issues });
      console.log(`${issues.length ? '✗' : '✓'} ${tag}${issues.length ? `\n    ${issues.join('\n    ')}` : ''}`);
      await context.close();
    }
  }
  await browser.close();
}
const failed = results.filter(r => r.issues.length).length;
console.log(`\n${results.length - failed}/${results.length} 通过，截图在 ${out}`);
process.exit(failed ? 1 : 0);
