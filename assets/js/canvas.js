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
// takes the focus. The wheel scrolls the page; a pinch or the buttons zoom. All text
// reaches React as props and is rendered as text.
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
  Controls,
  Handle,
  Position,
  MarkerType,
  applyNodeChanges,
  useReactFlow,
} from "../vendor/flow/xyflow-react/index.js"
import "../vendor/flow/xyflow-react/style.css"
import {
  ADD_SIZE,
  CARD_WIDTH,
  FIT,
  cardX,
  dropX,
  isStage,
  keyMove,
  layout,
  lineWidth,
  orderByDrop,
  sameOrder,
} from "./hooks/stages_canvas"

// The page's push and words, and what a "+" does, for the nodes React Flow draws.
const Page = createContext({push: () => {}, words: {}, add: () => {}})

const line = (text, key, className) => h("p", {key, className, title: text}, text)

// A workflow's name on one line, cut with an ellipsis, in full in its title and label.
const workflow = (name, key) =>
  h("p", {key, className: "truncate font-mono text-[12.5px]/[18px]", title: name, "aria-label": name}, name)

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
              h("p", {className: "text-[11.5px]/4 text-muted", "aria-hidden": "true"}, item.loop),
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

function Flow({initial, words, push, subscribe, el}) {
  const [view, setView] = useState(initial)
  const [nodes, setNodes] = useState(() => layout(initial).nodes)
  const viewRef = useRef(initial)
  // The card the arrow keys moved, to focus again once the page sends the new order.
  const focusId = useRef(null)
  // Set by a "+": the next view's selected stage is the new one.
  const added = useRef(false)
  // The new stage, to pan to once the canvas has fitted the longer line.
  const pending = useRef(null)
  const flow = useReactFlow()
  const count = (view.stages || []).length

  // Pans so the node `id` is in view, at the zoom the canvas has, unless it is already
  // whole in the canvas (`always` pans in any case, for a card not drawn yet).
  const reveal = useCallback(
    (id, always = false) => {
      const element = el.querySelector(`.react-flow__node[data-id="${CSS.escape(id)}"]`)
      if (!always && element) {
        const box = element.getBoundingClientRect()
        const frame = el.getBoundingClientRect()
        if (box.left >= frame.left && box.right <= frame.right) return
      }
      const node = flow.getNode(id)
      const index = (viewRef.current.stages || []).findIndex(s => String(s.id) === id)
      const width = node?.measured?.width ?? (index >= 0 ? CARD_WIDTH : ADD_SIZE)
      const height = node?.measured?.height ?? 120
      const x = node ? node.position.x : cardX(Math.max(index, 0))
      const y = node ? node.position.y : 0
      flow.setCenter(x + width / 2, y + height / 2, {zoom: flow.getViewport().zoom, duration: 150})
    },
    [el, flow],
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
          // The fit that follows the longer line pans to the new stage; its name in the
          // inspector takes the focus once the page has drawn it.
          pending.current = String(next.selected)
          requestAnimationFrame(() =>
            requestAnimationFrame(() => document.getElementById("stage-name")?.focus()),
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

  // Every stage in view when the number of stages changes, at a readable zoom: a line
  // wider than the canvas at the smallest zoom is shown from its start, then panned to
  // the selected card if that is out of view.
  useEffect(() => {
    let inner
    const frame = requestAnimationFrame(() => {
      flow.fitView(FIT)
      inner = requestAnimationFrame(() => {
        const {y, zoom} = flow.getViewport()
        const wide = lineWidth(count) * zoom + 32 > el.clientWidth
        if (wide) flow.setViewport({x: 16, y, zoom})
        const target = pending.current || (wide && viewRef.current.selected)
        pending.current = null
        if (target) reveal(String(target))
      })
    })
    return () => {
      cancelAnimationFrame(frame)
      cancelAnimationFrame(inner)
    }
  }, [count, flow, el, reveal])

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
  // do nothing (React Flow would move the card by pixels). A "+" keeps its keys.
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

  return h(
    Page.Provider,
    {value: {push, words, add}},
    h(
      "div",
      {className: "h-full w-full", onKeyDownCapture, onFocusCapture},
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
          // React Flow's MIT licence allows the badge to go; its licence file stays in
          // assets/vendor/flow/xyflow-react.
          proOptions: {hideAttribution: true},
          colorMode: theme(),
          "aria-label": words.label,
          ariaLabelConfig: {
            "node.a11yDescription.default": description,
            "node.a11yDescription.keyboardDisabled": description,
            "node.a11yDescription.ariaLiveMessage": () => words.moved,
            "controls.ariaLabel": words.controls,
            "controls.zoomIn.ariaLabel": words.zoom_in,
            "controls.zoomOut.ariaLabel": words.zoom_out,
            "controls.fitView.ariaLabel": words.fit,
          },
        },
        h(Controls, {showInteractive: false, position: "bottom-left", orientation: "horizontal"}),
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
