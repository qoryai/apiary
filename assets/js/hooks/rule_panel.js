// The panel of a connection row's Allow or Deny (`RunComponents.rule_panel/1`): in place,
// under the row, in the page's flow; never an overlay. The server renders it while it is
// open; this hook only moves the focus. As it opens, the focus goes into it (the element
// marked `data-autofocus`: the option chosen, Close, or the way to the level above's
// policy). As it goes while it held the focus (Cancel, Escape, a rule saved, the policy
// moved under it), the focus goes back to the icon that opened it (`data-anchor`), or,
// where it is gone, to the row's Show the rule or its copy icon (`data-back`), so it never
// falls to the page's body.
//
// The panel keeps its id from row to row, so a panel opened over another one is this same
// element patched and moved, not a new one: it opens anew when its anchor or its kind
// changes.

export const RulePanel = {
  mounted() {
    this.remember()
    this.enter()
  },

  updated() {
    const was = this.key
    this.remember()
    if (this.key !== was) this.enter()
  },

  destroyed() {
    const active = document.activeElement
    if (active && active !== document.body) return
    // The icon may be gone (a rule was added): the row's Show the rule, else its copy.
    for (const id of this.back) {
      const el = id && document.getElementById(id)
      if (el && el.getClientRects().length > 0) {
        el.focus({preventScroll: true})
        return
      }
    }
  },

  remember() {
    const {anchor, kind, back} = this.el.dataset
    this.key = `${anchor} ${kind}`
    this.back = [anchor, ...(back || "").split(" ")]
  },

  // After the patch, so that a panel that replaced another one keeps the focus.
  enter() {
    requestAnimationFrame(() => {
      const first = this.el.querySelector("[data-autofocus]")
      if (first) first.focus({preventScroll: true})
      this.el.scrollIntoView({block: "nearest"})
    })
  },
}
