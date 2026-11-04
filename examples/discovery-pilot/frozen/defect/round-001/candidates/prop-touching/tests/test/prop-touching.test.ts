import * as fc from "fast-check";
import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const nonEmpty = fc.record({
  x: fc.integer({ min: -100, max: 100 }),
  y: fc.integer({ min: -100, max: 100 }),
  width: fc.integer({ min: 1, max: 30 }),
  height: fc.integer({ min: 1, max: 30 }),
});

describe("touching rectangles never overlap", () => {
  it("right-adjacent, bottom-adjacent and corner-adjacent placements", () => {
    const seed = Number(process.env.FC_SEED);
    fc.assert(
      fc.property(
        nonEmpty,
        nonEmpty,
        fc.integer({ min: -29, max: 29 }),
        (a, b, off) => {
          const right: Rect = { ...b, x: a.x + a.width, y: a.y + off };
          const below: Rect = { ...b, x: a.x + off, y: a.y + a.height };
          const corner: Rect = { ...b, x: a.x + a.width, y: a.y + a.height };
          const left: Rect = { ...b, x: a.x - b.width, y: a.y + off };
          const above: Rect = { ...b, x: a.x + off, y: a.y - b.height };
          for (const other of [right, below, corner, left, above]) {
            expect(overlaps(a, other)).toBe(false);
            expect(overlaps(other, a)).toBe(false);
          }
        },
      ),
      { seed, numRuns: 200 },
    );
  });
});
