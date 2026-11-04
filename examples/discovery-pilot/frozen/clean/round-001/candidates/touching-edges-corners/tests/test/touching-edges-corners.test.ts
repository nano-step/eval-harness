import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("touching rectangles", () => {
  it("does not overlap when touching along a vertical edge", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(10, 0, 10, 10))).toBe(false);
    expect(overlaps(rect(10, 0, 10, 10), rect(0, 0, 10, 10))).toBe(false);
  });

  it("does not overlap when touching along a horizontal edge", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(0, 10, 10, 10))).toBe(false);
    expect(overlaps(rect(0, 10, 10, 10), rect(0, 0, 10, 10))).toBe(false);
  });

  it("does not overlap when touching at a corner", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(10, 10, 5, 5))).toBe(false);
    expect(overlaps(rect(10, 10, 5, 5), rect(0, 0, 10, 10))).toBe(false);
    expect(overlaps(rect(0, 0, 10, 10), rect(-5, -5, 5, 5))).toBe(false);
    expect(overlaps(rect(0, 0, 10, 10), rect(10, -5, 5, 5))).toBe(false);
  });

  it("touching with negative coordinates does not overlap", () => {
    expect(overlaps(rect(-20, -20, 10, 10), rect(-10, -10, 5, 5))).toBe(false);
    expect(overlaps(rect(-20, -20, 10, 10), rect(-10, -20, 5, 10))).toBe(false);
  });

  it("overlaps by a tiny margin on both axes", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(9, 9, 5, 5))).toBe(true);
    expect(overlaps(rect(0, 0, 10, 10), rect(9, 0, 5, 10))).toBe(true);
    expect(overlaps(rect(0, 0, 10, 10), rect(0, 9, 10, 5))).toBe(true);
  });
});
