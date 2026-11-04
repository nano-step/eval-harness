import * as fc from "fast-check";
import { describe, expect, it } from "vitest";
import { collidesAfterMove, overlaps, translate, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

// Baseline suite for the benchmark. It covers overlap, separation, containment, negative coordinates, zero-size FIRST
// rectangles, symmetry and translation invariance (deterministic fast-check properties with fixed seeds) and movement.
// It has no DEDICATED case for rectangles that only touch along an edge or corner, nor for a moving rectangle that ends
// exactly flush with an obstacle, and no zero-size SECOND rectangle case. That is not a claim that the property
// arbitraries never produce such contacts: whether a mutation run reports a gap there is measured, not assumed.
describe("overlaps", () => {
  it("is true for rectangles whose interiors intersect", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(5, 5, 10, 10))).toBe(true);
  });

  it("is false for rectangles separated by a gap on either axis", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(20, 0, 10, 10))).toBe(false);
    expect(overlaps(rect(0, 0, 10, 10), rect(0, 20, 10, 10))).toBe(false);
  });

  it("is true when one rectangle contains the other", () => {
    expect(overlaps(rect(0, 0, 100, 100), rect(10, 10, 5, 5))).toBe(true);
    expect(overlaps(rect(10, 10, 5, 5), rect(0, 0, 100, 100))).toBe(true);
  });

  it("is true for identical non-empty rectangles", () => {
    expect(overlaps(rect(3, 4, 5, 6), rect(3, 4, 5, 6))).toBe(true);
  });

  it("handles negative coordinates", () => {
    expect(overlaps(rect(-10, -10, 8, 8), rect(-6, -6, 8, 8))).toBe(true);
    expect(overlaps(rect(-10, -10, 4, 4), rect(5, 5, 4, 4))).toBe(false);
  });

  it("never overlaps a zero-size first rectangle", () => {
    expect(overlaps(rect(5, 5, 0, 5), rect(0, 0, 10, 10))).toBe(false);
    expect(overlaps(rect(5, 5, 5, 0), rect(0, 0, 10, 10))).toBe(false);
    expect(overlaps(rect(5, 5, 0, 0), rect(5, 5, 0, 0))).toBe(false);
  });

  it("rejects invalid rectangles", () => {
    expect(() => overlaps(rect(0, 0, -1, 1), rect(0, 0, 1, 1))).toThrow(RangeError);
    expect(() => overlaps(rect(0, 0, 1, 1), rect(Number.NaN, 0, 1, 1))).toThrow(RangeError);
  });
});

describe("properties (fixed seeds, non-empty rectangles)", () => {
  const nonEmpty = fc.record({
    x: fc.integer({ min: -50, max: 50 }),
    y: fc.integer({ min: -50, max: 50 }),
    width: fc.integer({ min: 1, max: 20 }),
    height: fc.integer({ min: 1, max: 20 }),
  });

  it("overlap is symmetric", () => {
    fc.assert(fc.property(nonEmpty, nonEmpty, (a, b) => overlaps(a, b) === overlaps(b, a)), { seed: 20261103, numRuns: 200 });
  });

  it("overlap is invariant under translating both rectangles", () => {
    fc.assert(
      fc.property(
        nonEmpty,
        nonEmpty,
        fc.integer({ min: -100, max: 100 }),
        fc.integer({ min: -100, max: 100 }),
        (a, b, dx, dy) => overlaps(a, b) === overlaps(translate(a, dx, dy), translate(b, dx, dy)),
      ),
      { seed: 20261104, numRuns: 200 },
    );
  });
});

describe("movement", () => {
  it("translate keeps the size and shifts the position", () => {
    expect(translate(rect(1, 2, 3, 4), 10, -5)).toEqual(rect(11, -3, 3, 4));
  });

  it("collides when the moved rectangle ends inside the obstacle", () => {
    expect(collidesAfterMove(rect(0, 0, 5, 5), 8, 0, rect(10, 0, 10, 5))).toBe(true);
  });

  it("does not collide when the moved rectangle stays clear of the obstacle", () => {
    expect(collidesAfterMove(rect(0, 0, 5, 5), 2, 0, rect(20, 0, 10, 5))).toBe(false);
  });
});
