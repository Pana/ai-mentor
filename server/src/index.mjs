import { createGateway } from './gateway.mjs';
const server = createGateway({ token: process.env.TUTOR_DEVICE_TOKEN, apiUrl: process.env.MODEL_API_URL,
  apiKey: process.env.MODEL_API_KEY, model: process.env.MODEL_NAME, jsonMode: process.env.MODEL_JSON_MODE !== 'false' });
const host = process.env.HOST || '127.0.0.1';
const port = Number(process.env.PORT || 8787);
server.listen(port, host, () => console.log(`LittleBear gateway listening on ${host}:${port}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
