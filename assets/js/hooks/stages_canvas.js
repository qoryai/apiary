// The Stages canvas (ApiaryWeb.StagesLive.Canvas), registered as the component's colocated
// hook, on Workspace settings › Stages, Instance settings › Workspace types and a
// workspace type's page. The page owns the process document: this hook only draws the view the page
// sends (data-view on mount, then "stages:view" events) and sends back a selection
// ("select"), an order of stages ("reorder"), a move by the arrow keys ("move") and a new
// stage at a place ("add_stage"). The inspector beside the canvas edits the selected stage.
//
// React and React Flow are vendored (assets/vendor/flow) and built as their own bundle,
// assets/js/canvas.js, fetched on the first mount of this hook and by no other page. If
// the bundle does not load, the hook shows the page's line in the box.
//
// Names and lines reach React as text props only; nothing here writes markup.

// The stages lie in a column, top to bottom, each card CARD_WIDTH wide at x 0. A card is as
// tall as its lines; React Flow measures it, and until then its height is estimated. Where
// the person may edit, a gap with a "+" sits before the first card and after the last.
export const CARD_WIDTH = 360
// The gap between two cards, in the canvas's units: wider where it has a "+".
export const GAP = {edit: 72, view: 56}
// The "+" button's size.
export const ADD_SIZE = 28

// The canvas draws the cards at zoom 1, so their text matches the page's; a pinch or the
// zoom buttons change it within these bounds. Above the column is a margin, where the
// zoom, Focus and Full screen buttons sit, and below it a smaller one. A card wider than
// the canvas keeps SIDE px of air at each edge.
export const ZOOM = {start: 1, min: 0.75, max: 1.5}
export const MARGIN_TOP = 56
export const MARGIN_BOTTOM = 24
export const SIDE = 16

// A card's lines, in px: the padding and border, the name, and each line under it with
// the gap before it. Only for the height of a card React Flow has not measured yet.
const CARD_FRAME = 34
const NAME_LINE = 26
const LINE = 24
const ROW_GAP = 8
const LOOP_FRAME = 38

// The estimated height of a card with `data` (layout's card data).
export const estimateHeight = data => {
  const sequence = data?.sequence || []
  const steps =
    sequence.length === 0
      ? [LINE]
      : sequence.map(item => ("loop" in item ? LOOP_FRAME + item.workflows.length * LINE : LINE))
  const rows = [...steps, LINE, ...(data?.alerts || []).map(() => LINE)]
  return CARD_FRAME + NAME_LINE + rows.reduce((sum, row) => sum + ROW_GAP + row, 0)
}

const gapOf = editable => (editable ? GAP.edit : GAP.view)

// The column for cards of `heights` (in order): each card's top, and the column's length,
// with the gap before the first card and after the last where the person may edit.
export const column = (heights, editable) => {
  const gap = gapOf(editable)
  const lead = editable ? gap : 0
  const tops = []
  let y = lead
  heights.forEach((height, index) => {
    if (index > 0) y += gap
    tops.push(y)
    y += height
  })
  return {tops, length: heights.length === 0 ? 0 : y + lead}
}

// The canvas's height outside a filling box: the whole column at `zoom`, with the margins.
export const paneHeight = (length, zoom) => Math.ceil(length * zoom) + MARGIN_TOP + MARGIN_BOTTOM

const clamp = (value, low, high) => Math.min(high, Math.max(low, value))

// The viewport for `viewport` ({x, y, zoom}) in a canvas of `size` ({width, height}) px
// showing a column `length` units long. The card is centred when it fits the width, and
// otherwise kept within SIDE px of each edge. The column starts at the top margin when it
// fits the height, and otherwise scrolls between its top at the top margin and its end at
// the bottom margin.
export const fitViewport = ({x, y, zoom}, {width, height}, length) => {
  const card = CARD_WIDTH * zoom
  const nextX = card + 2 * SIDE <= width ? (width - card) / 2 : clamp(x, width - card - SIDE, SIDE)
  const end = height - MARGIN_BOTTOM - length * zoom
  const nextY = end >= MARGIN_TOP ? MARGIN_TOP : clamp(y, end, MARGIN_TOP)
  return {x: nextX, y: nextY, zoom}
}

// React Flow's translateExtent for the same canvas at `zoom`: the area, in the canvas's
// units, that a pan or the wheel keeps the view inside, so they stop where fitViewport
// does.
export const panExtent = ({width, height}, length, zoom) => {
  const fits = CARD_WIDTH * zoom + 2 * SIDE <= width
  const left = fits ? CARD_WIDTH / 2 - width / (2 * zoom) : -SIDE / zoom
  const right = fits ? CARD_WIDTH / 2 + width / (2 * zoom) : CARD_WIDTH + SIDE / zoom
  const top = -MARGIN_TOP / zoom
  const bottom = Math.max(length + MARGIN_BOTTOM / zoom, (height - MARGIN_TOP) / zoom)
  return [
    [left, top],
    [right, bottom],
  ]
}

// The viewport's y that shows the node from `start` to `end` (in the canvas's units)
// whole, between the margins, moving the column as little as it can.
export const revealY = (start, end, viewport, size, length) => {
  const {y, zoom} = viewport
  let next = y
  if (start * zoom + y < MARGIN_TOP) next = MARGIN_TOP - start * zoom
  else if (end * zoom + y > size.height - MARGIN_BOTTOM) next = size.height - MARGIN_BOTTOM - end * zoom
  return fitViewport({...viewport, y: next}, size, length).y
}

const text = value => String(value ?? "")

// One step of a stage's sequence: a workflow, or a loop with its label and workflows.
const step = item =>
  item && typeof item === "object" && "loop" in item
    ? {loop: text(item.loop), workflows: (item.workflows || []).map(text)}
    : {workflow: text(item?.workflow)}

// The nodes and edges React Flow draws for `view`, and the column's length: the stages in
// a column, top to bottom, each joined to the next by an arrow; where the person may edit,
// a "+" node before the first card, in each gap and after the last card, which adds a
// stage at that place. `heights` maps a stage id to its card's measured height; a card
// with none has its estimated height. The nodes are in the column's order, a "+" between
// the cards it sits between, so Tab reaches them in that order.
export const layout = (view, heights = {}) => {
  const stages = Array.isArray(view?.stages) ? view.stages : []
  const editable = view?.editable === true
  const data = stages.map(stage => ({
    name: text(stage.name),
    sequence: (stage.sequence || []).map(step),
    gate: text(stage.gate),
    alerts: (stage.alerts || []).map(text),
  }))
  const sizes = stages.map((stage, index) => heights[String(stage.id)] || estimateHeight(data[index]))
  const {tops, length} = column(sizes, editable)
  const gap = gapOf(editable)
  const cards = stages.map((stage, index) => ({
    id: String(stage.id),
    type: "stage",
    position: {x: 0, y: tops[index]},
    selected: stage.id === view.selected,
    // A card of a canvas whose cards open nothing is not selected by a click, and Tab
    // passes it by (no tabindex). It stays a labelled group, with the canvas's card
    // description, so a screen reader still reads each stage.
    selectable: view?.selectable !== false,
    focusable: view?.selectable !== false,
    ariaRole: "group",
    draggable: editable,
    // A ring on keyboard focus: React Flow's stylesheet draws none for a custom node.
    className:
      "rounded-box focus-visible:!outline-2 focus-visible:!outline-offset-2 focus-visible:!outline-primary",
    ariaLabel: text(stage.label || stage.name),
    data: data[index],
  }))
  // A "+" at place `at`: in the middle of the gap before the card there, or of the gap
  // after the last. Its node is neither dragged nor selected, so React Flow sets its
  // pointer events to none; the style sets them to all, so a click reaches the button.
  const add = at => ({
    id: `add:${at}`,
    type: "add",
    position: {
      x: (CARD_WIDTH - ADD_SIZE) / 2,
      y: (at < cards.length ? tops[at] - gap / 2 : length - gap / 2) - ADD_SIZE / 2,
    },
    draggable: false,
    selectable: false,
    focusable: false,
    style: {pointerEvents: "all"},
    data: {at, label: text(at === 0 ? view.first : stages[at - 1].add)},
  })
  const nodes =
    editable && cards.length > 0
      ? [...cards.flatMap((card, index) => [add(index), card]), add(cards.length)]
      : cards
  const edges = cards.slice(1).map((card, index) => ({
    id: `${cards[index].id}->${card.id}`,
    source: cards[index].id,
    target: card.id,
    type: "straight",
    focusable: false,
    selectable: false,
  }))
  return {nodes, edges, length}
}

// Whether a node is a stage card, not a "+".
export const isStage = node => node?.type === "stage"

// The stage ids after the card `id` is dropped with the pointer at `y`, in the canvas's
// units, on a column whose cards start at `tops` (in the order `ids`) with `gap` between
// them: the card takes the place of the slot under the pointer, the first or the last
// one beyond either end. A slot reaches from the middle of the gap before its card to
// the middle of the gap after it.
export const orderByDrop = (ids, id, y, tops, gap) => {
  if (!Number.isFinite(y)) return ids
  const rest = ids.filter(other => other !== id)
  if (rest.length === ids.length) return ids
  const at = tops.slice(1).filter(top => y >= top - gap / 2).length
  return [...rest.slice(0, at), id, ...rest.slice(at)]
}

// Where a card was dropped, in the canvas's units: the pointer's y, from a mouse event or
// the touch that ended (`changedTouches`), through `toFlow` (React Flow's
// screenToFlowPosition); the dropped card's middle when the event has no point.
export const dropY = (event, node, toFlow) => {
  const point = event?.changedTouches?.[0] ?? event
  if (Number.isFinite(point?.clientX) && Number.isFinite(point?.clientY)) {
    const {y} = toFlow({x: point.clientX, y: point.clientY})
    if (Number.isFinite(y)) return y
  }
  return node.position.y + (node.measured?.height ?? estimateHeight(node.data)) / 2
}

// The arrow key's move of a card: one place earlier ("-1") or later ("1"), or nil.
export const keyMove = key => ({ArrowUp: "-1", ArrowDown: "1"})[key] ?? null

// Whether two orders differ.
export const sameOrder = (a, b) => a.length === b.length && a.every((id, i) => id === b[i])

let library = null

const load = (script, stylesheet) => {
  if (window.QoryStagesCanvas) return Promise.resolve(window.QoryStagesCanvas)
  if (library) return library
  library = new Promise((resolve, reject) => {
    const link = document.createElement("link")
    link.rel = "stylesheet"
    link.href = stylesheet
    document.head.appendChild(link)
    const tag = document.createElement("script")
    tag.src = script
    tag.onload = () =>
      window.QoryStagesCanvas ? resolve(window.QoryStagesCanvas) : reject(new Error("canvas bundle"))
    tag.onerror = () => {
      library = null
      tag.remove()
      reject(new Error("canvas bundle"))
    }
    document.head.appendChild(tag)
  })
  return library
}

const parse = text => {
  try {
    return JSON.parse(text || "{}")
  } catch (_err) {
    return {}
  }
}

export const StagesCanvas = {
  mounted() {
    this.view = parse(this.el.dataset.view)
    this.words = parse(this.el.dataset.words)
    this.handleEvent("stages:view", view => {
      this.view = view
      if (this.canvas) this.canvas.update(view)
    })
    load(this.el.dataset.script, this.el.dataset.stylesheet)
      .then(lib => {
        if (this.gone) return
        this.canvas = lib.mount(this.el.querySelector("[data-canvas]"), {
          view: this.view,
          words: this.words,
          push: (event, payload) => this.pushEvent(event, payload),
        })
      })
      .catch(() => {
        const note = this.el.querySelector("[data-canvas-failed]")
        if (note) note.hidden = false
      })
  },
  destroyed() {
    this.gone = true
    if (this.canvas) this.canvas.destroy()
  },
}
