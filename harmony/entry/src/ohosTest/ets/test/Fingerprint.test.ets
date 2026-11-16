import { describe, it, expect } from '@ohos/hypium';
import { sha256Hex } from '../../../main/ets/transport/TlsTransport';

export default function fingerprintTest() {
  describe('fingerprint', () => {
    it('sha256 matches known vector', 0, async () => {
      const hash = await sha256Hex(new Uint8Array([0x61, 0x62, 0x63]));
      expect(hash).assertEqual('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    });

    it('sha256 hashes binary data', 0, async () => {
      const hash = await sha256Hex(new Uint8Array([0x00, 0xff, 0x10, 0x20]));
      expect(hash).assertEqual('4033e6f229164922f1600f00a2dacd22e9b9bbdad58f82dd95095b0bb648eb83');
    });
  });
}