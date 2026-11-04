import { describe, expect, it } from "vitest";
import { collidesAfterMove, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("collidesAfterMove flush", () => {
  const obstacle = rect(10, 10, 10, 10);
  it("flush from the left does not collide, one more unit does", () => {
    expect(collidesAfterMove(rect(0, 10, 5, 10), 5, 0, obstacle)).toBe(false);
    expect(collidesAfterMove(rect(0, 10, 5, 10), 6, 0, obstacle)).toBe(true);
  });
  it("flush from above does not collide, one more unit does", () => {
    expect(collidesAfterMove(rect(10, 0, 10, 5), 0, 5, obstacle)).toBe(false);
    expect(collidesAfterMove(rect(10, 0, 10, 5), 0, 6, obstacle)).toBe(true);
  });
  it("flush from the right with negative movement", () => {
    expect(collidesAfterMove(rect(30, 10, 5, 10), -10, 0, obstacle)).toBe(false);
    expect(collidesAfterMove(rect(30, 10, 5, 10), -11, 0, obstacle)).toBe(true);
  });
});
