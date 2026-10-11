// The breadcrumb's two menus (ApiaryWeb.Layouts), each a panel opened by its chevron: the
// organisation menu beside the organisation, the workspace menu beside the workspace.
//
// The organisation menu has two panels under its search: the organisations on the left,
// and on the right the workspaces of the one pointed at. On opening, the page's
// organisation is pointed at and scrolled to; after that the one with focus, or the one
// under a mouse once it has rested there (REST), so a pointer crossing other rows on its
// way to the right panel points at none of them. A row's › points at it too, and moves
// into its workspaces; on a phone, where one panel shows at a time, it shows them in place
// of the organisations, with a button back.
//
// The search filters as the reader types: the organisation menu by an organisation's name
// and slug, keeping one whose workspace matches with only those workspaces; the workspace
// menu by a workspace's name and slug. A search opens every folded group it finds an
// organisation in, and an empty search folds them back as they were. ↓ from the search goes
// to the first row, ↑ and ↓ move within a panel, Enter in the search follows the first
// match; → and ← move between an organisation and its workspaces; Escape closes and gives
// focus back to the chevron. Focus or a pointer leaving the open menu and the chevrons
// closes it, the breadcrumb's own segments included; a tap on a button of the menu that
// takes no focus (Safari, iOS) does not, and focus goes back into the menu.
//
// Below 768 px the bar names the page alone, and the drawer's head holds a chevron for each
// menu too: the drawer closes (the NavDrawer hook), the menu opens as the sheet under the
// bar, and Escape closes it and gives the focus to the control its chevron names
// (`data-switcher-back`, the bar's menu button), the chevron being gone with the drawer.
//
// On a workspace's page every link of the menus carries the page, the path after its
// /:org/:workspace (`data-page-base`), as `?page=`, written when the menu opens and again
// as a link is followed, so the destination keeps it (ApiaryWeb.SwitchController). Every
// word is in the markup.

// The places opened last, which an earlier switcher kept, are not a preference any more.
const OLD_KEY = "qory:recent-places"

// How long the pointer rests on an organisation before it is pointed at, in ms.
export const REST = 100

// Whether a place's words (its `data-search`, lowercase) hold the search.
export const matches = (q, words) => q === "" || (words || "").includes(q)

// The organisation menu's search over its organisations, each `{search, workspaces}` (the
// words of the organisation and of each of its workspaces): for each, whether it shows,
// whether it matched by its own words, and which of its workspaces show. An organisation
// that matches shows all its workspaces; one kept by a workspace shows only the matching.
export const filterOrganisations = (q, organisations) =>
  organisations.map(({search, workspaces}) => {
    const own = matches(q, search)
    const shown = workspaces.map(words => own || matches(q, words))
    return {show: own || shown.includes(true), own, workspaces: shown}
  })

// The workspace menu's search over its workspaces' words: which show.
export const filterWorkspaces = (q, workspaces) => workspaces.map(words => matches(q, words))

// The status line's words for what a search left, in the server's words (`data-none`,
// `data-one`, `data-other`): none while nothing is searched.
export const statusWords = (q, count, {none, one, other}) => {
  if (q === "") return ""
  const words = count === 0 ? none : count === 1 ? one : other
  return (words || "").replace("%{count}", String(count))
}

// A link's `href` with the reader's page: `?page=` and the path after `base` (the page's
// own /:org/:workspace), where the page is under it; else the link alone.
export const withPage = (href, pathname, base) => {
  const link = href.split("?")[0]
  if (!base) return link
  const page = pathname.startsWith(base) ? pathname.slice(base.length) : null
  if (page === null || (page !== "" && !page.startsWith("/"))) return link
  return `${link}?page=${encodeURIComponent(page)}`
}

// What a key does in an open menu, by where the focus is: the search, the organisations
// (the left panel, or the workspace menu's one) or the organisation menu's workspaces.
export const keyAction = (key, where) => {
  if (key === "Escape") return "close"
  if (key === "ArrowDown") return where === "search" ? "first" : "next"
  if (key === "ArrowUp") return where === "search" ? null : "previous"
  if (key === "Enter" && where === "search") return "follow"
  if (key === "ArrowRight" && where === "organisations") return "into"
  if (key === "ArrowLeft" && where === "workspaces") return "back"
  return null
}

// The row ↑ or ↓ moves to from `at` among `count` rows: -1 is above the first.
export const step = (action, at, count) => {
  if (count === 0) return at
  if (action === "next") return at < 0 ? 0 : Math.min(at + 1, count - 1)
  return at <= 0 ? -1 : at - 1
}

// What an open menu does once focus has left one of its elements for nowhere, looked at
// again after the tap or click that moved it has run: nothing while focus is back inside;
// with focus fallen to the page (a tapped button, which takes none on Safari and iOS, or
// a control hidden under it), give it to what the menu shows; else close.
export const afterFocusLost = ({inside, onPage}) =>
  inside ? "keep" : onPage ? "refocus" : "close"

// What a pointer pressed anywhere on the page does to an open menu: nothing inside it; on a
// chevron, what the chevron's click says (it opens the other menu, or closes this one);
// anywhere else, the breadcrumb's own segments included, it closes.
export const pointerAction = ({inMenu, onChevron}) =>
  inMenu ? "keep" : onChevron ? "chevron" : "close"

// Where the focus goes as a menu closes: its chevron, or the control the chevron names
// (`data-switcher-back`) where there is one, found by its id.
export const focusBack = (opener, byId) =>
  (opener?.dataset?.switcherBack && byId(opener.dataset.switcherBack)) || opener

const shown = el => el.offsetParent !== null

// Every chevron that opens a menu: the breadcrumb's, and the drawer's head's.
const chevrons = () => document.querySelectorAll("[data-switcher-open]")

export const Switcher = {
  mounted() {
    try {
      localStorage.removeItem(OLD_KEY)
    } catch (_e) {}

    this.el.addEventListener("click", e => this.onClick(e))
    this.el.addEventListener("input", e => {
      if (this.menu?.contains(e.target)) this.filter()
    })
    this.el.addEventListener("keydown", e => this.onKey(e))
    this.el.addEventListener("focusin", e => {
      const row = e.target.closest("li[data-org]")
      if (row && this.menu?.contains(row)) this.point(row)
    })
    this.el.addEventListener("pointermove", e => this.onPointer(e))
    // A link takes the page again as it is followed: the markup may have been patched
    // since the menu opened.
    this.el.addEventListener("pointerdown", e => {
      this.pressed = e.target.closest("a, button, input")
      const link = e.target.closest("a[data-switch]")
      if (link) this.writePage(link)
    })
    this.el.addEventListener("focusout", e => {
      if (!this.menu) return
      if (e.relatedTarget) {
        if (!this.ours(e.relatedTarget)) this.close(false)
        return
      }
      clearTimeout(this.lost)
      this.lost = setTimeout(() => {
        if (!this.menu) return
        const now = document.activeElement
        // A control hidden with focus on it holds it nowhere the reader sees.
        const hidden = this.menu.contains(now) && !shown(now)
        const then = afterFocusLost({
          inside: this.ours(now) && !hidden,
          onPage: !now || now === document.body || hidden,
        })
        if (then === "refocus") this.refocus()
        else if (then === "close") this.close(false)
      }, 120)
    })
    // Pressed before focus moves, so a press that closes the menu leaves no focus to give
    // back (`close/1` clears the wait).
    this.outside = e => {
      if (!this.menu) return
      const then = pointerAction({
        inMenu: this.menu.contains(e.target),
        onChevron: !!e.target.closest?.("[data-switcher-open]"),
      })
      if (then === "close") this.close(false)
    }
    document.addEventListener("pointerdown", this.outside)
    // A chevron outside the breadcrumb, in the drawer's head, opens its menu too.
    this.elsewhere = e => {
      const trigger = e.target.closest?.("[data-switcher-open]")
      if (!trigger || this.el.contains(trigger)) return
      e.preventDefault()
      this.menu && this.opener === trigger ? this.close(true) : this.open(trigger)
    }
    document.addEventListener("click", this.elsewhere)
  },

  destroyed() {
    clearTimeout(this.rest)
    clearTimeout(this.lost)
    document.removeEventListener("pointerdown", this.outside)
    document.removeEventListener("click", this.elsewhere)
  },

  onClick(e) {
    const fold = e.target.closest("button[data-fold]")
    if (fold) {
      e.preventDefault()
      fold.setAttribute("aria-expanded", String(fold.getAttribute("aria-expanded") !== "true"))
      this.filter()
      return
    }
    const trigger = e.target.closest("[data-switcher-open]")
    if (trigger) {
      e.preventDefault()
      this.menu && this.opener === trigger ? this.close(true) : this.open(trigger)
      return
    }
    const show = e.target.closest("button[data-show]")
    if (show) {
      e.preventDefault()
      this.into(show.closest("li[data-org]"))
      return
    }
    if (e.target.closest("button[data-back]")) {
      e.preventDefault()
      this.back()
      return
    }
    const link = e.target.closest("a[data-switch]")
    if (link) this.writePage(link)
  },

  open(trigger) {
    if (this.menu) this.close(false)
    const menu = document.getElementById(trigger.getAttribute("aria-controls"))
    if (!menu) return
    this.menu = menu
    this.opener = trigger
    menu.querySelectorAll("a[data-switch]").forEach(link => this.writePage(link))
    this.search().value = ""
    delete menu.dataset.view
    menu.hidden = false
    this.filter()
    if (this.side()) {
      const current = menu.querySelector("li[data-org] > a[aria-current]")
      this.point(current?.parentElement || this.orgs()[0], true)
    } else {
      this.anchor(trigger)
    }
    chevrons().forEach(t => t.setAttribute("aria-expanded", String(t === trigger)))
    this.search().focus()
  },

  close(refocus) {
    clearTimeout(this.rest)
    clearTimeout(this.lost)
    if (this.menu) this.menu.hidden = true
    this.menu = null
    chevrons().forEach(t => t.setAttribute("aria-expanded", "false"))
    if (refocus) focusBack(this.opener, id => document.getElementById(id))?.focus()
  },

  search() {
    return this.menu.querySelector("input")
  },

  // Whether `el` is the open menu's or a chevron's, where focus stays with the menu open.
  ours(el) {
    return !!el && (this.menu.contains(el) || !!el.closest?.("[data-switcher-open]"))
  },

  // The organisation menu's right panel; none in the workspace menu.
  side() {
    return this.menu.querySelector(".q-switcher-side")
  },

  // The organisations shown: not left out by the search, nor in a folded group.
  orgs() {
    return [...this.menu.querySelectorAll("li[data-org]")].filter(row => !row.closest("[hidden]"))
  },

  workspacesOf(row) {
    return document.getElementById(`organisation-menu-of-${row.dataset.org}`)
  },

  writePage(link) {
    const base = this.el.dataset.pageBase
    link.setAttribute("href", withPage(link.getAttribute("href"), location.pathname, base))
  },

  // The workspace menu opens under the workspace's segment, and inside the window.
  anchor(trigger) {
    const nav = this.el.closest("nav")
    const segment = trigger.closest("li")?.querySelector(".q-trail-link")
    if (!nav || !segment) return
    const left = nav.getBoundingClientRect().left
    const room = document.documentElement.clientWidth - 8 - left - this.menu.offsetWidth
    const x = Math.max(0, Math.min(segment.getBoundingClientRect().left - left, room))
    this.menu.style.setProperty("--q-switcher-x", `${x}px`)
  },

  // Point at an organisation's row: its › expanded, its workspaces the right panel's.
  point(row, scroll = false) {
    if (!this.menu || !this.side()) return
    this.menu.querySelectorAll("li[data-org]").forEach(other => {
      other.querySelector("button[data-show]")?.setAttribute("aria-expanded", String(other === row))
    })
    this.menu.querySelectorAll("section[data-workspaces]").forEach(section => {
      section.hidden = !row || section.dataset.workspaces !== row.dataset.org
    })
    if (row && scroll) row.scrollIntoView({block: "nearest"})
  },

  pointed() {
    return [...this.menu.querySelectorAll("li[data-org]")].find(
      row => row.querySelector("button[data-show]")?.getAttribute("aria-expanded") === "true",
    )
  },

  // Into an organisation's workspaces: point at it and focus its first workspace, on a
  // phone the one panel shown.
  into(row) {
    if (!row) return
    this.point(row)
    this.menu.dataset.view = "workspaces"
    // An organisation with no workspace: on a phone the way back, the one control shown;
    // elsewhere focus stays on its ›.
    const first = [
      ...this.workspacesOf(row).querySelectorAll("a[data-switch]"),
      this.menu.querySelector("button[data-back]"),
    ].find(el => el && shown(el))
    first?.focus()
  },

  // Focus back in the menu: on the control last pressed where it is still shown, else the
  // first row of the panel shown, else the search.
  refocus() {
    const panel = [...this.menu.querySelectorAll("[data-panel]")].find(shown)
    const rows = panel ? this.rows(panel) : []
    const target = [this.pressed, ...rows].find(el => el && this.menu.contains(el) && shown(el))
    ;(target || this.search()).focus()
  },

  back() {
    delete this.menu.dataset.view
    this.pointed()?.querySelector("a")?.focus()
  },

  onPointer(e) {
    if (!this.menu || !this.side() || e.pointerType === "touch") return
    clearTimeout(this.rest)
    const row = e.target.closest("li[data-org]")
    if (!row || row === this.pointed()) return
    this.rest = setTimeout(() => this.point(row), REST)
  },

  filter() {
    const menu = this.menu
    if (!menu) return
    const q = this.search().value.trim().toLowerCase()
    let count = 0
    if (this.side()) {
      const rows = [...menu.querySelectorAll("li[data-org]")]
      const links = rows.map(row => [...this.workspacesOf(row).querySelectorAll("a[data-search]")])
      const result = filterOrganisations(
        q,
        rows.map((row, i) => ({
          search: row.dataset.search,
          workspaces: links[i].map(a => a.dataset.search),
        })),
      )
      rows.forEach((row, i) => {
        row.hidden = !result[i].show
        links[i].forEach((link, j) => (link.parentElement.hidden = !result[i].workspaces[j]))
      })
      this.matched = new Map(rows.map((row, i) => [row, result[i].own]))
      count = result.filter(r => r.show).length
      menu.querySelectorAll("[data-group]").forEach(group => {
        group.hidden = ![...group.querySelectorAll("li[data-org]")].some(row => !row.hidden)
        // A folded group shows its organisations while a search finds one in it.
        const list = group.querySelector("[data-fold-list]")
        const fold = group.querySelector("button[data-fold]")
        if (list && fold)
          list.hidden = q === "" ? fold.getAttribute("aria-expanded") !== "true" : false
      })
      const visible = this.orgs()
      if (!visible.includes(this.pointed())) this.point(visible[0])
    } else {
      const links = [...menu.querySelectorAll("a[data-search]")]
      const result = filterWorkspaces(q, links.map(a => a.dataset.search))
      links.forEach((link, i) => (link.parentElement.hidden = !result[i]))
      count = result.filter(Boolean).length
    }
    menu.querySelector(".q-switcher-empty").hidden = count > 0
    // Say what the search left, in the server's words: a count, or that nothing matches.
    const status = menu.querySelector("[role='status']")
    if (status) status.textContent = statusWords(q, count, status.dataset)
  },

  // The rows ↑ and ↓ move between in a panel: the left one's links and fold buttons, then
  // the foot's; the right one's way back and workspaces.
  rows(panel) {
    const foot = panel === this.side() ? [] : [...this.menu.querySelectorAll(".q-switcher-foot a")]
    return [...panel.querySelectorAll("a, button[data-fold], button[data-back]"), ...foot].filter(
      shown,
    )
  },

  // The first match: the first organisation shown, or its first workspace shown where the
  // search found the organisation by a workspace; in the workspace menu, the first
  // workspace shown.
  firstMatch() {
    const first = within =>
      [...within.querySelectorAll("a[data-switch]")].find(link => !link.parentElement.hidden)
    if (!this.side()) return first(this.menu)
    const row = this.orgs()[0]
    if (!row) return null
    return this.matched?.get(row) === false ? first(this.workspacesOf(row)) : row.querySelector("a")
  },

  onKey(e) {
    if (!this.menu) return
    const side = this.side()
    const where =
      e.target === this.search() ? "search" : side?.contains(e.target) ? "workspaces" : "organisations"
    const action = keyAction(e.key, where)
    if (!action || (!side && (action === "into" || action === "back"))) return
    e.preventDefault()
    if (action === "close") {
      e.stopPropagation()
      this.close(true)
    } else if (action === "follow") {
      const first = this.firstMatch()
      if (first) {
        this.writePage(first)
        first.click()
      }
    } else if (action === "into") {
      this.into(e.target.closest("li[data-org]"))
    } else if (action === "back") {
      this.back()
    } else {
      const panel = where === "workspaces" ? side : this.menu.querySelector("[data-panel]")
      const rows = this.rows(panel)
      // On a row's ›, as on its link.
      const at = rows.indexOf(e.target.closest("li[data-org]")?.querySelector("a") || e.target)
      const to = action === "first" ? step("next", -1, rows.length) : step(action, at, rows.length)
      if (to >= 0) rows[to]?.focus()
      else if (where === "workspaces") rows[0]?.focus()
      else this.search().focus()
    }
  },
}
