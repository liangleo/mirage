import { describe, it, expect } from '@ohos/hypium';
import { pickAccessoryIndex } from '../../../main/ets/transport/UsbDevice';

export default function usbDeviceTest() {
  describe('usbDevice', () => {
    it('returns -1 when list is empty', 0, () => {
      expect(pickAccessoryIndex([])).assertEqual(-1);
    });

    it('falls back to the only accessory', 0, () => {
      expect(pickAccessoryIndex([false])).assertEqual(0);
    });

    it('rejects ambiguous lists without a match', 0, () => {
      expect(pickAccessoryIndex([false, false])).assertEqual(-1);
    });

    it('picks the first mirage accessory', 0, () => {
      expect(pickAccessoryIndex([false, true, true])).assertEqual(1);
    });
  });
}