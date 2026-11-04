import { describe, expect, it } from "vitest";
import { collidesAfterMove, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("collidesAfterMove flush", () => {
  it("flush on x does not collide, one more unit does", () => {
    const obstacle = rect(10, 0, 10, 5);
    expect(collidesAfterMove(rect(0, 0, 5, 5), 5, 0, obstacle)).toBe(false);
    expect(collidesAfterMove(rect(0, 0, 5, 5), 6, 0, obstacle)).toBe(true);
  });

  it("flush on y does not collide, one more unit does", () => {
    const obstacle = rect(0, 10, 5, 10);
    expect(collidesAfterMove(rect(0, 0, 5, 5), 0, 5, obstacle)).toBe(false);
    expect(collidesAfterMove(rect(0, 0, 5, 5), 0, 6, obstacle)).toBe(true);
  });

  it("flush from the other side (moving left)", () => {
    const obstacle = rect(0, 0, 10, 5);
    expect(collidesAfterMove(rect(20, 0, 5, 5), -10, 0, obstacle)).toBe(false);
    expect(collidesAfterMove(rect(20, 0, 5, 5), -11, 0, obstacle)).toBe(true);
  });
});
