import { randomUUID, timingSafeEqual } from 'node:crypto';
import { acceptWebSocket } from './websocket.mjs';

const maxText = 2_000;
const maxContext = 24_000;
function authorized(req, token) {
  const received = Buffer.from(req.headers.authorization ?? ''), expected = Buffer.from(`Bearer ${token}`);
  return received.length === expected.length && timingSafeEqual(received, expected);
}
function clean(value, max) { return typeof value === 'string' ? value.trim().slice(0, max) : ''; }

/** Provider-neutral realtime voice protocol. The mock makes UI and protocol
 * tests deterministic; a provider adapter can be supplied through respondText. */
export function attachVoice(server, config = {}) {
  const token = config.token, respondText = config.respondText, mock = config.mock === true;
  server.on('upgrade', (req, socket, head) => {
    const url = new URL(req.url ?? '/', 'http://localhost');
    if (url.pathname !== '/v1/voice' || !authorized(req, token)) {
      socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n'); socket.destroy(); return;
    }
    let started = false, closed = false, sessionContext = {};
    let responseController = null, responseGeneration = 0, inputTimes = [];
    const sessionID = randomUUID();
    const connection = acceptWebSocket(req, socket, head, async (message, binary, ws) => {
      if (closed) return;
      if (binary) return; // reserved for PCM audio sent to a real provider adapter
      let event; try { event = JSON.parse(message); } catch { ws.sendJSON({ type: 'error', code: 'invalid_json' }); return; }
      if (event?.type === 'session.start') {
        if (started) return ws.sendJSON({ type: 'error', code: 'session_already_started' });
        started = true;
        sessionContext = event.context && typeof event.context === 'object' ? event.context : {};
        const encodedContext = JSON.stringify(sessionContext);
        if (encodedContext.length > maxContext) { started = false; return ws.sendJSON({ type: 'error', code: 'context_too_large' }); }
        const context = clean(encodedContext, maxContext);
        ws.sendJSON({ type: 'session.ready', session_id: sessionID, audio: { format: 'pcm_s16le', sample_rate: 16_000, channels: 1 }, context_bytes: context.length });
        return;
      }
      if (!started) return ws.sendJSON({ type: 'error', code: 'session_not_started' });
      if (event?.type === 'response.cancel') {
        responseGeneration += 1;
        responseController?.abort(); responseController = null;
        return ws.sendJSON({ type: 'response.cancelled' });
      }
      if (event?.type !== 'input.text') return;
      const text = clean(event.text, maxText);
      if (!text) return ws.sendJSON({ type: 'error', code: 'empty_input' });
      inputTimes = inputTimes.filter(time => Date.now() - time < 60_000);
      if (inputTimes.length >= 20) return ws.sendJSON({ type: 'error', code: 'rate_limited' });
      inputTimes.push(Date.now());
      responseGeneration += 1;
      const generation = responseGeneration;
      responseController?.abort();
      responseController = new AbortController();
      const signal = responseController.signal;
      ws.sendJSON({ type: 'input.transcript.final', text });
      try {
        const reply = respondText ? await respondText({ text, context: sessionContext, sessionID, signal }) : mock ? `我听到了：${text}` : null;
        if (closed || signal.aborted || generation !== responseGeneration) return;
        if (!reply) return ws.sendJSON({ type: 'error', code: 'voice_provider_not_configured' });
        const output = clean(reply, 8_000);
        ws.sendJSON({ type: 'assistant.response.start' });
        for (const part of output.match(/.{1,24}/gu) ?? []) ws.sendJSON({ type: 'assistant.text.delta', text: part });
        ws.sendJSON({ type: 'assistant.text.done', text: output });
        ws.sendJSON({ type: 'assistant.response.done' });
      } catch (error) {
        if (!closed && !signal.aborted && generation === responseGeneration) ws.sendJSON({ type: 'error', code: 'voice_provider_unavailable' });
      } finally {
        if (generation === responseGeneration) responseController = null;
      }
    }, () => { closed = true; responseGeneration += 1; responseController?.abort(); responseController = null; });
    connection?.sendJSON({ type: 'hello', protocol: 'littlebear.voice.v1' });
  });
  return server;
}
