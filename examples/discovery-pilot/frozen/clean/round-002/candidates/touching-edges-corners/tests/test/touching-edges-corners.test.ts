import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("touching rectangles", () => {
  it("edge touching on x does not overlap in either order", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(10, 0, 10, 10))).toBe(false);
    expect(overlaps(rect(10, 0, 10, 10), rect(0, 0, 10, 10))).toBe(false);
  });
  it("edge touching on y does not overlap in either order", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(0, 10, 10, 10))).toBe(false);
    expect(overlaps(rect(0, 10, 10, 10), rect(0, 0, 10, 10))).toBe(false);
  });
  it("corner touching does not overlap", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(10, 10, 5, 5))).toBe(false);
    expect(overlaps(rect(-5, -5, 5, 5), rect(0, 0, 5, 5))).toBe(false);
  });
  it("one unit of penetration overlaps", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(9, 0, 10, 10))).toBe(true);
    expect(overlaps(rect(0, 0, 10, 10), rect(0, 9, 10, 10))).toBe(true);
    expect(overlaps(rect(0, 0, 10, 10), rect(9, 9, 10, 10))).toBe(true);
  });
  it("overlap on one axis only is not an overlap", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(5, 20, 10, 10))).toBe(false);
    expect(overlaps(rect(0, 0, 10, 10), rect(20, 5, 10, 10))).toBe(false);
  });
});
