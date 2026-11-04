import * as fc from "fast-check";
import { describe, expect, it } from "vitest";
import { overlaps, translate } from "../src/collision";

const anyRect = fc.record({
  x: fc.integer({ min: -20, max: 20 }),
  y: fc.integer({ min: -20, max: 20 }),
  width: fc.integer({ min: 0, max: 8 }),
  height: fc.integer({ min: 0, max: 8 }),
});

describe("overlap properties", () => {
  it("is symmetric and translation invariant, and false whenever a rectangle is empty", () => {
    fc.assert(
      fc.property(anyRect, anyRect, fc.integer({ min: -30, max: 30 }), fc.integer({ min: -30, max: 30 }), (a, b, dx, dy) => {
        const r = overlaps(a, b);
        expect(r).toBe(overlaps(b, a));
        expect(r).toBe(overlaps(translate(a, dx, dy), translate(b, dx, dy)));
        if (a.width === 0 || a.height === 0 || b.width === 0 || b.height === 0) {
          expect(r).toBe(false);
        }
      }),
      { seed: Number(process.env.FC_SEED), numRuns: 300 },
    );
  });

  it("a rectangle placed flush to the right never overlaps", () => {
    fc.assert(
      fc.property(anyRect, fc.integer({ min: -5, max: 5 }), (a, dy) => {
        const b = { x: a.x + a.width, y: a.y + dy, width: 3, height: 3 };
        expect(overlaps(a, b)).toBe(false);
        expect(overlaps(b, a)).toBe(false);
      }),
      { seed: Number(process.env.FC_SEED), numRuns: 300 },
    );
  });
});
