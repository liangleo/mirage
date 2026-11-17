import { describe, it, expect } from '@ohos/hypium';
import { Stats } from '../../../main/ets/core/Stats';

export default function statsTest() {
  describe('stats', () => {
    it('reports no p95 before any sample', 0, () => {
      const stats = new Stats();
      expect(stats.snapshot(1000).e2eP95Ms).assertEqual(-1);
    });

    it('reports nearest-rank p95 of e2e samples', 0, () => {
      const stats = new Stats();
      for (let ms = 1; ms <= 100; ms++) {
        stats.setE2eMs(ms);
      }
      expect(stats.snapshot(1000).e2eP95Ms).assertEqual(95);
    });

    it('ignores negative samples', 0, () => {
      const stats = new Stats();
      stats.setE2eMs(-1);
      expect(stats.snapshot(1000).e2eP95Ms).assertEqual(-1);
      stats.setE2eMs(20);
      expect(stats.snapshot(1000).e2eP95Ms).assertEqual(20);
    });

    it('keeps only the recent window', 0, () => {
      const stats = new Stats();
      for (let i = 0; i < 100; i++) {
        stats.setE2eMs(200);
      }
      for (let i = 0; i < 300; i++) {
        stats.setE2eMs(10);
      }
      expect(stats.snapshot(1000).e2eP95Ms).assertEqual(10);
    });

    it('reports a one-second window for feedback', 0, () => {
      const stats = new Stats();
      for (let i = 0; i < 60; i++) {
        stats.onVideo(1000, i * 16);
      }
      stats.onVideo(1000, 1000);
      expect(stats.currentFpsX10()).assertEqual(610);
      expect(stats.currentBitrateBps()).assertEqual(488000);
    });
  });
}