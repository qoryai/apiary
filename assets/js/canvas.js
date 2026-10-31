// The canvas bundle of Workspace settings › Stages: React and React Flow (@xyflow/react),
// vendored under assets/vendor/flow (see assets/vendor/README.md). A separate esbuild
// entry, so only the Stages page downloads it: the StagesCanvas hook
// (hooks/stages_canvas.js) adds this script and the stylesheet esbuild writes beside it
// (canvas.css) on first mount, then calls `mount`.
//
// The canvas draws the view the page sends and sends back two events: "select", with a
// stage id, and "reorder", with every stage id in the new order, after a card is dragged.
// The left and right arrow keys move the focused card one place earlier or later ("move"),
// and the focus stays on it. The wheel scrolls the page; a pinch or the buttons zoom. All
// text reaches React as props and is rendered as text.
import {createElement as h, memo, useCallback, useEffect, useRef, useState} from "react"
import {createRoot} from "react-dom/client"
import {
  ReactFlow,
  ReactFlowProvider,
  Controls,
  Handle,
  Position,
  MarkerType,
  applyNodeChanges,
  useReactFlow,
} from "../vendor/flow/xyflow-react/index.js"
import "../vendor/flow/xyflow-react/style.css"
import {CARD_WIDTH, FIT, dropX, keyMove, layout, orderByDrop, sameOrder} from "./hooks/stages_canvas"

const line = (text, key, className) => h("p", {key, className}, text)

const StageCard = memo(({data, selected}) =>
  h(
    "div",
    {
      className: [
        "grid gap-1 rounded-box border bg-base-100 p-2.5 text-left text-[13px]/[18px] shadow-sm",
        selected ? "border-primary ring-2 ring-primary" : "border-base-300",
      ].join(" "),
      style: {width: CARD_WIDTH},
    },
    h(Handle, {type: "target", position: Position.Left, isConnectable: false, className: "!opacity-0"}),
    line(data.name, "name", "truncate text-[14px]/5 font-semibold text-base-content"),
    ...data.workflows.map((name, i) => line(name, `w${i}`, "break-all font-mono text-[12.5px]/[18px]")),
    line(data.loop, "loop", "text-muted"),
    line(data.gate, "gate", "text-muted"),
    ...data.alerts.map((text, i) => line(text, `a${i}`, "text-error")),
    h(Handle, {type: "source", position: Position.Right, isConnectable: false, className: "!opacity-0"}),
  ),
)

const nodeTypes = {stage: StageCard}

const theme = () =>
  (document.documentElement.dataset.theme || "").includes("dark") ? "dark" : "light"

function Flow({initial, words, push, subscribe, el}) {
  const [view, setView] = useState(initial)
  const [nodes, setNodes] = useState(() => layout(initial).nodes)
  const viewRef = useRef(initial)
  const nodesRef = useRef(nodes)
  nodesRef.current = nodes
  // The card the arrow keys moved, to focus again once the page sends the new order.
  const focusId = useRef(null)
  const flow = useReactFlow()
  const count = (view.stages || []).length

  useEffect(
    () =>
      subscribe(next => {
        viewRef.current = next
        setView(next)
        setNodes(layout(next).nodes)
      }),
    [subscribe],
  )

  // Every stage in view when the number of stages changes.
  useEffect(() => {
    const frame = requestAnimationFrame(() => flow.fitView(FIT))
    return () => cancelAnimationFrame(frame)
  }, [count, flow])

  // The moved card keeps the focus after the page redraws the stages in the new order.
  useEffect(() => {
    const id = focusId.current
    if (!id) return
    const card = el.querySelector(`.react-flow__node[data-id="${CSS.escape(id)}"]`)
    if (card && document.activeElement !== card) card.focus()
    if (card) focusId.current = null
  }, [view, el])

  const snapBack = useCallback(() => setNodes(layout(viewRef.current).nodes), [])

  const onNodesChange = useCallback(changes => setNodes(current => applyNodeChanges(changes, current)), [])

  // The slot under the pointer when the card is dropped.
  const onNodeDragStop = useCallback(
    (event, node) => {
      const before = (viewRef.current.stages || []).map(s => String(s.id))
      const x = dropX(event, node, point => flow.screenToFlowPosition(point))
      const order = orderByDrop(before, node.id, x)
      if (!sameOrder(order, before)) push("reorder", {ids: order})
      snapBack()
    },
    [flow, push, snapBack],
  )

  // The arrow keys on a card, before React Flow's handler, which moves it by pixels.
  const onKeyDownCapture = useCallback(
    event => {
      const card = event.target.closest?.(".react-flow__node")
      if (!card || !viewRef.current.editable || !event.key.startsWith("Arrow")) return
      event.preventDefault()
      event.stopPropagation()
      const by = keyMove(event.key)
      if (!by) return
      focusId.current = card.dataset.id
      push("move", {id: card.dataset.id, by})
    },
    [push],
  )

  const onSelectionChange = useCallback(
    ({nodes: chosen}) => {
      if (chosen.length === 1 && chosen[0].id !== viewRef.current.selected) {
        viewRef.current = {...viewRef.current, selected: chosen[0].id}
        push("select", {id: chosen[0].id})
      }
    },
    [push],
  )

  const edges = layout(view).edges.map(edge => ({...edge, markerEnd: {type: MarkerType.ArrowClosed}}))

  return h(
    "div",
    {className: "h-full w-full", onKeyDownCapture},
    h(
    ReactFlow,
    {
      nodes,
      edges,
      nodeTypes,
      onNodesChange,
      onNodeDragStop,
      onSelectionChange,
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
      minZoom: 0.3,
      maxZoom: 1.5,
      fitView: true,
      fitViewOptions: FIT,
      colorMode: theme(),
      "aria-label": words.label,
      ariaLabelConfig: {
        "node.a11yDescription.default": words.node,
        "node.a11yDescription.keyboardDisabled": words.node,
        "node.a11yDescription.ariaLiveMessage": () => words.moved,
        "controls.ariaLabel": words.controls,
        "controls.zoomIn.ariaLabel": words.zoom_in,
        "controls.zoomOut.ariaLabel": words.zoom_out,
        "controls.fitView.ariaLabel": words.fit,
      },
    },
    h(Controls, {showInteractive: false, position: "bottom-left", orientation: "horizontal"}),
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
