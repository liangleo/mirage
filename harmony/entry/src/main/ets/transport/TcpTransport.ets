import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Transport } from './Transport';

export class TcpTransport implements Transport {
  private host: string;
  private port: number;
  private sock: socket.TCPSocket | null = null;
  private dataCb: ((data: Uint8Array) => void) | null = null;
  private closedCb: ((reason: string) => void) | null = null;

  constructor(host: string, port: number) {
    this.host = host;
    this.port = port;
  }

  onData(cb: (data: Uint8Array) => void): void {
    this.dataCb = cb;
  }

  onClosed(cb: (reason: string) => void): void {
    this.closedCb = cb;
  }

  async open(): Promise<void> {
    const sock = socket.constructTCPSocketInstance();
    sock.on('message', (info: socket.SocketMessageInfo) => {
      if (this.dataCb !== null) {
        this.dataCb(new Uint8Array(info.message));
      }
    });
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
    await sock.connect({
      address: { address: this.host, port: this.port, family: 1 },
      timeout: 5000
    });
    await sock.setExtraOptions({ TCPNoDelay: true, keepAlive: true });
    this.sock = sock;
  }

  async write(data: Uint8Array): Promise<void> {
    const sock = this.sock;
    if (sock === null) {
      throw new Error('transport not connected');
    }
    const buffer = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
    await sock.send({ data: buffer });
  }

  async close(): Promise<void> {
    const sock = this.sock;
    this.sock = null;
    if (sock === null) {
      return;
    }
    sock.off('message');
    sock.off('close');
    sock.off('error');
    try {
      await sock.close();
    } catch (e) {
    }
  }
}