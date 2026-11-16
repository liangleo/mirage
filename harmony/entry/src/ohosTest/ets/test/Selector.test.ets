import { describe, it, expect } from '@ohos/hypium';
import { selectTransport, TransportKind } from '../../../main/ets/transport/TransportSelector';
import { TransportMode } from '../../../main/ets/settings/SettingsStore';

export default function selectorTest() {
  describe('transportSelector', () => {
    it('auto prefers accessory', 0, () => {
      const choice = selectTransport(TransportMode.AUTO, true, '1.2.3.4', 7778);
      expect(choice!.kind).assertEqual(TransportKind.USB);
    });

    it('auto falls back to wifi', 0, () => {
      const choice = selectTransport(TransportMode.AUTO, false, '1.2.3.4', 7778);
      expect(choice!.kind).assertEqual(TransportKind.WIFI);
      expect(choice!.host).assertEqual('1.2.3.4');
      expect(choice!.port).assertEqual(7778);
    });

    it('auto falls back to loopback tcp', 0, () => {
      const choice = selectTransport(TransportMode.AUTO, false, '', 0);
      expect(choice!.kind).assertEqual(TransportKind.TCP);
      expect(choice!.host).assertEqual('127.0.0.1');
      expect(choice!.port).assertEqual(7777);
    });

    it('usb waits when absent', 0, () => {
      const choice = selectTransport(TransportMode.USB, false, '1.2.3.4', 7778);
      expect(choice!.kind).assertEqual(TransportKind.WAIT_USB);
    });

    it('usb connects when present', 0, () => {
      const choice = selectTransport(TransportMode.USB, true, '1.2.3.4', 7778);
      expect(choice!.kind).assertEqual(TransportKind.USB);
    });

    it('wifi needs a valid address', 0, () => {
      expect(selectTransport(TransportMode.WIFI, false, '', 0)).assertNull();
      expect(selectTransport(TransportMode.WIFI, false, '1.2.3.4', 0)).assertNull();
      expect(selectTransport(TransportMode.WIFI, false, '  ', 7778)).assertNull();
    });

    it('tcp forces loopback', 0, () => {
      const choice = selectTransport(TransportMode.TCP, true, '1.2.3.4', 7778);
      expect(choice!.kind).assertEqual(TransportKind.TCP);
      expect(choice!.host).assertEqual('127.0.0.1');
      expect(choice!.port).assertEqual(7777);
    });
  });
}