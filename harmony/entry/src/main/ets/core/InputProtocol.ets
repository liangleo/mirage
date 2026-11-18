import { util } from '@kit.ArkTS';
import { encodeFrame, MessageType, ProtocolException } from './Protocol';

export enum PointerKind {
  DOWN = 1,
  MOVE = 2,
  UP = 3,
  CANCEL = 4,
  HOVER = 5
}

export const POINTER_SAMPLE_SIZE: number = 32;
export const MAX_INPUT_SAMPLES: number = 32;
export const MAX_TEXT_BYTES: number = 4096;

export class PointerSample {
  kind: PointerKind;
  pointerID: number;
  buttons: number;
  x: number;
  y: number;
  pressure: number;
  tiltX: number;
  tiltY: number;
  tsMicros: number;

  constructor(kind: PointerKind, pointerID: number, buttons: number, x: number, y: number,
    pressure: number, tiltX: number, tiltY: number, tsMicros: number) {
    this.kind = kind;
    this.pointerID = pointerID;
    this.buttons = buttons;
    this.x = x;
    this.y = y;
    this.pressure = pressure;
    this.tiltX = tiltX;
    this.tiltY = tiltY;
    this.tsMicros = tsMicros;
  }
}

export enum KeyAction {
  DOWN = 1,
  UP = 2
}

export class KeyInput {
  action: KeyAction;
  modifiers: number;
  flags: number;
  keycode: number;
  unicode: number;
  tsMicros: number;

  constructor(action: KeyAction, modifiers: number, flags: number, keycode: number, unicode: number,
    tsMicros: number) {
    this.action = action;
    this.modifiers = modifiers;
    this.flags = flags;
    this.keycode = keycode;
    this.unicode = unicode;
    this.tsMicros = tsMicros;
  }
}

export class TextInput {
  text: string;
  tsMicros: number;

  constructor(text: string, tsMicros: number) {
    this.text = text;
    this.tsMicros = tsMicros;
  }
}

export enum ScrollPhase {
  BEGIN = 1,
  CHANGE = 2,
  END = 3
}

export class ScrollFlags {
  static readonly COMMAND: number = 1;
  static readonly PRECISE: number = 2;
}

export class ScrollInput {
  phase: ScrollPhase;
  flags: number;
  dx: number;
  dy: number;
  tsMicros: number;

  constructor(phase: ScrollPhase, flags: number, dx: number, dy: number, tsMicros: number) {
    this.phase = phase;
    this.flags = flags;
    this.dx = dx;
    this.dy = dy;
    this.tsMicros = tsMicros;
  }
}

function finite(...values: number[]): boolean {
  for (const value of values) {
    if (!Number.isFinite(value)) {
      return false;
    }
  }
  return true;
}

function writeU64(view: DataView, offset: number, value: number): void {
  const hi = Math.floor(value / 4294967296);
  view.setUint32(offset, hi);
  view.setUint32(offset + 4, value - hi * 4294967296);
}

function readU64(view: DataView, offset: number): number {
  return view.getUint32(offset) * 4294967296 + view.getUint32(offset + 4);
}

export enum CtrlCode {
  REQUEST_KEYFRAME = 1,
  RELEASE_ALL = 2,
  INPUT_ENABLED = 3,
  INPUT_DISABLED = 4,
  UDP_FAILED = 5,
  UDP_READY = 6,
  USB_REQUEST = 7
}

export class CtrlMessage {
  code: number;
  reason: string;

  constructor(code: number, reason: string) {
    this.code = code;
    this.reason = reason;
  }
}

export function encodeCtrl(code: number, reason: string = ''): Uint8Array {
  if (reason.length === 0) {
    return encodeFrame(MessageType.CTRL, new Uint8Array([code]));
  }
  const bytes = new util.TextEncoder().encodeInto(reason);
  if (bytes.length > 255) {
    throw new ProtocolException('ctrl reason too long');
  }
  const payload = new Uint8Array(2 + bytes.length);
  payload[0] = code;
  payload[1] = bytes.length;
  payload.set(bytes, 2);
  return encodeFrame(MessageType.CTRL, payload);
}

export function decodeCtrl(payload: Uint8Array): CtrlMessage {
  if (payload.length < 1) {
    throw new ProtocolException('malformed ctrl');
  }
  const code = payload[0];
  if (code !== CtrlCode.INPUT_DISABLED) {
    return new CtrlMessage(code, '');
  }
  if (payload.length < 2) {
    throw new ProtocolException('malformed ctrl');
  }
  const length = payload[1];
  if (payload.length !== 2 + length) {
    throw new ProtocolException('malformed ctrl');
  }
  if (length === 0) {
    return new CtrlMessage(code, '');
  }
  return new CtrlMessage(code, util.TextDecoder.create('utf-8').decodeToString(payload.slice(2, 2 + length)));
}

export function encodePointerFrame(samples: PointerSample[]): Uint8Array {
  if (samples.length === 0 || samples.length > MAX_INPUT_SAMPLES) {
    throw new ProtocolException(`bad input count ${samples.length}`);
  }
  for (const sample of samples) {
    if (!finite(sample.x, sample.y, sample.pressure, sample.tiltX, sample.tiltY)) {
      throw new ProtocolException('non-finite pointer');
    }
  }
  const payload = new Uint8Array(2 + samples.length * POINTER_SAMPLE_SIZE);
  const view = new DataView(payload.buffer);
  view.setUint16(0, samples.length);
  for (let i = 0; i < samples.length; i++) {
    const base = 2 + i * POINTER_SAMPLE_SIZE;
    const sample = samples[i];
    payload[base] = sample.kind;
    payload[base + 1] = sample.pointerID;
    view.setUint16(base + 2, sample.buttons);
    view.setFloat32(base + 4, sample.x);
    view.setFloat32(base + 8, sample.y);
    view.setFloat32(base + 12, sample.pressure);
    view.setFloat32(base + 16, sample.tiltX);
    view.setFloat32(base + 20, sample.tiltY);
    writeU64(view, base + 24, sample.tsMicros);
  }
  return encodeFrame(MessageType.INPUT, payload);
}

export function decodePointerFrame(payload: Uint8Array): PointerSample[] {
  if (payload.length < 2) {
    throw new ProtocolException('malformed input');
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.length);
  const count = view.getUint16(0);
  if (count === 0 || count > MAX_INPUT_SAMPLES) {
    throw new ProtocolException(`bad input count ${count}`);
  }
  if (payload.length !== 2 + count * POINTER_SAMPLE_SIZE) {
    throw new ProtocolException('malformed input');
  }
  const samples: PointerSample[] = [];
  for (let i = 0; i < count; i++) {
    const base = 2 + i * POINTER_SAMPLE_SIZE;
    const kind = payload[base];
    if (kind < PointerKind.DOWN || kind > PointerKind.HOVER) {
      throw new ProtocolException('bad pointer kind');
    }
    const sample = new PointerSample(kind, payload[base + 1], view.getUint16(base + 2),
      view.getFloat32(base + 4), view.getFloat32(base + 8), view.getFloat32(base + 12),
      view.getFloat32(base + 16), view.getFloat32(base + 20), readU64(view, base + 24));
    if (!finite(sample.x, sample.y, sample.pressure, sample.tiltX, sample.tiltY)) {
      throw new ProtocolException('non-finite pointer');
    }
    samples.push(sample);
  }
  return samples;
}

export function encodeKeyFrame(key: KeyInput): Uint8Array {
  const payload = new Uint8Array(18);
  const view = new DataView(payload.buffer);
  payload[0] = key.action;
  payload[1] = key.modifiers;
  payload[2] = key.flags;
  payload[3] = 0;
  view.setUint16(4, key.keycode);
  view.setUint32(6, key.unicode);
  writeU64(view, 10, key.tsMicros);
  return encodeFrame(MessageType.KEY, payload);
}

export function decodeKeyFrame(payload: Uint8Array): KeyInput {
  if (payload.length !== 18) {
    throw new ProtocolException('malformed key');
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.length);
  const action = payload[0];
  if (action !== KeyAction.DOWN && action !== KeyAction.UP) {
    throw new ProtocolException('bad key action');
  }
  return new KeyInput(action, payload[1], payload[2], view.getUint16(4), view.getUint32(6),
    readU64(view, 10));
}

export function encodeTextFrame(text: TextInput): Uint8Array {
  if (text.text.length === 0) {
    throw new ProtocolException('bad text length 0');
  }
  const bytes = new util.TextEncoder().encodeInto(text.text);
  if (bytes.length > MAX_TEXT_BYTES) {
    throw new ProtocolException(`bad text length ${bytes.length}`);
  }
  const payload = new Uint8Array(2 + bytes.length + 8);
  const view = new DataView(payload.buffer);
  view.setUint16(0, bytes.length);
  payload.set(bytes, 2);
  writeU64(view, 2 + bytes.length, text.tsMicros);
  return encodeFrame(MessageType.TEXT, payload);
}

export function decodeTextFrame(payload: Uint8Array): TextInput {
  if (payload.length < 10) {
    throw new ProtocolException('malformed text');
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.length);
  const length = view.getUint16(0);
  if (length < 1 || length > MAX_TEXT_BYTES || payload.length !== 2 + length + 8) {
    throw new ProtocolException('malformed text');
  }
  const bytes = payload.slice(2, 2 + length);
  const text = util.TextDecoder.create('utf-8').decodeToString(bytes);
  return new TextInput(text, readU64(view, 2 + length));
}

export function encodeScrollFrame(scroll: ScrollInput): Uint8Array {
  if (!finite(scroll.dx, scroll.dy)) {
    throw new ProtocolException('non-finite scroll');
  }
  const payload = new Uint8Array(20);
  const view = new DataView(payload.buffer);
  payload[0] = scroll.phase;
  payload[1] = scroll.flags;
  view.setFloat32(4, scroll.dx);
  view.setFloat32(8, scroll.dy);
  writeU64(view, 12, scroll.tsMicros);
  return encodeFrame(MessageType.SCROLL, payload);
}

export function decodeScrollFrame(payload: Uint8Array): ScrollInput {
  if (payload.length !== 20) {
    throw new ProtocolException('malformed scroll');
  }
  const view = new DataView(payload.buffer, payload.byteOffset, payload.length);
  const phase = payload[0];
  if (phase < ScrollPhase.BEGIN || phase > ScrollPhase.END) {
    throw new ProtocolException('bad scroll phase');
  }
  const dx = view.getFloat32(4);
  const dy = view.getFloat32(8);
  if (!finite(dx, dy)) {
    throw new ProtocolException('non-finite scroll');
  }
  return new ScrollInput(phase, payload[1], dx, dy, readU64(view, 12));
}