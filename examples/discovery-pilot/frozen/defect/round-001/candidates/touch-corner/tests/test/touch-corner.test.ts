import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("overlaps corner contact", () => {
  it("bottom-right corner of a touches top-left of b", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(10, 10, 10, 10))).toBe(false);
    expect(overlaps(rect(10, 10, 10, 10), rect(0, 0, 10, 10))).toBe(false);
  });

  it("top-right corner of a touches bottom-left of b", () => {
    expect(overlaps(rect(0, 10, 10, 10), rect(10, 0, 10, 10))).toBe(false);
    expect(overlaps(rect(10, 0, 10, 10), rect(0, 10, 10, 10))).toBe(false);
  });

  it("corner contact at negative coordinates", () => {
    expect(overlaps(rect(-20, -20, 10, 10), rect(-10, -10, 5, 5))).toBe(false);
  });
});
