import { open } from 'node:fs/promises';
import { join } from 'node:path';
import { pipeline } from 'node:stream/promises';

export async function serveAndroidUpdate(req, res, directory) {
  const match = /^\/android-updates\/(latest\.json|[a-f0-9]{64}\.apk)$/.exec(req.url);
  if (req.method !== 'GET' || !match) return false;
  const manifest = match[1] === 'latest.json';
  let file;
  try {
    file = await open(join(directory, match[1]));
    const stat = await file.stat();
    res.writeHead(200, { 'Content-Type': manifest ? 'application/json' : 'application/vnd.android.package-archive',
      'Content-Length': stat.size, 'Cache-Control': manifest ? 'no-store' : 'public, max-age=31536000, immutable' });
    await pipeline(file.createReadStream(), res);
  } catch (error) {
    if (!res.headersSent && !res.destroyed) {
      res.writeHead(error.code === 'ENOENT' ? 404 : 500, { 'Cache-Control': 'no-store' });
      res.end();
    }
  } finally {
    await file?.close();
  }
  return true;
}
