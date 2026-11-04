import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("zero-size second rectangle", () => {
  it("zero width second rectangle strictly inside never overlaps", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(5, 2, 0, 5))).toBe(false);
  });
  it("zero height second rectangle strictly inside never overlaps", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(2, 5, 5, 0))).toBe(false);
  });
  it("zero size second rectangle inside never overlaps", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(5, 5, 0, 0))).toBe(false);
  });
  it("zero size in both argument orders is false", () => {
    expect(overlaps(rect(5, 2, 0, 5), rect(0, 0, 10, 10))).toBe(false);
    expect(overlaps(rect(2, 5, 5, 0), rect(0, 0, 10, 10))).toBe(false);
  });
});
