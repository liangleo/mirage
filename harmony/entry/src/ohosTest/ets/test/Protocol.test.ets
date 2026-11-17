import { describe, it, expect } from '@ohos/hypium';
import {
  FrameDecoder,
  MessageType,
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

    it('encodes hello with an empty name', 0, () => {
      const frame = encodeHello(new Hello());
      expect(frame.length).assertEqual(37);
      expect(frame[4]).assertEqual(MessageType.HELLO);
      expect(frame[36]).assertEqual(0);
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

    it('resyncs past a zero length header', 0, () => {
      const zero = new Uint8Array([0x00, 0x00, 0x00, 0x00, MessageType.PING]);
      const ping = encodePing(7);
      const decoder = new FrameDecoder();
      decoder.append(concat(zero, ping));
      const frame = decoder.next();
      expect(frame!.type).assertEqual(MessageType.PING);
      expect(decodePing(frame!.payload)).assertEqual(7);
      expect(decoder.skippedBytes).assertEqual(zero.length);
    });

    it('resyncs onto a frame after leading garbage', 0, () => {
      const garbage = new Uint8Array(37);
      garbage.fill(0xff);
      const ping = encodePing(1000);
      const decoder = new FrameDecoder();
      decoder.append(concat(garbage, ping));
      const frame = decoder.next();
      expect(frame!.type).assertEqual(MessageType.PING);
      expect(decodePing(frame!.payload)).assertEqual(1000);
      expect(decoder.skippedBytes).assertEqual(garbage.length);
    });

    it('skips an unknown message type', 0, () => {
      const decoder = new FrameDecoder();
      decoder.append(concat(encodeFrame(99, new Uint8Array([1, 2, 3])), encodePing(5)));
      const frame = decoder.next();
      expect(frame!.type).assertEqual(MessageType.PING);
      expect(decodePing(frame!.payload)).assertEqual(5);
      expect(decoder.next() === null).assertTrue();
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

    it('resyncs past a plausible but bogus video header', 0, () => {
      // Opening mid-frame can leave a header-shaped coincidence at byte 0 with
      // a huge length; waiting for it would starve the stream forever.
      const bogus = new Uint8Array([0x00, 0x10, 0x00, 0x00, MessageType.VIDEO, 0x7f, 0x7f]);
      const ping = encodePing(11);
      const decoder = new FrameDecoder();
      decoder.append(concat(bogus, ping));
      const frame = decoder.next();
      expect(frame!.type).assertEqual(MessageType.PING);
      expect(decodePing(frame!.payload)).assertEqual(11);
      expect(decoder.skippedBytes).assertEqual(bogus.length);
    });

    it('rejects a ping header with the wrong length', 0, () => {
      const bogus = new Uint8Array([0x00, 0x00, 0x10, 0x00, MessageType.PING, 0, 0, 0, 0]);
      const ping = encodePing(3);
      const decoder = new FrameDecoder();
      decoder.append(concat(bogus, ping));
      const frame = decoder.next();
      expect(frame!.type).assertEqual(MessageType.PING);
      expect(decodePing(frame!.payload)).assertEqual(3);
    });

    it('locks onto a large frame that starts after garbage', 0, () => {
      // Resync finds the header while the payload is still in flight; dropping
      // the header here would lose every frame bigger than one read.
      const garbage = new Uint8Array(9);
      garbage.fill(0xff);
      const payload = new Uint8Array(30);
      payload[0] = 1;
      payload[1] = 1;
      const video = encodeFrame(MessageType.VIDEO, payload);
      const decoder = new FrameDecoder();
      decoder.append(concat(garbage, video.slice(0, 10)));
      expect(decoder.next() === null).assertTrue();
      expect(decoder.pendingTotal).assertEqual(video.length);
      decoder.append(video.slice(10));
      const frame = decoder.next();
      expect(frame!.type).assertEqual(MessageType.VIDEO);
      expect(frame!.payload.length).assertEqual(video.length - 5);
      expect(decoder.pendingTotal).assertEqual(0);
    });

    it('keeps a split header across reads', 0, () => {
      const full = encodePing(42);
      const decoder = new FrameDecoder();
      decoder.append(full.slice(0, 4));
      expect(decoder.next() === null).assertTrue();
      expect(decoder.skippedBytes).assertEqual(0);
      decoder.append(full.slice(4));
      expect(decodePing(decoder.next()!.payload)).assertEqual(42);
      expect(decoder.skippedBytes).assertEqual(0);
    });
  });
}