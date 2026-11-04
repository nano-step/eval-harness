import * as fc from "fast-check";
import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const anyRect = fc.record({
  x: fc.integer({ min: -30, max: 30 }),
  y: fc.integer({ min: -30, max: 30 }),
  width: fc.integer({ min: 0, max: 15 }),
  height: fc.integer({ min: 0, max: 15 }),
});

const reference = (a: Rect, b: Rect): boolean => {
  const w = Math.min(a.x + a.width, b.x + b.width) - Math.max(a.x, b.x);
  const h = Math.min(a.y + a.height, b.y + b.height) - Math.max(a.y, b.y);
  return w > 0 && h > 0;
};

describe("overlaps properties", () => {
  it("matches the interior-intersection-area definition", () => {
    fc.assert(
      fc.property(anyRect, anyRect, (a, b) => overlaps(a, b) === reference(a, b)),
      { seed: Number(process.env.FC_SEED), numRuns: 300 },
    );
  });

  it("is symmetric and translation invariant, including zero-size rectangles", () => {
    fc.assert(
      fc.property(
        anyRect,
        anyRect,
        fc.integer({ min: -100, max: 100 }),
        fc.integer({ min: -100, max: 100 }),
        (a, b, dx, dy) => {
          const moved = overlaps(
            { ...a, x: a.x + dx, y: a.y + dy },
            { ...b, x: b.x + dx, y: b.y + dy },
          );
          expect(overlaps(a, b)).toBe(overlaps(b, a));
          expect(moved).toBe(overlaps(a, b));
        },
      ),
      { seed: Number(process.env.FC_SEED), numRuns: 300 },
    );
  });

  it("a rectangle with a zero dimension never overlaps anything", () => {
    fc.assert(
      fc.property(anyRect, anyRect, (a, b) => {
        const flat = { ...a, width: 0 };
        expect(overlaps(flat, b)).toBe(false);
        expect(overlaps(b, flat)).toBe(false);
      }),
      { seed: Number(process.env.FC_SEED), numRuns: 300 },
    );
  });
});
