export interface DecoderEvent {
  kind: string;
  frameId: number;
  bytes: number;
  flags: number;
  captureTsMicros: number;
  decodeMs: number;
  reason: string;
}

export const openDecoder: (width: number, height: number, fps: number, surfaceId: string) => boolean;
export const setSurface: (surfaceId: string) => boolean;
export const submitVideo: (annexB: ArrayBuffer, flags: number, frameId: number, captureTsMicros: number) => number;
export const closeDecoder: () => void;
export const onEvent: (callback: (event: DecoderEvent) => void) => void;