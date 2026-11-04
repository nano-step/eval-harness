import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("invalid rectangles", () => {
  const ok = rect(0, 0, 5, 5);
  const zero = rect(0, 0, 0, 0);

  it("throws RangeError for an invalid second rectangle", () => {
    expect(() => overlaps(ok, rect(0, 0, -1, 5))).toThrow(RangeError);
    expect(() => overlaps(ok, rect(0, 0, 5, -1))).toThrow(RangeError);
    expect(() => overlaps(ok, rect(Number.NaN, 0, 5, 5))).toThrow(RangeError);
    expect(() => overlaps(ok, rect(0, Number.POSITIVE_INFINITY, 5, 5))).toThrow(RangeError);
    expect(() => overlaps(ok, rect(0, 0, Number.POSITIVE_INFINITY, 5))).toThrow(RangeError);
  });

  it("throws RangeError for an invalid first rectangle", () => {
    expect(() => overlaps(rect(0, Number.NEGATIVE_INFINITY, 5, 5), ok)).toThrow(RangeError);
    expect(() => overlaps(rect(0, 0, 5, Number.NaN), ok)).toThrow(RangeError);
  });

  it("still throws when the other rectangle has zero size", () => {
    expect(() => overlaps(zero, rect(0, 0, -2, 5))).toThrow(RangeError);
    expect(() => overlaps(rect(0, 0, -2, 5), zero)).toThrow(RangeError);
    expect(() => overlaps(zero, rect(Number.NaN, 0, 1, 1))).toThrow(RangeError);
  });
});
