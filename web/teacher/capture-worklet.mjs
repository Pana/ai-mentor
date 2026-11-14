// Runs on the audio thread: averages the mic signal down to 16 kHz and posts 40 ms chunks of 16-bit samples.
class Capture extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ratio = Math.max(1, sampleRate / 16000);
    this.position = 0; this.sum = 0; this.count = 0;
    this.chunk = new Int16Array(640); this.filled = 0;
  }
  process(inputs) {
    const input = inputs[0]?.[0];
    if (!input) return true;
    for (let i = 0; i < input.length; i++) {
      this.sum += input[i]; this.count += 1; this.position += 1;
      if (this.position < this.ratio) continue;
      this.position -= this.ratio;
      const sample = this.sum / this.count;
      this.sum = 0; this.count = 0;
      this.chunk[this.filled++] = Math.max(-32768, Math.min(32767, Math.round(sample * 32767)));
      if (this.filled === this.chunk.length) {
        const copy = this.chunk.slice();
        this.port.postMessage(copy.buffer, [copy.buffer]);
        this.filled = 0;
      }
    }
    return true;
  }
}
registerProcessor('capture', Capture);
