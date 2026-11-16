import { describe, it, expect } from '@ohos/hypium';
import { PointerKind, ScrollFlags, ScrollPhase } from '../../../main/ets/core/InputProtocol';
import {
  GestureMapper,
  TouchAction,
  TouchFrame,
  TouchSample,
  TouchTool
} from '../../../main/ets/input/GestureMapper';

function p(id: number, x: number, y: number, tool: TouchTool = TouchTool.FINGER): TouchSample {
  return new TouchSample(id, x, y, tool);
}

export default function gestureMapperTest() {
  describe('gestureMapper', () => {
    it('short tap emits down then up with primary button', 0, () => {
      const mapper = new GestureMapper();
      expect(mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5)], 1000)).length).assertEqual(0);
      const up = mapper.onFrame(new TouchFrame(TouchAction.UP, [], 1100));
      expect(up.length).assertEqual(2);
      expect(up[0].pointer![0].kind).assertEqual(PointerKind.DOWN);
      expect(up[0].pointer![0].buttons).assertEqual(1);
      expect(up[1].pointer![0].kind).assertEqual(PointerKind.UP);
      expect(up[1].pointer![0].buttons).assertEqual(0);
      expect(up[1].pointer![0].tsMicros).assertEqual(1100000);
    });

    it('long press emits secondary click', 0, () => {
      const mapper = new GestureMapper();
      mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5)], 0));
      const up = mapper.onFrame(new TouchFrame(TouchAction.UP, [], 600));
      expect(up.length).assertEqual(2);
      expect(up[0].pointer![0].buttons).assertEqual(2);
      expect(up[1].pointer![0].buttons).assertEqual(2);
    });

    it('movement beyond slop turns into a drag', 0, () => {
      const mapper = new GestureMapper();
      mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5)], 0));
      const first = mapper.onFrame(new TouchFrame(TouchAction.MOVE, [p(0, 0.52, 0.5)], 10));
      expect(first.length).assertEqual(2);
      expect(first[0].pointer![0].kind).assertEqual(PointerKind.DOWN);
      expect(first[1].pointer![0].kind).assertEqual(PointerKind.MOVE);
      const second = mapper.onFrame(new TouchFrame(TouchAction.MOVE, [p(0, 0.55, 0.5)], 20));
      expect(second.length).assertEqual(1);
      expect(second[0].pointer![0].x).assertEqual(0.55);
      const up = mapper.onFrame(new TouchFrame(TouchAction.UP, [p(0, 0.55, 0.5)], 30));
      expect(up.length).assertEqual(1);
      expect(up[0].pointer![0].kind).assertEqual(PointerKind.UP);
    });

    it('movement inside slop is ignored', 0, () => {
      const mapper = new GestureMapper();
      mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5)], 0));
      expect(mapper.onFrame(new TouchFrame(TouchAction.MOVE, [p(0, 0.505, 0.5)], 10)).length).assertEqual(0);
    });

    it('two-finger move emits precise scroll with centroid delta', 0, () => {
      const mapper = new GestureMapper();
      mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.3, 0.5)], 0));
      const begin = mapper.onFrame(new TouchFrame(TouchAction.POINTER_DOWN,
        [p(0, 0.3, 0.5), p(1, 0.5, 0.5)], 10));
      expect(begin.length).assertEqual(1);
      expect(begin[0].scroll!.phase).assertEqual(ScrollPhase.BEGIN);
      expect(begin[0].scroll!.flags).assertEqual(ScrollFlags.PRECISE);
      const change = mapper.onFrame(new TouchFrame(TouchAction.MOVE,
        [p(0, 0.31, 0.5), p(1, 0.51, 0.5)], 20));
      expect(change.length).assertEqual(1);
      expect(change[0].scroll!.phase).assertEqual(ScrollPhase.CHANGE);
      expect(change[0].scroll!.flags).assertEqual(ScrollFlags.PRECISE);
      expect(change[0].scroll!.dy).assertEqual(0);
      expect(Math.abs(change[0].scroll!.dx - 10) < 1e-3).assertTrue();
      const end = mapper.onFrame(new TouchFrame(TouchAction.POINTER_UP, [p(0, 0.31, 0.5)], 30));
      expect(end.length).assertEqual(1);
      expect(end[0].scroll!.phase).assertEqual(ScrollPhase.END);
    });

    it('pinch emits command scroll from spread delta', 0, () => {
      const mapper = new GestureMapper();
      mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.4, 0.5)], 0));
      mapper.onFrame(new TouchFrame(TouchAction.POINTER_DOWN, [p(0, 0.4, 0.5), p(1, 0.6, 0.5)], 10));
      const change = mapper.onFrame(new TouchFrame(TouchAction.MOVE,
        [p(0, 0.39, 0.5), p(1, 0.61, 0.5)], 20));
      expect(change.length).assertEqual(1);
      expect(change[0].scroll!.flags).assertEqual(ScrollFlags.COMMAND | ScrollFlags.PRECISE);
      expect(change[0].scroll!.dx).assertEqual(0);
      expect(Math.abs(change[0].scroll!.dy - 8) < 1e-3).assertTrue();
    });

    it('three fingers cancel scrolling', 0, () => {
      const mapper = new GestureMapper();
      mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.3, 0.5)], 0));
      const event = mapper.onFrame(new TouchFrame(TouchAction.POINTER_DOWN,
        [p(0, 0.3, 0.5), p(1, 0.5, 0.5), p(2, 0.7, 0.5)], 10));
      expect(event.length).assertEqual(0);
      expect(mapper.onFrame(new TouchFrame(TouchAction.MOVE,
        [p(0, 0.4, 0.5), p(1, 0.6, 0.5), p(2, 0.8, 0.5)], 20)).length).assertEqual(0);
    });

    it('stylus presses immediately', 0, () => {
      const mapper = new GestureMapper();
      const down = mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5, TouchTool.STYLUS)], 0));
      expect(down.length).assertEqual(1);
      expect(down[0].pointer![0].kind).assertEqual(PointerKind.DOWN);
    });

    it('only stylus produces hover events', 0, () => {
      const mapper = new GestureMapper();
      expect(mapper.onFrame(new TouchFrame(TouchAction.HOVER_MOVE, [p(0, 0.5, 0.5)], 0)).length).assertEqual(0);
      const hover = mapper.onFrame(new TouchFrame(TouchAction.HOVER_MOVE,
        [p(0, 0.5, 0.5, TouchTool.STYLUS)], 10));
      expect(hover.length).assertEqual(1);
      expect(hover[0].pointer![0].kind).assertEqual(PointerKind.HOVER);
      expect(hover[0].pointer![0].buttons).assertEqual(0);
    });

    it('cancel releases an active drag', 0, () => {
      const mapper = new GestureMapper();
      mapper.onFrame(new TouchFrame(TouchAction.DOWN, [p(0, 0.5, 0.5)], 0));
      mapper.onFrame(new TouchFrame(TouchAction.MOVE, [p(0, 0.6, 0.5)], 10));
      const cancel = mapper.onFrame(new TouchFrame(TouchAction.CANCEL, [], 20));
      expect(cancel.length).assertEqual(1);
      expect(cancel[0].pointer![0].kind).assertEqual(PointerKind.CANCEL);
      expect(cancel[0].pointer![0].buttons).assertEqual(0);
    });
  });
}