import { PointerKind, PointerSample, ScrollFlags, ScrollInput, ScrollPhase } from '../core/InputProtocol';

export enum TouchTool {
  FINGER,
  STYLUS,
  ERASER
}

export enum TouchAction {
  DOWN,
  MOVE,
  UP,
  POINTER_DOWN,
  POINTER_UP,
  CANCEL,
  HOVER_ENTER,
  HOVER_MOVE,
  HOVER_EXIT
}

export class TouchSample {
  id: number;
  x: number;
  y: number;
  tool: TouchTool;
  buttons: number;
  pressure: number;
  tiltX: number;
  tiltY: number;

  constructor(id: number, x: number, y: number, tool: TouchTool = TouchTool.FINGER,
    buttons: number = 1, pressure: number = 1, tiltX: number = 0, tiltY: number = 0) {
    this.id = id;
    this.x = x;
    this.y = y;
    this.tool = tool;
    this.buttons = buttons;
    this.pressure = pressure;
    this.tiltX = tiltX;
    this.tiltY = tiltY;
  }
}

export class TouchFrame {
  action: TouchAction;
  pointers: TouchSample[];
  eventTimeMs: number;

  constructor(action: TouchAction, pointers: TouchSample[], eventTimeMs: number) {
    this.action = action;
    this.pointers = pointers;
    this.eventTimeMs = eventTimeMs;
  }
}

export class GestureEvent {
  pointer: PointerSample[] | null = null;
  scroll: ScrollInput | null = null;

  static ofPointer(samples: PointerSample[]): GestureEvent {
    const event = new GestureEvent();
    event.pointer = samples;
    return event;
  }

  static ofScroll(scroll: ScrollInput): GestureEvent {
    const event = new GestureEvent();
    event.scroll = scroll;
    return event;
  }
}

const enum Mode {
  IDLE,
  TENTATIVE,
  DRAG,
  SCROLL,
  STYLUS,
  IGNORE
}

class Metrics {
  cx: number;
  cy: number;
  spread: number;

  constructor(cx: number, cy: number, spread: number) {
    this.cx = cx;
    this.cy = cy;
    this.spread = spread;
  }
}

export class GestureMapper {
  private readonly touchSlop: number;
  private readonly longPressMs: number;
  private mode: Mode = Mode.IDLE;
  private down: TouchSample | null = null;
  private downTime: number = 0;
  private lastDrag: TouchSample | null = null;
  private lastCentroidX: number = 0;
  private lastCentroidY: number = 0;
  private lastSpread: number = 0;
  private scrollStarted: boolean = false;

  constructor(touchSlop: number = 0.01, longPressMs: number = 500) {
    this.touchSlop = touchSlop;
    this.longPressMs = longPressMs;
  }

  onFrame(frame: TouchFrame): GestureEvent[] {
    const action = frame.action;
    if (action === TouchAction.DOWN) {
      return this.onDown(frame);
    }
    if (action === TouchAction.MOVE) {
      return this.onMove(frame);
    }
    if (action === TouchAction.POINTER_DOWN) {
      return this.onPointerDown(frame);
    }
    if (action === TouchAction.POINTER_UP) {
      return this.onPointerUp(frame);
    }
    if (action === TouchAction.UP) {
      return this.onUp(frame);
    }
    if (action === TouchAction.CANCEL) {
      return this.onCancel();
    }
    if (action === TouchAction.HOVER_ENTER || action === TouchAction.HOVER_MOVE) {
      return this.onHover(frame);
    }
    return [];
  }

  reset(): GestureEvent[] {
    return this.onCancel();
  }

  private onDown(frame: TouchFrame): GestureEvent[] {
    if (frame.pointers.length === 0) {
      return [];
    }
    const first = frame.pointers[0];
    this.down = first;
    this.downTime = frame.eventTimeMs;
    this.lastDrag = first;
    if (first.tool !== TouchTool.FINGER) {
      this.mode = Mode.STYLUS;
      return [this.pointer(first, PointerKind.DOWN, frame.eventTimeMs)];
    }
    this.mode = Mode.TENTATIVE;
    return [];
  }

  private onMove(frame: TouchFrame): GestureEvent[] {
    if (frame.pointers.length === 0) {
      return [];
    }
    const first = frame.pointers[0];
    if (this.mode === Mode.TENTATIVE) {
      const origin = this.down;
      if (origin === null) {
        return [];
      }
      if (Math.hypot(first.x - origin.x, first.y - origin.y) <= this.touchSlop) {
        return [];
      }
      this.mode = Mode.DRAG;
      this.lastDrag = first;
      return [
        this.pointer(origin, PointerKind.DOWN, frame.eventTimeMs),
        this.pointer(first, PointerKind.MOVE, frame.eventTimeMs)
      ];
    }
    if (this.mode === Mode.DRAG) {
      this.lastDrag = first;
      return [this.pointer(first, PointerKind.MOVE, frame.eventTimeMs)];
    }
    if (this.mode === Mode.STYLUS) {
      this.lastDrag = first;
      return [this.pointer(first, PointerKind.MOVE, frame.eventTimeMs)];
    }
    if (this.mode === Mode.SCROLL) {
      return this.onScrollMove(frame);
    }
    return [];
  }

  private onPointerDown(frame: TouchFrame): GestureEvent[] {
    const events: GestureEvent[] = [];
    if (this.mode === Mode.DRAG && this.lastDrag !== null) {
      events.push(this.pointer(this.lastDrag, PointerKind.CANCEL, frame.eventTimeMs, 0));
    }
    if (this.mode === Mode.STYLUS) {
      const sample = this.down !== null ? this.down : frame.pointers[0];
      if (sample !== undefined) {
        events.push(this.pointer(sample, PointerKind.CANCEL, frame.eventTimeMs, 0));
      }
    }
    if (frame.pointers.length >= 3) {
      this.mode = Mode.IGNORE;
      return events;
    }
    this.mode = Mode.SCROLL;
    const metrics = this.metrics(frame.pointers);
    this.lastCentroidX = metrics.cx;
    this.lastCentroidY = metrics.cy;
    this.lastSpread = metrics.spread;
    this.scrollStarted = true;
    events.push(this.scroll(ScrollPhase.BEGIN, 0, 0, ScrollFlags.PRECISE));
    return events;
  }

  private onPointerUp(frame: TouchFrame): GestureEvent[] {
    if (this.mode !== Mode.SCROLL || frame.pointers.length >= 2) {
      return [];
    }
    const metrics = this.metrics(frame.pointers);
    this.lastCentroidX = metrics.cx;
    this.lastCentroidY = metrics.cy;
    this.lastSpread = metrics.spread;
    this.scrollStarted = false;
    this.mode = Mode.IGNORE;
    return [this.scroll(ScrollPhase.END, 0, 0, ScrollFlags.PRECISE)];
  }

  private onUp(frame: TouchFrame): GestureEvent[] {
    const events: GestureEvent[] = [];
    if (this.mode === Mode.TENTATIVE) {
      const sample = this.down;
      if (sample === null) {
        this.resetState();
        return [];
      }
      const held = frame.eventTimeMs - this.downTime >= this.longPressMs;
      const buttons = held ? 2 : 1;
      events.push(this.pointer(sample, PointerKind.DOWN, frame.eventTimeMs, buttons));
      events.push(this.pointer(sample, PointerKind.UP, frame.eventTimeMs, held ? 2 : 0));
    } else if (this.mode === Mode.DRAG) {
      const sample = frame.pointers.length > 0 ? frame.pointers[0] : this.lastDrag;
      if (sample !== null) {
        events.push(this.pointer(sample, PointerKind.UP, frame.eventTimeMs, 0));
      }
    } else if (this.mode === Mode.STYLUS) {
      const sample = frame.pointers.length > 0 ? frame.pointers[0] : this.lastDrag;
      if (sample !== null) {
        events.push(this.pointer(sample, PointerKind.UP, frame.eventTimeMs, 0));
      }
    } else if (this.mode === Mode.SCROLL && this.scrollStarted) {
      events.push(this.scroll(ScrollPhase.END, 0, 0, ScrollFlags.PRECISE));
    }
    this.resetState();
    return events;
  }

  private onCancel(): GestureEvent[] {
    const events: GestureEvent[] = [];
    if (this.mode === Mode.DRAG && this.lastDrag !== null) {
      events.push(this.pointer(this.lastDrag, PointerKind.CANCEL, 0, 0));
    } else if (this.mode === Mode.STYLUS) {
      const sample = this.lastDrag !== null ? this.lastDrag : this.down;
      if (sample !== null) {
        events.push(this.pointer(sample, PointerKind.CANCEL, 0, 0));
      }
    } else if (this.mode === Mode.SCROLL && this.scrollStarted) {
      events.push(this.scroll(ScrollPhase.END, 0, 0, ScrollFlags.PRECISE));
    }
    this.resetState();
    return events;
  }

  private onHover(frame: TouchFrame): GestureEvent[] {
    if (frame.pointers.length === 0) {
      return [];
    }
    const first = frame.pointers[0];
    if (first.tool !== TouchTool.STYLUS && first.tool !== TouchTool.ERASER) {
      return [];
    }
    return [this.pointer(first, PointerKind.HOVER, frame.eventTimeMs, 0)];
  }

  private onScrollMove(frame: TouchFrame): GestureEvent[] {
    if (frame.pointers.length < 2) {
      return [];
    }
    const metrics = this.metrics(frame.pointers);
    const pinch = this.lastSpread > 0 && Math.abs(metrics.spread - this.lastSpread) / this.lastSpread > 0.02;
    const flags = pinch ? ScrollFlags.COMMAND | ScrollFlags.PRECISE : ScrollFlags.PRECISE;
    const dx = pinch ? 0 : (metrics.cx - this.lastCentroidX) * 1000;
    const dy = pinch ? (metrics.spread - this.lastSpread) * 400 : (metrics.cy - this.lastCentroidY) * 1000;
    this.lastCentroidX = metrics.cx;
    this.lastCentroidY = metrics.cy;
    this.lastSpread = metrics.spread;
    return [this.scroll(ScrollPhase.CHANGE, dx, dy, flags)];
  }

  private metrics(pointers: TouchSample[]): Metrics {
    const first = pointers[0];
    const second = pointers.length > 1 ? pointers[1] : first;
    return new Metrics((first.x + second.x) / 2, (first.y + second.y) / 2,
      Math.hypot(first.x - second.x, first.y - second.y));
  }

  private pointer(sample: TouchSample, kind: PointerKind, eventTimeMs: number,
    buttons: number = sample.buttons): GestureEvent {
    return GestureEvent.ofPointer([new PointerSample(kind, sample.id, buttons, sample.x, sample.y,
      sample.pressure, sample.tiltX, sample.tiltY, eventTimeMs * 1000)]);
  }

  private scroll(phase: ScrollPhase, dx: number, dy: number, flags: number): GestureEvent {
    return GestureEvent.ofScroll(new ScrollInput(phase, flags, dx, dy, Date.now() * 1000));
  }

  private resetState(): void {
    this.mode = Mode.IDLE;
    this.down = null;
    this.downTime = 0;
    this.lastDrag = null;
    this.scrollStarted = false;
  }
}