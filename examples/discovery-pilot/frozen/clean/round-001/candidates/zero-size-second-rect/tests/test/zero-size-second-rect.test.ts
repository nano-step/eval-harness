import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("zero-size rectangles", () => {
  const big = rect(0, 0, 100, 100);

  it("never overlaps when the second rectangle has zero width", () => {
    expect(overlaps(big, rect(50, 50, 0, 10))).toBe(false);
    expect(overlaps(rect(50, 50, 0, 10), big)).toBe(false);
  });

  it("never overlaps when the second rectangle has zero height", () => {
    expect(overlaps(big, rect(50, 50, 10, 0))).toBe(false);
    expect(overlaps(rect(50, 50, 10, 0), big)).toBe(false);
  });

  it("never overlaps when the second rectangle is a point inside the first", () => {
    expect(overlaps(big, rect(50, 50, 0, 0))).toBe(false);
    expect(overlaps(rect(50, 50, 0, 0), big)).toBe(false);
  });

  it("identical zero-size rectangles do not overlap", () => {
    expect(overlaps(rect(5, 5, 0, 0), rect(5, 5, 0, 0))).toBe(false);
    expect(overlaps(rect(5, 5, 0, 7), rect(5, 5, 0, 7))).toBe(false);
    expect(overlaps(rect(5, 5, 7, 0), rect(5, 5, 7, 0))).toBe(false);
  });

  it("zero-size rectangle on the boundary does not overlap", () => {
    expect(overlaps(big, rect(0, 0, 0, 0))).toBe(false);
    expect(overlaps(big, rect(100, 100, 0, 0))).toBe(false);
  });
});
