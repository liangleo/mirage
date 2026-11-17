import { preferences } from '@kit.ArkData';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';

export enum TransportMode {
  AUTO = 'AUTO',
  USB = 'USB',
  WIFI = 'WIFI',
  TCP = 'TCP'
}

export interface KeyValueStore {
  getString(key: string): string;
  getInt(key: string): number;
  putString(key: string, value: string): void;
  putInt(key: string, value: number): void;
  flush(): Promise<void>;
}

export class Settings {
  host: string = '';
  port: number = 0;
  fingerprintHex: string = '';
  transportMode: TransportMode = TransportMode.AUTO;
}

const KEY_HOST = 'host';
const KEY_PORT = 'port';
const KEY_FINGERPRINT = 'fingerprint';
const KEY_DEVICE_ID = 'device_id';

function toHex(bytes: Uint8Array): string {
  let out = '';
  for (const b of bytes) {
    out += b.toString(16).padStart(2, '0');
  }
  return out;
}

export class SettingsStore {
  private kv: KeyValueStore;

  constructor(kv: KeyValueStore) {
    this.kv = kv;
  }

  load(): Settings {
    const settings = new Settings();
    settings.host = this.kv.getString(KEY_HOST);
    settings.port = this.kv.getInt(KEY_PORT);
    settings.fingerprintHex = this.kv.getString(KEY_FINGERPRINT);
    // 传输方式每次启动都回到 AUTO：上次选的 USB 存下来后，掉线就再也回不到自动降级。
    return settings;
  }

  async savePairing(host: string, port: number, fingerprintHex: string): Promise<void> {
    this.kv.putString(KEY_HOST, host);
    this.kv.putInt(KEY_PORT, port);
    this.kv.putString(KEY_FINGERPRINT, fingerprintHex);
    await this.kv.flush();
  }

  async deviceId(): Promise<Uint8Array> {
    const stored = this.kv.getString(KEY_DEVICE_ID);
    if (stored.length === 32) {
      const bytes = new Uint8Array(16);
      let valid = true;
      for (let i = 0; i < 16; i++) {
        const byte = parseInt(stored.substring(i * 2, i * 2 + 2), 16);
        if (Number.isNaN(byte)) {
          valid = false;
          break;
        }
        bytes[i] = byte;
      }
      if (valid) {
        return bytes;
      }
    }
    const id = cryptoFramework.createRandom().generateRandomSync(16).data;
    this.kv.putString(KEY_DEVICE_ID, toHex(id));
    await this.kv.flush();
    return id;
  }
}

export class PreferencesKeyValueStore implements KeyValueStore {
  private prefs: preferences.Preferences;

  constructor(prefs: preferences.Preferences) {
    this.prefs = prefs;
  }

  getString(key: string): string {
    return this.prefs.getSync(key, '') as string;
  }

  getInt(key: string): number {
    return this.prefs.getSync(key, 0) as number;
  }

  putString(key: string, value: string): void {
    this.prefs.putSync(key, value);
  }

  putInt(key: string, value: number): void {
    this.prefs.putSync(key, value);
  }

  async flush(): Promise<void> {
    await this.prefs.flush();
  }
}