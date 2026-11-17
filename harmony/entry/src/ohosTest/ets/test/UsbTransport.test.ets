import { describe, it, expect } from '@ohos/hypium';
import {
  shouldWaitForUsb,
  UsbBridge,
  UsbPort,
  UsbTransport
} from '../../../main/ets/transport/UsbTransport';

class FakePort implements UsbPort {
  mirage: boolean[] = [];
  right: boolean = true;
  grant: boolean = true;
  opened: number = -1;
  openCalls: number = 0;
  closed: boolean = false;
  fd: number = 7;
  request: () => Promise<boolean> = () => Promise.resolve(this.grant);

  count(): number {
    return this.mirage.length;
  }

  isMirage(index: number): boolean {
    return this.mirage[index];
  }

  hasRight(index: number): boolean {
    return this.right;
  }

  async requestRight(index: number): Promise<boolean> {
    return this.request();
  }

  open(index: number): number {
    this.openCalls += 1;
    this.opened = index;
    return this.fd;
  }

  close(): void {
    this.closed = true;
  }
}

class FakeBridge implements UsbBridge {
  startedFd: number = -1;
  stopped: boolean = false;
  written: number = 0;
  accept: boolean = true;
  emit: (kind: string, data: ArrayBuffer | null) => void = () => {
  };

  start(fd: number, onEvent: (kind: string, data: ArrayBuffer | null) => void): boolean {
    if (!this.accept) {
      return false;
    }
    this.startedFd = fd;
    this.emit = onEvent;
    return true;
  }

  stop(): void {
    this.stopped = true;
  }

  write(data: Uint8Array): number {
    this.written += data.length;
    return data.length;
  }
}

async function expectFailure(run: () => Promise<void>): Promise<string> {
  try {
    await run();
  } catch (err) {
    return (err as Error).message;
  }
  return '';
}

export default function usbTransportTest() {
  describe('usbTransport', () => {
    it('rejects when no accessory is present', 0, async () => {
      const transport = new UsbTransport(new FakePort(), new FakeBridge(), () => {
      });
      const message = await expectFailure(() => transport.open());
      expect(message.indexOf('未发现 USB 设备') >= 0).assertTrue();
    });

    it('rejects when the user denies access', 0, async () => {
      const port = new FakePort();
      port.mirage = [true];
      port.right = false;
      port.grant = false;
      let authPending = 0;
      const bridge = new FakeBridge();
      const transport = new UsbTransport(port, bridge, () => {
        authPending += 1;
      });
      const message = await expectFailure(() => transport.open());
      expect(message.indexOf('USB 权限被拒绝') >= 0).assertTrue();
      expect(authPending).assertEqual(1);
      expect(bridge.startedFd).assertEqual(-1);
    });

    it('forwards data events and closes on accessory loss', 0, async () => {
      const port = new FakePort();
      port.mirage = [true];
      const bridge = new FakeBridge();
      const transport = new UsbTransport(port, bridge, () => {
      });
      let received = -1;
      let closedReason = '';
      transport.onData((data: Uint8Array) => {
        received = data.length;
      });
      transport.onClosed((reason: string) => {
        closedReason = reason;
      });

      await transport.open();
      expect(bridge.startedFd).assertEqual(7);

      bridge.emit('data', new Uint8Array([1, 2, 3, 4]).buffer as ArrayBuffer);
      expect(received).assertEqual(4);

      bridge.emit('closed', null);
      expect(closedReason).assertEqual('USB 已断开');
      expect(port.closed).assertTrue();
      expect(bridge.stopped).assertTrue();

      bridge.emit('data', new Uint8Array([9]).buffer as ArrayBuffer);
      expect(received).assertEqual(4);
    });

    it('rejects writes before open', 0, async () => {
      const transport = new UsbTransport(new FakePort(), new FakeBridge(), () => {
      });
      const message = await expectFailure(() => transport.write(new Uint8Array([1])));
      expect(message.indexOf('USB 未连接') >= 0).assertTrue();
    });

    it('closes without notifying the session', 0, async () => {
      const port = new FakePort();
      port.mirage = [true];
      const bridge = new FakeBridge();
      const transport = new UsbTransport(port, bridge, () => {
      });
      let closedReason = '';
      transport.onClosed((reason: string) => {
        closedReason = reason;
      });

      await transport.open();
      await transport.close();
      expect(bridge.stopped).assertTrue();
      expect(port.closed).assertTrue();
      expect(closedReason).assertEqual('');
    });

    it('aborts open when closed during authorization', 0, async () => {
      const port = new FakePort();
      port.mirage = [true];
      port.right = false;
      let release: (granted: boolean) => void = () => {
      };
      port.request = () => new Promise<boolean>((resolve: (granted: boolean) => void) => {
        release = resolve;
      });
      const bridge = new FakeBridge();
      const transport = new UsbTransport(port, bridge, () => {
      });

      const opening = transport.open();
      await transport.close();
      release(true);
      const message = await expectFailure(() => opening);

      expect(message.indexOf('USB 已断开') >= 0).assertTrue();
      expect(port.openCalls).assertEqual(0);
      expect(bridge.startedFd).assertEqual(-1);
    });

    it('reports a timeout when authorization never resolves', 0, async () => {
      const port = new FakePort();
      port.mirage = [true];
      port.right = false;
      port.request = () => new Promise<boolean>(() => {
      });
      const bridge = new FakeBridge();
      const transport = new UsbTransport(port, bridge, () => {
      }, 20);

      const message = await expectFailure(() => transport.open());
      expect(message.indexOf('USB 授权超时') >= 0).assertTrue();
      expect(port.openCalls).assertEqual(0);
    });
  });

  describe('usbWaitPolicy', () => {
    it('resumes waiting only after a real disconnect', 0, () => {
      expect(shouldWaitForUsb('USB 已断开')).assertTrue();
      expect(shouldWaitForUsb('未发现 USB 设备')).assertTrue();
      expect(shouldWaitForUsb('USB 写入失败')).assertTrue();
      expect(shouldWaitForUsb('USB 权限被拒绝')).assertFalse();
      expect(shouldWaitForUsb('USB 授权超时')).assertFalse();
      expect(shouldWaitForUsb('USB 打开失败')).assertFalse();
      expect(shouldWaitForUsb('服务端断开')).assertFalse();
    });
  });
}