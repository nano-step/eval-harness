# Axis-aligned rectangle collision contract

This document is the task specification for the discovery pilot benchmark. The benchmark is
modelled on axis-aligned rectangle collision as used by 2D canvas tooling. It is a self-contained
fixture; the actual `img2pixi2d` plugin has no collision implementation and this code is not part
of it.

## Data model

A rectangle has `x`, `y`, `width` and `height`.

- `x` and `y` are finite numbers. Negative coordinates are valid.
- `width` and `height` are finite numbers that are greater than or equal to zero.
- A rectangle with a non-finite value or a negative size is invalid. Every function in this module
  throws a `RangeError` when it receives an invalid rectangle.

## Overlap

`overlaps(a, b)` is `true` only when the interiors of `a` and `b` intersect in an area greater than
zero. A rectangle covers the half-open ranges `[x, x + width)` and `[y, y + height)`.

- Rectangles that only touch along an edge or at a corner do not overlap.
- A rectangle with a width or height of zero has no interior. It never overlaps another rectangle,
  including an identical zero-size rectangle and a rectangle that fully surrounds it.
- Two identical rectangles with a non-zero size overlap, and a rectangle overlaps another
  rectangle that fully contains it.
- Overlap is symmetric: `overlaps(a, b)` equals `overlaps(b, a)`.
- Overlap is translation invariant: moving both rectangles by the same offset does not change the
  result.

## Movement

`translate(rect, dx, dy)` returns a new rectangle moved by `dx` and `dy` with the same size.

`collidesAfterMove(moving, dx, dy, obstacle)` is `overlaps(translate(moving, dx, dy), obstacle)`.
A rectangle that moves until it is exactly flush against an obstacle does not collide with it.
Moving one unit further into the obstacle does collide.
