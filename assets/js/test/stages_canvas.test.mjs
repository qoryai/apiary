// The Stages canvas's layout and order (assets/js/hooks/stages_canvas.js): the stages in a
// line joined by arrows, text props only, and the order a drag leaves.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {CARD_GAP, CARD_WIDTH, FIT, keyMove, layout, orderByDrop, sameOrder} from "../hooks/stages_canvas.js"

const view = {
  editable: true,
  selected: "st_b",
  stages: [
    {id: "st_a", name: "Explore", workflows: ["explore-a-ticket"], loop: "Loop", gate: "Gate", alerts: []},
    {id: "st_b", name: "Build", workflows: [], loop: "No loop", gate: "No gate", alerts: ["x"]},
    {id: "st_c", name: "<b>Release</b>", workflows: [], loop: "", gate: "", alerts: []},
  ],
}

test("stages lie in a line, left to right, and the selected one is selected", () => {
  const {nodes} = layout(view)
  assert.deepEqual(
    nodes.map(n => [n.id, n.position.x, n.position.y, n.selected]),
    [
      ["st_a", 0, 0, false],
      ["st_b", CARD_WIDTH + CARD_GAP, 0, true],
      ["st_c", 2 * (CARD_WIDTH + CARD_GAP), 0, false],
    ],
  )
})

test("each stage is joined to the next, and only to the next", () => {
  assert.deepEqual(
    layout(view).edges.map(e => [e.source, e.target]),
    [
      ["st_a", "st_b"],
      ["st_b", "st_c"],
    ],
  )
})

test("names reach the card as text, unchanged", () => {
  const card = layout(view).nodes[2]
  assert.equal(card.data.name, "<b>Release</b>")
  assert.equal(card.ariaLabel, "<b>Release</b>")
  assert.deepEqual(layout(view).nodes[1].data.alerts, ["x"])
})

test("a member's canvas has no card to drag", () => {
  assert.ok(layout({...view, editable: false}).nodes.every(n => n.draggable === false))
})

test("no view draws nothing", () => {
  assert.deepEqual(layout(undefined), {nodes: [], edges: []})
})

test("a card dropped with the pointer on another card takes that card's place", () => {
  const ids = ["st_a", "st_b", "st_c", "st_d"]
  const slot = n => n * (CARD_WIDTH + CARD_GAP) + CARD_WIDTH / 2
  // Across two cards: from the first place to the third.
  assert.deepEqual(orderByDrop(ids, "st_a", slot(2)), ["st_b", "st_c", "st_a", "st_d"])
  assert.deepEqual(orderByDrop(ids, "st_d", slot(0)), ["st_d", "st_a", "st_b", "st_c"])
  assert.deepEqual(orderByDrop(ids, "st_b", slot(1)), ids)
  // Beyond either end: the first or the last place.
  assert.deepEqual(orderByDrop(ids, "st_b", -500), ["st_b", "st_a", "st_c", "st_d"])
  assert.deepEqual(orderByDrop(ids, "st_a", 5000), ["st_b", "st_c", "st_d", "st_a"])
  assert.equal(sameOrder(orderByDrop(ids, "st_a", slot(2)), ids), false)
  assert.equal(sameOrder(["st_a"], ["st_a"]), true)
})

test("left and right move a card one place; up and down move nothing", () => {
  assert.equal(keyMove("ArrowLeft"), "-1")
  assert.equal(keyMove("ArrowRight"), "1")
  assert.equal(keyMove("ArrowUp"), null)
  assert.equal(keyMove("Enter"), null)
})

test("five default stages fit about 800 px at zoom 1, and fitView never zooms past 1", () => {
  assert.ok(5 * CARD_WIDTH + 4 * CARD_GAP <= 800 / (1 + 2 * FIT.padding))
  assert.equal(FIT.maxZoom, 1)
})

test("each card has a ring on keyboard focus", () => {
  for (const node of layout(view).nodes) assert.match(node.className, /focus-visible:!outline-primary/)
})
