import { util } from '@kit.ArkTS';

export enum MessageType {
  HELLO = 1,
  SESSION_CONFIG = 2,
  VIDEO = 3,
  INPUT = 4,
  FEEDBACK = 5,
  CTRL = 6,
  PING = 7,
  BYE = 8,
  KEY = 9,
  TEXT = 10,
  SCROLL = 11,
  UDP_CONFIG = 12
}

export const MAX_PAYLOAD: number = 8 * 1024 * 1024;

export class ProtocolException extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'ProtocolException';
  }
}

export class Frame {
  type: number;
  payload: Uint8Array;

  constructor(type: number, payload: Uint8Array) {
    this.type = type;
    this.payload = payload;
  }
}

export class FrameDecoder {
  private buf: Uint8Array = new Uint8Array(0);
  private len: number = 0;

  append(data: Uint8Array): void {
    if (this.len + data.length > this.buf.length) {
      let capacity = Math.max(4096, this.buf.length * 2);
      while (capacity < this.len + data.length) {
        capacity *= 2;
      }
      const grown = new Uint8Array(capacity);
      grown.set(this.buf.subarray(0, this.len));
      this.buf = grown;
    }
    this.buf.set(data, this.len);
    this.len += data.length;
  }

  next(): Frame | null {
    if (this.len < 4) {
      return null;
    }
    const view = new DataView(this.buf.buffer, this.buf.byteOffset, this.len);
    const length = view.getUint32(0);
    if (length < 1) {
      throw new ProtocolException(`malformed length ${length}`);
    }
    if (length > MAX_PAYLOAD + 1) {
      throw new ProtocolException(`oversized frame ${length}`);
    }
    const total = 4 + length;
    if (this.len < total) {
      return null;
    }
    const type = this.buf[4];
    const payload = this.buf.slice(5, total);
    this.len -= total;
    if (this.len > 0) {
      this.buf.copyWithin(0, total, total + this.len);
    }
    return new Frame(type, payload);
  }
}

export class Hello {
  protoVersion: number = 1;
  clientVersion: number = 1;
  deviceID: Uint8Array = new Uint8Array(16);
  screenWidth: number = 0;
  screenHeight: number = 0;
  xdpi: number = 0;
  ydpi: number = 0;
  maxFPS: number = 60;
  codecs: number = 1;
  features: number = 0;
  rotation: number = 0;
  name: string = '';
}

export class SessionConfig {
  width: number = 0;
  height: number = 0;
  fps: number = 0;
  codec: number = 0;
  bitrate: number = 0;
  rotation: number = 0;
  inputCaps: number = 0;
}

export class VideoHeader {
  codec: number = 0;
  flags: number = 0;
  frameId: number = 0;
  captureTsMicros: number = 0;
  reserved: number = 0;
}

export class VideoFrame {
  header: VideoHeader;
  annexB: Uint8Array;

  constructor(header: VideoHeader, annexB: Uint8Array) {
    this.header = header;
    this.annexB = annexB;
  }
}

function encodeUtf8(text: string): Uint8Array {
  const encoded = new util.TextEncoder().encodeInto(text);
  return encoded;
}

export function encodeFrame(type: number, payload: Uint8Array): Uint8Array {
  const frame = new Uint8Array(5 + payload.length);
  new DataView(frame.buffer).setUint32(0, payload.length + 1);
  frame[4] = type;
  frame.set(payload, 5);
  return frame;
}

export function encodeHello(hello: Hello): Uint8Array {
  if (hello.deviceID.length !== 16) {
    throw new ProtocolException('deviceID must be 16 bytes');
  }
  const nameBytes = encodeUtf8(hello.name);
  if (nameBytes.length > 255) {
    throw new ProtocolException('name must fit in 255 UTF-8 bytes');
  }
  const payload = new Uint8Array(32 + nameBytes.length);
  const view = new DataView(payload.buffer);
  payload[0] = hello.protoVersion;
  view.setUint16(1, hello.clientVersion);
  payload.set(hello.deviceID, 3);
  view.setUint16(19, hello.screenWidth);
  view.setUint16(21, hello.screenHeight);
  view.setUint16(23, hello.xdpi);
  view.setUint16(25, hello.ydpi);
  payload[27] = hello.maxFPS;
  payload[28] = hello.codecs;
  payload[29] = hello.features;
  payload[30] = hello.rotation;
  payload[31] = nameBytes.length;
  payload.set(nameBytes, 32);
  return encodeFrame(MessageType.HELLO, payload);
}

export function decodeSessionConfig(payload: Uint8Array): SessionConfig {
  if (payload.length < 11) {
    throw new ProtocolException('malformed session config');
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.length);
  const config = new SessionConfig();
  config.width = view.getUint16(0);
  config.height = view.getUint16(2);
  config.fps = payload[4];
  config.codec = payload[5];
  config.bitrate = view.getUint32(6);
  config.rotation = payload[10];
  config.inputCaps = payload.length >= 12 ? payload[11] : 0;
  return config;
}

export function decodeVideo(payload: Uint8Array): VideoFrame {
  if (payload.length < 18) {
    throw new ProtocolException('malformed video frame');
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.length);
  const header = new VideoHeader();
  header.codec = payload[0];
  header.flags = payload[1];
  header.frameId = view.getUint32(2);
  header.captureTsMicros = view.getUint32(6) * 4294967296 + view.getUint32(10);
  header.reserved = view.getUint32(14);
  return new VideoFrame(header, payload.slice(18));
}

export function encodePing(tsMicros: number): Uint8Array {
  const payload = new Uint8Array(8);
  const view = new DataView(payload.buffer);
  const hi = Math.floor(tsMicros / 4294967296);
  view.setUint32(0, hi);
  view.setUint32(4, tsMicros - hi * 4294967296);
  return encodeFrame(MessageType.PING, payload);
}

export function decodePing(payload: Uint8Array): number {
  if (payload.length < 8) {
    throw new ProtocolException('malformed ping');
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.length);
  return view.getUint32(0) * 4294967296 + view.getUint32(4);
}