// A stage's card on the Stages canvas, as elements of `h` (React's createElement in
// canvas.js), so that a test can draw it without React: its name, its description, its
// workflows and loops, its gate line and its alert lines. All text is a text child or a
// title, never markup.
import {CARD_WIDTH} from "./hooks/stages_canvas.js"

const line = (h, text, key, className) =>
  h("p", {key, className, title: text}, text)

// A workflow's name on one line, cut with an ellipsis, in full in its title and label.
// Where the page has the harness's list, a check or a cross before it: a different shape,
// not only a different colour, with the mark's words in the title and the label.
const workflow = (h, name, key, mark) =>
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

const steps = (h, sequence, words, marks) =>
  sequence.length === 0
    ? [line(h, words.no_workflow, "none", "text-muted")]
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
              ...item.workflows.map((name, j) => workflow(h, name, `w${j}`, markOf(marks, name))),
            )
          : workflow(h, item.workflow, `s${i}`, markOf(marks, item.workflow)),
      )

// The card for `data` (layout's card data), selected or not, with `words` the canvas's
// words and `handle(type)` the element of a "target" or "source" handle.
export const stageCard = (h, {data, selected, words, handle}) =>
  h(
    "div",
    {
      className: [
        "grid gap-2 rounded-box border bg-base-100 px-[18px] py-4 text-left text-[16px]/6 shadow-sm",
        selected ? "border-primary ring-2 ring-primary" : "border-base-300",
      ].join(" "),
      style: {width: CARD_WIDTH},
    },
    handle("target"),
    line(h, data.name, "name", "truncate text-[18px]/[26px] font-semibold text-base-content"),
    // The description, if any: plain text with its line breaks, wrapped, at most three
    // lines; in full in its title.
    data.description
      ? line(h, data.description, "description", "line-clamp-3 whitespace-pre-line break-words text-[14px]/5 text-muted")
      : null,
    ...steps(h, data.sequence, words, data.marks),
    line(h, data.gate, "gate", "text-muted"),
    ...data.alerts.map((text, i) => line(h, text, `a${i}`, "text-error")),
    handle("source"),
  )
