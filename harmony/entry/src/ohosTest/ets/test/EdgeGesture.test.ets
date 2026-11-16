import { describe, it, expect } from '@ohos/hypium';
import { EdgeDecision, EdgeGesture } from '../../../main/ets/input/EdgeGesture';

export default function edgeGestureTest() {
  describe('edgeGesture', () => {
    it('lets a right-edge tap through as a normal click', 0, () => {
      const gesture = new EdgeGesture();
      expect(gesture.onDown(1350, 1440)).assertEqual(EdgeDecision.PASS);
      expect(gesture.onUp()).assertEqual(EdgeDecision.PASS);
    });

    it('holds moves inside the edge strip below the swipe threshold', 0, () => {
      const gesture = new EdgeGesture();
      expect(gesture.onDown(1350, 1440)).assertEqual(EdgeDecision.PASS);
      expect(gesture.onMove(1340)).assertEqual(EdgeDecision.HOLD);
      expect(gesture.onMove(1330)).assertEqual(EdgeDecision.HOLD);
      expect(gesture.onUp()).assertEqual(EdgeDecision.PASS);
    });

    it('opens the drawer when the swipe threshold is crossed', 0, () => {
      const gesture = new EdgeGesture();
      expect(gesture.onDown(1350, 1440)).assertEqual(EdgeDecision.PASS);
      expect(gesture.onMove(1310)).assertEqual(EdgeDecision.OPEN);
      expect(gesture.onMove(1300)).assertEqual(EdgeDecision.PASS);
    });

    it('passes everything through outside the edge strip', 0, () => {
      const gesture = new EdgeGesture();
      expect(gesture.onDown(700, 1440)).assertEqual(EdgeDecision.PASS);
      expect(gesture.onMove(690)).assertEqual(EdgeDecision.PASS);
      expect(gesture.onUp()).assertEqual(EdgeDecision.PASS);
    });
  });
}