import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { gunzipSync, gzipSync } from 'node:zlib';
import { audioFrame, createVolcAsr, fullRequestFrame, parseResponse } from '../src/volc-asr.mjs';

test('Volc ASR request frames use the documented binary envelope', () => {
  const full = fullRequestFrame({ audio: { format: 'pcm' } }, 7);
  assert.deepEqual([...full.subarray(0, 4)], [0x11, 0x11, 0x11, 0]);
  assert.equal(full.readInt32BE(4), 7);
  const fullPayload = JSON.parse(gunzipSync(full.subarray(12)).toString());
  assert.deepEqual(fullPayload, { audio: { format: 'pcm' } });

  const last = audioFrame(Buffer.from([1, 2, 3]), 9, true);
  assert.deepEqual([...last.subarray(0, 4)], [0x11, 0x23, 0x11, 0]);
  assert.equal(last.readInt32BE(4), -9);
  assert.deepEqual([...gunzipSync(last.subarray(12))], [1, 2, 3]);
});

test('Volc ASR response frames decode final text and errors', () => {
  const body = gzipSync(Buffer.from(JSON.stringify({ result: { text: '春天的春' } })));
  const frame = Buffer.alloc(16 + body.length);
  Buffer.from([0x11, 0x93, 0x11, 0]).copy(frame, 0);
  frame.writeInt32BE(-1, 4);
  frame.writeUInt32BE(body.length, 8);
  body.copy(frame, 12);
  const parsed = parseResponse(frame);
  assert.equal(parsed.last, true);
  assert.equal(parsed.text, '春天的春');

  const error = Buffer.alloc(16);
  Buffer.from([0x11, 0xf0, 0x11, 0]).copy(error, 0);
  error.writeInt32BE(45000001, 4);
  error.writeUInt32BE(0, 8);
  assert.equal(parseResponse(error).code, 45000001);
});

test('Volc ASR sends a recorded utterance and returns the final transcript', async () => {
  class FakeWebSocket extends EventEmitter {
    constructor(url, options) {
      super(); this.url = url; this.options = options; this.frames = [];
      queueMicrotask(() => this.emit('open'));
    }
    send(frame) {
      this.frames.push(Buffer.from(frame));
      if (frame[1] === 0x23) {
        const body = gzipSync(Buffer.from(JSON.stringify({ result: { text: '春天的春' } })));
        const response = Buffer.alloc(12 + body.length);
        Buffer.from([0x11, 0x93, 0x11, 0]).copy(response, 0);
        response.writeInt32BE(-1, 4); response.writeUInt32BE(body.length, 8); body.copy(response, 12);
        queueMicrotask(() => this.emit('message', response));
      }
    }
    close() {}
    terminate() {}
  }
  const asr = createVolcAsr({ apiKey: 'test-key', WebSocketImpl: FakeWebSocket });
  const result = await asr.transcribe(Buffer.alloc(6_400));
  assert.equal(result.text, '春天的春');
});
