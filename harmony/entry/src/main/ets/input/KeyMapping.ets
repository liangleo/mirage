export class InputModifiers {
  static readonly SHIFT: number = 1;
  static readonly CONTROL: number = 2;
  static readonly OPTION: number = 4;
  static readonly COMMAND: number = 8;
  static readonly CAPS_LOCK: number = 16;
  static readonly FN: number = 32;
}

const KEY_SHIFT_LEFT: number = 2047;
const KEY_SHIFT_RIGHT: number = 2048;
const KEY_CTRL_LEFT: number = 2072;
const KEY_CTRL_RIGHT: number = 2073;
const KEY_ALT_LEFT: number = 2045;
const KEY_ALT_RIGHT: number = 2046;
const KEY_META_LEFT: number = 2076;
const KEY_META_RIGHT: number = 2077;
const KEY_CAPS_LOCK: number = 2074;

let cachedMap: Map<number, number> | null = null;

function keyMap(): Map<number, number> {
  if (cachedMap !== null) {
    return cachedMap;
  }
  const map = new Map<number, number>();
  for (let i = 0; i < 26; i++) {
    map.set(2017 + i, 29 + i);
  }
  for (let i = 0; i < 10; i++) {
    map.set(2000 + i, 7 + i);
  }
  for (let i = 0; i < 12; i++) {
    map.set(2090 + i, 131 + i);
  }
  map.set(2043, 55);
  map.set(2044, 56);
  map.set(2056, 68);
  map.set(2057, 69);
  map.set(2058, 70);
  map.set(2059, 71);
  map.set(2060, 72);
  map.set(2061, 73);
  map.set(2062, 74);
  map.set(2063, 75);
  map.set(2064, 76);
  map.set(2049, 61);
  map.set(2050, 62);
  map.set(2054, 66);
  map.set(2055, 67);
  map.set(2071, 112);
  map.set(2070, 111);
  map.set(2012, 19);
  map.set(2013, 20);
  map.set(2014, 21);
  map.set(2015, 22);
  map.set(2081, 122);
  map.set(2082, 123);
  map.set(2068, 92);
  map.set(2069, 93);
  map.set(KEY_ALT_LEFT, 57);
  map.set(KEY_ALT_RIGHT, 58);
  map.set(KEY_SHIFT_LEFT, 59);
  map.set(KEY_SHIFT_RIGHT, 60);
  map.set(KEY_CTRL_LEFT, 113);
  map.set(KEY_CTRL_RIGHT, 114);
  map.set(KEY_META_LEFT, 117);
  map.set(KEY_META_RIGHT, 118);
  map.set(KEY_CAPS_LOCK, 115);
  cachedMap = map;
  return map;
}

export function androidKeycode(harmonyKey: number): number {
  const code = keyMap().get(harmonyKey);
  return code === undefined ? 0 : code;
}

// Android modifier keycodes: Shift 59/60, Alt 57/58, Ctrl 113/114,
// Meta 117/118, Caps Lock 115. Their key-up must always reach the tracker.
export function isModifierKey(androidKey: number): boolean {
  return androidKey === 57 || androidKey === 58 || androidKey === 59 || androidKey === 60 ||
    androidKey === 113 || androidKey === 114 || androidKey === 115 || androidKey === 117 || androidKey === 118;
}

export function unicodeFor(androidKey: number, modifiers: number): number {
  const shifted = (modifiers & InputModifiers.SHIFT) !== 0;
  const caps = (modifiers & InputModifiers.CAPS_LOCK) !== 0;
  if (androidKey >= 29 && androidKey <= 54) {
    const lower = 'abcdefghijklmnopqrstuvwxyz'.charCodeAt(androidKey - 29);
    return shifted !== caps ? lower - 32 : lower;
  }
  if (androidKey >= 7 && androidKey <= 16) {
    const digit = androidKey - 7;
    if (!shifted) {
      return '0123456789'.charCodeAt(digit);
    }
    return ')!@#$%^&*('.charCodeAt(digit);
  }
  if (androidKey === 55) {
    return shifted ? 60 : 44;
  }
  if (androidKey === 56) {
    return shifted ? 62 : 46;
  }
  if (androidKey === 68) {
    return shifted ? 126 : 96;
  }
  if (androidKey === 69) {
    return shifted ? 95 : 45;
  }
  if (androidKey === 70) {
    return shifted ? 43 : 61;
  }
  if (androidKey === 71) {
    return shifted ? 123 : 91;
  }
  if (androidKey === 72) {
    return shifted ? 125 : 93;
  }
  if (androidKey === 73) {
    return shifted ? 124 : 92;
  }
  if (androidKey === 74) {
    return shifted ? 58 : 59;
  }
  if (androidKey === 75) {
    return shifted ? 34 : 39;
  }
  if (androidKey === 76) {
    return shifted ? 63 : 47;
  }
  if (androidKey === 62) {
    return 32;
  }
  if (androidKey === 17) {
    return 42;
  }
  if (androidKey === 18) {
    return 35;
  }
  return 0;
}

export class ModifierTracker {
  private shiftCount: number = 0;
  private ctrlCount: number = 0;
  private altCount: number = 0;
  private metaCount: number = 0;
  private capsDown: boolean = false;
  capsLocked: boolean = false;

  update(harmonyKey: number, down: boolean): number {
    if (harmonyKey === KEY_SHIFT_LEFT || harmonyKey === KEY_SHIFT_RIGHT) {
      this.shiftCount = this.adjust(this.shiftCount, down);
    } else if (harmonyKey === KEY_CTRL_LEFT || harmonyKey === KEY_CTRL_RIGHT) {
      this.ctrlCount = this.adjust(this.ctrlCount, down);
    } else if (harmonyKey === KEY_ALT_LEFT || harmonyKey === KEY_ALT_RIGHT) {
      this.altCount = this.adjust(this.altCount, down);
    } else if (harmonyKey === KEY_META_LEFT || harmonyKey === KEY_META_RIGHT) {
      this.metaCount = this.adjust(this.metaCount, down);
    } else if (harmonyKey === KEY_CAPS_LOCK) {
      if (down && !this.capsDown) {
        this.capsLocked = !this.capsLocked;
      }
      this.capsDown = down;
    }
    return this.flags();
  }

  reset(): void {
    this.shiftCount = 0;
    this.ctrlCount = 0;
    this.altCount = 0;
    this.metaCount = 0;
    this.capsDown = false;
    this.capsLocked = false;
  }

  private adjust(count: number, down: boolean): number {
    if (down) {
      return Math.min(count + 1, 2);
    }
    return Math.max(count - 1, 0);
  }

  private flags(): number {
    let flags = 0;
    if (this.shiftCount > 0) {
      flags |= InputModifiers.SHIFT;
    }
    if (this.ctrlCount > 0) {
      flags |= InputModifiers.CONTROL;
    }
    if (this.altCount > 0) {
      flags |= InputModifiers.OPTION;
    }
    if (this.metaCount > 0) {
      flags |= InputModifiers.COMMAND;
    }
    if (this.capsLocked) {
      flags |= InputModifiers.CAPS_LOCK;
    }
    return flags;
  }
}