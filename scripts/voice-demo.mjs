// Protocol smoke demo for the realtime voice session. Node 22 provides a
// WebSocket client, so this exercises the same gateway events used by iOS.
// Usage: node scripts/voice-demo.mjs http://127.0.0.1:8787 TOKEN "小熊，帮我看看这道题"
const base = process.argv[2] || 'http://127.0.0.1:8787';
const token = process.argv[3];
const message = process.argv.slice(4).join(' ') || '小熊，帮我看看这道题';
if (!token) { console.error('usage: node scripts/voice-demo.mjs <gateway-url> <device-token> [message]'); process.exit(2); }

const url = new URL(base);
url.protocol = url.protocol === 'https:' ? 'wss:' : 'ws:';
url.pathname = `${url.pathname.replace(/\/$/, '')}/v1/voice`;
const socket = new WebSocket(url, { headers: { Authorization: `Bearer ${token}` } });
socket.onopen = () => {
  socket.send(JSON.stringify({ type: 'session.start', wake_word: '小熊', context: {
    grade: 2, subject: 'MATH', title: '演示题', instructions: '24 + 18 = ?', answer: '', history: []
  } }));
  setTimeout(() => socket.send(JSON.stringify({ type: 'input.text', text: message })), 50);
};
socket.onmessage = event => {
  const value = JSON.parse(event.data);
  if (value.type === 'assistant.text.delta') process.stdout.write(value.text);
  else if (value.type === 'assistant.response.done') { process.stdout.write('\n'); socket.close(); }
  else if (value.type === 'error') { console.error(`\nvoice error: ${value.code}`); socket.close(); process.exitCode = 1; }
};
socket.onerror = () => { console.error('voice WebSocket connection failed'); process.exitCode = 1; };
