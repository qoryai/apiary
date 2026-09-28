// The State menu's family headings, on the menu's form. A heading is a checkbox over the
// states under it (both carry data-family): a change of the heading ticks or unticks its
// states before the event reaches LiveView, so the form it serialises already holds them;
// the server renders the checked and mixed states, and the mixed one is mirrored into the
// `indeterminate` property, which no attribute can set. Without this script the server reads
// the heading itself (Filters.change/2), so the menu works either way.

export const FamilyBoxes = {
  mounted() {
    this.sync()
    // Capture, so it runs before LiveView's own listener has read the form.
    this.el.addEventListener(
      "input",
      e => {
        const heading = e.target.closest?.('input[name^="family_"]')
        if (!heading) return
        for (const box of this.states(heading.dataset.family)) box.checked = heading.checked
        heading.indeterminate = false
      },
      true
    )
  },
  updated() {
    this.sync()
  },
  states(family) {
    return this.el.querySelectorAll(`input[name$="[]"][data-family="${family}"]`)
  },
  sync() {
    for (const heading of this.el.querySelectorAll('input[name^="family_"]')) {
      heading.indeterminate = heading.getAttribute("aria-checked") === "mixed"
    }
  },
}
