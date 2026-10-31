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

// The width of a stage card and the gap after it, in the canvas's units.
export const CARD_WIDTH = 220
export const CARD_GAP = 60

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

// The stage ids ordered by where their cards are now, left to right.
export const orderByX = nodes => [...nodes].sort((a, b) => a.position.x - b.position.x).map(n => n.id)

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
