import { onUdpEvent, startUdp, stopUdp, UdpEvent } from 'libmirage.so';
import { UdpConfig, UdpFrame, UdpReceiver, UdpReceiverListener } from '../core/UdpReceiver';

export class NativeUdpReceiver implements UdpReceiver {
  private listener: UdpReceiverListener | null = null;
  private subscribed: boolean = false;

  start(host: string, config: UdpConfig, listener: UdpReceiverListener): boolean {
    this.listener = listener;
    if (!this.subscribed) {
      this.subscribed = true;
      onUdpEvent((event: UdpEvent): void => {
        this.dispatch(event);
      });
    }
    const key = config.key.buffer.slice(config.key.byteOffset,
      config.key.byteOffset + config.key.byteLength);
    const nonce = config.noncePrefix.buffer.slice(config.noncePrefix.byteOffset,
      config.noncePrefix.byteOffset + config.noncePrefix.byteLength);
    return startUdp(host, config.port, key, nonce);
  }

  stop(): void {
    this.listener = null;
    stopUdp();
  }

  private dispatch(event: UdpEvent): void {
    const listener = this.listener;
    if (listener === null) {
      return;
    }
    if (event.kind === 'udpReady') {
      listener.onReady();
      return;
    }
    if (event.kind === 'udpFailed') {
      listener.onFailed(event.reason !== undefined ? event.reason : 'udp failed');
      return;
    }
    if (event.kind === 'udpFrame' && event.data !== undefined) {
      listener.onFrame(new UdpFrame(event.frameId !== undefined ? event.frameId : 0,
        event.key === true, new Uint8Array(event.data)));
    }
  }
}
