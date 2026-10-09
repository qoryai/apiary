// The breadcrumb's menus (assets/js/hooks/switcher.js): what the keys do, what a search
// leaves and how the status line says it, and the page a link carries.
// `node --test assets/js/test/` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {
  REST,
  afterFocusLost,
  pointerAction,
  filterOrganisations,
  filterWorkspaces,
  keyAction,
  statusWords,
  step,
  withPage,
} from "../hooks/switcher.js"

// Acme with production and staging, Example Org with research, and Initech with none.
const ORGANISATIONS = [
  {search: "acme acme", workspaces: ["production production", "staging staging"]},
  {search: "example org example-org", workspaces: ["research research"]},
  {search: "initech initech", workspaces: []},
]

test("an empty search shows every organisation and every workspace", () => {
  assert.deepEqual(
    filterOrganisations("", ORGANISATIONS).map(o => [o.show, o.workspaces]),
    [
      [true, [true, true]],
      [true, [true]],
      [true, []],
    ],
  )
})

test("an organisation found by its name or slug shows all its workspaces", () => {
  const [acme, example, initech] = filterOrganisations("acme", ORGANISATIONS)
  assert.deepEqual(acme, {show: true, own: true, workspaces: [true, true]})
  assert.equal(example.show, false)
  assert.equal(initech.show, false)

  assert.equal(filterOrganisations("example-org", ORGANISATIONS)[1].own, true)
})

test("an organisation found by a workspace is kept with only the matching workspaces", () => {
  const [acme, example] = filterOrganisations("prod", ORGANISATIONS)
  assert.deepEqual(acme, {show: true, own: false, workspaces: [true, false]})
  assert.equal(example.show, false)
})

test("a search that finds nothing leaves no organisation", () => {
  assert.ok(filterOrganisations("nothing", ORGANISATIONS).every(o => !o.show))
})

test("the workspace menu filters its workspaces by name and slug", () => {
  const words = ["production production", "staging staging", "research research"]
  assert.deepEqual(filterWorkspaces("", words), [true, true, true])
  assert.deepEqual(filterWorkspaces("stag", words), [false, true, false])
  assert.deepEqual(filterWorkspaces("nothing", words), [false, false, false])
})

test("the status line says what is left in the server's words, and nothing before a search", () => {
  const words = {
    none: "No workspace matches.",
    one: "1 workspace matches.",
    other: "%{count} workspaces match.",
  }

  assert.equal(statusWords("", 3, words), "")
  assert.equal(statusWords("x", 0, words), "No workspace matches.")
  assert.equal(statusWords("x", 1, words), "1 workspace matches.")
  assert.equal(statusWords("x", 3, words), "3 workspaces match.")
})

test("the keys: from the search ↓ goes to the first row; ↑ and ↓ move; → and ← between panels", () => {
  assert.equal(keyAction("ArrowDown", "search"), "first")
  assert.equal(keyAction("ArrowUp", "search"), null)
  assert.equal(keyAction("Enter", "search"), "follow")
  assert.equal(keyAction("Escape", "search"), "close")

  assert.equal(keyAction("ArrowDown", "organisations"), "next")
  assert.equal(keyAction("ArrowUp", "organisations"), "previous")
  assert.equal(keyAction("ArrowRight", "organisations"), "into")
  assert.equal(keyAction("ArrowLeft", "organisations"), null)
  // Enter on a row follows its link, as the browser does.
  assert.equal(keyAction("Enter", "organisations"), null)
  assert.equal(keyAction("Escape", "organisations"), "close")

  assert.equal(keyAction("ArrowLeft", "workspaces"), "back")
  assert.equal(keyAction("ArrowRight", "workspaces"), null)
  assert.equal(keyAction("ArrowDown", "workspaces"), "next")
  assert.equal(keyAction("Escape", "workspaces"), "close")

  // The search's own keys stay the field's.
  assert.equal(keyAction("ArrowLeft", "search"), null)
  assert.equal(keyAction("ArrowRight", "search"), null)
  assert.equal(keyAction("a", "search"), null)
})

test("↑ and ↓ stay within a panel; ↑ from the first row leaves it", () => {
  assert.equal(step("next", -1, 3), 0)
  assert.equal(step("next", 0, 3), 1)
  assert.equal(step("next", 2, 3), 2)
  assert.equal(step("previous", 2, 3), 1)
  assert.equal(step("previous", 0, 3), -1)
  assert.equal(step("next", -1, 0), -1)
})

test("a link carries the page after the workspace's own path, and nothing off a workspace's page", () => {
  const base = "/acme/production"
  const link = "/example-org/research/switch/runs"

  assert.equal(
    withPage(link, "/acme/production/runs/abc/terminal", base),
    `${link}?page=%2Fruns%2Fabc%2Fterminal`,
  )

  assert.equal(withPage(link, "/acme/production", base), `${link}?page=`)
  // Written again, the page is the reader's, not added twice.
  assert.equal(withPage(`${link}?page=%2Fold`, "/acme/production/nodes", base), `${link}?page=%2Fnodes`)
  // An organisation's page has no base: the link alone.
  assert.equal(withPage(`${link}?page=%2Fnodes`, "/acme/settings/people", undefined), link)
  // A path that only starts like the base is not under it.
  assert.equal(withPage(link, "/acme/production-2/runs", base), link)
})

test("the pointer rests about 100 ms before an organisation is pointed at", () => {
  assert.equal(REST, 100)
})

test("focus lost for nowhere: kept inside, given back from the page, else the menu closes", () => {
  // A tap on ›, a group's fold or the way back, which takes no focus on Safari and iOS.
  assert.equal(afterFocusLost({inside: false, onPage: true}), "refocus")
  // The click that followed moved focus into the menu, or the window lost focus.
  assert.equal(afterFocusLost({inside: true, onPage: false}), "keep")
  // Focus went to something else on the page.
  assert.equal(afterFocusLost({inside: false, onPage: false}), "close")
})

test("a pointer pressed in the open menu keeps it, on a chevron is the chevron's, elsewhere closes it", () => {
  assert.equal(pointerAction({inMenu: true, onChevron: false}), "keep")
  assert.equal(pointerAction({inMenu: false, onChevron: true}), "chevron")
  // The breadcrumb's own segments, its separators and avatars, and the rest of the page.
  assert.equal(pointerAction({inMenu: false, onChevron: false}), "close")
})
