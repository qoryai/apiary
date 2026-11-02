// The Stages canvas's layout and order (assets/js/hooks/stages_canvas.js): the stages in a
// column, top to bottom, joined by arrows, a "+" in each gap and after the last card,
// loops as groups, text props only, the order a drag or the arrow keys leave, the
// viewport's bounds, and no "more" control. `node --test 'assets/js/test/*.test.mjs'` (no
// npm).

import {test} from "node:test"
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"

import * as canvas from "../hooks/stages_canvas.js"

const {
  ADD_SIZE,
  CARD_WIDTH,
  GAP,
  MARGIN_BOTTOM,
  MARGIN_TOP,
  SIDE,
  ZOOM,
  column,
  dropY,
  estimateHeight,
  fitViewport,
  isStage,
  keyMove,
  layout,
  orderByDrop,
  panExtent,
  paneHeight,
  revealY,
  sameOrder,
} = canvas

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

// Measured heights: Explore 160, Build 150, Release 120.
const heights = {st_a: 160, st_b: 150, st_c: 120}

const stages = (v, h = heights) => layout(v, h).nodes.filter(isStage)

test("stages lie in a column, top to bottom, at their measured heights", () => {
  const g = GAP.edit
  assert.deepEqual(
    stages(view).map(n => [n.id, n.position.x, n.position.y, n.selected]),
    [
      ["st_a", 0, g, false],
      ["st_b", 0, g + 160 + g, true],
      ["st_c", 0, g + 160 + g + 150 + g, false],
    ],
  )
  // The column ends with a gap after the last card, for its "+".
  assert.equal(layout(view, heights).length, g + 160 + g + 150 + g + 120 + g)
})

test("a view-only column has no gap before the first card or after the last", () => {
  const v = {...view, editable: false}
  assert.deepEqual(
    stages(v).map(n => n.position.y),
    [0, 160 + GAP.view, 160 + GAP.view + 150 + GAP.view],
  )
  assert.equal(layout(v, heights).length, 160 + GAP.view + 150 + GAP.view + 120)
  assert.deepEqual(column([], false), {tops: [], length: 0})
})

test("a card React Flow has not measured has its estimated height", () => {
  const nodes = stages(view, {})
  assert.equal(nodes[1].position.y - nodes[0].position.y, estimateHeight(nodes[0].data) + GAP.edit)
  // A loop's card is taller than a card with one workflow, and an alert adds a line.
  assert.ok(estimateHeight(nodes[0].data) > estimateHeight({...nodes[1].data, alerts: []}))
  assert.ok(estimateHeight(nodes[1].data) > estimateHeight({...nodes[1].data, alerts: []}))
})

test("each stage is joined to the next, and only to the next, by a straight arrow", () => {
  assert.deepEqual(
    layout(view).edges.map(e => [e.source, e.target, e.type]),
    [
      ["st_a", "st_b", "straight"],
      ["st_b", "st_c", "straight"],
    ],
  )
})

test("cards are 360 px wide", () => {
  assert.equal(CARD_WIDTH, 360)
})

test("names reach the card as text, unchanged, with the full label for a screen reader", () => {
  const card = stages(view)[2]
  assert.equal(card.data.name, "<b>Release</b>")
  assert.equal(card.ariaLabel, "<b>Release</b>")
  assert.equal(stages(view)[0].ariaLabel, view.stages[0].label)
  assert.deepEqual(stages(view)[1].data.alerts, ["x"])
})

test("a loop is a group of its workflows with its label inside one card; a workflow is a step", () => {
  assert.deepEqual(stages(view)[0].data.sequence, [{loop: "at most 3 rounds", workflows: ["explore-a-ticket"]}])
  assert.deepEqual(stages(view)[1].data.sequence, [{workflow: "build"}])
  assert.deepEqual(stages(view)[2].data.sequence, [])
  assert.equal(stages(view).length, 3)
})

test("a + sits above the first card, in each gap and below the last, and adds a stage there", () => {
  const nodes = layout(view, heights).nodes
  const adds = nodes.filter(n => n.type === "add")
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
  // Centred on the cards, and in its gap: below the card before it, above the card after.
  const cards = stages(view)
  for (const n of adds) {
    assert.equal(n.position.x + ADD_SIZE / 2, CARD_WIDTH / 2)
    const above = cards[n.data.at - 1]
    const below = cards[n.data.at]
    if (above) assert.ok(n.position.y >= above.position.y + heights[above.id])
    if (below) assert.ok(n.position.y + ADD_SIZE <= below.position.y)
    else assert.ok(n.position.y + ADD_SIZE <= layout(view, heights).length)
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
  assert.deepEqual(layout(undefined), {nodes: [], edges: [], length: 0})
})

// Four cards, 100 units tall, 72 apart: they start at 72, 244, 416 and 588.
const tops = [72, 244, 416, 588]
const ids = ["st_a", "st_b", "st_c", "st_d"]
const middle = n => tops[n] + 50

test("a card dropped with the pointer on another card takes that card's place", () => {
  // Across two cards: from the first place to the third.
  assert.deepEqual(orderByDrop(ids, "st_a", middle(2), tops, 72), ["st_b", "st_c", "st_a", "st_d"])
  assert.deepEqual(orderByDrop(ids, "st_d", middle(0), tops, 72), ["st_d", "st_a", "st_b", "st_c"])
  assert.deepEqual(orderByDrop(ids, "st_b", middle(1), tops, 72), ids)
  // A slot reaches to the middle of the gap: just above the third card is still its slot.
  assert.deepEqual(orderByDrop(ids, "st_a", tops[2] - 30, tops, 72), ["st_b", "st_c", "st_a", "st_d"])
  assert.deepEqual(orderByDrop(ids, "st_a", tops[2] - 40, tops, 72), ["st_b", "st_a", "st_c", "st_d"])
  // Beyond either end: the first or the last place.
  assert.deepEqual(orderByDrop(ids, "st_b", -500, tops, 72), ["st_b", "st_a", "st_c", "st_d"])
  assert.deepEqual(orderByDrop(ids, "st_a", 5000, tops, 72), ["st_b", "st_c", "st_d", "st_a"])
  assert.equal(sameOrder(orderByDrop(ids, "st_a", middle(2), tops, 72), ids), false)
  assert.equal(sameOrder(["st_a"], ["st_a"]), true)
})

test("a drop with no point keeps the order", () => {
  assert.deepEqual(orderByDrop(ids, "st_c", NaN, tops, 72), ids)
  assert.deepEqual(orderByDrop(ids, "st_c", undefined, tops, 72), ids)
})

test("a drop reads the pointer's y from a mouse or a touch, else the card's middle", () => {
  const toFlow = ({x, y}) => ({x, y: y - 100})
  const node = {position: {x: 0, y: tops[2]}, measured: {height: 100}, data: {}}
  assert.equal(dropY({clientX: 10, clientY: 400}, node, toFlow), 300)
  // A touch drag: a TouchEvent has no clientY; the touch that ended has.
  const touch = {clientX: undefined, changedTouches: [{clientX: 10, clientY: 250}]}
  assert.equal(dropY(touch, node, toFlow), 150)
  // No point at all: the card's middle, so the card stays where it was dropped.
  assert.equal(dropY({changedTouches: []}, node, toFlow), middle(2))
  assert.equal(dropY({clientX: 10, clientY: 10}, node, () => ({y: NaN})), middle(2))
  assert.deepEqual(orderByDrop(ids, "st_c", middle(2), tops, 72), ids)
})

test("up and down move a card one place; left and right move nothing", () => {
  assert.equal(keyMove("ArrowUp"), "-1")
  assert.equal(keyMove("ArrowDown"), "1")
  assert.equal(keyMove("ArrowLeft"), null)
  assert.equal(keyMove("ArrowRight"), null)
  assert.equal(keyMove("Enter"), null)
})

test("the cards start at zoom 1, and a pinch or the buttons zoom from 0.75 to 1.5", () => {
  assert.deepEqual(ZOOM, {start: 1, min: 0.75, max: 1.5})
})

test("outside a filling box the canvas is as tall as the column at its zoom, with the margins", () => {
  // The top margin has the zoom, Focus and Full screen buttons (28 px, 12 px from the
  // top) above the column, so they cover none of it.
  assert.ok(MARGIN_TOP >= 12 + 28 + 8)
  assert.equal(paneHeight(500, 1), 500 + MARGIN_TOP + MARGIN_BOTTOM)
  assert.equal(paneHeight(500, 1.5), 750 + MARGIN_TOP + MARGIN_BOTTOM)
  assert.equal(paneHeight(500, 0.75), 375 + MARGIN_TOP + MARGIN_BOTTOM)
})

test("the card is centred, and a short column starts at the top margin", () => {
  const size = {width: 900, height: 800}
  assert.deepEqual(fitViewport({x: 0, y: -300, zoom: 1}, size, 500), {x: 270, y: MARGIN_TOP, zoom: 1})
  assert.deepEqual(fitViewport({x: 0, y: 0, zoom: 1.5}, size, 400), {x: 180, y: MARGIN_TOP, zoom: 1.5})
})

test("a long column scrolls between its top and its end, and no further", () => {
  const size = {width: 900, height: 800}
  const end = 800 - MARGIN_BOTTOM - 2000
  assert.equal(fitViewport({x: 270, y: -500, zoom: 1}, size, 2000).y, -500)
  assert.equal(fitViewport({x: 270, y: 200, zoom: 1}, size, 2000).y, MARGIN_TOP)
  assert.equal(fitViewport({x: 270, y: -5000, zoom: 1}, size, 2000).y, end)
})

test("a card wider than the canvas scrolls sideways within its edges", () => {
  const size = {width: 320, height: 800}
  assert.equal(fitViewport({x: 100, y: 0, zoom: 1}, size, 300).x, SIDE)
  assert.equal(fitViewport({x: -500, y: 0, zoom: 1}, size, 300).x, 320 - CARD_WIDTH - SIDE)
  assert.equal(fitViewport({x: -10, y: 0, zoom: 1}, size, 300).x, -10)
})

test("the pan bounds stop a pan or the wheel where the fit does", () => {
  const size = {width: 900, height: 800}
  const zoom = 1
  const [[left, top], [right, bottom]] = panExtent(size, 2000, zoom)
  // The view's edges, in the canvas's units, at each end of the fit's range.
  const fitTop = fitViewport({x: 0, y: 1e6, zoom}, size, 2000)
  const fitEnd = fitViewport({x: 0, y: -1e6, zoom}, size, 2000)
  assert.equal(-fitTop.y / zoom, top)
  assert.equal((size.height - fitEnd.y) / zoom, bottom)
  assert.equal(-fitTop.x / zoom, left)
  assert.equal((size.width - fitTop.x) / zoom, right)
  // A short column: the bounds are the view itself, so nothing scrolls.
  const [[, shortTop], [, shortBottom]] = panExtent(size, 300, zoom)
  assert.equal((shortBottom - shortTop) * zoom, size.height)
})

test("a card that takes the focus is scrolled into view as little as it can", () => {
  const size = {width: 900, height: 600}
  const length = 2000
  // Below the view: its end comes to the bottom margin.
  assert.equal(revealY(1000, 1150, {x: 0, y: MARGIN_TOP, zoom: 1}, size, length), 600 - MARGIN_BOTTOM - 1150)
  // In view: no move.
  assert.equal(revealY(100, 250, {x: 0, y: MARGIN_TOP, zoom: 1}, size, length), MARGIN_TOP)
  // Above the view: its top comes to the top margin.
  assert.equal(revealY(300, 450, {x: 0, y: -800, zoom: 1}, size, length), MARGIN_TOP - 300)
})

test("each card has a ring on keyboard focus", () => {
  for (const node of stages(view)) assert.match(node.className, /focus-visible:!outline-primary/)
})

test("a canvas whose cards open nothing draws cards a click does not select", () => {
  assert.ok(stages(view).every(node => node.selectable === true))
  const preview = {...view, editable: false, selectable: false}
  assert.ok(stages(preview).every(node => node.selectable === false))
  // Tab stops on no card of the preview (React Flow gives a node that is not focusable no
  // tabindex), and on each card of the Stages page; each card stays a labelled group.
  assert.ok(stages(preview).every(node => node.focusable === false))
  assert.ok(stages(view).every(node => node.focusable === true))
  assert.ok([...stages(view), ...stages(preview)].every(n => n.ariaRole === "group" && n.ariaLabel))
  // View only: no "+", and no card to drag.
  assert.equal(layout(preview).nodes.filter(node => node.type === "add").length, 0)
  assert.ok(layout(preview).nodes.every(node => node.draggable === false))
})

test("there is no \"more\" control and no edge fade: extra stages are reached by scrolling", () => {
  for (const name of ["outside", "panLeft", "panRight", "clampX", "lineWidth"]) {
    assert.equal(name in canvas, false, name)
  }
  const bundle = readFileSync(new URL("../canvas.js", import.meta.url), "utf8")
  assert.doesNotMatch(bundle, /moreButton|more\(|fade|words\.(left|right)/)
  const component = readFileSync(
    new URL("../../../lib/apiary_web/live/stages_live/canvas.ex", import.meta.url),
    "utf8",
  )
  assert.doesNotMatch(component, /more stage|%\{count\} more/)
})

test("the canvas draws a dotted ground, 20 px apart, 1 px dots", () => {
  const bundle = readFileSync(new URL("../canvas.js", import.meta.url), "utf8")
  assert.match(bundle, /h\(Background, \{variant: "dots", gap: 20, size: 1\}\)/)
})
