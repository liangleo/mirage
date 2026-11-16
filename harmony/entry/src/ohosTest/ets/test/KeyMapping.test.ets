import { describe, it, expect } from '@ohos/hypium';
import {
  androidKeycode,
  InputModifiers,
  isModifierKey,
  ModifierTracker,
  unicodeFor
} from '../../../main/ets/input/KeyMapping';

export default function keyMappingTest() {
  describe('keyMapping', () => {
    it('maps harmony keycodes to android keycodes', 0, () => {
      expect(androidKeycode(2017)).assertEqual(29);
      expect(androidKeycode(2042)).assertEqual(54);
      expect(androidKeycode(2000)).assertEqual(7);
      expect(androidKeycode(2009)).assertEqual(16);
      expect(androidKeycode(2043)).assertEqual(55);
      expect(androidKeycode(2054)).assertEqual(66);
      expect(androidKeycode(2055)).assertEqual(67);
      expect(androidKeycode(2012)).assertEqual(19);
      expect(androidKeycode(2072)).assertEqual(113);
      expect(androidKeycode(2090)).assertEqual(131);
      expect(androidKeycode(2101)).assertEqual(142);
      expect(androidKeycode(9999)).assertEqual(0);
    });

    it('derives unicode from android keycode and modifiers', 0, () => {
      expect(unicodeFor(29, 0)).assertEqual(97);
      expect(unicodeFor(29, InputModifiers.SHIFT)).assertEqual(65);
      expect(unicodeFor(29, InputModifiers.CAPS_LOCK)).assertEqual(65);
      expect(unicodeFor(29, InputModifiers.SHIFT | InputModifiers.CAPS_LOCK)).assertEqual(97);
      expect(unicodeFor(7, InputModifiers.SHIFT)).assertEqual(41);
      expect(unicodeFor(8, InputModifiers.SHIFT)).assertEqual(33);
      expect(unicodeFor(16, 0)).assertEqual(57);
      expect(unicodeFor(69, 0)).assertEqual(45);
      expect(unicodeFor(70, InputModifiers.SHIFT)).assertEqual(43);
      expect(unicodeFor(62, 0)).assertEqual(32);
      expect(unicodeFor(66, 0)).assertEqual(0);
    });

    it('tracks modifiers and caps lock across events', 0, () => {
      const tracker = new ModifierTracker();
      expect(tracker.update(2047, true)).assertEqual(InputModifiers.SHIFT);
      expect(tracker.update(2072, true)).assertEqual(InputModifiers.SHIFT | InputModifiers.CONTROL);
      expect(tracker.update(2047, false)).assertEqual(InputModifiers.CONTROL);
      expect(tracker.update(2074, true)).assertEqual(InputModifiers.CONTROL | InputModifiers.CAPS_LOCK);
      expect(tracker.update(2074, true)).assertEqual(InputModifiers.CONTROL | InputModifiers.CAPS_LOCK);
      expect(tracker.update(2074, false)).assertEqual(InputModifiers.CONTROL | InputModifiers.CAPS_LOCK);
      expect(tracker.update(2074, true)).assertEqual(InputModifiers.CONTROL);
      expect(tracker.update(9999, true)).assertEqual(InputModifiers.CONTROL);
      tracker.reset();
      expect(tracker.update(9999, true)).assertEqual(0);
    });

    it('does not go negative on unmatched releases', 0, () => {
      const tracker = new ModifierTracker();
      expect(tracker.update(2047, false)).assertEqual(0);
      expect(tracker.update(2047, true)).assertEqual(InputModifiers.SHIFT);
      expect(tracker.update(2048, true)).assertEqual(InputModifiers.SHIFT);
      expect(tracker.update(2047, false)).assertEqual(InputModifiers.SHIFT);
      expect(tracker.update(2048, false)).assertEqual(0);
    });

    it('recognises android modifier keycodes so their release is forwarded', 0, () => {
      expect(isModifierKey(59)).assertTrue();
      expect(isModifierKey(60)).assertTrue();
      expect(isModifierKey(57)).assertTrue();
      expect(isModifierKey(58)).assertTrue();
      expect(isModifierKey(113)).assertTrue();
      expect(isModifierKey(114)).assertTrue();
      expect(isModifierKey(117)).assertTrue();
      expect(isModifierKey(118)).assertTrue();
      expect(isModifierKey(115)).assertTrue();
      expect(isModifierKey(29)).assertFalse();
      expect(isModifierKey(67)).assertFalse();
    });
  });
}