import { describe, it, expect } from '@ohos/hypium';
import {
  FrameDecoder,
  MessageType,
  ProtocolException,
  Hello,
  encodeHello,
  encodePing,
  decodePing,
  decodeSessionConfig,
  decodeVideo,
  encodeFrame
} from '../../../main/ets/core/Protocol';

const VECTOR_HELLO =
  '0000002701010001000102030405060708090a0b0c0d0e0f0a00064000f000f03c010000064d6972616765';
const VECTOR_SESSION_CONFIG = '0000000d020b4007803c010100902d0000';
const VECTOR_VIDEO_HEADER = '0301010000000100000000000003e800000000';
const VECTOR_VIDEO_PAYLOAD = 'deadbeef';

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

function concat(a: Uint8Array, b: Uint8Array): Uint8Array {
  const out = new Uint8Array(a.length + b.length);
  out.set(a, 0);
  out.set(b, a.length);
  return out;
}

export default function protocolTest() {
  describe('protocol', () => {
    it('encodes hello from vectors', 0, () => {
      const hello = new Hello();
      hello.protoVersion = 1;
      hello.clientVersion = 1;
      hello.deviceID = new Uint8Array([0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]);
      hello.screenWidth = 2560;
      hello.screenHeight = 1600;
      hello.xdpi = 240;
      hello.ydpi = 240;
      hello.maxFPS = 60;
      hello.codecs = 1;
      hello.features = 0;
      hello.rotation = 0;
      hello.name = 'Mirage';
      expect(toHex(encodeHello(hello))).assertEqual(VECTOR_HELLO);
    });

    it('decodes session config from vectors', 0, () => {
      const decoder = new FrameDecoder();
      decoder.append(hexToBytes(VECTOR_SESSION_CONFIG));
      const frame = decoder.next();
      expect(frame!.type).assertEqual(MessageType.SESSION_CONFIG);
      const config = decodeSessionConfig(frame!.payload);
      expect(config.width).assertEqual(2880);
      expect(config.height).assertEqual(1920);
      expect(config.fps).assertEqual(60);
      expect(config.codec).assertEqual(1);
      expect(config.bitrate).assertEqual(16814125);
      expect(config.rotation).assertEqual(0);
      expect(config.inputCaps).assertEqual(0);
    });

    it('assembles a frame split across reads', 0, () => {
      const full = encodePing(1000);
      const decoder = new FrameDecoder();
      decoder.append(full.slice(0, 3));
      expect(decoder.next() === null).assertTrue();
      decoder.append(full.slice(3));
      const frame = decoder.next();
      expect(frame!.type).assertEqual(MessageType.PING);
      expect(decodePing(frame!.payload)).assertEqual(1000);
    });

    it('returns two frames from one read', 0, () => {
      const decoder = new FrameDecoder();
      decoder.append(concat(encodePing(1), encodePing(2)));
      expect(decodePing(decoder.next()!.payload)).assertEqual(1);
      expect(decodePing(decoder.next()!.payload)).assertEqual(2);
      expect(decoder.next() === null).assertTrue();
    });

    it('rejects oversized and zero length', 0, () => {
      let oversized = false;
      try {
        const decoder = new FrameDecoder();
        decoder.append(new Uint8Array([0x02, 0x00, 0x00, 0x01, MessageType.PING]));
        decoder.next();
      } catch (e) {
        oversized = e instanceof ProtocolException;
      }
      expect(oversized).assertTrue();

      let zero = false;
      try {
        const decoder = new FrameDecoder();
        decoder.append(new Uint8Array([0x00, 0x00, 0x00, 0x00, MessageType.PING]));
        decoder.next();
      } catch (e) {
        zero = e instanceof ProtocolException;
      }
      expect(zero).assertTrue();
    });

    it('decodes video header and annex-b payload', 0, () => {
      const full = concat(hexToBytes('00000017' + VECTOR_VIDEO_HEADER), hexToBytes(VECTOR_VIDEO_PAYLOAD));
      const decoder = new FrameDecoder();
      decoder.append(full);
      const frame = decoder.next();
      expect(frame!.type).assertEqual(MessageType.VIDEO);
      const video = decodeVideo(frame!.payload);
      expect(video.header.codec).assertEqual(1);
      expect(video.header.flags).assertEqual(1);
      expect(video.header.frameId).assertEqual(1);
      expect(video.header.captureTsMicros).assertEqual(1000);
      expect(video.header.reserved).assertEqual(0);
      expect(toHex(video.annexB)).assertEqual(VECTOR_VIDEO_PAYLOAD);
    });

    it('ignores unknown message types at frame level', 0, () => {
      const decoder = new FrameDecoder();
      decoder.append(encodeFrame(99, new Uint8Array([1, 2, 3])));
      const frame = decoder.next();
      expect(frame!.type).assertEqual(99);
      expect(frame!.payload.length).assertEqual(3);
    });
  });
}