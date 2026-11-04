import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("axis combination", () => {
  it("does not overlap when x ranges intersect but y ranges are disjoint", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(5, 20, 10, 10))).toBe(false);
    expect(overlaps(rect(5, 20, 10, 10), rect(0, 0, 10, 10))).toBe(false);
  });

  it("does not overlap when y ranges intersect but x ranges are disjoint", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(20, 5, 10, 10))).toBe(false);
    expect(overlaps(rect(20, 5, 10, 10), rect(0, 0, 10, 10))).toBe(false);
  });

  it("does not overlap when x intersects and y only touches", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(5, 10, 10, 10))).toBe(false);
  });

  it("width and height are not confused for non-square rectangles", () => {
    expect(overlaps(rect(0, 0, 100, 1), rect(50, 0, 1, 100))).toBe(true);
    expect(overlaps(rect(0, 0, 100, 1), rect(50, 1, 1, 100))).toBe(false);
    expect(overlaps(rect(0, 0, 1, 100), rect(1, 50, 100, 1))).toBe(false);
    expect(overlaps(rect(0, 0, 1, 100), rect(0, 50, 100, 1))).toBe(true);
  });

  it("identical non-empty rectangles overlap, including at negative positions", () => {
    expect(overlaps(rect(-7, -3, 4, 9), rect(-7, -3, 4, 9))).toBe(true);
  });

  it("a rectangle overlaps one that fully contains it", () => {
    expect(overlaps(rect(-50, -50, 100, 100), rect(-1, -1, 2, 2))).toBe(true);
    expect(overlaps(rect(-1, -1, 2, 2), rect(-50, -50, 100, 100))).toBe(true);
  });
});
