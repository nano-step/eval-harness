export interface Rect {
  readonly x: number;
  readonly y: number;
  readonly width: number;
  readonly height: number;
}

function assertValid(rect: Rect, name: string): void {
  const { x, y, width, height } = rect;
  if (![x, y, width, height].every(Number.isFinite) || width < 0 || height < 0) {
    throw new RangeError(`${name} must have finite coordinates and a non-negative size`);
  }
}

export function overlaps(a: Rect, b: Rect): boolean {
  assertValid(a, "a");
  assertValid(b, "b");
  if (a.width === 0 || a.height === 0 || b.width === 0 || b.height === 0) {
    return false;
  }
  return (
    a.x < b.x + b.width &&
    b.x < a.x + a.width &&
    a.y < b.y + b.height &&
    b.y < a.y + a.height
  );
}

export function translate(rect: Rect, dx: number, dy: number): Rect {
  return { x: rect.x + dx, y: rect.y + dy, width: rect.width, height: rect.height };
}

export function collidesAfterMove(moving: Rect, dx: number, dy: number, obstacle: Rect): boolean {
  return overlaps(translate(moving, dx, dy), obstacle);
}
