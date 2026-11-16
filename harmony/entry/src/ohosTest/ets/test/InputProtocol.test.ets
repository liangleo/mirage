import { describe, it, expect } from '@ohos/hypium';
import { FrameDecoder, MessageType, ProtocolException } from '../../../main/ets/core/Protocol';
import {
  CtrlCode,
  decodeCtrl,
  decodeKeyFrame,
  decodePointerFrame,
  decodeScrollFrame,
  decodeTextFrame,
  encodeCtrl,
  encodeKeyFrame,
  encodePointerFrame,
  encodeScrollFrame,
  encodeTextFrame,
  KeyAction,
  PointerKind,
  ScrollFlags,
  ScrollPhase,
  TextInput
} from '../../../main/ets/core/InputProtocol';

const VECTOR_INPUT =
  '000000430400020100000142c90000434840003f4ccccd3dcccccdbe4ccccd00000019debd01c70200000142cb0000434940003f333333000000000000000000000019debd061e';
const VECTOR_KEY = '000000130901090000001d0000006100007048860ddf79';
const VECTOR_TEXT = '000000140a0009e4bda0e5a5bd61626300000034005f7a85';
const VECTOR_SCROLL = '000000150b010200003fc00000c0100000000000e891bf9908';

function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function toHex(bytes: Uint8Array): string {
  let out = '';
  for (const b of bytes) {
    out += b.toString(16).padStart(2, '0');
  }
  return out;
}

function payloadOf(hex: string, type: number): Uint8Array {
  const decoder = new FrameDecoder();
  decoder.append(hexToBytes(hex));
  const frame = decoder.next()!;
  expect(frame.type).assertEqual(type);
  return frame.payload;
}

export default function inputProtocolTest() {
  describe('inputProtocol', () => {
    it('decodes and re-encodes pointer samples from vectors', 0, () => {
      const samples = decodePointerFrame(payloadOf(VECTOR_INPUT, MessageType.INPUT));
      expect(samples.length).assertEqual(2);
      expect(samples[0].kind).assertEqual(PointerKind.DOWN);
      expect(samples[0].pointerID).assertEqual(0);
      expect(samples[0].buttons).assertEqual(1);
      expect(Math.abs(samples[0].x - 100.5) < 1e-5).assertTrue();
      expect(Math.abs(samples[0].y - 200.25) < 1e-5).assertTrue();
      expect(Math.abs(samples[0].pressure - 0.8) < 1e-5).assertTrue();
      expect(Math.abs(samples[0].tiltX - 0.1) < 1e-5).assertTrue();
      expect(Math.abs(samples[0].tiltY + 0.2) < 1e-5).assertTrue();
      expect(samples[0].tsMicros).assertEqual(111111111111);
      expect(samples[1].kind).assertEqual(PointerKind.MOVE);
      expect(samples[1].tsMicros).assertEqual(111111112222);
      expect(toHex(encodePointerFrame(samples))).assertEqual(VECTOR_INPUT);
    });

    it('rejects bad pointer counts', 0, () => {
      let zero = false;
      try {
        decodePointerFrame(new Uint8Array([0, 0]));
      } catch (e) {
        zero = e instanceof ProtocolException;
      }
      expect(zero).assertTrue();

      let extra = false;
      try {
        decodePointerFrame(new Uint8Array([0, 1, 1, 0, 0, 1]));
      } catch (e) {
        extra = e instanceof ProtocolException;
      }
      expect(extra).assertTrue();
    });

    it('decodes and re-encodes key events from vectors', 0, () => {
      const key = decodeKeyFrame(payloadOf(VECTOR_KEY, MessageType.KEY));
      expect(key.action).assertEqual(KeyAction.DOWN);
      expect(key.modifiers).assertEqual(9);
      expect(key.flags).assertEqual(0);
      expect(key.keycode).assertEqual(29);
      expect(key.unicode).assertEqual(97);
      expect(key.tsMicros).assertEqual(123456789012345);
      expect(toHex(encodeKeyFrame(key))).assertEqual(VECTOR_KEY);
    });

    it('decodes and re-encodes text from vectors', 0, () => {
      const text = decodeTextFrame(payloadOf(VECTOR_TEXT, MessageType.TEXT));
      expect(text.text).assertEqual('你好abc');
      expect(text.tsMicros).assertEqual(223344556677);
      expect(toHex(encodeTextFrame(text))).assertEqual(VECTOR_TEXT);
    });

    it('rejects empty and oversized text', 0, () => {
      let empty = false;
      try {
        encodeTextFrame(new TextInput('', 1));
      } catch (e) {
        empty = e instanceof ProtocolException;
      }
      expect(empty).assertTrue();

      let oversized = false;
      let big = '';
      for (let i = 0; i < 4097; i++) {
        big += 'a';
      }
      try {
        encodeTextFrame(new TextInput(big, 1));
      } catch (e) {
        oversized = e instanceof ProtocolException;
      }
      expect(oversized).assertTrue();
    });

    it('decodes and re-encodes scroll from vectors', 0, () => {
      const scroll = decodeScrollFrame(payloadOf(VECTOR_SCROLL, MessageType.SCROLL));
      expect(scroll.phase).assertEqual(ScrollPhase.BEGIN);
      expect(scroll.flags).assertEqual(ScrollFlags.PRECISE);
      expect(Math.abs(scroll.dx - 1.5) < 1e-5).assertTrue();
      expect(Math.abs(scroll.dy + 2.25) < 1e-5).assertTrue();
      expect(scroll.tsMicros).assertEqual(998877665544);
      expect(toHex(encodeScrollFrame(scroll))).assertEqual(VECTOR_SCROLL);
    });

    it('encodes and decodes ctrl messages', 0, () => {
      expect(toHex(encodeCtrl(CtrlCode.RELEASE_ALL))).assertEqual('000000020602');
      const payload = encodeCtrl(CtrlCode.INPUT_DISABLED, '输入已暂停').slice(5);
      const decoded = decodeCtrl(payload);
      expect(decoded.code).assertEqual(CtrlCode.INPUT_DISABLED);
      expect(decoded.reason).assertEqual('输入已暂停');
      const unknown = decodeCtrl(new Uint8Array([99, 1, 2]));
      expect(unknown.code).assertEqual(99);
      expect(unknown.reason).assertEqual('');
    });

    it('rejects truncated ctrl reasons', 0, () => {
      let rejected = false;
      try {
        decodeCtrl(new Uint8Array([4, 10, 1, 2]));
      } catch (e) {
        rejected = e instanceof ProtocolException;
      }
      expect(rejected).assertTrue();
    });
  });
}