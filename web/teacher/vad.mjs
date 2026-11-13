/**
 * Decides when the child starts and stops talking from the level of each mic chunk.
 * The noise floor adapts to the room; while the teacher is speaking the start threshold is raised,
 * so echo the browser did not cancel does not count as the child barging in.
 */
export class VoiceActivityDetector {
  noiseFloor = -60;
  speaking = false;
  startMargin = 14;
  strictExtra = 8;
  endMargin = 8;
  startAfterMs = 180;
  endAfterMs = 800;
  maxSpeechMs = 30_000;
  #aboveMs = 0; #belowMs = 0; #speechMs = 0;

  /** `level` in dBFS for a chunk lasting `ms`; `strict` while the teacher is talking. Returns 'start', 'end' or null. */
  process(level, ms, strict = false) {
    if (this.speaking) {
      this.#speechMs += ms;
      this.#belowMs = level < this.noiseFloor + this.endMargin ? this.#belowMs + ms : 0;
      if (this.#belowMs >= this.endAfterMs || this.#speechMs >= this.maxSpeechMs) { this.reset(); return 'end'; }
      return null;
    }
    // Track the room: fall quickly to quieter levels, rise slowly so speech does not become the floor.
    this.noiseFloor = level < this.noiseFloor ? this.noiseFloor * 0.7 + level * 0.3 : this.noiseFloor + (level - this.noiseFloor) * 0.01;
    this.noiseFloor = Math.min(-30, Math.max(-80, this.noiseFloor));
    const threshold = Math.max(this.noiseFloor + this.startMargin, -48) + (strict ? this.strictExtra : 0);
    this.#aboveMs = level > threshold ? this.#aboveMs + ms : 0;
    if (this.#aboveMs >= this.startAfterMs) { this.speaking = true; this.#aboveMs = 0; this.#belowMs = 0; this.#speechMs = 0; return 'start'; }
    return null;
  }

  reset() { this.speaking = false; this.#aboveMs = 0; this.#belowMs = 0; this.#speechMs = 0; }
}

/** dBFS of 16-bit samples. */
export function levelOf(samples) {
  if (!samples.length) return -100;
  let sum = 0;
  for (let i = 0; i < samples.length; i++) { const value = samples[i] / 32768; sum += value * value; }
  return 10 * Math.log10(Math.max(sum / samples.length, 1e-10));
}
