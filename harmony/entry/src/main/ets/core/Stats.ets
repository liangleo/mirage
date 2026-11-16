export class StatsSnapshot {
  fps: number = 0;
  decodeMs: number = 0;
  bitrateMbps: number = 0;
  dropped: number = 0;
  e2eMs: number = -1;
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

  onVideo(byteCount: number, nowMs: number = Date.now()): void {
    if (this.lastTickMs === 0) {
      this.lastTickMs = nowMs;
    }
    this.frames += 1;
    this.bytes += byteCount;
  }

  onDropped(): void {
    this.dropped += 1;
  }

  setDecodeMs(value: number): void {
    this.decodeMs = value;
  }

  setE2eMs(value: number): void {
    this.e2eMs = value;
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
    snap.rttMs = this.rttMs;
    snap.codec = this.codecLabel;
    return snap;
  }
}