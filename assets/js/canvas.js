// The canvas bundle of Workspace settings › Stages: React and React Flow (@xyflow/react),
// vendored under assets/vendor/flow (see assets/vendor/README.md). A separate esbuild
// entry, so only the Stages page downloads it: the StagesCanvas hook
// (hooks/stages_canvas.js) adds this script and the stylesheet esbuild writes beside it
// (canvas.css) on first mount, then calls `mount`.
//
// The canvas is the page's editor. It draws the view the page sends and sends back:
// "select", with a stage id, on a click or Enter on a card; "reorder", with every stage
// id in the new order, after a card is dropped; "move", one place earlier or later, on
// the left and right arrow keys, with the focus kept on the moved card; and "add_stage",
// with the place, from a "+" before the first card, between two cards or after the last.
// A card or "+" that takes the focus is panned into view, and so is the selected card;
// after a "+", the new stage is selected, panned to, and its name field in the inspector
// takes the focus with its text selected. The cards are drawn at zoom 1 from the first
// stage; the canvas is as tall as the tallest card. Where cards are out of view, the edge
// fades and a "← n more" or "→ n more" button pans to them. The wheel scrolls the page; a
// pinch or the zoom buttons zoom. All text reaches React as props and is rendered as text.
import {
  createContext,
  createElement as h,
  memo,
  useCallback,
  useContext,
  useEffect,
  useRef,
  useState,
} from "react"
import {createRoot} from "react-dom/client"
import {
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
  MARGIN_TOP,
  ZOOM,
  cardX,
  clampX,
  dropX,
  isStage,
  keyMove,
  layout,
  orderByDrop,
  outside,
  panLeft,
  panRight,
  paneHeight,
  revealX,
  sameOrder,
} from "./hooks/stages_canvas"

// The page's push and words, and what a "+" does, for the nodes React Flow draws.
const Page = createContext({push: () => {}, words: {}, add: () => {}})

const line = (text, key, className) => h("p", {key, className, title: text}, text)

// A workflow's name on one line, cut with an ellipsis, in full in its title and label.
const workflow = (name, key) =>
  h("p", {key, className: "truncate font-mono text-[13px]/[18px]", title: name, "aria-label": name}, name)

const steps = (sequence, words) =>
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
                className: "grid gap-0.5 rounded-[6px] border border-dashed border-base-content/35 px-2 pb-1.5 pt-1",
              },
              h("p", {className: "text-[12px]/4 text-muted", "aria-hidden": "true"}, item.loop),
              ...item.workflows.map((name, j) => workflow(name, `w${j}`)),
            )
          : workflow(item.workflow, `s${i}`),
      )

const StageCard = memo(({data, selected}) => {
  const {words} = useContext(Page)
  return h(
    "div",
    {
      className: [
        "grid gap-1.5 rounded-box border bg-base-100 p-2.5 text-left text-[13px]/[18px] shadow-sm",
        selected ? "border-primary ring-2 ring-primary" : "border-base-300",
      ].join(" "),
      style: {width: CARD_WIDTH},
    },
    h(Handle, {type: "target", position: Position.Left, isConnectable: false, className: "!opacity-0"}),
    line(data.name, "name", "truncate text-[14px]/5 font-semibold text-base-content"),
    ...steps(data.sequence, words),
    line(data.gate, "gate", "text-muted"),
    ...data.alerts.map((text, i) => line(text, `a${i}`, "text-error")),
    h(Handle, {type: "source", position: Position.Right, isConnectable: false, className: "!opacity-0"}),
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

// A "more" button's text or label with its number of cards.
const fill = (template, count) => String(template || "").replaceAll("%{count}", String(count))

function Flow({initial, words, push, subscribe, el}) {
  const [view, setView] = useState(initial)
  const [nodes, setNodes] = useState(() => layout(initial).nodes)
  // The viewport after each pan or zoom, by the pointer or by a button.
  const viewport = useViewport()
  const [width, setWidth] = useState(() => el.clientWidth)
  const viewRef = useRef(initial)
  // The card the arrow keys moved, to focus again once the page sends the new order.
  const focusId = useRef(null)
  // Set by a "+": the next view's selected stage is the new one.
  const added = useRef(false)
  // The new stage, to pan to once React Flow has drawn it.
  const pending = useRef(null)
  // The side of the "more" button last pressed, and both buttons, to keep the focus on
  // the canvas when that button goes.
  const pressed = useRef(null)
  const leftButton = useRef(null)
  const rightButton = useRef(null)
  const flow = useReactFlow()
  const count = (view.stages || []).length

  useEffect(() => {
    const observer = new ResizeObserver(() => setWidth(el.clientWidth))
    observer.observe(el)
    return () => observer.disconnect()
  }, [el])

  // Moves the line sideways to `x`, with the cards at the top margin.
  const panTo = useCallback(
    (x, duration = 150) => {
      const {zoom} = flow.getViewport()
      flow.setViewport({x, y: MARGIN_TOP, zoom}, {duration})
    },
    [flow],
  )

  // Pans so the node `id` is whole in the canvas, moving the line as little as it can.
  const reveal = useCallback(
    id => {
      const node = flow.getNode(id)
      const index = (viewRef.current.stages || []).findIndex(s => String(s.id) === id)
      const start = node ? node.position.x : cardX(Math.max(index, 0))
      const end = start + (node?.measured?.width ?? (index >= 0 ? CARD_WIDTH : ADD_SIZE))
      const current = flow.getViewport()
      const total = (viewRef.current.stages || []).length
      const x = revealX(start, end, total, current, el.clientWidth)
      if (Math.abs(x - current.x) > 0.5) panTo(x)
    },
    [el, flow, panTo],
  )

  useEffect(
    () =>
      subscribe(next => {
        const before = viewRef.current.selected
        viewRef.current = next
        setView(next)
        setNodes(layout(next).nodes)
        if (added.current && next.selected && next.selected !== before) {
          added.current = false
          // Pan to the new stage once React Flow has drawn it; its name in the inspector
          // takes the focus, with "New stage" selected, so typing replaces it.
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

  const add = useCallback(
    at => {
      added.current = true
      push("add_stage", {at: String(at)})
    },
    [push],
  )

  // A card or "+" that takes the focus by Tab is panned into view.
  const onFocusCapture = useCallback(
    event => {
      const id = event.target.closest?.(".react-flow__node")?.dataset.id
      if (id) reveal(id)
    },
    [reveal],
  )

  // When the number of stages changes: pan to a new stage, or keep the shorter line from
  // ending left of the canvas's right edge.
  useEffect(() => {
    let inner
    const frame = requestAnimationFrame(() => {
      inner = requestAnimationFrame(() => {
        const target = pending.current
        pending.current = null
        if (target) return reveal(target)
        const current = flow.getViewport()
        const x = clampX(current.x, count, current.zoom, el.clientWidth)
        if (Math.abs(x - current.x) > 0.5) panTo(x)
      })
    })
    return () => {
      cancelAnimationFrame(frame)
      cancelAnimationFrame(inner)
    }
  }, [count, flow, el, reveal, panTo])

  // The canvas is as tall as the tallest card at the zoom it has, with its margins.
  const measured = nodes.filter(isStage).map(node => node.measured?.height || 0)
  const tallest = Math.max(0, ...measured) || 120
  const height = paneHeight(tallest, viewport.zoom)
  useEffect(() => {
    el.style.height = `${height}px`
  }, [el, height])

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

  const hidden = outside(count, viewport, width)

  // A "more" button that a pan removed passes the focus to the other one.
  useEffect(() => {
    const side = pressed.current
    if (!side || document.activeElement !== document.body) return
    if (side === "right" && hidden.right === 0) leftButton.current?.focus()
    if (side === "left" && hidden.left === 0) rightButton.current?.focus()
    pressed.current = null
  }, [hidden.left, hidden.right])

  const more = side => {
    pressed.current = side
    const current = flow.getViewport()
    const pan = side === "right" ? panRight : panLeft
    panTo(pan(count, current, el.clientWidth), 200)
  }

  // Each vertical move ends with the cards back at the top margin.
  const onMoveEnd = useCallback(
    (_event, next) => {
      if (Math.abs(next.y - MARGIN_TOP) > 0.5) flow.setViewport({...next, y: MARGIN_TOP})
    },
    [flow],
  )

  const snapBack = useCallback(() => setNodes(layout(viewRef.current).nodes), [])

  const onNodesChange = useCallback(changes => setNodes(current => applyNodeChanges(changes, current)), [])

  const select = useCallback(
    id => {
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
      const x = dropX(event, node, point => flow.screenToFlowPosition(point))
      const order = orderByDrop(before, node.id, x)
      if (!sameOrder(order, before)) push("reorder", {ids: order})
      snapBack()
    },
    [flow, push, snapBack],
  )

  // Keys on a card, before React Flow's handlers: Enter or Space opens it in the
  // inspector; left and right move it one place where the person may edit; up and down
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

  const edges = layout(view).edges.map(edge => ({...edge, markerEnd: {type: MarkerType.ArrowClosed}}))
  const description = view.editable === true ? words.node : words.node_read

  const fade = side =>
    h("div", {
      key: `fade-${side}`,
      "aria-hidden": "true",
      className: [
        "pointer-events-none absolute inset-y-0 z-10 w-16 from-base-200 to-transparent",
        side === "left" ? "left-0 bg-linear-to-r" : "right-0 bg-linear-to-l",
      ].join(" "),
    })

  const moreButton = (side, number) =>
    h(
      "button",
      {
        key: `more-${side}`,
        ref: side === "left" ? leftButton : rightButton,
        type: "button",
        className: [
          "btn btn-sm absolute top-1/2 z-10 -translate-y-1/2 border-base-300 bg-base-100 font-normal shadow-sm",
          side === "left" ? "left-2" : "right-2",
        ].join(" "),
        "aria-label": fill(number === 1 ? words[`${side}_label_one`] : words[`${side}_label`], number),
        onClick: () => more(side),
      },
      fill(words[side], number),
    )

  const zoomButton = (label, symbol, onClick) =>
    h(
      "button",
      {
        type: "button",
        className: "btn btn-ghost btn-xs h-6 min-h-6 w-6 px-0 text-[14px]/none",
        "aria-label": label,
        title: label,
        onClick,
      },
      h("span", {"aria-hidden": "true"}, symbol),
    )

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
          elementsSelectable: true,
          deleteKeyCode: null,
          selectionKeyCode: null,
          multiSelectionKeyCode: null,
          zoomOnDoubleClick: false,
          // The wheel scrolls the page; a pinch and the buttons zoom.
          zoomOnScroll: false,
          preventScrolling: false,
          defaultViewport: {x: 0, y: MARGIN_TOP, zoom: ZOOM.start},
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
      ),
      hidden.left > 0 && fade("left"),
      hidden.right > 0 && fade("right"),
      hidden.left > 0 && moreButton("left", hidden.left),
      hidden.right > 0 && moreButton("right", hidden.right),
      // In the top margin, above the cards.
      h(
        "div",
        {
          role: "group",
          "aria-label": words.controls,
          className: "absolute right-1 top-1 z-10 flex gap-0.5 rounded-field border border-base-300 bg-base-100",
        },
        zoomButton(words.zoom_out, "−", () => flow.zoomOut({duration: 150})),
        zoomButton(words.zoom_in, "+", () => flow.zoomIn({duration: 150})),
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
