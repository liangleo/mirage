export interface Transport {
  open(): Promise<void>;
  write(data: Uint8Array): Promise<void>;
  close(): Promise<void>;
  onData(cb: (data: Uint8Array) => void): void;
  onClosed(cb: (reason: string) => void): void;
}