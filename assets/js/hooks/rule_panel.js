// The panel of a connection row's Allow or Deny (`RunComponents.rule_panel/1`): in place,
// under the row, in the page's flow; never an overlay. The server renders it while it is
// open; this hook only moves the focus. As it opens, the focus goes into it (the element
// marked `data-autofocus`: the option chosen, Close, or the way to the level above's
// policy). As it goes while it held the focus (Cancel, Escape, a rule saved, the policy
// moved under it), the focus goes back to the row's action, or to the row's ⋯ menu where
// a narrow table hides the action, so it never falls to the page's body.

export const RulePanel = {
  mounted() {
    this.remember()
    const first = this.el.querySelector("[data-autofocus]")
    // After the patch, so that a panel that replaced another one keeps the focus.
    requestAnimationFrame(() => {
      if (first) first.focus({preventScroll: true})
      this.el.scrollIntoView({block: "nearest"})
    })
  },

  updated() {
    this.remember()
  },

  destroyed() {
    const active = document.activeElement
    if (active && active !== document.body) return
    // The action may have become the "Rule" link; it keeps the id.
    for (const id of this.back) {
      const el = id && document.getElementById(id)
      if (el && el.getClientRects().length > 0) {
        el.focus({preventScroll: true})
        return
      }
    }
  },

  remember() {
    this.back = [this.el.dataset.anchor, this.el.dataset.menu]
  },
}
