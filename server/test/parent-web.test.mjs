import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createGateway } from '../src/gateway.mjs';
import { createApi } from '../src/api.mjs';

test('parent web page is served at /parent/ with a strict CSP and no framing', async t => {
  const dataDir = mkdtempSync(join(tmpdir(), 'littlebear-parent-web-'));
  const api = createApi({ dataDir });
  const server = createGateway({ token: 'device-test-token-not-a-secret-12345', api });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const base = `http://127.0.0.1:${server.address().port}`;
  t.after(() => new Promise(resolve => { server.close(() => { api.close(); rmSync(dataDir, { recursive: true, force: true }); resolve(); }); server.closeAllConnections(); }));

  const page = await fetch(`${base}/parent/`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get('content-type'), /text\/html/);
  const csp = page.headers.get('content-security-policy');
  assert.match(csp, /default-src 'self'/);
  assert.match(csp, /frame-ancestors 'none'/);
  assert.doesNotMatch(csp, /unsafe-inline|unsafe-eval/);
  assert.equal(page.headers.get('x-frame-options'), 'DENY');
  assert.equal(page.headers.get('referrer-policy'), 'no-referrer');
  const html = await page.text();
  assert.match(html, /小熊伴学 · 家长/);
  assert.doesNotMatch(html, /<script(?![^>]*\bsrc=)[^>]*>/, 'no inline scripts: the CSP would block them');
  assert.doesNotMatch(html, /\son[a-z]+=/i, 'no inline event handlers');
  assert.doesNotMatch(html, /\sstyle=/i, 'no inline styles');

  for (const [path, type] of [['app.mjs', /text\/javascript/], ['style.css', /text\/css/]]) {
    const asset = await fetch(`${base}/parent/${path}`);
    assert.equal(asset.status, 200, path);
    assert.match(asset.headers.get('content-type'), type);
    assert.equal(asset.headers.get('content-security-policy'), null, 'the CSP goes on the page only');
  }
  assert.equal((await fetch(`${base}/parent`, { redirect: 'manual' })).status, 301);
  assert.equal((await fetch(`${base}/parent/..%2f..%2fserver%2f.env.example`)).status, 404);
  assert.equal((await fetch(`${base}/parent/`, { method: 'POST' })).status, 405);
  // The teacher page still has its own headers after the two pages started sharing the file server.
  assert.match((await fetch(`${base}/teacher/`)).headers.get('permissions-policy'), /microphone/);
});
