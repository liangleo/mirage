import { describe, it, expect } from '@ohos/hypium';
import {
  ClientSession,
  SessionListener
} from '../../../main/ets/core/ClientSession';
import { Hello } from '../../../main/ets/core/Protocol';
import { CtrlCode, encodeCtrl } from '../../../main/ets/core/InputProtocol';
import { Stats } from '../../../main/ets/core/Stats';
import { Transport } from '../../../main/ets/transport/Transport';
import { TransportChoice, TransportKind } from '../../../main/ets/transport/TransportSelector';

class FakeTransport implements Transport {
  dataCb: (data: Uint8Array) => void = (data: Uint8Array) => {
  };
  closedCb: (reason: string) => void = (reason: string) => {
  };
  writes: number = 0;

  open(): Promise<void> {
    return Promise.resolve();
  }

  write(data: Uint8Array): Promise<void> {
    this.writes++;
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

class RecordingListener extends SessionListener {
  gates: boolean[] = [];
  reasons: string[] = [];

  onInputGate(enabled: boolean, reason: string): void {
    this.gates.push(enabled);
    this.reasons.push(reason);
  }
}

function tick(): Promise<void> {
  return new Promise<void>((resolve: () => void) => {
    setTimeout(() => {
      resolve();
    }, 0);
  });
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
  });
}