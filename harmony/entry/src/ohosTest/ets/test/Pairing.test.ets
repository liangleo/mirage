import { describe, it, expect } from '@ohos/hypium';
import { parsePairingUrl, decodeFingerprint, fingerprintsMatch } from '../../../main/ets/net/Pairing';
import { SettingsStore, KeyValueStore, TransportMode } from '../../../main/ets/settings/SettingsStore';

const FP = 'ab'.repeat(32);
const UUID = '550e8400-e29b-41d4-a716-446655440000';

class MemoryStore implements KeyValueStore {
  private data: Map<string, string> = new Map<string, string>();
  private numbers: Map<string, number> = new Map<string, number>();

  getString(key: string): string {
    const value = this.data.get(key);
    return value === undefined ? '' : value;
  }

  getInt(key: string): number {
    const value = this.numbers.get(key);
    return value === undefined ? 0 : value;
  }

  putString(key: string, value: string): void {
    this.data.set(key, value);
  }

  putInt(key: string, value: number): void {
    this.numbers.set(key, value);
  }

  async flush(): Promise<void> {
  }
}

function toHex(bytes: Uint8Array): string {
  let out = '';
  for (const b of bytes) {
    out += b.toString(16).padStart(2, '0');
  }
  return out;
}

export default function pairingTest() {
  describe('pairing', () => {
    it('parses a valid pairing url', 0, () => {
      const payload = parsePairingUrl(
        `mirage://pair?v=1&host=192.168.1.5&port=7778&fp=${FP}&name=Mac%20Mini&id=${UUID}`);
      expect(payload === null).assertFalse();
      expect(payload!.host).assertEqual('192.168.1.5');
      expect(payload!.port).assertEqual(7778);
      expect(payload!.name).assertEqual('Mac Mini');
      expect(payload!.deviceId).assertEqual(UUID);
      expect(payload!.fingerprintHex).assertEqual(FP);
      expect(decodeFingerprint(FP)!.length).assertEqual(32);
    });

    it('defaults name to host', 0, () => {
      const payload = parsePairingUrl(`mirage://pair?v=1&host=10.0.0.2&port=7778&fp=${FP}&id=${UUID}`);
      expect(payload!.name).assertEqual('10.0.0.2');
    });

    it('rejects bad pairing urls', 0, () => {
      expect(parsePairingUrl('https://pair?host=a&port=1')).assertNull();
      expect(parsePairingUrl(null)).assertNull();
      expect(parsePairingUrl(`mirage://pair?v=2&host=a&port=1&fp=${FP}&id=${UUID}`)).assertNull();
      expect(parsePairingUrl(`mirage://pair?v=1&host=&port=1&fp=${FP}&id=${UUID}`)).assertNull();
      expect(parsePairingUrl(`mirage://pair?v=1&host=a&port=0&fp=${FP}&id=${UUID}`)).assertNull();
      expect(parsePairingUrl(`mirage://pair?v=1&host=a&port=70000&fp=${FP}&id=${UUID}`)).assertNull();
      expect(parsePairingUrl(`mirage://pair?v=1&host=a&port=1&fp=ab&id=${UUID}`)).assertNull();
      expect(parsePairingUrl(`mirage://pair?v=1&host=a&port=1&fp=${FP}&id=not-a-uuid`)).assertNull();
      expect(parsePairingUrl(`mirage://pair?v=1&host=a&port=1&fp=${FP}`)).assertNull();
    });

    it('compares fingerprints exactly', 0, () => {
      expect(fingerprintsMatch(FP, FP)).assertTrue();
      expect(fingerprintsMatch(FP, 'cd'.repeat(32))).assertFalse();
      expect(fingerprintsMatch('', FP)).assertFalse();
      expect(fingerprintsMatch(FP, '')).assertFalse();
    });
  });

  describe('settings', () => {
    it('persists pairing but starts every launch in AUTO', 0, async () => {
      const kv = new MemoryStore();
      const store = new SettingsStore(kv);
      await store.savePairing('192.168.1.9', 7778, FP);
      const loaded = new SettingsStore(kv).load();
      expect(loaded.host).assertEqual('192.168.1.9');
      expect(loaded.port).assertEqual(7778);
      expect(loaded.fingerprintHex).assertEqual(FP);
      expect(loaded.transportMode).assertEqual(TransportMode.AUTO);
    });

    it('restores the last transport mode', 0, async () => {
      const kv = new MemoryStore();
      const store = new SettingsStore(kv);
      await store.saveMode(TransportMode.WIFI);
      expect(new SettingsStore(kv).load().transportMode).assertEqual(TransportMode.WIFI);
      await store.saveMode(TransportMode.USB);
      expect(new SettingsStore(kv).load().transportMode).assertEqual(TransportMode.USB);
    });

    it('ignores an unknown stored transport mode', 0, () => {
      const kv = new MemoryStore();
      kv.putString('transportMode', 'SATELLITE');
      expect(new SettingsStore(kv).load().transportMode).assertEqual(TransportMode.AUTO);
    });

    it('persists a manually typed address', 0, async () => {
      const kv = new MemoryStore();
      const store = new SettingsStore(kv);
      await store.saveAddress('10.0.0.7', 7777);
      const loaded = new SettingsStore(kv).load();
      expect(loaded.host).assertEqual('10.0.0.7');
      expect(loaded.port).assertEqual(7777);
    });

    it('defaults to debug off and input on', 0, () => {
      const loaded = new SettingsStore(new MemoryStore()).load();
      expect(loaded.debugOn).assertFalse();
      expect(loaded.inputOn).assertTrue();
    });

    it('persists the debug and input toggles', 0, async () => {
      const kv = new MemoryStore();
      const store = new SettingsStore(kv);
      await store.saveUi(true, false);
      const loaded = new SettingsStore(kv).load();
      expect(loaded.debugOn).assertTrue();
      expect(loaded.inputOn).assertFalse();
    });

    it('generates a stable 16-byte device id', 0, async () => {
      const kv = new MemoryStore();
      const first = await new SettingsStore(kv).deviceId();
      const second = await new SettingsStore(kv).deviceId();
      expect(first.length).assertEqual(16);
      expect(toHex(first)).assertEqual(toHex(second));
      expect(kv.getString('device_id').length).assertEqual(32);
    });
  });
}