// UDP 视频接收抽象：native 实现负责收包/解密/重组/NACK，这里只暴露
// 「完整帧 / 就绪 / 失败」三种事件，便于 ClientSession 单测注入假实现。

export class UdpFrame {
  frameId: number;
  keyFrame: boolean;
  bytes: Uint8Array;

  constructor(frameId: number, keyFrame: boolean, bytes: Uint8Array) {
    this.frameId = frameId;
    this.keyFrame = keyFrame;
    this.bytes = bytes;
  }
}

export class UdpReceiverListener {
  onReady: () => void = () => {
  };
  onFrame: (frame: UdpFrame) => void = (frame: UdpFrame) => {
  };
  onFailed: (reason: string) => void = (reason: string) => {
  };
  onKeyframeNeeded: () => void = () => {
  };
}

export class UdpConfig {
  host: string = '';
  port: number = 0;
  key: Uint8Array = new Uint8Array(0);
  noncePrefix: Uint8Array = new Uint8Array(0);
}

export interface UdpReceiver {
  start(host: string, config: UdpConfig, listener: UdpReceiverListener): boolean;

  stop(): void;
}