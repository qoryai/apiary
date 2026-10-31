// The canvas of Workspace settings › Stages (ApiaryWeb.StagesLive.Index), registered as the
// page's colocated hook. The page owns the process document: this hook only draws the
// view the page sends (data-view on mount, then "stages:view" events) and sends back
// a selection ("select") and an order of stages ("reorder"). Every other change, and
// every change the canvas makes, also has a button in the page's markup.
//
// React and React Flow are vendored (assets/vendor/flow) and built as their own bundle,
// assets/js/canvas.js, fetched on the first mount of this hook and by no other page. If
// the bundle does not load, the hook shows the page's line under the box, and the list
// of stages under it still does everything.
//
// Names and lines reach React as text props only; nothing here writes markup.

// The width of a stage card and the gap after it, in the canvas's units. Five cards, the
// default process, fit a canvas about 800 px wide at zoom 1, the most fitView zooms in.
export const CARD_WIDTH = 136
export const CARD_GAP = 20

// The fitView options: little padding, and never larger than zoom 1.
export const FIT = {padding: 0.02, maxZoom: 1}

// The nodes and edges React Flow draws for `view`: the stages in a line, left to right,
// each joined to the next by an arrow.
export const layout = view => {
  const stages = Array.isArray(view?.stages) ? view.stages : []
  const nodes = stages.map((stage, index) => ({
    id: String(stage.id),
    type: "stage",
    position: {x: index * (CARD_WIDTH + CARD_GAP), y: 0},
    selected: stage.id === view.selected,
    draggable: view.editable === true,
    // A ring on keyboard focus: React Flow's stylesheet draws none for a custom node.
    className:
      "rounded-box focus-visible:!outline-2 focus-visible:!outline-offset-2 focus-visible:!outline-primary",
    ariaLabel: String(stage.name ?? ""),
    data: {
      name: String(stage.name ?? ""),
      workflows: (stage.workflows || []).map(String),
      loop: String(stage.loop ?? ""),
      gate: String(stage.gate ?? ""),
      alerts: (stage.alerts || []).map(String),
    },
  }))
  const edges = nodes.slice(1).map((node, index) => ({
    id: `${nodes[index].id}->${node.id}`,
    source: nodes[index].id,
    target: node.id,
    focusable: false,
    selectable: false,
  }))
  return {nodes, edges}
}

// The stage ids after the card `id` is dropped with the pointer at `x`, in the canvas's
// units: the card takes the place of the slot under the pointer, the first or the last
// one beyond either end.
export const orderByDrop = (ids, id, x) => {
  const rest = ids.filter(other => other !== id)
  if (rest.length === ids.length) return ids
  const slot = Math.floor((x + CARD_GAP / 2) / (CARD_WIDTH + CARD_GAP))
  const at = Math.min(Math.max(slot, 0), ids.length - 1)
  return [...rest.slice(0, at), id, ...rest.slice(at)]
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
