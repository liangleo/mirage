import { describe, it, expect } from '@ohos/hypium';

export default function harnessTest() {
  describe('harness', () => {
    it('runs', 0, () => {
      expect(1 + 1).assertEqual(2);
    });
  });
}