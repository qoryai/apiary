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

// The fitView options: never larger than zoom 1, and never smaller than 0.75, so the text
// stays readable (five default stages fit 960 px at about 0.8); a longer line is shown
// from its start and pans, with the selected card kept in view.
export const FIT = {padding: 0.04, maxZoom: 1, minZoom: 0.75}

// The left edge of the card at place `index`: a gap, with its "+", before the first card.
export const cardX = index => CARD_GAP + index * (CARD_WIDTH + CARD_GAP)

// The width of the line of `count` cards, with a "+" before each card and after the last.
export const lineWidth = count => CARD_GAP + count * (CARD_WIDTH + CARD_GAP)

const text = value => String(value ?? "")

// One step of a stage's sequence: a workflow, or a loop with its label and workflows.
const step = item =>
  item && typeof item === "object" && "loop" in item
    ? {loop: text(item.loop), workflows: (item.workflows || []).map(text)}
    : {workflow: text(item?.workflow)}

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
