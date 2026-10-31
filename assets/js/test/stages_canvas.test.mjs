// The Stages canvas's layout and order (assets/js/hooks/stages_canvas.js): the stages in a
// line joined by arrows, text props only, and the order a drag leaves.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {CARD_GAP, CARD_WIDTH, layout, orderByX, sameOrder} from "../hooks/stages_canvas.js"

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

test("a card dragged past another changes the order", () => {
  const nodes = layout(view).nodes.map(n => (n.id === "st_a" ? {...n, position: {x: 300, y: 40}} : n))
  const order = orderByX(nodes)
  assert.deepEqual(order, ["st_b", "st_a", "st_c"])
  assert.equal(sameOrder(order, ["st_a", "st_b", "st_c"]), false)
  assert.equal(sameOrder(["st_a"], ["st_a"]), true)
})
