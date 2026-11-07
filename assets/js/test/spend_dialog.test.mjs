// The spend's dialog (assets/js/hooks/spend_dialog.js): it opens modal with focus on
// Cancel, or on the element whose id is in data-focus, keeps the browser from closing it
// on Escape, and moves focus back to the action's button once removed.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {SpendDialog, giveBack, keep, open} from "../hooks/spend_dialog.js"

// An element with what the hook reads: an id, focus, and a place on the page.
const element = (doc, id) => {
  const el = {id, focus: () => (doc.activeElement = el)}
  doc.elements[id] = el
  return el
}

// A document with `ids` on the page.
const page = (...ids) => {
  const doc = {elements: {}, activeElement: null}
  doc.getElementById = id => doc.elements[id] || null
  doc.contains = el => Object.values(doc.elements).includes(el)
  for (const id of ids) element(doc, id)
  return doc
}

// A dialog with Cancel and a confirm button; `returnTo` the id of the action's button,
// `focus` the id of the element for the first focus (data-focus).
const dialog = (doc, returnTo, focus) => {
  const cancel = element(doc, "spend-dialog-cancel")
  const go = element(doc, "spend-dialog-go")
  const listeners = {}

  return {
    id: "spend-dialog",
    open: false,
    modal: false,
    dataset: {...(returnTo && {return: returnTo}), ...(focus && {focus})},
    showModal() {
      this.open = true
      this.modal = true
    },
    addEventListener: (type, fun) => (listeners[type] = fun),
    listeners,
    cancel,
    go,
  }
}

test("opens modal, with focus on Cancel, not on the confirm button", () => {
  const doc = page("work-item-stage-escalation-another")
  const el = dialog(doc, "work-item-stage-escalation-another")
  doc.activeElement = doc.elements["work-item-stage-escalation-another"]

  const back = open(el, doc)

  assert.equal(el.modal, true)
  assert.equal(doc.activeElement, el.cancel)
  assert.notEqual(doc.activeElement, el.go)
  assert.equal(back, doc.elements["work-item-stage-escalation-another"])
})

test("opens with focus on the element whose id is in data-focus", () => {
  const doc = page("take-in-open", "spend-dialog-comment")
  const el = dialog(doc, "take-in-open", "spend-dialog-comment")

  open(el, doc)

  assert.equal(doc.activeElement, doc.elements["spend-dialog-comment"])
})

test("with data-focus set to an id not on the page, focus goes to Cancel", () => {
  const doc = page("artifact-save")
  const el = dialog(doc, "artifact-save", "spend-dialog-gone")

  open(el, doc)

  assert.equal(doc.activeElement, el.cancel)
})

test("without data-return, moves focus back to what had it before", () => {
  const doc = page("set-up-test-run")
  doc.activeElement = doc.elements["set-up-test-run"]

  assert.equal(open(dialog(doc), doc), doc.elements["set-up-test-run"])
})

test("Escape's close by the browser is prevented: the server removes the dialog", () => {
  let prevented = false
  keep({preventDefault: () => (prevented = true)})
  assert.equal(prevented, true)
})

test("moves focus back to the action's button, and to nothing removed from the page", () => {
  const doc = page("target-environment-rebuild")
  const button = doc.elements["target-environment-rebuild"]

  giveBack(button, doc)
  assert.equal(doc.activeElement, button)

  doc.activeElement = null
  giveBack({id: "gone", focus: () => assert.fail("focused a removed button")}, doc)
  giveBack(null, doc)
  assert.equal(doc.activeElement, null)
})

test("the hook: mounted opens and listens for cancel; destroyed moves focus back", () => {
  const doc = page("artifact-save")
  globalThis.document = doc
  const el = dialog(doc, "artifact-save")
  const hook = {...SpendDialog, el}

  hook.mounted()
  assert.equal(el.modal, true)
  assert.equal(doc.activeElement, el.cancel)
  assert.equal(el.listeners.cancel, keep)

  hook.destroyed()
  assert.equal(doc.activeElement, doc.elements["artifact-save"])
  delete globalThis.document
})
