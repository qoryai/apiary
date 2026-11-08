// The take in's dialog, a wide spend dialog (assets/js/hooks/spend_dialog.js): it opens
// with focus on the field data-focus names, and on Escape the field in it with focus loses
// it, so LiveView sends the change it holds back for phx-debounce before the cancel.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {flush, open} from "../hooks/spend_dialog.js"

// A document with elements of `ids`, each with focus.
const page = (...ids) => {
  const doc = {elements: {}, activeElement: null}
  doc.getElementById = id => doc.elements[id] || null
  for (const id of ids) {
    const el = {id, focus: () => (doc.activeElement = el)}
    doc.elements[id] = el
  }
  return doc
}

test("with data-focus, opens with focus on that field", () => {
  const doc = page("backlog-ticket-take-in-button", "take-in-dialog-comment", "take-in-dialog-go")

  const el = {
    open: false,
    dataset: {return: "backlog-ticket-take-in-button", focus: "take-in-dialog-comment"},
    showModal() {
      this.open = true
    },
    querySelector: () => doc.elements["take-in-dialog-go"],
  }

  const back = open(el, doc)

  assert.equal(el.open, true)
  assert.equal(doc.activeElement, doc.elements["take-in-dialog-comment"])
  assert.equal(back, doc.elements["backlog-ticket-take-in-button"])
})

test("on Escape, the field in the dialog with focus loses it", () => {
  const doc = page("take-in-dialog-comment")
  const field = doc.elements["take-in-dialog-comment"]
  let blurred = 0
  field.blur = () => (blurred += 1)
  const el = {contains: node => node === field}
  doc.activeElement = field

  flush({key: "Enter"}, el, doc)
  assert.equal(blurred, 0)

  flush({key: "Escape"}, el, doc)
  assert.equal(blurred, 1)

  doc.activeElement = {blur: () => assert.fail("blurred a field outside the dialog")}
  flush({key: "Escape"}, el, doc)
})
