export interface DecoderEvent {
  kind: string;
  frameId: number;
  bytes: number;
  flags: number;
  captureTsMicros: number;
  decodeMs: number;
  reason: string;
}

export const openDecoder: (width: number, height: number, fps: number, surfaceId: string,
  callback: (opened: boolean) => void) => void;
export const submitVideo: (annexB: ArrayBuffer, flags: number, frameId: number, captureTsMicros: number) => number;
export const closeDecoder: () => void;
export const onEvent: (callback: (event: DecoderEvent) => void) => void;

export const startUsb: (fd: number, onEvent: (kind: string, data: ArrayBuffer | null) => void) => boolean;
export const stopUsb: () => void;
export const usbWrite: (data: Uint8Array) => number;

export interface UdpEvent {
  kind: string;
  frameId?: number;
  key?: boolean;
  captureTs?: number;
  data?: ArrayBuffer;
  reason?: string;
}

export const onUdpEvent: (callback: (event: UdpEvent) => void) => void;
export const startUdp: (host: string, port: number, key: ArrayBuffer, noncePrefix: ArrayBuffer) => boolean;
export const stopUdp: () => void;
