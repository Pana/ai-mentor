const DEFAULT_URL = 'https://openspeech.bytedance.com/api/v3/tts/unidirectional';
const DEFAULT_RESOURCE_ID = 'seed-tts-2.0';
export const TTS_SAMPLE_RATE = 24_000;
const FINISHED = 20_000_000;

/**
 * Volcengine/Doubao speech synthesis over the V3 HTTP chunked endpoint. Each response line is a JSON object;
 * `data` holds base64 audio, and code 20000000 ends the stream. Audio is 24 kHz mono PCM16LE.
 */
export function createVolcTts({ apiKey, resourceId = DEFAULT_RESOURCE_ID, speaker, url = DEFAULT_URL, speechRate = 0,
  fetchImpl = fetch } = {}) {
  if (!apiKey || !speaker) return null;
  resourceId ||= DEFAULT_RESOURCE_ID; url ||= DEFAULT_URL;
  return {
    sampleRate: TTS_SAMPLE_RATE,
    /** Yields PCM chunks for `text` as they arrive. */
    async *synthesize(text, { signal } = {}) {
      const response = await fetchImpl(url, { method: 'POST', redirect: 'error', signal,
        headers: { 'Content-Type': 'application/json', 'X-Api-Key': apiKey, 'X-Api-Resource-Id': resourceId },
        body: JSON.stringify({ user: { uid: 'littlebear-teacher' }, req_params: { text, speaker,
          audio_params: { format: 'pcm', sample_rate: TTS_SAMPLE_RATE, speech_rate: speechRate } } }) });
      if (!response.ok) throw new Error(`volc_tts_http_${response.status}`);
      const decoder = new TextDecoder();
      let buffer = '', finished = false;
      const parse = line => {
        const trimmed = line.trim().replace(/^data:\s*/, '');
        if (!trimmed.startsWith('{')) return null;
        const value = JSON.parse(trimmed);
        if (value.code === FINISHED) { finished = true; return null; }
        if (value.code && value.code !== 0) throw new Error(`volc_tts_${value.code}`);
        return typeof value.data === 'string' && value.data ? Buffer.from(value.data, 'base64') : null;
      };
      for await (const chunk of response.body) {
        buffer += decoder.decode(chunk, { stream: true });
        let index;
        while ((index = buffer.indexOf('\n')) >= 0) {
          const audio = parse(buffer.slice(0, index));
          buffer = buffer.slice(index + 1);
          if (audio?.length) yield audio;
          if (finished) return;
        }
        if (buffer.length > 4_000_000) throw new Error('volc_tts_line_too_long');
      }
      const audio = parse(buffer + decoder.decode());
      if (audio?.length) yield audio;
    }
  };
}
