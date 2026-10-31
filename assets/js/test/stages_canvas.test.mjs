// The Stages canvas's layout and order (assets/js/hooks/stages_canvas.js): the stages in a
// line joined by arrows, a "+" in each gap and after the last card, loops as groups, text
// props only, and the order a drag leaves.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  ADD_SIZE,
  CARD_GAP,
  CARD_WIDTH,
  FIT,
  cardX,
  dropX,
  isStage,
  keyMove,
  layout,
  lineWidth,
  orderByDrop,
  sameOrder,
} from "../hooks/stages_canvas.js"

const view = {
  editable: true,
  selected: "st_b",
  first: "Add a stage before Explore",
  stages: [
    {
      id: "st_a",
      name: "Explore",
      label: "Explore. a loop of explore-a-ticket, at most 3 rounds. Gate: a member approves",
      sequence: [{loop: "at most 3 rounds", workflows: ["explore-a-ticket"]}],
      gate: "Gate: a member approves",
      add: "Add a stage after Explore",
      alerts: [],
    },
    {id: "st_b", name: "Build", sequence: [{workflow: "build"}], gate: "No gate", add: "Add a stage after Build", alerts: ["x"]},
    {id: "st_c", name: "<b>Release</b>", sequence: [], gate: "", add: "Add a stage after <b>Release</b>", alerts: []},
  ],
}

const stages = v => layout(v).nodes.filter(isStage)

test("stages lie in a line, left to right, and the selected one is selected", () => {
  const nodes = stages(view)
  assert.deepEqual(
    nodes.map(n => [n.id, n.position.x, n.position.y, n.selected]),
    [
      ["st_a", CARD_GAP, 0, false],
      ["st_b", CARD_GAP + CARD_WIDTH + CARD_GAP, 0, true],
      ["st_c", CARD_GAP + 2 * (CARD_WIDTH + CARD_GAP), 0, false],
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

test("names reach the card as text, unchanged, with the full label for a screen reader", () => {
  const card = stages(view)[2]
  assert.equal(card.data.name, "<b>Release</b>")
  assert.equal(card.ariaLabel, "<b>Release</b>")
  assert.equal(stages(view)[0].ariaLabel, view.stages[0].label)
  assert.deepEqual(stages(view)[1].data.alerts, ["x"])
})

test("a loop is a group of its workflows with its label; a workflow is a step", () => {
  assert.deepEqual(stages(view)[0].data.sequence, [{loop: "at most 3 rounds", workflows: ["explore-a-ticket"]}])
  assert.deepEqual(stages(view)[1].data.sequence, [{workflow: "build"}])
  assert.deepEqual(stages(view)[2].data.sequence, [])
})

test("a + sits before the first card, in each gap and after the last, and adds a stage there", () => {
  const adds = layout(view).nodes.filter(n => n.type === "add")
  assert.deepEqual(
    adds.map(n => [n.data.at, n.data.label]),
    [
      [0, "Add a stage before Explore"],
      [1, "Add a stage after Explore"],
      [2, "Add a stage after Build"],
      [3, "Add a stage after <b>Release</b>"],
    ],
  )
  assert.ok(adds.every(n => n.draggable === false && n.selectable === false))
  // A click reaches the button: React Flow gives such a node no pointer events of its own.
  assert.ok(adds.every(n => n.style.pointerEvents === "all"))
  // In its gap: after the card before it, before the card after it.
  for (const n of adds) {
    if (n.data.at > 0) assert.ok(n.position.x >= cardX(n.data.at - 1) + CARD_WIDTH)
    assert.ok(n.position.x + ADD_SIZE <= cardX(n.data.at))
  }
})

test("Tab reaches each + between the cards it sits between", () => {
  assert.deepEqual(
    layout(view).nodes.map(n => n.id),
    ["add:0", "st_a", "add:1", "st_b", "add:2", "st_c", "add:3"],
  )
})

test("a member's canvas has no card to drag and no +", () => {
  const nodes = layout({...view, editable: false}).nodes
  assert.ok(nodes.every(n => n.draggable === false))
  assert.ok(nodes.every(isStage))
})

test("no view draws nothing", () => {
  assert.deepEqual(layout(undefined), {nodes: [], edges: []})
})

test("a card dropped with the pointer on another card takes that card's place", () => {
  const ids = ["st_a", "st_b", "st_c", "st_d"]
  const slot = n => cardX(n) + CARD_WIDTH / 2
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

test("a drop with no point keeps the order", () => {
  const ids = ["st_a", "st_b", "st_c"]
  assert.deepEqual(orderByDrop(ids, "st_c", NaN), ids)
  assert.deepEqual(orderByDrop(ids, "st_c", undefined), ids)
})

test("a drop reads the pointer of a mouse or a touch, else the card's middle", () => {
  const toFlow = ({x, y}) => ({x: x - 100, y})
  const node = {position: {x: 2 * (CARD_WIDTH + CARD_GAP), y: 0}}
  assert.equal(dropX({clientX: 400, clientY: 50}, node, toFlow), 300)
  // A touch drag: a TouchEvent has no clientX; the touch that ended has.
  const touch = {clientX: undefined, changedTouches: [{clientX: 250, clientY: 50}]}
  assert.equal(dropX(touch, node, toFlow), 150)
  // No point at all: the card's middle, so the card stays where it was dropped.
  const middle = node.position.x + CARD_WIDTH / 2
  assert.equal(dropX({changedTouches: []}, node, toFlow), middle)
  assert.equal(dropX({clientX: 10, clientY: 10}, node, () => ({x: NaN})), middle)
  assert.deepEqual(orderByDrop(["st_a", "st_b", "st_c"], "st_c", middle), ["st_a", "st_b", "st_c"])
})

test("left and right move a card one place; up and down move nothing", () => {
  assert.equal(keyMove("ArrowLeft"), "-1")
  assert.equal(keyMove("ArrowRight"), "1")
  assert.equal(keyMove("ArrowUp"), null)
  assert.equal(keyMove("Enter"), null)
})

test("five default stages fit a 960 px canvas at zoom 0.75 or more, and never past 1", () => {
  assert.equal(FIT.maxZoom, 1)
  assert.equal(FIT.minZoom, 0.75)
  assert.equal(lineWidth(5), CARD_GAP + 5 * (CARD_WIDTH + CARD_GAP))
  const zoom = (960 - 2) / (lineWidth(5) * (1 + FIT.padding))
  assert.ok(zoom >= 0.75, `zoom ${zoom}`)
})

test("each card has a ring on keyboard focus", () => {
  for (const node of stages(view)) assert.match(node.className, /focus-visible:!outline-primary/)
})
