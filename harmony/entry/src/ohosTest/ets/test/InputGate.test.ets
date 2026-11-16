import { describe, it, expect } from '@ohos/hypium';
import { InputGate } from '../../../main/ets/core/InputGate';

export default function inputGateTest() {
  describe('inputGate', () => {
    it('requires connection, local and server switches', 0, () => {
      const gate = new InputGate();
      expect(gate.allow()).assertFalse();
      gate.setConnected(true);
      expect(gate.allow()).assertTrue();
      gate.setLocalEnabled(false);
      expect(gate.allow()).assertFalse();
      gate.setLocalEnabled(true);
      gate.applyCtrl(4, '输入已暂停');
      expect(gate.allow()).assertFalse();
      expect(gate.reason).assertEqual('输入已暂停');
      gate.applyCtrl(3, '');
      expect(gate.allow()).assertTrue();
      expect(gate.reason).assertEqual('');
    });

    it('release_all remains possible while input is disabled', 0, () => {
      const gate = new InputGate();
      gate.setConnected(true);
      gate.applyCtrl(4, '输入已暂停');
      expect(gate.allow()).assertFalse();
      expect(gate.allowRelease()).assertTrue();
      gate.setConnected(false);
      expect(gate.allowRelease()).assertFalse();
    });

    it('unknown ctrl codes do not change state', 0, () => {
      const gate = new InputGate();
      gate.setConnected(true);
      gate.applyCtrl(99, 'x');
      expect(gate.allow()).assertTrue();
      expect(gate.reason).assertEqual('');
    });

    it('reset keeps the local switch but clears server state', 0, () => {
      const gate = new InputGate();
      gate.setConnected(true);
      gate.setLocalEnabled(false);
      gate.applyCtrl(4, '输入已暂停');
      gate.reset();
      expect(gate.getLocalEnabled()).assertFalse();
      expect(gate.getServerEnabled()).assertTrue();
      expect(gate.reason).assertEqual('');
    });
  });
}