import { describe, it, expect } from '@ohos/hypium';
import {
  ClientSession,
  SessionListener
} from '../../../main/ets/core/ClientSession';
import { Hello, MessageType, encodeFrame } from '../../../main/ets/core/Protocol';
import { UdpConfig, UdpFrame, UdpReceiver, UdpReceiverListener } from '../../../main/ets/core/UdpReceiver';
import { CtrlCode, encodeCtrl } from '../../../main/ets/core/InputProtocol';
import { VideoFrame } from '../../../main/ets/core/Protocol';
import { Stats } from '../../../main/ets/core/Stats';
import { SessionState } from '../../../main/ets/core/SessionMachine';
import { Transport } from '../../../main/ets/transport/Transport';
import { TransportChoice, TransportKind } from '../../../main/ets/transport/TransportSelector';

class FakeTransport implements Transport {
  dataCb: (data: Uint8Array) => void = (data: Uint8Array) => {
  };
  closedCb: (reason: string) => void = (reason: string) => {
  };
  writes: number = 0;
  sent: Uint8Array[] = [];

  open(): Promise<void> {
    return Promise.resolve();
  }

  write(data: Uint8Array): Promise<void> {
    this.writes++;
    this.sent.push(data.slice());
    return Promise.resolve();
  }

  close(): Promise<void> {
    return Promise.resolve();
  }

  onData(cb: (data: Uint8Array) => void): void {
    this.dataCb = cb;
  }

  onClosed(cb: (reason: string) => void): void {
    this.closedCb = cb;
  }

  feed(frame: Uint8Array): void {
    this.dataCb(frame);
  }
}

class FakeUdp implements UdpReceiver {
  host: string = '';
  config: UdpConfig | null = null;
  listener: UdpReceiverListener | null = null;
  stopped: number = 0;

  start(host: string, config: UdpConfig, listener: UdpReceiverListener): boolean {
    this.host = host;
    this.config = config;
    this.listener = listener;
    return true;
  }

  stop(): void {
    this.stopped++;
  }
}

class RecordingListener extends SessionListener {
  gates: boolean[] = [];
  reasons: string[] = [];
  closed: string[] = [];

  onInputGate(enabled: boolean, reason: string): void {
    this.gates.push(enabled);
    this.reasons.push(reason);
  }

  onClosed(reason: string): void {
    this.closed.push(reason);
  }

  videos: number[] = [];

  onVideo(frame: VideoFrame): void {
    this.videos.push(frame.annexB.length);
  }
}

function tick(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, 0);
  });
}

function udpConfigFrame(port: number): Uint8Array {
  const payload = new Uint8Array(40);
  const view = new DataView(payload.buffer);
  view.setUint16(0, port);
  payload[2] = 1;
  for (let i = 0; i < 32; i++) {
    payload[3 + i] = i;
  }
  payload[35] = 1;
  payload[39] = 1;
  return encodeFrame(MessageType.UDP_CONFIG, payload);
}

function ctrlCodeOf(frame: Uint8Array): number {
  return frame[5];
}

export default function clientSessionTest() {
  describe('clientSessionInputGate', () => {
    it('recovers when the server re-enables after the UI disabled locally', 0, async () => {
      const transport = new FakeTransport();
      const listener = new RecordingListener();
      const session = new ClientSession(new TransportChoice(TransportKind.WIFI, '127.0.0.1', 1),
        (choice: TransportChoice): Transport => transport, new Hello(), new Stats(), listener);
      session.start();
      await tick();

      transport.feed(encodeCtrl(CtrlCode.INPUT_DISABLED, '此设备未授权控制 Mac'));
      expect(listener.gates.length).assertEqual(1);
      expect(listener.gates[0]).assertFalse();
      expect(listener.reasons[0]).assertEqual('此设备未授权控制 Mac');

      session.setInputEnabled(false);
      transport.feed(encodeCtrl(CtrlCode.INPUT_ENABLED));
      expect(listener.gates.length).assertEqual(2);
      expect(listener.gates[1]).assertTrue();
      expect(listener.reasons[1]).assertEqual('');

      session.stop();
    });

    it('stops retrying when USB access is denied', 0, async () => {
      const transport = new FakeTransport();
      const listener = new RecordingListener();
      let opens = 0;
      const session = new ClientSession(new TransportChoice(TransportKind.USB, '', 0),
        (choice: TransportChoice): Transport => {
          opens += 1;
          return transport;
        }, new Hello(), new Stats(), listener);
      session.start();
      await tick();

      transport.closedCb('USB 权限被拒绝');
      await tick();

      expect(opens).assertEqual(1);
      expect(listener.closed.length).assertEqual(1);
      expect(listener.closed[0]).assertEqual('USB 权限被拒绝');
      expect(session.getModel().state).assertEqual(SessionState.Stopped);

      session.stop();
    });

    it('stops retrying when USB authorization times out', 0, async () => {
      const transport = new FakeTransport();
      const listener = new RecordingListener();
      let opens = 0;
      const session = new ClientSession(new TransportChoice(TransportKind.USB, '', 0),
        (choice: TransportChoice): Transport => {
          opens += 1;
          return transport;
        }, new Hello(), new Stats(), listener);
      session.start();
      await tick();

      transport.closedCb('USB 授权超时');
      await tick();

      expect(opens).assertEqual(1);
      expect(listener.closed.length).assertEqual(1);
      expect(listener.closed[0]).assertEqual('USB 授权超时');
      expect(session.getModel().state).assertEqual(SessionState.Stopped);

      session.stop();
    });

    it('ends a USB session on any close instead of retrying', 0, async () => {
      const transport = new FakeTransport();
      const listener = new RecordingListener();
      let opens = 0;
      const session = new ClientSession(new TransportChoice(TransportKind.USB, '', 0),
        (choice: TransportChoice): Transport => {
          opens += 1;
          return transport;
        }, new Hello(), new Stats(), listener);
      session.start();
      await tick();

      transport.closedCb('USB 已断开');
      await tick();

      expect(opens).assertEqual(1);
      expect(listener.closed.join('|')).assertEqual('USB 已断开');
      expect(session.getModel().state).assertEqual(SessionState.Stopped);

      session.stop();
    });
  });

  describe('clientSessionUdp', () => {
    it('starts the udp receiver from a config frame and acks readiness', 0, async () => {
      const transport = new FakeTransport();
      const udp = new FakeUdp();
      const listener = new RecordingListener();
      const session = new ClientSession(new TransportChoice(TransportKind.WIFI, '192.168.10.112', 7778),
        (choice: TransportChoice): Transport => transport, new Hello(), new Stats(), listener, udp);
      session.start();
      await tick();

      transport.feed(udpConfigFrame(7778));
      expect(udp.host).assertEqual('192.168.10.112');
      expect(udp.config!.port).assertEqual(7778);

      udp.listener!.onReady();
      let codes = transport.sent.map((f: Uint8Array) => ctrlCodeOf(f));
      expect(codes.indexOf(CtrlCode.UDP_READY) >= 0).assertFalse();
      udp.listener!.onFrame(new UdpFrame(1, true, new Uint8Array(4)));
      codes = transport.sent.map((f: Uint8Array) => ctrlCodeOf(f));
      expect(codes.indexOf(CtrlCode.UDP_READY) >= 0).assertTrue();
      session.stop();
      expect(udp.stopped > 0).assertTrue();
    });

    it('delivers udp frames and ignores tcp video once active', 0, async () => {
      const transport = new FakeTransport();
      const udp = new FakeUdp();
      const listener = new RecordingListener();
      const session = new ClientSession(new TransportChoice(TransportKind.WIFI, '192.168.10.112', 7778),
        (choice: TransportChoice): Transport => transport, new Hello(), new Stats(), listener, udp);
      session.start();
      await tick();

      transport.feed(udpConfigFrame(7778));
      udp.listener!.onReady();

      udp.listener!.onFrame(new UdpFrame(7, true, new Uint8Array(9)));
      expect(listener.videos.length).assertEqual(1);
      expect(listener.videos[0]).assertEqual(9);

      // TCP 视频头：codec=1/flags=1/frameId=8
      const tcpVideo = new Uint8Array(18 + 4);
      const view = new DataView(tcpVideo.buffer);
      view.setUint8(0, 1);
      view.setUint8(1, 1);
      view.setUint32(4, 8);
      transport.feed(encodeFrame(MessageType.VIDEO, tcpVideo));
      expect(listener.videos.length).assertEqual(1);

      session.stop();
    });

    it('sends a usb request control frame when asked', 0, async () => {
      const transport = new FakeTransport();
      const listener = new RecordingListener();
      const session = new ClientSession(new TransportChoice(TransportKind.WIFI, '192.168.10.112', 7778),
        (choice: TransportChoice): Transport => transport, new Hello(), new Stats(), listener);
      session.start();
      await tick();
      session.requestUsb();
      const hasUsbRequest = transport.sent.some((f: Uint8Array) => f[5] === CtrlCode.USB_REQUEST);
      expect(hasUsbRequest).assertTrue();
      session.stop();
    });

    it('falls back to tcp video when udp reports failure', 0, async () => {
      const transport = new FakeTransport();
      const udp = new FakeUdp();
      const listener = new RecordingListener();
      const session = new ClientSession(new TransportChoice(TransportKind.WIFI, '192.168.10.112', 7778),
        (choice: TransportChoice): Transport => transport, new Hello(), new Stats(), listener, udp);
      session.start();
      await tick();

      transport.feed(udpConfigFrame(7778));
      udp.listener!.onReady();
      udp.listener!.onFailed('timeout');

      const codes = transport.sent.map((f: Uint8Array) => ctrlCodeOf(f));
      expect(codes.indexOf(CtrlCode.UDP_FAILED) >= 0).assertTrue();

      const tcpVideo = new Uint8Array(18 + 4);
      const view = new DataView(tcpVideo.buffer);
      view.setUint8(0, 1);
      view.setUint8(1, 1);
      view.setUint32(4, 9);
      transport.feed(encodeFrame(MessageType.VIDEO, tcpVideo));
      expect(listener.videos.length).assertEqual(1);

      session.stop();
    });
  });
}
