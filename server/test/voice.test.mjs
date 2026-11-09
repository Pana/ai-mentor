import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { createGateway } from '../src/gateway.mjs';

const token = 'device-voice-test-token-not-a-secret-12345';

test('voice WebSocket authenticates and streams a mock response', async t => {
  const server = createGateway({ token, voice: { token, mock: true } });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const ws = new WebSocket(`ws://127.0.0.1:${server.address().port}/v1/voice`, { headers: { Authorization: `Bearer ${token}` } });
  t.after(() => new Promise(resolve => {
    ws.close();
    setTimeout(() => { server.close(resolve); server.closeAllConnections(); }, 20);
  }));
  const events = [];
  ws.onmessage = event => events.push(JSON.parse(event.data));
  await new Promise(resolve => { ws.onopen = resolve; });
  ws.send(JSON.stringify({ type: 'session.start', context: { grade: 2, subject: 'MATH' } }));
  await new Promise(resolve => setTimeout(resolve, 20));
  ws.send(JSON.stringify({ type: 'input.text', text: '你好' }));
  await new Promise(resolve => {
    const timer = setInterval(() => { if (events.some(event => event.type === 'assistant.response.done')) { clearInterval(timer); resolve(); } }, 5);
  });
  assert.equal(events[0].type, 'hello');
  assert.ok(events.some(event => event.type === 'session.ready'));
  assert.ok(events.some(event => event.type === 'assistant.text.delta' && event.text.includes('你好')));
  assert.ok(events.some(event => event.type === 'assistant.response.done'));
});

test('voice WebSocket rejects an invalid device credential', async t => {
  const server = createGateway({ token, voice: { token, mock: true } });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const ws = new WebSocket(`ws://127.0.0.1:${server.address().port}/v1/voice`, { headers: { Authorization: 'Bearer wrong-token' } });
  t.after(() => new Promise(resolve => { ws.close(); server.close(resolve); server.closeAllConnections(); }));
  const error = await new Promise(resolve => { ws.onerror = resolve; });
  assert.ok(error);
});

test('voice cancellation aborts an in-flight provider response', async t => {
  let aborted = false;
  const server = createGateway({ token, voice: { respondText: async ({ signal }) => await new Promise((resolve, reject) => {
    signal.addEventListener('abort', () => { aborted = true; reject(new Error('cancelled')); }, { once: true });
  }) } });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  const ws = new WebSocket(`ws://127.0.0.1:${server.address().port}/v1/voice`, { headers: { Authorization: `Bearer ${token}` } });
  t.after(() => new Promise(resolve => { ws.close(); setTimeout(() => { server.close(resolve); server.closeAllConnections(); }, 20); }));
  const events = [];
  ws.onmessage = event => events.push(JSON.parse(event.data));
  await new Promise(resolve => { ws.onopen = resolve; });
  ws.send(JSON.stringify({ type: 'session.start', context: { grade: 2, subject: 'MATH' } }));
  await new Promise(resolve => setTimeout(resolve, 20));
  ws.send(JSON.stringify({ type: 'input.text', text: '你好' }));
  await new Promise(resolve => {
    const timer = setInterval(() => { if (events.some(event => event.type === 'input.transcript.final')) { clearInterval(timer); resolve(); } }, 5);
  });
  ws.send(JSON.stringify({ type: 'response.cancel' }));
  await new Promise(resolve => {
    const timer = setInterval(() => { if (events.some(event => event.type === 'response.cancelled')) { clearInterval(timer); resolve(); } }, 5);
  });
  assert.equal(aborted, true);
  assert.equal(events.some(event => event.type === 'assistant.response.done'), false);
});
