// The canvas of Workspace settings › Stages (ApiaryWeb.StagesLive.Index), registered as the
// page's colocated hook. The canvas is the page's editor, and the page owns the process
// document: this hook only draws the view the page sends (data-view on mount, then
// "stages:view" events) and sends back a selection ("select"), an order of stages
// ("reorder"), a move by the arrow keys ("move") and a new stage at a place
// ("add_stage"). The inspector under the canvas edits the selected stage.
//
// React and React Flow are vendored (assets/vendor/flow) and built as their own bundle,
// assets/js/canvas.js, fetched on the first mount of this hook and by no other page. If
// the bundle does not load, the hook shows the page's line in the box.
//
// Names and lines reach React as text props only; nothing here writes markup.

// The width of a stage card and the gap after it, in the canvas's units: the gap holds the
// "+" that adds a stage there. Workflow names longer than a card show in full in their
// title and the card's label.
export const CARD_WIDTH = 176
export const CARD_GAP = 44
// The "+" button's size, and its distance from the top of the line.
export const ADD_SIZE = 28
export const ADD_TOP = 8

// The canvas draws the cards at zoom 1, so their text matches the page's; a pinch or the
// zoom buttons change it within these bounds. Its height is the tallest card's at that
// zoom, with a margin above, where the zoom and "more" buttons sit, so they cover no card,
// and one below.
export const ZOOM = {start: 1, min: 0.75, max: 1.5}
export const MARGIN_TOP = 32
export const MARGIN_BOTTOM = 24

// The canvas's height for a tallest card of `tallest` units at `zoom`.
export const paneHeight = (tallest, zoom) => Math.ceil(tallest * zoom) + MARGIN_TOP + MARGIN_BOTTOM

// The left edge of the card at place `index`: a gap, with its "+", before the first card.
export const cardX = index => CARD_GAP + index * (CARD_WIDTH + CARD_GAP)

// The width of the line of `count` cards, with a "+" before each card and after the last.
export const lineWidth = count => CARD_GAP + count * (CARD_WIDTH + CARD_GAP)

// The cards of a line of `count` that are not whole in a canvas `width` px wide at
// `viewport` ({x, zoom}): `left` before its left edge, `right` past its right edge, each
// counted as whole cards; a card cut by an edge counts on that side.
export const outside = (count, {x, zoom}, width) => {
  let left = 0
  let right = 0
  for (let index = 0; index < count; index++) {
    const start = cardX(index) * zoom + x
    if (start < -0.5) left++
    else if (start + CARD_WIDTH * zoom > width + 0.5) right++
  }
  return {left, right}
}

// The viewport's x for `x`, kept so the line neither starts right of the canvas's left edge
// nor ends left of its right edge.
export const clampX = (x, count, zoom, width) => Math.min(0, Math.max(x, width - lineWidth(count) * zoom))

// The viewport's x after "→ more": the first card past the right edge becomes the first
// card in view.
export const panRight = (count, viewport, width) => {
  const {x, zoom} = viewport
  const index = Array.from({length: count}, (_, i) => i).find(
    i => cardX(i) * zoom + x >= -0.5 && (cardX(i) + CARD_WIDTH) * zoom + x > width + 0.5,
  )
  if (index === undefined) return x
  return clampX(-(cardX(index) - CARD_GAP) * zoom, count, zoom, width)
}

// The viewport's x after "← more": the last card before the left edge becomes the last
// card in view.
export const panLeft = (count, viewport, width) => {
  const {x, zoom} = viewport
  let index = -1
  for (let i = 0; i < count; i++) if (cardX(i) * zoom + x < -0.5) index = i
  if (index < 0) return x
  return clampX(width - (cardX(index) + CARD_WIDTH + CARD_GAP) * zoom, count, zoom, width)
}

// The viewport's x that shows the node from `start` to `end` (in the canvas's units) whole,
// with half a gap beside it, moving the line as little as it can.
export const revealX = (start, end, count, viewport, width) => {
  const {x, zoom} = viewport
  const pad = CARD_GAP / 2
  let next = x
  if (start * zoom + x < 0) next = -(start - pad) * zoom
  else if (end * zoom + x > width) next = width - (end + pad) * zoom
  return clampX(next, count, zoom, width)
}

const text = value => String(value ?? "")

// One step of a stage's sequence: a workflow, or a loop with its label and workflows.
const step = item =>
  item && typeof item === "object" && "loop" in item
    ? {loop: text(item.loop), workflows: (item.workflows || []).map(text)}
    : {workflow: text(item?.workflow)}

// Each workflow's mark, by name: whether the harness lists it, and its label as text.
// None for a page with no list of the harness's workflows.
const marks = value =>
  value && typeof value === "object" && !Array.isArray(value)
    ? Object.fromEntries(
        Object.entries(value).map(([name, mark]) => [
          text(name),
          {listed: mark?.listed === true, label: text(mark?.label)},
        ]),
      )
    : {}

// The nodes and edges React Flow draws for `view`: the stages in a line, left to right,
// each joined to the next by an arrow; where the person may edit, a "+" node before the
// first card, in each gap and after the last card, which adds a stage at that place. The
// nodes are in the line's order, a "+" between the cards it sits between, so Tab reaches
// them in that order.
export const layout = view => {
  const stages = Array.isArray(view?.stages) ? view.stages : []
  const editable = view?.editable === true
  const cards = stages.map((stage, index) => ({
    id: String(stage.id),
    type: "stage",
    position: {x: cardX(index), y: 0},
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
    data: {
      name: text(stage.name),
      sequence: (stage.sequence || []).map(step),
      gate: text(stage.gate),
      alerts: (stage.alerts || []).map(text),
      marks: marks(stage.marks),
    },
  }))
  // A "+" at place `at`: before the card there, or after the last. Its node is neither
  // dragged nor selected, so React Flow gives it no pointer events; the style gives them
  // back, so a click reaches the button.
  const add = at => ({
    id: `add:${at}`,
    type: "add",
    position: {x: at * (CARD_WIDTH + CARD_GAP) + (CARD_GAP - ADD_SIZE) / 2, y: ADD_TOP},
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
    focusable: false,
    selectable: false,
  }))
  return {nodes, edges}
}

// Whether a node is a stage card, not a "+".
export const isStage = node => node?.type === "stage"

// The stage ids after the card `id` is dropped with the pointer at `x`, in the canvas's
// units: the card takes the place of the slot under the pointer, the first or the last
// one beyond either end.
export const orderByDrop = (ids, id, x) => {
  if (!Number.isFinite(x)) return ids
  const rest = ids.filter(other => other !== id)
  if (rest.length === ids.length) return ids
  const slot = Math.floor((x - CARD_GAP / 2) / (CARD_WIDTH + CARD_GAP))
  const at = Math.min(Math.max(slot, 0), ids.length - 1)
  return [...rest.slice(0, at), id, ...rest.slice(at)]
}

// Where a card was dropped, in the canvas's units: the pointer's x, from a mouse event or
// the touch that ended (`changedTouches`), through `toFlow` (React Flow's
// screenToFlowPosition); the dropped card's middle when the event has no point.
export const dropX = (event, node, toFlow) => {
  const point = event?.changedTouches?.[0] ?? event
  if (Number.isFinite(point?.clientX) && Number.isFinite(point?.clientY)) {
    const {x} = toFlow({x: point.clientX, y: point.clientY})
    if (Number.isFinite(x)) return x
  }
  return node.position.x + CARD_WIDTH / 2
}

// The arrow key's move of a card: one place earlier ("-1") or later ("1"), or nil.
export const keyMove = key => ({ArrowLeft: "-1", ArrowRight: "1"})[key] ?? null

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
