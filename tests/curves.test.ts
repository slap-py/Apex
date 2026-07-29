import assert from "node:assert/strict";
import test from "node:test";
import { analyzeCurves, type Coordinate } from "../lib/curves";

const line = (points: number[][]): Coordinate[] => points.map(([x, y]) => [x, y]);

test("does not emit a pace note for a straight route", () => {
  assert.deepEqual(analyzeCurves(line([[0, 0], [0.001, 0], [0.002, 0], [0.003, 0]])), []);
});

test("classifies a substantial bend with ordered, bounded output", () => {
  const curves = analyzeCurves(line([[0, 0], [0.0003, 0], [0.0006, 0], [0.0006, 0.0003], [0.0006, 0.0006], [0.0006, 0.0009]]));
  assert.equal(curves.length, 1);
  assert.equal(curves[0].direction, "left");
  assert.ok(curves[0].rating >= 1 && curves[0].rating <= 6);
  assert.ok(curves[0].lengthMeters >= 32);
  assert.ok(curves[0].routeEndMeters > curves[0].routeStartMeters);
});

test("keeps close opposing curves as separate calls", () => {
  const curves = analyzeCurves(line([[0, 0], [0.0003, 0], [0.0006, 0], [0.0006, 0.0003], [0.0006, 0.0006], [0.0009, 0.0006], [0.0012, 0.0006]]));
  assert.ok(curves.length >= 2);
  assert.notEqual(curves[0].direction, curves[1].direction);
});
