import { describe, expect, it } from "vitest";
import { overlaps, type Rect } from "../src/collision";

const rect = (x: number, y: number, width: number, height: number): Rect => ({ x, y, width, height });

describe("overlaps touching on x edge", () => {
  it("a's right edge touches b's left edge", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(10, 0, 10, 10))).toBe(false);
  });

  it("b's right edge touches a's left edge", () => {
    expect(overlaps(rect(10, 0, 10, 10), rect(0, 0, 10, 10))).toBe(false);
  });

  it("touching with partially offset y range", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(10, 5, 10, 10))).toBe(false);
    expect(overlaps(rect(10, 5, 10, 10), rect(0, 0, 10, 10))).toBe(false);
  });

  it("one unit of penetration on x does overlap", () => {
    expect(overlaps(rect(0, 0, 10, 10), rect(9, 0, 10, 10))).toBe(true);
  });
});
