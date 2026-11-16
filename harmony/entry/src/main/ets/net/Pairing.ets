export class PairingPayload {
  host: string;
  port: number;
  fingerprintHex: string;
  name: string;
  deviceId: string;

  constructor(host: string, port: number, fingerprintHex: string, name: string, deviceId: string) {
    this.host = host;
    this.port = port;
    this.fingerprintHex = fingerprintHex;
    this.name = name;
    this.deviceId = deviceId;
  }
}

const UUID_PATTERN = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;

function safeDecode(value: string): string | null {
  try {
    return decodeURIComponent(value);
  } catch (e) {
    return null;
  }
}

export function decodeFingerprint(hex: string | null): Uint8Array | null {
  if (hex === null || hex.length !== 64) {
    return null;
  }
  const out = new Uint8Array(32);
  for (let i = 0; i < 32; i++) {
    const byte = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
    if (Number.isNaN(byte)) {
      return null;
    }
    out[i] = byte;
  }
  return out;
}

export function parsePairingUrl(url: string | null): PairingPayload | null {
  if (url === null) {
    return null;
  }
  const trimmed = url.trim();
  if (!trimmed.toLowerCase().startsWith('mirage://pair?')) {
    return null;
  }
  const query = trimmed.substring('mirage://pair?'.length);
  const values = new Map<string, string>();
  for (const pair of query.split('&')) {
    const index = pair.indexOf('=');
    if (index <= 0) {
      continue;
    }
    const key = safeDecode(pair.substring(0, index));
    const value = safeDecode(pair.substring(index + 1));
    if (key === null || value === null) {
      return null;
    }
    values.set(key, value);
  }

  if (values.get('v') !== '1') {
    return null;
  }
  const host = values.get('host');
  if (host === undefined || host.length === 0) {
    return null;
  }
  const portText = values.get('port');
  const port = portText === undefined ? NaN : Number(portText);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    return null;
  }
  const fpValue = values.get('fp');
  const fingerprintText = fpValue === undefined ? '' : fpValue;
  if (decodeFingerprint(fingerprintText) === null) {
    return null;
  }
  const deviceId = values.get('id');
  if (deviceId === undefined || !UUID_PATTERN.test(deviceId)) {
    return null;
  }
  const name = values.get('name');
  return new PairingPayload(host, port, fingerprintText, name === undefined ? host : name, deviceId);
}

export function fingerprintsMatch(advertisedHex: string, savedHex: string): boolean {
  const advertised = decodeFingerprint(advertisedHex);
  const saved = decodeFingerprint(savedHex);
  if (advertised === null || saved === null) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < 32; i++) {
    diff |= advertised[i] ^ saved[i];
  }
  return diff === 0;
}