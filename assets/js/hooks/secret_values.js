// New secret's Values, on its form: "One value" or "Several values, each with a value ID".
// Everything here happens in the browser alone, and the form sends no change event, so no
// value leaves the browser before Save.
//
// - The choice shows the fields of one value or of several, and turns off the fields of
//   the other, so that Save sends only the values of the choice taken (synced on every
//   change of the choice, and again as the form submits, before LiveView reads it). The
//   server renders the same: the group not chosen hidden, its fields off.
// - "Add another value" copies the row in the <template>, at the next index, renumbers
//   the rows ("Value 3", and its Remove "Remove value 3", for whoever hears them) and
//   moves the focus to its value ID; past the most a secret holds it is off, and a line
//   says why.
// - Remove, on a row past the first two, takes the row out and leaves the focus on "Add
//   another value".
//
// The server knows none of this until Save, so a render it sends for any other reason (a
// count in the sidebar, say) would put its own choice and rows back. Before such a patch
// the hook keeps, in this object only, the choice, the rows in their order and what was
// written in them, and puts them back once the patch is in; the focus too. Nothing kept is
// sent, stored or logged, and it is dropped once put back. A refused save's render is the
// one the server means: the form's `data-refused-saves` counts them, and when it changes
// the server's choice and rows, each with its errors and its value empty, stand.
//
// LiveView calls beforeUpdate and updated only when the form differs from the server's
// render as a node, attributes and children, but its patch still empties every field the
// person wrote in without leaving the focus there. So the form carries an attribute the
// server never renders (`data-values-kept`), set again after each patch: the form always
// differs, and the hook hears of every patch.

export const SecretValues = {
  mounted() {
    this.el.addEventListener("click", e => {
      if (e.target.closest("[data-add-value]")) {
        e.preventDefault()
        this.add()
        return
      }
      const remove = e.target.closest("[data-remove-value]")
      if (remove) {
        e.preventDefault()
        this.remove(remove.closest("[data-value-row]"))
      }
    })
    this.el.addEventListener("change", e => {
      if (e.target.name === "secret[values_kind]") this.sync()
    })
    // At the form, before LiveView's own listener, on the window, serialises it.
    this.el.addEventListener("submit", () => this.sync())
    this.sync()
    this.mark()
  },
  mark() {
    this.el.setAttribute("data-values-kept", "")
  },
  beforeUpdate(toEl) {
    const refused = toEl?.dataset?.refusedSaves !== this.el.dataset.refusedSaves
    this.kept = refused ? null : this.keep()
  },
  updated() {
    if (this.kept) this.restore(this.kept)
    this.kept = null
    this.sync()
    this.mark()
  },
  several() {
    return this.el.querySelector('input[name="secret[values_kind]"][value="several"]')?.checked
  },
  groups() {
    return {
      one: this.el.querySelector("#secret-one-value"),
      several: this.el.querySelector("#secret-several-values"),
    }
  },
  sync() {
    const several = this.several()
    const {one, several: many} = this.groups()
    if (!one || !many) return
    this.show(one, !several)
    this.show(many, several)
    this.renumber()
    this.full()
  },
  show(group, shown) {
    group.hidden = !shown
    for (const field of group.querySelectorAll("input, textarea")) field.disabled = !shown
  },
  rows() {
    return Array.from(this.el.querySelectorAll("#secret-values > [data-value-row]"))
  },
  add() {
    const list = this.el.querySelector("#secret-values")
    const template = this.el.querySelector("#secret-value-template")
    const {several} = this.groups()
    const rows = this.rows()
    if (!list || !template || rows.length >= this.max()) return

    const index = rows.reduce((max, row) => Math.max(max, Number(row.dataset.index) + 1), 0)
    const html = template.innerHTML.replaceAll("__INDEX__", String(index))
    const holder = document.createElement("template")
    holder.innerHTML = html.replaceAll("__NUMBER__", String(rows.length + 1))
    const row = holder.content.firstElementChild
    for (const field of row.querySelectorAll("input, textarea")) field.disabled = !!several.hidden
    list.appendChild(row)

    this.renumber()
    this.full()
    row.querySelector("input")?.focus()
  },
  remove(row) {
    if (!row) return
    row.remove()
    this.renumber()
    this.full()
    this.el.querySelector("#secret-add-value")?.focus()
  },
  renumber() {
    const {several} = this.groups()
    const legend = several?.dataset.legend
    const remove = several?.dataset.remove
    this.rows().forEach((row, i) => {
      const number = String(i + 1)
      const words = row.querySelector("legend")
      if (words && legend) words.textContent = legend.replace("__NUMBER__", number)
      const button = row.querySelector("[data-remove-value]")
      if (button && remove) button.setAttribute("aria-label", remove.replace("__NUMBER__", number))
    })
  },
  max() {
    return Number(this.groups().several?.dataset.max) || 32
  },
  full() {
    const full = this.rows().length >= this.max()
    const add = this.el.querySelector("#secret-add-value")
    const line = this.el.querySelector("#secret-values-full")
    // The error on the values as a whole says it already.
    const said = !!this.el.querySelector("#secret-values-error")
    if (add) add.disabled = full
    if (line) line.hidden = !full || said
  },
  // What the person chose and wrote, as it is before a patch: the rows themselves, which
  // the patch may take out of the page, with what each holds.
  keep() {
    const one = this.el.querySelector("#secret-one-value textarea")
    const focused = this.el.contains(document.activeElement) ? document.activeElement : null
    return {
      several: !!this.several(),
      one: one ? one.value : null,
      rows: this.rows().map(row => ({
        id: row.id,
        row,
        valueId: row.querySelector("input")?.value ?? "",
        value: row.querySelector("textarea")?.value ?? "",
      })),
      focus: focused?.id || null,
      selection:
        focused && typeof focused.selectionStart === "number"
          ? [focused.selectionStart, focused.selectionEnd]
          : null,
    }
  },
  restore(kept) {
    for (const radio of this.el.querySelectorAll('input[name="secret[values_kind]"]')) {
      radio.checked = (radio.value === "several") === kept.several
    }

    const one = this.el.querySelector("#secret-one-value textarea")
    if (one && kept.one !== null) one.value = kept.one

    const list = this.el.querySelector("#secret-values")
    if (list) {
      const now = new Map(this.rows().map(row => [row.id, row]))
      for (const {id, row} of kept.rows) {
        // The server's own row while it is there, else the person's, put back.
        list.appendChild(now.get(id) || row)
        now.delete(id)
      }
      for (const row of now.values()) row.remove()

      for (const {id, valueId, value} of kept.rows) {
        const row = document.getElementById(id)
        const input = row?.querySelector("input")
        const textarea = row?.querySelector("textarea")
        if (input) input.value = valueId
        if (textarea) textarea.value = value
      }
    }

    this.sync()

    const focus = kept.focus && document.getElementById(kept.focus)
    if (focus && document.activeElement !== focus) {
      focus.focus({preventScroll: true})
      if (kept.selection && typeof focus.setSelectionRange === "function") {
        try {
          focus.setSelectionRange(kept.selection[0], kept.selection[1])
        } catch (_e) {
          // a field without a selection
        }
      }
    }
  },
}
