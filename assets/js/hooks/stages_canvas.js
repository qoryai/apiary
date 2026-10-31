// The canvas of Workspace settings › Stages (ApiaryWeb.StagesLive.Index), registered as the
// page's colocated hook. The canvas is the page's editor, and the page owns the process
// document: this hook only draws the view the page sends (data-view on mount, then
// "stages:view" events) and sends back a selection ("select"), an order of stages
// ("reorder"), a move by the arrow keys ("move") and a new stage at a place
// ("add_stage"). The inspector beside the canvas edits the selected stage.
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

// The fitView options: never larger than zoom 1, and never smaller than 0.85, so the text
// stays readable; a longer line is shown from its start and scrolls sideways (the canvas
// pans on a drag of its background).
export const FIT = {padding: 0.04, maxZoom: 1, minZoom: 0.85}

// The width of the line of `count` cards, with the "+" after the last one.
export const lineWidth = count => count * (CARD_WIDTH + CARD_GAP)

const text = value => String(value ?? "")

// One step of a stage's sequence: a workflow, or a loop with its label and workflows.
const step = item =>
  item && typeof item === "object" && "loop" in item
    ? {loop: text(item.loop), workflows: (item.workflows || []).map(text)}
    : {workflow: text(item?.workflow)}

// The nodes and edges React Flow draws for `view`: the stages in a line, left to right,
// each joined to the next by an arrow; where the person may edit, a "+" node in each gap
// and after the last card, which adds a stage at that place.
export const layout = view => {
  const stages = Array.isArray(view?.stages) ? view.stages : []
  const editable = view?.editable === true
  const nodes = stages.map((stage, index) => ({
    id: String(stage.id),
    type: "stage",
    position: {x: index * (CARD_WIDTH + CARD_GAP), y: 0},
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
  const adds = editable
    ? stages.map((stage, index) => ({
        id: `add:${index + 1}`,
        type: "add",
        position: {x: index * (CARD_WIDTH + CARD_GAP) + CARD_WIDTH + (CARD_GAP - ADD_SIZE) / 2, y: ADD_TOP},
        draggable: false,
        selectable: false,
        focusable: false,
        data: {at: index + 1, label: text(stage.add)},
      }))
    : []
  const edges = nodes.slice(1).map((node, index) => ({
    id: `${nodes[index].id}->${node.id}`,
    source: nodes[index].id,
    target: node.id,
    focusable: false,
    selectable: false,
  }))
  return {nodes: [...nodes, ...adds], edges}
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
  const slot = Math.floor((x + CARD_GAP / 2) / (CARD_WIDTH + CARD_GAP))
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
