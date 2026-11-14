import { gunzipSync, gzipSync } from 'node:zlib';
import { randomUUID } from 'node:crypto';
import WebSocket from 'ws';

const DEFAULT_URL = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream';
const DEFAULT_STREAM_URL = 'wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async';
const DEFAULT_RESOURCE_ID = 'volc.seedasr.sauc.duration';

function header(messageType, flags = 0b0001) {
  return Buffer.from([(0b0001 << 4) | 0b0001, (messageType << 4) | flags, (0b0001 << 4) | 0b0001, 0]);
}
export function fullRequestFrame(payload, sequence = 1) {
  const body = gzipSync(Buffer.from(JSON.stringify(payload)));
  const frame = Buffer.alloc(12 + body.length);
  header(0b0001, 0b0001).copy(frame, 0);
  frame.writeInt32BE(sequence, 4);
  frame.writeUInt32BE(body.length, 8);
  body.copy(frame, 12);
  return frame;
}

export function audioFrame(audio, sequence, last = false) {
  const body = gzipSync(Buffer.from(audio));
  const frame = Buffer.alloc(12 + body.length);
  header(0b0010, last ? 0b0011 : 0b0001).copy(frame, 0);
  frame.writeInt32BE(last ? -Math.abs(sequence) : sequence, 4);
  frame.writeUInt32BE(body.length, 8);
  body.copy(frame, 12);
  return frame;
}

function responseText(payload) {
  const result = payload?.result;
  if (Array.isArray(result)) return result.map(item => item?.text || '').join('');
  return result?.text || payload?.text || '';
}

export function parseResponse(message) {
  const data = Buffer.from(message);
  if (data.length < 4) throw new Error('volc_response_short');
  const headerBytes = (data[0] & 0x0f) * 4;
  if (headerBytes < 4 || data.length < headerBytes) throw new Error('volc_response_header');
  const messageType = data[1] >> 4;
  const flags = data[1] & 0x0f;
  const serialization = data[2] >> 4;
  const compression = data[2] & 0x0f;
  let offset = headerBytes;
  let sequence = null;
  if (flags & 0x01) { if (data.length < offset + 4) throw new Error('volc_response_sequence'); sequence = data.readInt32BE(offset); offset += 4; }
  const last = Boolean(flags & 0x02);
  let event = null;
  if (flags & 0x04) { if (data.length < offset + 4) throw new Error('volc_response_event'); event = data.readInt32BE(offset); offset += 4; }
  let code = 0;
  let payloadSize = data.length - offset;
  if (messageType === 0b1001) {
    if (data.length < offset + 4) throw new Error('volc_response_payload_size');
    payloadSize = data.readUInt32BE(offset); offset += 4;
  } else if (messageType === 0b1111) {
    if (data.length < offset + 8) throw new Error('volc_response_error');
    code = data.readInt32BE(offset); payloadSize = data.readUInt32BE(offset + 4); offset += 8;
  }
  let payload = data.subarray(offset, offset + payloadSize);
  if (compression === 0b0001 && payload.length) payload = gunzipSync(payload);
  let body = null;
  if (serialization === 0b0001 && payload.length) body = JSON.parse(payload.toString('utf8'));
  return { messageType, sequence, event, last, code, body, text: responseText(body) };
}

/**
 * Transcribes one 16 kHz mono PCM16LE utterance with Volcengine's one-sentence ASR.
 * This waits for the final result instead of rendering interim text, which is the
 * right tradeoff for a child saying a phrase such as “春天的春”.
 */
export function createVolcAsr({ apiKey, resourceId = DEFAULT_RESOURCE_ID, url = DEFAULT_URL, streamUrl = DEFAULT_STREAM_URL,
  WebSocketImpl = WebSocket } = {}) {
  if (!apiKey) return null;
  resourceId ||= DEFAULT_RESOURCE_ID; url ||= DEFAULT_URL; streamUrl ||= DEFAULT_STREAM_URL;
  return {
    /**
     * Opens a bidirectional streaming recognition for one utterance (the voice teacher). Audio is sent while
     * the child speaks; `onText` receives interim text; `end()` sends the last packet and resolves with the final text.
     */
    stream({ onText, signal } = {}) {
      const requestId = randomUUID();
      const ws = new WebSocketImpl(streamUrl, { headers: {
        'X-Api-Key': apiKey, 'X-Api-Resource-Id': resourceId, 'X-Api-Request-Id': requestId, 'X-Api-Connect-Id': requestId
      } });
      let sequence = 1, open = false, ended = false, settled = false, latestText = '', bytes = 0, timer;
      const queue = [];
      let resolveFinal, rejectFinal;
      const final = new Promise((resolve, reject) => { resolveFinal = resolve; rejectFinal = reject; });
      final.catch(() => {}); // observed through end(); an abandoned stream must not raise an unhandled rejection
      const finish = (error, value) => {
        if (settled) return;
        settled = true; clearTimeout(timer); signal?.removeEventListener('abort', abort);
        try { ws.close(); } catch { /* already closed */ }
        error ? rejectFinal(error) : resolveFinal(value);
      };
      const abort = () => { try { ws.terminate?.(); } catch { /* already closed */ } finish(Object.assign(new Error('aborted'), { name: 'AbortError' })); };
      signal?.addEventListener('abort', abort, { once: true });
      timer = setTimeout(() => finish(new Error('volc_asr_timeout')), 90_000);
      const sendAudio = (chunk, last) => ws.send(audioFrame(chunk, sequence++, last));
      ws.on('error', error => finish(error));
      ws.on('close', () => finish(new Error('volc_asr_closed')));
      ws.on('message', message => {
        try {
          const response = parseResponse(message);
          if (response.code) return finish(new Error(`volc_asr_${response.code}`));
          if (response.text && response.text !== latestText) { latestText = response.text; onText?.(latestText); }
          if (response.last) finish(null, { text: latestText, requestId });
        } catch (error) { finish(error); }
      });
      ws.once('open', () => {
        try {
          ws.send(fullRequestFrame({
            user: { uid: 'littlebear-teacher' },
            audio: { language: 'zh-CN', format: 'pcm', codec: 'raw', rate: 16_000, bits: 16, channel: 1 },
            request: { model_name: 'bigmodel', enable_itn: true, enable_punc: true, enable_ddc: false, show_utterances: true, result_type: 'full' }
          }, sequence++));
          open = true;
          for (const [chunk, last] of queue.splice(0)) sendAudio(chunk, last);
        } catch (error) { finish(error); }
      });
      return {
        write(pcm) {
          if (settled || ended || !pcm?.length || bytes + pcm.length > 3_200_000) return; // 100 s; the caller ends the turn
          bytes += pcm.length;
          open ? sendAudio(pcm, false) : queue.push([Buffer.from(pcm), false]);
        },
        end() {
          if (!settled && !ended) {
            ended = true;
            // The last packet must carry audio; 20 ms of silence closes an utterance that ended on a full chunk.
            const tail = Buffer.alloc(640);
            open ? sendAudio(tail, true) : queue.push([tail, true]);
          }
          return final;
        },
        abort
      };
    },
    async transcribe(pcm, { signal } = {}) {
      if (!Buffer.isBuffer(pcm) || pcm.length < 320) throw new Error('audio_too_short');
      if (pcm.length > 1_600_000) throw new Error('audio_too_large');
      const requestId = randomUUID();
      const ws = new WebSocketImpl(url, { headers: {
        'X-Api-Key': apiKey,
        'X-Api-Resource-Id': resourceId,
        'X-Api-Request-Id': requestId
      } });
      const chunks = [];
      for (let offset = 0; offset < pcm.length; offset += 6400) chunks.push(pcm.subarray(offset, Math.min(offset + 6400, pcm.length)));
      return await new Promise((resolve, reject) => {
        let settled = false, sequence = 1, timer, latestText = '';
        const finish = (error, value) => {
          if (settled) return;
          settled = true; clearTimeout(timer); signal?.removeEventListener('abort', abort);
          try { ws.close(); } catch { /* already closed */ }
          error ? reject(error) : resolve(value);
        };
        const abort = () => { try { ws.terminate?.(); } catch { /* already closed */ } finish(Object.assign(new Error('aborted'), { name: 'AbortError' })); };
        timer = setTimeout(() => finish(new Error('volc_asr_timeout')), 30_000);
        signal?.addEventListener('abort', abort, { once: true });
        ws.on('error', error => finish(error));
        ws.on('message', message => {
          try {
            const response = parseResponse(message);
            if (response.code) return finish(new Error(`volc_asr_${response.code}`));
            if (response.text) latestText = response.text;
            if (response.last) finish(null, { text: latestText, requestId });
          } catch (error) { finish(error); }
        });
        ws.once('open', async () => {
          try {
            ws.send(fullRequestFrame({
              user: { uid: 'littlebear-hanzi' },
              audio: { language: 'zh-CN', format: 'pcm', codec: 'raw', rate: 16_000, bits: 16, channel: 1 },
              request: { model_name: 'bigmodel', enable_itn: false, enable_punc: true, enable_ddc: false,
                show_utterances: true }
            }, sequence++));
            for (let i = 0; i < chunks.length; i++) {
              if (signal?.aborted) return;
              ws.send(audioFrame(chunks[i], sequence++, i === chunks.length - 1));
            }
          } catch (error) { finish(error); }
        });
      });
    }
  };
}
