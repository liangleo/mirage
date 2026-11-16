import { isEdgeSwipe, isEdgeStart } from './InputGeometry';

export enum EdgeDecision {
  PASS = 0,
  HOLD = 1,
  OPEN = 2
}

// A touch that starts in the right-edge strip is forwarded as a normal press,
// so taps in the strip still reach the Mac. Moves are held until the gesture
// either ends (tap/drag inside the strip) or crosses the swipe threshold.
export class EdgeGesture {
  private tracking: boolean = false;
  private startX: number = -1;
  private width: number = 0;

  onDown(xVp: number, widthVp: number): EdgeDecision {
    this.tracking = isEdgeStart(xVp, widthVp);
    this.startX = xVp;
    this.width = widthVp;
    return EdgeDecision.PASS;
  }

  onMove(xVp: number): EdgeDecision {
    if (!this.tracking) {
      return EdgeDecision.PASS;
    }
    if (isEdgeSwipe(this.startX, this.width, xVp)) {
      this.tracking = false;
      return EdgeDecision.OPEN;
    }
    return EdgeDecision.HOLD;
  }

  onUp(): EdgeDecision {
    this.tracking = false;
    return EdgeDecision.PASS;
  }
}