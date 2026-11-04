import * as fc from "fast-check";
import { describe, expect, it } from "vitest";
import { overlaps } from "../src/collision";

const anyRect = fc.record({
  x: fc.integer({ min: -10, max: 10 }),
  y: fc.integer({ min: -10, max: 10 }),
  width: fc.integer({ min: 0, max: 8 }),
  height: fc.integer({ min: 0, max: 8 }),
});

describe("overlaps matches half-open interval reference", () => {
  it("agrees with strict interval intersection on a small integer grid", () => {
    const seed = Number(process.env.FC_SEED);
    fc.assert(
      fc.property(anyRect, anyRect, (a, b) => {
        const expected =
          a.width > 0 &&
          a.height > 0 &&
          b.width > 0 &&
          b.height > 0 &&
          Math.max(a.x, b.x) < Math.min(a.x + a.width, b.x + b.width) &&
          Math.max(a.y, b.y) < Math.min(a.y + a.height, b.y + b.height);
        expect(overlaps(a, b)).toBe(expected);
      }),
      { seed, numRuns: 500 },
    );
  });
});
