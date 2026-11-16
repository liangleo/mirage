import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { Transport } from './Transport';
import { decodeFingerprint } from '../net/Pairing';

export async function sha256Bytes(data: Uint8Array): Promise<Uint8Array> {
  const md = cryptoFramework.createMd('SHA256');
  await md.update({ data: data });
  const digest = await md.digest();
  return digest.data;
}

export async function sha256Hex(data: Uint8Array): Promise<string> {
  const bytes = await sha256Bytes(data);
  let out = '';
  for (const b of bytes) {
    out += b.toString(16).padStart(2, '0');
  }
  return out;
}

function fingerprintEquals(actual: Uint8Array, expectedHex: string): boolean {
  const expected = decodeFingerprint(expectedHex);
  if (expected === null || actual.length !== expected.length) {
    return false;
  }
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= actual[i] ^ expected[i];
  }
  return diff === 0;
}

export class TlsTransport implements Transport {
  private host: string;
  private port: number;
  private fingerprintHex: string;
  private sock: socket.TLSSocket | null = null;
  private dataCb: ((data: Uint8Array) => void) | null = null;
  private closedCb: ((reason: string) => void) | null = null;

  constructor(host: string, port: number, fingerprintHex: string) {
    this.host = host;
    this.port = port;
    this.fingerprintHex = fingerprintHex;
  }

  onData(cb: (data: Uint8Array) => void): void {
    this.dataCb = cb;
  }

  onClosed(cb: (reason: string) => void): void {
    this.closedCb = cb;
  }

  async open(): Promise<void> {
    const sock = socket.constructTLSSocketInstance();
    sock.on('close', () => {
      if (this.closedCb !== null) {
        this.closedCb('连接已关闭');
      }
    });
    sock.on('error', (err: BusinessError) => {
      if (this.closedCb !== null) {
        this.closedCb(`网络错误 ${err.code}`);
      }
    });
    await sock.bind({ address: '0.0.0.0', port: 0, family: 1 });
    await sock.connect({
      address: { address: this.host, port: this.port, family: 1 },
      secureOptions: { protocols: [socket.Protocol.TLSv12, socket.Protocol.TLSv13] },
      skipRemoteValidation: true,
      timeout: 5000
    });

    let certificate: Uint8Array | null = null;
    try {
      const raw = await sock.getRemoteCertificate();
      certificate = raw.data;
    } catch (e) {
      certificate = null;
    }
    if (certificate === null) {
      await this.teardown(sock);
      throw new Error('无法获取服务器证书');
    }
    const actual = await sha256Bytes(certificate);
    if (!fingerprintEquals(actual, this.fingerprintHex)) {
      await this.teardown(sock);
      throw new Error('证书指纹不匹配');
    }
    // 必须在 connect 成功后再注册 message，提前注册收不到任何入站数据（HarmonyOS 7.0 实测）
    sock.on('message', (info: socket.SocketMessageInfo) => {
      if (this.dataCb !== null) {
        this.dataCb(new Uint8Array(info.message));
      }
    });
    this.sock = sock;
  }

  async write(data: Uint8Array): Promise<void> {
    const sock = this.sock;
    if (sock === null) {
      throw new Error('transport not connected');
    }
    const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    await sock.send(buffer);
  }

  async close(): Promise<void> {
    const sock = this.sock;
    this.sock = null;
    if (sock !== null) {
      await this.teardown(sock);
    }
  }

  private async teardown(sock: socket.TLSSocket): Promise<void> {
    sock.off('message');
    sock.off('close');
    sock.off('error');
    try {
      await sock.close();
    } catch (e) {
    }
  }
}