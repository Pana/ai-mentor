import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import { createGateway } from '../src/gateway.mjs';

test('gateway serves only the release manifest and content-addressed APKs', async t => {
  const dir = await mkdtemp(join(tmpdir(), 'bear-update-'));
  const server = createGateway({ updateDir: dir, token: 'test-only-android-update-token' });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => {
    await new Promise(resolve => server.close(resolve));
    await rm(dir, { recursive: true, force: true });
  });
  const base = `http://127.0.0.1:${server.address().port}/android-updates/`;
  assert.equal((await fetch(base + 'latest.json')).status, 404);
  const filename = 'a'.repeat(64) + '.apk';
  await writeFile(join(dir, 'latest.json'), '{"versionCode":4}');
  await writeFile(join(dir, filename), 'test apk');
  await writeFile(join(dir, 'private.txt'), 'private');
  const manifest = await fetch(base + 'latest.json');
  assert.equal(manifest.headers.get('cache-control'), 'no-store');
  assert.deepEqual(await manifest.json(), { versionCode: 4 });
  const apk = await fetch(base + filename);
  assert.equal(apk.headers.get('content-type'), 'application/vnd.android.package-archive');
  assert.equal(await apk.text(), 'test apk');
  assert.equal((await fetch(base + 'private.txt')).status, 404);
});
