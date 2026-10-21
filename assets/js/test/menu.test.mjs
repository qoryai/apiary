// Where a floating menu's list goes (assets/js/hooks/menu.js, `spot`): under its trigger,
// right edges aligned, and never nearer than 8px to the viewport's left edge.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {spot} from "../hooks/menu.js"

const VIEWPORT = {width: 1280, height: 800}

// A trigger's box, as getBoundingClientRect gives it: 32px tall, from `left` to `right`.
const box = (left, right, top = 100) => ({left, right, top, bottom: top + 32})

test("a list goes under its trigger, its right edge on the trigger's", () => {
  assert.deepEqual(spot(box(1100, 1200), 240, 300, VIEWPORT), {top: 136, right: 80})
})

test("a list with no room below goes above its trigger", () => {
  assert.deepEqual(spot(box(1100, 1200, 700), 240, 300, VIEWPORT), {top: 396, right: 80})
})

test("a list keeps 8px from the right edge when its trigger reaches it", () => {
  assert.deepEqual(spot(box(1200, 1278), 240, 300, VIEWPORT), {top: 136, right: 8})
})

test("a list wider than the room left of its trigger starts 8px from the left edge", () => {
  // The trigger's right edge is at 120px: a 300px list right-aligned to it would start at
  // -180px.
  assert.deepEqual(spot(box(40, 120), 300, 200, VIEWPORT), {top: 136, left: 8})
})

test("a list that would start exactly 8px from the left edge stays right-aligned", () => {
  assert.deepEqual(spot(box(40, 248), 240, 200, VIEWPORT), {top: 136, right: 1032})
})

test("a phone: a list right-aligned to a trigger near the left edge starts at 8px", () => {
  const phone = {width: 375, height: 667}
  assert.deepEqual(spot(box(16, 200), 300, 200, phone), {top: 136, left: 8})
})
