import { readFile } from 'node:fs/promises';
import { join, normalize, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const types = { '.html': 'text/html; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png' };
const defaultWebDir = fileURLToPath(new URL('../../web/teacher/', import.meta.url));

/**
 * Serves the voice teacher web page (`web/teacher`) at `/teacher/`. The page itself holds no secret: it pairs
 * as a device through the phase-1 API and talks to `/v1/teacher` with that device's credential.
 */
export function createTeacherPage({ webDir = defaultWebDir } = {}) {
  const send = (res, status, body, headers = {}) => {
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers });
    res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  };
  return async function handle(req, res) {
    const path = req.url.split('?')[0];
    if (path !== '/teacher' && !path.startsWith('/teacher/')) return false;
    if (req.method !== 'GET' && req.method !== 'HEAD') { send(res, 405, { error: 'method_not_allowed' }); return true; }
    if (path === '/teacher') { res.writeHead(301, { Location: '/teacher/' }); res.end(); return true; }
    let relative;
    try { relative = normalize(decodeURIComponent(path.slice('/teacher/'.length) || 'index.html')); } catch { send(res, 404, { error: 'not_found' }); return true; }
    const type = types[extname(relative)];
    if (!type || relative.split(sep).includes('..') || relative.startsWith(sep) || relative.includes('\0')) { send(res, 404, { error: 'not_found' }); return true; }
    try {
      const body = await readFile(join(webDir, relative));
      // Older WebKit does not treat 'self' as covering the page's own WebSocket origin, so it is spelled out.
      const host = /^[A-Za-z0-9.\-:[\]]{1,255}$/.test(req.headers.host ?? '') ? req.headers.host : '';
      const sockets = host ? ` ws://${host} wss://${host}` : '';
      send(res, 200, req.method === 'HEAD' ? '' : body, { 'Content-Type': type, 'Cache-Control': 'no-cache',
        ...(type.startsWith('text/html') ? { 'Permissions-Policy': 'microphone=(self)',
          'Content-Security-Policy': `default-src 'self'; connect-src 'self'${sockets}; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'none'` } : {}) });
    } catch { send(res, 404, { error: 'not_found' }); }
    return true;
  };
}
