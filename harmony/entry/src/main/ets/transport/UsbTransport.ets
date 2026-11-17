import { usbManager } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { startUsb, stopUsb, usbWrite } from 'libmirage.so';
import { Transport } from './Transport';
import { pickAccessoryIndex } from './UsbDevice';

const DOMAIN = 0x0200;
const TAG = 'MirageUsb';
const AUTH_TIMEOUT_MS = 60000;

const AUTH_GRANTED = 1;
const AUTH_DENIED = 0;
const AUTH_TIMEOUT = -1;

export interface UsbPort {
  count(): number;
  isMirage(index: number): boolean;
  hasRight(index: number): boolean;
  requestRight(index: number): Promise<boolean>;
  open(index: number): number;
  close(): void;
}

export interface UsbBridge {
  start(fd: number, onEvent: (kind: string, data: ArrayBuffer | null) => void): boolean;
  stop(): void;
  write(data: Uint8Array): number;
}

export function isMirageAccessory(accessory: usbManager.USBAccessory): boolean {
  return accessory.manufacturer === 'Mirage' || accessory.product === 'Mirage Display';
}

export function hasUsbAccessory(port: UsbPort): boolean {
  const matches: boolean[] = [];
  for (let i = 0; i < port.count(); i++) {
    matches.push(port.isMirage(i));
  }
  return pickAccessoryIndex(matches) >= 0;
}

// 只有真正掉线才值得重新插线等待；授权被拒/超时、打开失败重试只会反复弹窗或必然失败。
// 写入失败通常是 Mac 桥正在重启，等它几秒就能连上。
export function shouldWaitForUsb(reason: string): boolean {
  return reason === 'USB 已断开' || reason === '未发现 USB 设备' || reason === 'USB 写入失败';
}

export class SystemUsbPort implements UsbPort {
  private accessories: usbManager.USBAccessory[] = [];
  private handle: usbManager.USBAccessoryHandle | null = null;

  constructor() {
    try {
      this.accessories = usbManager.getAccessoryList();
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'accessory list failed: %{public}s', (err as Error).message);
    }
  }

  count(): number {
    return this.accessories.length;
  }

  isMirage(index: number): boolean {
    return isMirageAccessory(this.accessories[index]);
  }

  hasRight(index: number): boolean {
    return usbManager.hasAccessoryRight(this.accessories[index]);
  }

  async requestRight(index: number): Promise<boolean> {
    return usbManager.requestAccessoryRight(this.accessories[index]);
  }

  open(index: number): number {
    const handle = usbManager.openAccessory(this.accessories[index]);
    this.handle = handle;
    return handle.accessoryFd;
  }

  close(): void {
    const handle = this.handle;
    this.handle = null;
    if (handle === null) {
      return;
    }
    try {
      hilog.info(DOMAIN, TAG, 'closeAccessory begin');
      usbManager.closeAccessory(handle);
      hilog.info(DOMAIN, TAG, 'closeAccessory end');
    } catch (err) {
      hilog.warn(DOMAIN, TAG, 'close accessory failed: %{public}s', (err as Error).message);
    }
  }
}

class NativeUsbBridge implements UsbBridge {
  start(fd: number, onEvent: (kind: string, data: ArrayBuffer | null) => void): boolean {
    return startUsb(fd, onEvent);
  }

  stop(): void {
    stopUsb();
  }

  write(data: Uint8Array): number {
    return usbWrite(data);
  }
}

export function systemUsbBridge(): UsbBridge {
  return new NativeUsbBridge();
}

export class UsbTransport implements Transport {
  private port: UsbPort;
  private bridge: UsbBridge;
  private onAuthPending: () => void;
  private authTimeoutMs: number;
  private dataCb: ((data: Uint8Array) => void) | null = null;
  private closedCb: ((reason: string) => void) | null = null;
  private opened: boolean = false;
  private closed: boolean = false;

  constructor(port: UsbPort, bridge: UsbBridge, onAuthPending: () => void,
    authTimeoutMs: number = AUTH_TIMEOUT_MS) {
    this.port = port;
    this.bridge = bridge;
    this.onAuthPending = onAuthPending;
    this.authTimeoutMs = authTimeoutMs;
  }

  onData(cb: (data: Uint8Array) => void): void {
    this.dataCb = cb;
  }

  onClosed(cb: (reason: string) => void): void {
    this.closedCb = cb;
  }

  async open(): Promise<void> {
    const matches: boolean[] = [];
    for (let i = 0; i < this.port.count(); i++) {
      matches.push(this.port.isMirage(i));
    }
    const index = pickAccessoryIndex(matches);
    if (index < 0) {
      throw new Error('未发现 USB 设备');
    }
    if (!this.port.hasRight(index)) {
      this.onAuthPending();
      const auth = await this.requestWithTimeout(index);
      if (this.closed) {
        throw new Error('USB 已断开');
      }
      if (auth === AUTH_TIMEOUT) {
        throw new Error('USB 授权超时');
      }
      if (auth !== AUTH_GRANTED) {
        throw new Error('USB 权限被拒绝');
      }
    }
    if (this.closed) {
      throw new Error('USB 已断开');
    }
    const fd = this.port.open(index);
    const started = this.bridge.start(fd, (kind: string, data: ArrayBuffer | null) => {
      this.onBridgeEvent(kind, data);
    });
    if (!started) {
      this.port.close();
      throw new Error('USB 打开失败');
    }
    this.opened = true;
  }

  async write(data: Uint8Array): Promise<void> {
    if (!this.opened || this.closed) {
      throw new Error('USB 未连接');
    }
    const written = this.bridge.write(data);
    if (written !== data.length) {
      throw new Error('USB 写入失败');
    }
  }

  async close(): Promise<void> {
    this.finish('', false);
  }

  private requestWithTimeout(index: number): Promise<number> {
    return new Promise<number>((resolve: (result: number) => void) => {
      let done = false;
      const timer = setTimeout(() => {
        if (!done) {
          done = true;
          resolve(AUTH_TIMEOUT);
        }
      }, this.authTimeoutMs);
      this.port.requestRight(index).then((granted: boolean) => {
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(granted ? AUTH_GRANTED : AUTH_DENIED);
        }
      }).catch((err: Error) => {
        hilog.warn(DOMAIN, TAG, 'request accessory right failed: %{public}s', err.message);
        if (!done) {
          done = true;
          clearTimeout(timer);
          resolve(AUTH_DENIED);
        }
      });
    });
  }

  private onBridgeEvent(kind: string, data: ArrayBuffer | null): void {
    if (this.closed) {
      return;
    }
    if (kind === 'data' && data !== null) {
      if (this.dataCb !== null) {
        this.dataCb(new Uint8Array(data));
      }
    } else if (kind === 'closed') {
      this.finish('USB 已断开', true);
    }
  }

  private finish(reason: string, notify: boolean): void {
    if (this.closed) {
      return;
    }
    this.closed = true;
    this.opened = false;
    hilog.info(DOMAIN, TAG, 'finish: stopping bridge');
    this.bridge.stop();
    hilog.info(DOMAIN, TAG, 'finish: closing port');
    this.port.close();
    hilog.info(DOMAIN, TAG, 'finish: done');
    if (notify && reason.length > 0 && this.closedCb !== null) {
      this.closedCb(reason);
    }
  }
}