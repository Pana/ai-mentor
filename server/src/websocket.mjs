import { createHash } from 'node:crypto';

// Small RFC 6455 server used by the gateway so the project does not need a
// native module or a second public port. It supports text, binary, ping/pong
// and close frames needed by the voice session.
export function acceptWebSocket(req, socket, head, onMessage, onClose) {
  const key = req.headers['sec-websocket-key'];
  if (!key || req.headers.upgrade?.toLowerCase() !== 'websocket') {
    socket.destroy();
    return null;
  }
  const accept = createHash('sha1').update(`${key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`).digest('base64');
  socket.write(['HTTP/1.1 101 Switching Protocols', 'Upgrade: websocket', 'Connection: Upgrade',
    `Sec-WebSocket-Accept: ${accept}`, '\r\n'].join('\r\n'));
  const connection = new WebSocketConnection(socket, onMessage, onClose);
  if (head?.length) connection.receive(head);
  return connection;
}

class WebSocketConnection {
  #socket; #buffer = Buffer.alloc(0); #onMessage; #onClose; #closed = false;
  constructor(socket, onMessage, onClose) {
    this.#socket = socket; this.#onMessage = onMessage; this.#onClose = onClose;
    socket.on('data', data => this.receive(data));
    socket.on('close', () => this.close(false));
    socket.on('error', () => this.close(false));
  }
  receive(data) {
    if (this.#closed) return;
    this.#buffer = Buffer.concat([this.#buffer, data]);
    while (true) {
      if (this.#buffer.length < 2) return;
      const first = this.#buffer[0], second = this.#buffer[1];
      const fin = (first & 0x80) !== 0, opcode = first & 0x0f, masked = (second & 0x80) !== 0;
      let length = second & 0x7f, offset = 2;
      if (length === 126) { if (this.#buffer.length < 4) return; length = this.#buffer.readUInt16BE(2); offset = 4; }
      else if (length === 127) { if (this.#buffer.length < 10) return; if (this.#buffer.readUInt32BE(2) !== 0) return this.close(true, 1009, 'message too large'); length = this.#buffer.readUInt32BE(6); offset = 10; }
      if (!masked || !fin || length > 4_000_000) return this.close(true, 1002, 'invalid frame');
      if (this.#buffer.length < offset + 4 + length) return;
      const mask = this.#buffer.subarray(offset, offset + 4); offset += 4;
      const payload = Buffer.from(this.#buffer.subarray(offset, offset + length));
      this.#buffer = this.#buffer.subarray(offset + length);
      for (let i = 0; i < payload.length; i++) payload[i] ^= mask[i % 4];
      if (opcode === 0x8) return this.close(true, 1000, '');
      if (opcode === 0x9) { this.#writeFrame(0xA, payload); continue; }
      if (opcode === 0xA) continue;
      if (opcode === 0x1) this.#onMessage(payload.toString('utf8'), false, this);
      else if (opcode === 0x2) this.#onMessage(payload, true, this);
      else return this.close(true, 1003, 'unsupported frame');
    }
  }
  sendJSON(value) { this.#writeFrame(0x1, Buffer.from(JSON.stringify(value))); }
  sendBinary(value) { this.#writeFrame(0x2, Buffer.from(value)); }
  close(notify = true, code = 1000, reason = '') {
    if (this.#closed) return;
    if (notify && !this.#socket.destroyed) {
      const body = Buffer.alloc(2 + Buffer.byteLength(reason)); body.writeUInt16BE(code, 0); body.write(reason, 2); this.#writeFrame(0x8, body);
    }
    this.#closed = true;
    if (!this.#socket.destroyed) this.#socket.end();
    this.#onClose?.();
  }
  #writeFrame(opcode, payload) {
    if (this.#closed || this.#socket.destroyed) return;
    const length = payload.length; let header;
    if (length < 126) header = Buffer.from([0x80 | opcode, length]);
    else if (length <= 0xffff) { header = Buffer.alloc(4); header[0] = 0x80 | opcode; header[1] = 126; header.writeUInt16BE(length, 2); }
    else { header = Buffer.alloc(10); header[0] = 0x80 | opcode; header[1] = 127; header.writeUInt32BE(0, 2); header.writeUInt32BE(length, 6); }
    this.#socket.write(Buffer.concat([header, payload]));
  }
}
