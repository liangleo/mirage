import { GestureEvent, GestureMapper, TouchAction, TouchFrame, TouchSample, TouchTool } from '../input/GestureMapper';
import { normalizePoint, Point } from '../input/InputGeometry';

@Component
export struct InputOverlay {
  @Prop contentWidth: number;
  @Prop contentHeight: number;
  onEvents: (events: GestureEvent[]) => void = (events: GestureEvent[]) => {
  };
  private mapper: GestureMapper = new GestureMapper();

  private handleTouch(event: TouchEvent): void {
    const type = event.type;
    let action: TouchAction;
    let touches: TouchObject[];
    if (type === TouchType.Down) {
      action = event.touches.length > 1 ? TouchAction.POINTER_DOWN : TouchAction.DOWN;
      touches = event.touches;
    } else if (type === TouchType.Move) {
      action = TouchAction.MOVE;
      touches = event.touches;
    } else if (type === TouchType.Up) {
      const remaining = event.touches.length - event.changedTouches.length;
      action = remaining > 0 ? TouchAction.POINTER_UP : TouchAction.UP;
      touches = event.changedTouches;
    } else if (type === TouchType.Cancel) {
      action = TouchAction.CANCEL;
      touches = event.changedTouches;
    } else {
      return;
    }

    const pointers: TouchSample[] = [];
    for (const touch of touches) {
      const point: Point = normalizePoint(touch.x, touch.y, this.contentWidth, this.contentHeight);
      const tool: TouchTool = event.sourceTool === SourceTool.Pen ? TouchTool.STYLUS : TouchTool.FINGER;
      const pressure: number = touch.pressure !== undefined ? touch.pressure : 1;
      const tiltX: number = clampTilt(event.tiltX);
      const tiltY: number = clampTilt(event.tiltY);
      pointers.push(new TouchSample(touch.id, point.x, point.y, tool, 1, pressure, tiltX, tiltY));
    }
    const events: GestureEvent[] = this.mapper.onFrame(new TouchFrame(action, pointers, Date.now()));
    if (events.length > 0) {
      this.onEvents(events);
    }
  }

  build() {
    Stack() {
    }
    .width(this.contentWidth)
    .height(this.contentHeight)
    .onTouch((event: TouchEvent) => {
      this.handleTouch(event);
    })
  }
}

function clampTilt(value: number | undefined): number {
  if (value === undefined) {
    return 0;
  }
  const normalized = value / 90;
  if (normalized < -1) {
    return -1;
  }
  return normalized > 1 ? 1 : normalized;
}