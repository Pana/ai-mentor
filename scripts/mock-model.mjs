// Stand-in for an OpenAI-compatible /chat/completions endpoint, for local end-to-end tests only.
// Replies with fixed, valid tutor JSON per request mode. Never use it as a real tutor.
import http from 'node:http';

const replies = {
  help: { message: '先看看个位：4 加 8 等于多少？满十要怎么办？', assessment: 'UNKNOWN' },
  check: { message: '答案 42 是对的：个位 4 + 8 = 12，向十位进 1。', assessment: 'CORRECT' },
  recognize: { message: '已识别，请家长核对。', assessment: 'UNKNOWN', title: '口算练习', instructions: '第 12 页 1–5 题', subject: 'MATH' },
  practice: { message: '试试这道新题。', assessment: 'UNKNOWN', exercise: {
    concept: '两位数加法', prompt: '算一算：35 + 27 = ？请填写一个整数。', answer: '62',
    hints: ['先把 27 分成 20 和 7。', '先算 35 + 20，再加 7。', '35 + 20 = 55，55 + 7 = 62。'], explanation: '35 + 27 = 62，个位满十进一。' } }
};

const port = Number(process.argv[2] || 18788);
const seen = [];
http.createServer(async (req, res) => {
  let body = '';
  for await (const chunk of req) body += chunk;
  if (req.method === 'GET' && req.url === '/seen') { res.end(JSON.stringify(seen)); return; }
  try {
    const request = JSON.parse(body);
    const content = request.messages.at(-1).content;
    const task = JSON.parse(content.find(part => part.type === 'text').text);
    seen.push({ mode: task.mode, model: request.model, image: content.some(part => part.type === 'image_url') });
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ choices: [{ message: { content: JSON.stringify(replies[task.mode]) } }] }));
  } catch {
    res.writeHead(400); res.end('{}');
  }
}).listen(port, '127.0.0.1', () => console.log(`mock model on 127.0.0.1:${port}`));
