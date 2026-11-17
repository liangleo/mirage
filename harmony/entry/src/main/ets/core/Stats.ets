export class StatsSnapshot {
  fps: number = 0;
  decodeMs: number = 0;
  bitrateMbps: number = 0;
  dropped: number = 0;
  e2eMs: number = -1;
  e2eP95Ms: number = -1;
  rttMs: number = -1;
  codec: string = '';
}

export class Stats {
  private frames: number = 0;
  private bytes: number = 0;
  private lastTickMs: number = 0;
  private decodeMs: number = 0;
  private dropped: number = 0;
  private e2eMs: number = -1;
  private rttMs: number = -1;
  private codecLabel: string = '';
  // 滚动窗口约 5s（60fps），用于 p95 而不是瞬时值
  private e2eSamples: number[] = [];
  // 独立的 1s 窗口，供 FEEDBACK 上报，避免和浮层的 snapshot 抢计数器
  private fbStartMs: number = -1;
  private fbFrames: number = 0;
  private fbBytes: number = 0;
  private fbFpsX10: number = 0;
  private fbBitrateBps: number = 0;

  onVideo(byteCount: number, nowMs: number = Date.now()): void {
    if (this.lastTickMs === 0) {
      this.lastTickMs = nowMs;
    }
    this.frames += 1;
    this.bytes += byteCount;
    if (this.fbStartMs < 0) {
      this.fbStartMs = nowMs;
    }
    this.fbFrames += 1;
    this.fbBytes += byteCount;
    const elapsed = nowMs - this.fbStartMs;
    if (elapsed >= 1000) {
      this.fbFpsX10 = Math.floor(this.fbFrames * 10000 / elapsed);
      this.fbBitrateBps = Math.floor(this.fbBytes * 8 * 1000 / elapsed);
      this.fbFrames = 0;
      this.fbBytes = 0;
      this.fbStartMs = nowMs;
    }
  }

  currentFpsX10(): number {
    return this.fbFpsX10;
  }

  currentBitrateBps(): number {
    return this.fbBitrateBps;
  }

  currentDropped(): number {
    return this.dropped;
  }

  currentE2eMs(): number {
    return this.e2eMs;
  }

  onDropped(): void {
    this.dropped += 1;
  }

  setDecodeMs(value: number): void {
    this.decodeMs = value;
  }

  setE2eMs(value: number): void {
    if (value < 0) {
      return;
    }
    this.e2eMs = value;
    this.e2eSamples.push(value);
    if (this.e2eSamples.length > 300) {
      this.e2eSamples.shift();
    }
  }

  setRttMs(value: number): void {
    this.rttMs = value;
  }

  setCodecLabel(value: string): void {
    this.codecLabel = value;
  }

  currentDecodeMs(): number {
    return this.decodeMs;
  }

  currentRttMs(): number {
    return this.rttMs;
  }

  snapshot(nowMs: number = Date.now()): StatsSnapshot {
    if (this.lastTickMs === 0) {
      this.lastTickMs = nowMs;
    }
    const elapsed = Math.max(nowMs - this.lastTickMs, 1);
    const snap = new StatsSnapshot();
    snap.fps = Math.floor(this.frames * 1000 / elapsed);
    snap.bitrateMbps = this.bytes * 8 / elapsed / 1000;
    this.frames = 0;
    this.bytes = 0;
    this.lastTickMs = nowMs;
    snap.decodeMs = this.decodeMs;
    snap.dropped = this.dropped;
    snap.e2eMs = this.e2eMs;
    snap.e2eP95Ms = this.percentile95();
    snap.rttMs = this.rttMs;
    snap.codec = this.codecLabel;
    return snap;
  }

  private percentile95(): number {
    const count = this.e2eSamples.length;
    if (count === 0) {
      return -1;
    }
    const sorted = this.e2eSamples.slice().sort((a: number, b: number): number => a - b);
    return sorted[Math.ceil(count * 0.95) - 1];
  }
}