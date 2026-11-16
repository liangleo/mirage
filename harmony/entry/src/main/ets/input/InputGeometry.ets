export const EDGE_FRACTION: number = 0.15;
export const EDGE_SWIPE_VP: number = 40;

export class ContentRect {
  width: number;
  height: number;

  constructor(width: number = 0, height: number = 0) {
    this.width = width;
    this.height = height;
  }
}

export class Point {
  x: number;
  y: number;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

export function fitContent(containerWidth: number, containerHeight: number, videoWidth: number,
  videoHeight: number): ContentRect {
  if (containerWidth <= 0 || containerHeight <= 0) {
    return new ContentRect();
  }
  const width = videoWidth > 0 ? videoWidth : 16;
  const height = videoHeight > 0 ? videoHeight : 9;
  const scale = Math.min(containerWidth / width, containerHeight / height);
  return new ContentRect(Math.floor(width * scale), Math.floor(height * scale));
}

export function normalizePoint(xVp: number, yVp: number, widthVp: number, heightVp: number): Point {
  if (widthVp <= 0 || heightVp <= 0) {
    return new Point(0, 0);
  }
  return new Point(clamp01(xVp / widthVp), clamp01(yVp / heightVp));
}

export function isEdgeStart(xVp: number, widthVp: number): boolean {
  if (widthVp <= 0) {
    return false;
  }
  return xVp >= widthVp * (1 - EDGE_FRACTION);
}

export function isEdgeSwipe(startXVp: number, widthVp: number, currentXVp: number): boolean {
  if (!isEdgeStart(startXVp, widthVp)) {
    return false;
  }
  return startXVp - currentXVp >= EDGE_SWIPE_VP;
}

function clamp01(value: number): number {
  if (value < 0) {
    return 0;
  }
  return value > 1 ? 1 : value;
}