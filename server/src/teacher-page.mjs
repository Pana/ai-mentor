import { readFile } from 'node:fs/promises';
import { join, normalize, extname, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const types = { '.html': 'text/html; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png' };
const webRoot = fileURLToPath(new URL('../../web/', import.meta.url));

/**
 * Serves the static files of one web page from `webDir` under `prefix` (`/teacher`, `/parent`). `htmlHeaders(host)`
 * gives the page's own headers (Content-Security-Policy and so on), added to the HTML only.
 */
export function createWebPage({ prefix, webDir, htmlHeaders = () => ({}) }) {
  const send = (res, status, body, headers = {}) => {
    res.writeHead(status, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers });
    res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  };
  return async function handle(req, res) {
    const path = req.url.split('?')[0];
    if (path !== prefix && !path.startsWith(`${prefix}/`)) return false;
    if (req.method !== 'GET' && req.method !== 'HEAD') { send(res, 405, { error: 'method_not_allowed' }); return true; }
    if (path === prefix) { res.writeHead(301, { Location: `${prefix}/` }); res.end(); return true; }
    let relative;
    try { relative = normalize(decodeURIComponent(path.slice(prefix.length + 1) || 'index.html')); } catch { send(res, 404, { error: 'not_found' }); return true; }
    const type = types[extname(relative)];
    if (!type || relative.split(sep).includes('..') || relative.startsWith(sep) || relative.includes('\0')) { send(res, 404, { error: 'not_found' }); return true; }
    try {
      const body = await readFile(join(webDir, relative));
      const host = /^[A-Za-z0-9.\-:[\]]{1,255}$/.test(req.headers.host ?? '') ? req.headers.host : '';
      send(res, 200, req.method === 'HEAD' ? '' : body, { 'Content-Type': type, 'Cache-Control': 'no-cache',
        ...(type.startsWith('text/html') ? htmlHeaders(host) : {}) });
    } catch { send(res, 404, { error: 'not_found' }); }
    return true;
  };
}

/**
 * Serves the voice teacher web page (`web/teacher`) at `/teacher/`. The page itself holds no secret: it pairs
 * as a device through the phase-1 API and talks to `/v1/teacher` with that device's credential.
 */
export function createTeacherPage({ webDir = join(webRoot, 'teacher') } = {}) {
  return createWebPage({ prefix: '/teacher', webDir, htmlHeaders: host => {
    // Older WebKit does not treat 'self' as covering the page's own WebSocket origin, so it is spelled out.
    const sockets = host ? ` ws://${host} wss://${host}` : '';
    return { 'Permissions-Policy': 'microphone=(self)',
      'Content-Security-Policy': `default-src 'self'; connect-src 'self'${sockets}; style-src 'self' 'unsafe-inline'; img-src 'self' data:; object-src 'none'; base-uri 'none'` };
  } });
}

/**
 * The parent web page (`web/parent`) at `/parent/`: sign in with a phone number and manage the family through the
 * phase-1 API. It keeps a parent credential, so other sites may not frame it and it sends no referrer.
 */
export function createParentPage({ webDir = join(webRoot, 'parent') } = {}) {
  return createWebPage({ prefix: '/parent', webDir, htmlHeaders: () => ({
    'Content-Security-Policy': "default-src 'self'; connect-src 'self'; style-src 'self'; img-src 'self' data:; object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'",
    'X-Frame-Options': 'DENY', 'Referrer-Policy': 'no-referrer' }) });
}
