// The canvas bundle of the Stages canvas: React and React Flow (@xyflow/react), vendored
// under assets/vendor/flow (see assets/vendor/README.md). A separate esbuild entry, so only
// the pages with the canvas download it: the StagesCanvas hook (hooks/stages_canvas.js)
// adds this script and the stylesheet esbuild writes beside it (canvas.css) on first
// mount, then calls `mount`.
//
// The canvas is the page's editor. It draws the view the page sends and sends back:
// "select", with a stage id, on a click or Enter on a card; "reorder", with every stage
// id in the new order, after a card is dropped; "move", one place earlier or later, on
// the up and down arrow keys, with the focus kept on the moved card; and "add_stage",
// with the place, from a "+" before the first card, between two cards or after the last.
// The cards lie in a column, top to bottom, on a dotted ground. A card or "+" that takes
// the focus is scrolled into view, and so is the selected card; after a "+", the new stage
// is selected, scrolled to, and its name field in the inspector takes the focus with its
// text selected. The cards are drawn at zoom 1 from the first stage.
//
// In a box that fills the window (`.q-canvas-fill`, app.css) the wheel scrolls the
// column; elsewhere the canvas is as tall as the column and the wheel scrolls the page. A
// pinch or the zoom buttons zoom. Focus (`f`) sets the box to fill the window until
// Escape, and Full screen sets it to fill the screen. All text reaches React as props and is rendered as text.
import {
  createContext,
  createElement as h,
  memo,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react"
import {createRoot} from "react-dom/client"
import {
  Background,
  ReactFlow,
  ReactFlowProvider,
  Handle,
  Position,
  MarkerType,
  applyNodeChanges,
  useReactFlow,
  useViewport,
} from "../vendor/flow/xyflow-react/index.js"
import "../vendor/flow/xyflow-react/style.css"
import {
  ADD_SIZE,
  CARD_WIDTH,
  GAP,
  MARGIN_TOP,
  SIDE,
  ZOOM,
  dropY,
  fitViewport,
  isStage,
  keyMove,
  layout,
  orderByDrop,
  panExtent,
  paneHeight,
  revealY,
  sameOrder,
} from "./hooks/stages_canvas"
import {singleKeys} from "./hooks/shortcuts"

// The class on <html> while a canvas has Focus (app.css).
const FOCUS_CLASS = "q-canvas-focus"

// A key that is typed into a field, not a shortcut.
const typing = target =>
  !!target && (target.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(target.tagName))

// The page's push and words, and what a "+" does, for the nodes React Flow draws.
const Page = createContext({push: () => {}, words: {}, add: () => {}})

const line = (text, key, className) => h("p", {key, className, title: text}, text)

// A workflow's name on one line, cut with an ellipsis, in full in its title and label.
// Where the page has the harness's list, a check or a cross before it: a different shape,
// not only a different colour, with the mark's words in the title and the label.
const workflow = (name, key, mark) =>
  mark
    ? h(
        "p",
        {
          key,
          className: "flex min-w-0 items-center gap-1 text-[16px]/6",
          title: mark.label,
          "aria-label": mark.label,
          "data-mark": mark.listed ? "listed" : "missing",
        },
        h(
          "span",
          {"aria-hidden": "true", className: mark.listed ? "shrink-0 text-success" : "shrink-0 text-error"},
          mark.listed ? "\u2713" : "\u2717",
        ),
        h("span", {className: "truncate font-mono", "aria-hidden": "true"}, name),
      )
    : h("p", {key, className: "truncate font-mono text-[16px]/6", title: name, "aria-label": name}, name)

// The mark set for `name`, read with hasOwn: a name such as "constructor" is a key of every object.
const markOf = (marks, name) => (marks && Object.hasOwn(marks, name) ? marks[name] : undefined)

const steps = (sequence, words, marks) =>
  sequence.length === 0
    ? [line(words.no_workflow, "none", "text-muted")]
    : sequence.map((item, i) =>
        "loop" in item
          ? // A loop: a bracket around its workflows, labelled with its rounds.
            h(
              "div",
              {
                key: `s${i}`,
                role: "group",
                "aria-label": item.loop,
                className: "grid gap-0.5 rounded-[6px] border border-dashed border-base-content/35 px-2.5 pb-2 pt-1.5",
              },
              h("p", {className: "text-[14px]/5 text-muted", "aria-hidden": "true"}, item.loop),
              ...item.workflows.map((name, j) => workflow(name, `w${j}`, markOf(marks, name))),
            )
          : workflow(item.workflow, `s${i}`, markOf(marks, item.workflow)),
      )

const StageCard = memo(({data, selected}) => {
  const {words} = useContext(Page)
  return h(
    "div",
    {
      className: [
        "grid gap-2 rounded-box border bg-base-100 px-[18px] py-4 text-left text-[16px]/6 shadow-sm",
        selected ? "border-primary ring-2 ring-primary" : "border-base-300",
      ].join(" "),
      style: {width: CARD_WIDTH},
    },
    h(Handle, {type: "target", position: Position.Top, isConnectable: false, className: "!opacity-0"}),
    line(data.name, "name", "truncate text-[18px]/[26px] font-semibold text-base-content"),
    ...steps(data.sequence, words, data.marks),
    line(data.gate, "gate", "text-muted"),
    ...data.alerts.map((text, i) => line(text, `a${i}`, "text-error")),
    h(Handle, {type: "source", position: Position.Bottom, isConnectable: false, className: "!opacity-0"}),
  )
})

// A "+" between two cards, or after the last: adds a stage at its place.
const AddNode = memo(({data}) => {
  const {add} = useContext(Page)
  return h(
    "button",
    {
      type: "button",
      className:
        "nodrag nopan pointer-events-auto grid place-items-center rounded-full border border-base-300 bg-base-100 text-[16px]/none text-base-content shadow-sm hover:border-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary",
      style: {width: ADD_SIZE, height: ADD_SIZE},
      "aria-label": data.label,
      title: data.label,
      onClick: () => add(data.at),
    },
    h("span", {"aria-hidden": "true"}, "+"),
  )
})

const nodeTypes = {stage: StageCard, add: AddNode}

const theme = () =>
  (document.documentElement.dataset.theme || "").includes("dark") ? "dark" : "light"

const moved = (a, b) => Math.abs(a.x - b.x) > 0.5 || Math.abs(a.y - b.y) > 0.5

// `fresh` (layout's nodes) with the size React Flow measured for each node in `current`,
// so a new view moves the cards without hiding them to measure them again.
const keepMeasured = (fresh, current) => {
  const sizes = new Map(current.map(node => [node.id, node.measured]))
  return fresh.map(node => (sizes.get(node.id) ? {...node, measured: sizes.get(node.id)} : node))
}

// The box Focus and Full screen give the window or the screen: the filling box with the
// canvas and the inspector beside it, or the canvas's box alone.
const boxOf = el => el.closest(".q-canvas-fill") || el.closest(".q-canvas") || el

function Flow({initial, words, push, subscribe, el}) {
  const [view, setView] = useState(initial)
  // Each card's measured height, by stage id, for the column's positions.
  const heights = useRef({})
  const [nodes, setNodes] = useState(() => layout(initial).nodes)
  // The viewport after each pan or zoom, by the pointer or by a button.
  const viewport = useViewport()
  const [size, setSize] = useState(() => ({width: el.clientWidth, height: el.clientHeight}))
  const sizeRef = useRef(size)
  sizeRef.current = size
  const viewRef = useRef(initial)
  // The card the arrow keys moved, to focus again once the page sends the new order.
  const focusId = useRef(null)
  // Set by a "+": the next view's selected stage is the new one.
  const added = useRef(false)
  // The new stage, to scroll to once React Flow has drawn it.
  const pending = useRef(null)
  const flow = useReactFlow()
  // Whether the canvas fills the window, where the wheel scrolls it.
  const fills = useMemo(() => !!el.closest(".q-canvas-fill"), [el])
  const [focused, setFocused] = useState(false)
  const [full, setFull] = useState(false)
  const canFull = !!(document.fullscreenEnabled && boxOf(el).requestFullscreen)

  const {edges: lines, length} = layout(view, heights.current)
  const lengthRef = useRef(length)
  lengthRef.current = length

  useEffect(() => {
    const observer = new ResizeObserver(() => setSize({width: el.clientWidth, height: el.clientHeight}))
    observer.observe(el)
    return () => observer.disconnect()
  }, [el])

  // Outside a filling box the canvas is as tall as the column at its zoom (app.css reads
  // the variable).
  useEffect(() => {
    el.style.setProperty("--q-canvas-height", `${paneHeight(length, viewport.zoom)}px`)
  }, [el, length, viewport.zoom])

  // The card centred, the column within its bounds, after each change of size, length or
  // zoom.
  useEffect(() => {
    if (!size.width || !size.height) return
    const current = flow.getViewport()
    const next = fitViewport(current, size, length)
    if (moved(current, next)) flow.setViewport(next)
  }, [flow, size, length, viewport.zoom])

  const extent = useMemo(
    () => (size.width && size.height ? panExtent(size, length, viewport.zoom) : undefined),
    [size, length, viewport.zoom],
  )

  // Once React Flow measures a card whose height differs from the one used, the cards
  // under it move to their places.
  useEffect(() => {
    const measured = {}
    for (const node of nodes) {
      const height = node.measured?.height
      if (isStage(node) && height && heights.current[node.id] !== height) measured[node.id] = height
    }
    if (Object.keys(measured).length === 0) return
    heights.current = {...heights.current, ...measured}
    const places = new Map(layout(viewRef.current, heights.current).nodes.map(n => [n.id, n.position]))
    setNodes(current =>
      current.map(node =>
        node.dragging || !places.has(node.id) ? node : {...node, position: places.get(node.id)},
      ),
    )
  }, [nodes])

  // Scrolls so the node `id` is whole in the canvas, moving the column as little as it can.
  const reveal = useCallback(
    id => {
      const node = flow.getNode(id) ?? layout(viewRef.current, heights.current).nodes.find(n => n.id === id)
      if (!node) return
      const start = node.position.y
      const end = start + (node.measured?.height ?? ADD_SIZE)
      const current = flow.getViewport()
      const y = revealY(start, end, current, sizeRef.current, lengthRef.current)
      if (Math.abs(y - current.y) > 0.5) flow.setViewport({...current, y}, {duration: 150})
    },
    [flow],
  )

  useEffect(
    () =>
      subscribe(next => {
        const before = viewRef.current.selected
        viewRef.current = next
        setView(next)
        setNodes(current => keepMeasured(layout(next, heights.current).nodes, current))
        if (added.current && next.selected && next.selected !== before) {
          added.current = false
          // Scroll to the new stage once React Flow has drawn it; its name in the
          // inspector takes the focus, with "New stage" selected, so typing replaces it.
          pending.current = String(next.selected)
          requestAnimationFrame(() =>
            requestAnimationFrame(() => {
              const input = document.getElementById("stage-name")
              input?.focus()
              input?.select()
            }),
          )
        } else if (next.selected && next.selected !== before) {
          requestAnimationFrame(() => reveal(String(next.selected)))
        }
      }),
    [subscribe, reveal],
  )

  // The new stage, once React Flow has drawn it.
  useEffect(() => {
    if (!pending.current) return
    let inner
    const frame = requestAnimationFrame(() => {
      inner = requestAnimationFrame(() => {
        const target = pending.current
        pending.current = null
        if (target) reveal(target)
      })
    })
    return () => {
      cancelAnimationFrame(frame)
      cancelAnimationFrame(inner)
    }
  }, [view, reveal])

  const add = useCallback(
    at => {
      added.current = true
      push("add_stage", {at: String(at)})
    },
    [push],
  )

  // A card or "+" that takes the focus by Tab is scrolled into view.
  const onFocusCapture = useCallback(
    event => {
      const id = event.target.closest?.(".react-flow__node")?.dataset.id
      if (id) reveal(id)
    },
    [reveal],
  )

  // The moved card keeps the focus after the page sends the new order. React Flow draws
  // the reordered nodes in commits after this one, and moving a focused element in the
  // DOM blurs it, so the focus is set again on each of the next few frames, by node id,
  // unless the person has put it somewhere else.
  useEffect(() => {
    const id = focusId.current
    if (!id) return
    focusId.current = null
    let frames = 8
    let frame
    const step = () => {
      const card = el.querySelector(`.react-flow__node[data-id="${CSS.escape(id)}"]`)
      const active = document.activeElement
      const free = !active || active === document.body || el.contains(active)
      if (card && free && active !== card) card.focus({preventScroll: true})
      if (--frames > 0) frame = requestAnimationFrame(step)
    }
    frame = requestAnimationFrame(step)
    return () => cancelAnimationFrame(frame)
  }, [view, el])

  // Focus: the <html> class sets the box to fill the window (app.css) until Escape, or
  // until the canvas goes. `f` anywhere on the page but in a field turns it on and off, as on the
  // Terminal.
  useEffect(() => {
    document.documentElement.classList.toggle(FOCUS_CLASS, focused)
    const onKey = event => {
      if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey) return
      if (document.querySelector("dialog[open]")) return
      if (event.key === "Escape" && focused) {
        setFocused(false)
      } else if (event.key === "f" && singleKeys() && !typing(event.target)) {
        event.preventDefault()
        setFocused(on => !on)
      }
    }
    document.addEventListener("keydown", onKey)
    return () => {
      document.removeEventListener("keydown", onKey)
      document.documentElement.classList.remove(FOCUS_CLASS)
    }
  }, [focused])

  // Full screen: the browser's, where it has one.
  useEffect(() => {
    const box = boxOf(el)
    const onChange = () => setFull(document.fullscreenElement === box)
    document.addEventListener("fullscreenchange", onChange)
    return () => {
      document.removeEventListener("fullscreenchange", onChange)
      if (document.fullscreenElement === box) document.exitFullscreen?.()
    }
  }, [el])

  const toggleFull = useCallback(() => {
    const box = boxOf(el)
    if (document.fullscreenElement === box) document.exitFullscreen()
    else box.requestFullscreen()
  }, [el])

  // Each move ends with the card centred and the column within its bounds.
  const onMoveEnd = useCallback(
    (_event, next) => {
      const fit = fitViewport(next, sizeRef.current, lengthRef.current)
      if (moved(next, fit)) flow.setViewport(fit)
    },
    [flow],
  )

  const snapBack = useCallback(
    () => setNodes(current => keepMeasured(layout(viewRef.current, heights.current).nodes, current)),
    [],
  )

  const onNodesChange = useCallback(changes => setNodes(current => applyNodeChanges(changes, current)), [])

  // A canvas whose cards open nothing (`selectable` false, such as on a workspace type's
  // page) sends no "select".
  const select = useCallback(
    id => {
      if (viewRef.current.selectable === false) return
      if (id === viewRef.current.selected) return
      viewRef.current = {...viewRef.current, selected: id}
      push("select", {id})
    },
    [push],
  )

  // The slot under the pointer when the card is dropped.
  const onNodeDragStop = useCallback(
    (event, node) => {
      if (!isStage(node)) return
      const before = (viewRef.current.stages || []).map(s => String(s.id))
      const tops = layout(viewRef.current, heights.current)
        .nodes.filter(isStage)
        .map(card => card.position.y)
      const y = dropY(event, node, point => flow.screenToFlowPosition(point))
      const order = orderByDrop(before, node.id, y, tops, GAP.edit)
      if (!sameOrder(order, before)) push("reorder", {ids: order})
      snapBack()
    },
    [flow, push, snapBack],
  )

  // Keys on a card, before React Flow's handlers: Enter or Space opens it in the
  // inspector; up and down move it one place where the person may edit; left and right
  // do nothing (React Flow would move the card by pixels). A button keeps its keys.
  const onKeyDownCapture = useCallback(
    event => {
      if (event.target.closest?.("button")) return
      const card = event.target.closest?.(".react-flow__node")
      const id = card?.dataset.id
      if (!id || id.startsWith("add:")) return
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault()
        select(id)
        return
      }
      if (!event.key.startsWith("Arrow") || !viewRef.current.editable) return
      event.preventDefault()
      event.stopPropagation()
      const by = keyMove(event.key)
      if (!by) return
      focusId.current = id
      push("move", {id, by})
    },
    [push, select],
  )

  const onSelectionChange = useCallback(
    ({nodes: chosen}) => {
      const stages = chosen.filter(isStage)
      if (stages.length === 1) select(stages[0].id)
    },
    [select],
  )

  const edges = lines.map(edge => ({...edge, markerEnd: {type: MarkerType.ArrowClosed}}))
  const description =
    view.selectable === false ? words.node_view : view.editable === true ? words.node : words.node_read
  // The wheel scrolls the column where the canvas fills the window, in Focus or on the
  // full screen; elsewhere the canvas is as tall as the column and the wheel scrolls the
  // page.
  const scrolls = fills || focused || full

  const base =
    "btn btn-xs h-7 min-h-7 gap-1.5 border-base-300 bg-base-100 text-[13px]/none font-normal shadow-none aria-pressed:bg-base-300"
  const control = `${base} px-2`
  const square = `${base} w-7 px-0`

  const zoomButton = (label, symbol, onClick) =>
    h(
      "button",
      {type: "button", className: square, "aria-label": label, title: label, onClick},
      h("span", {"aria-hidden": "true"}, symbol),
    )

  const fullWords = full ? words.leave_full_screen : words.full_screen

  return h(
    Page.Provider,
    {value: {push, words, add}},
    h(
      "div",
      {className: "relative h-full w-full", onKeyDownCapture, onFocusCapture},
      h(
        ReactFlow,
        {
          nodes,
          edges,
          nodeTypes,
          onNodesChange,
          onNodeDragStop,
          onSelectionChange,
          onMoveEnd,
          nodesDraggable: view.editable === true,
          nodesConnectable: false,
          edgesFocusable: false,
          elementsSelectable: view.selectable !== false,
          deleteKeyCode: null,
          selectionKeyCode: null,
          multiSelectionKeyCode: null,
          zoomOnDoubleClick: false,
          zoomOnScroll: false,
          panOnScroll: scrolls,
          panOnScrollMode: "vertical",
          preventScrolling: scrolls,
          translateExtent: extent,
          defaultViewport: fitViewport({x: SIDE, y: MARGIN_TOP, zoom: ZOOM.start}, size, 0),
          minZoom: ZOOM.min,
          maxZoom: ZOOM.max,
          // React Flow's MIT licence allows the badge to go; its licence file stays in
          // assets/vendor/flow/xyflow-react.
          proOptions: {hideAttribution: true},
          colorMode: theme(),
          "aria-label": words.label,
          ariaLabelConfig: {
            "node.a11yDescription.default": description,
            "node.a11yDescription.keyboardDisabled": description,
            "node.a11yDescription.ariaLiveMessage": () => words.moved,
          },
        },
        // The dots; their colour is the theme's (`.q-canvas` in app.css).
        h(Background, {variant: "dots", gap: 20, size: 1}),
      ),
      // In the top margin, at the right: the zoom buttons, Focus and Full screen.
      h(
        "div",
        {
          role: "group",
          "aria-label": words.controls,
          className: "absolute right-4 top-3 z-10 flex items-center gap-1.5",
        },
        zoomButton(words.zoom_out, "−", () => flow.zoomOut({duration: 150})),
        zoomButton(words.zoom_in, "+", () => flow.zoomIn({duration: 150})),
        h(
          "button",
          {
            type: "button",
            className: control,
            title: words.focus_title,
            "aria-pressed": String(focused),
            "aria-keyshortcuts": "f",
            onClick: () => setFocused(on => !on),
          },
          h("span", {className: "hero-arrows-pointing-in-micro size-4 shrink-0", "aria-hidden": "true"}),
          h("span", null, words.focus),
        ),
        canFull &&
          h(
            "button",
            {
              type: "button",
              className: square,
              title: fullWords,
              "aria-label": fullWords,
              "aria-pressed": String(full),
              onClick: toggleFull,
            },
            h("span", {className: "hero-arrows-pointing-out-micro size-4 shrink-0", "aria-hidden": "true"}),
          ),
      ),
    ),
  )
}

const mount = (el, {view, words, push}) => {
  const listeners = new Set()
  // The newest view, for a listener that subscribes after it arrived.
  let latest = view
  const subscribe = fn => {
    listeners.add(fn)
    if (latest !== view) fn(latest)
    return () => listeners.delete(fn)
  }
  const root = createRoot(el)
  root.render(h(ReactFlowProvider, null, h(Flow, {initial: view, words, push, subscribe, el})))
  return {
    update: next => {
      latest = next
      listeners.forEach(fn => fn(next))
    },
    destroy: () => root.unmount(),
  }
}

window.QoryStagesCanvas = {mount}
