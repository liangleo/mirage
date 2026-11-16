export interface ProbeResult {
  ok: boolean;
  frames: number;
  nals: number;
  totalMs: number;
  fps: number;
  error: string;
}

export interface FdWriteResult {
  n: number;
  err: number;
}

export interface FdReadResult {
  ok: boolean;
  n: number;
  err: number;
  stage: number;
  ready: number;
  avail: number;
  bytes: ArrayBuffer;
}

export interface FdInfoResult {
  target: string;
  mode: number;
  isSocket: number;
  isChar: number;
  isFifo: number;
  size: number;
  soType: number;
  flags: number;
}

export const fdInfo: (fd: number) => FdInfoResult;
export const probeDecode: (data: ArrayBuffer, width: number, height: number) => ProbeResult;
export const fdWrite: (fd: number, data: ArrayBuffer) => FdWriteResult;
export const fdRead: (fd: number, maxLen: number, timeoutMs: number) => FdReadResult;