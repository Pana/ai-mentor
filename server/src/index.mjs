import { createGateway } from './gateway.mjs';
import { createApi } from './api.mjs';
import { createHanzi } from './hanzi.mjs';
import { createVolcAsr } from './volc-asr.mjs';
import { createVolcTts } from './volc-tts.mjs';

const model = { apiUrl: process.env.MODEL_API_URL, apiKey: process.env.MODEL_API_KEY, model: process.env.MODEL_NAME,
  jsonMode: process.env.MODEL_JSON_MODE !== 'false' };
const api = createApi({ dataDir: process.env.DATA_DIR || './data', bootstrapToken: process.env.PARENT_BOOTSTRAP_TOKEN || '', model });
const asr = createVolcAsr({ apiKey: process.env.VOLC_ASR_API_KEY, resourceId: process.env.VOLC_ASR_RESOURCE_ID,
  url: process.env.VOLC_ASR_URL, streamUrl: process.env.VOLC_ASR_STREAM_URL });
const tts = createVolcTts({ apiKey: process.env.VOLC_TTS_API_KEY || process.env.VOLC_ASR_API_KEY,
  resourceId: process.env.VOLC_TTS_RESOURCE_ID, speaker: process.env.VOLC_TTS_SPEAKER, url: process.env.VOLC_TTS_URL,
  speechRate: Number(process.env.VOLC_TTS_SPEECH_RATE || 0) });
const hanzi = createHanzi({ token: process.env.TUTOR_DEVICE_TOKEN, dataDir: process.env.DATA_DIR || './data',
  model: { ...model, model: process.env.HANZI_MODEL_NAME || model.model }, asr });
const server = createGateway({ token: process.env.TUTOR_DEVICE_TOKEN, ...model,
  visionModel: process.env.MODEL_VISION_NAME || '', imagesSupported: process.env.MODEL_SUPPORTS_IMAGES !== 'false',
  voice: { token: process.env.TUTOR_DEVICE_TOKEN, mock: process.env.VOICE_MOCK === 'true' }, api, hanzi,
  teacher: { asr, tts, model: { apiUrl: model.apiUrl, apiKey: model.apiKey, model: process.env.TEACHER_MODEL_NAME || model.model } } });
const host = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT || 8787);
server.listen(port, host, () => console.log(`LittleBear gateway listening on ${host}:${port}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => { api.close(); hanzi.close(); process.exit(0); }));
