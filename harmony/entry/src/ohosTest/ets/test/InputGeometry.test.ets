import { describe, it, expect } from '@ohos/hypium';
import {
  ContentRect,
  fitContent,
  isEdgeStart,
  isEdgeSwipe,
  normalizePoint,
  Point
} from '../../../main/ets/input/InputGeometry';

export default function inputGeometryTest() {
  describe('inputGeometry', () => {
    it('fits video into container preserving aspect ratio', 0, () => {
      const a = fitContent(1000, 1000, 16, 9);
      expect(a.width).assertEqual(1000);
      expect(a.height).assertEqual(562);
      const b = fitContent(1000, 500, 4, 3);
      expect(b.width).assertEqual(666);
      expect(b.height).assertEqual(500);
      const none = fitContent(0, 500, 16, 9);
      expect(none.width).assertEqual(0);
      expect(none.height).assertEqual(0);
    });

    it('treats invalid video size as 16 by 9', 0, () => {
      const rect = fitContent(1600, 900, 0, 0);
      expect(rect.width).assertEqual(1600);
      expect(rect.height).assertEqual(900);
    });

    it('normalizes and clamps touch coordinates', 0, () => {
      const p: Point = normalizePoint(150, 250, 300, 500);
      expect(p.x).assertEqual(0.5);
      expect(p.y).assertEqual(0.5);
      const low = normalizePoint(-10, 600, 300, 500);
      expect(low.x).assertEqual(0);
      expect(low.y).assertEqual(1);
      const empty = normalizePoint(10, 10, 0, 0);
      expect(empty.x).assertEqual(0);
      expect(empty.y).assertEqual(0);
    });

    it('classifies right-edge swipe without eating inner taps', 0, () => {
      expect(isEdgeStart(870, 1000)).assertTrue();
      expect(isEdgeStart(800, 1000)).assertFalse();
      expect(isEdgeSwipe(900, 1000, 850)).assertTrue();
      expect(isEdgeSwipe(900, 1000, 880)).assertFalse();
      expect(isEdgeSwipe(800, 1000, 700)).assertFalse();
      expect(isEdgeSwipe(900, 1000, 870)).assertFalse();
    });

    it('ignores edge checks for degenerate widths', 0, () => {
      expect(isEdgeStart(10, 0)).assertFalse();
      expect(isEdgeSwipe(10, 0, -50)).assertFalse();
      const rect: ContentRect = new ContentRect();
      expect(rect.width).assertEqual(0);
    });
  });
}