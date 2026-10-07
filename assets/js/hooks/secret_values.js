// New secret's Values, on its form: "One value" or "Several values, each with a value ID".
// Everything here happens in the browser alone, and the form sends no change event, so no
// value leaves the browser before Save.
//
// - The choice shows the fields of one value or of several, and turns off the fields of
//   the other, so that Save sends only the values of the choice taken (synced on every
//   change of the choice, and again as the form submits, before LiveView reads it).
// - "Add another value" copies the row in the <template>, at the next index, renumbers
//   the rows ("Value 3", for whoever hears it) and moves the focus to its value ID; past
//   the most a secret holds it is off, and a line says why.
// - Remove, on a row past the first two, takes the row out and leaves the focus on "Add
//   another value".
//
// After a refused save the server renders the rows it was sent again, each with its value
// ID and its errors, and every value empty.

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
  },
  updated() {
    this.sync()
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
    const words = this.groups().several?.dataset.legend
    if (!words) return
    this.rows().forEach((row, i) => {
      const legend = row.querySelector("legend")
      if (legend) legend.textContent = words.replace("__NUMBER__", String(i + 1))
    })
  },
  max() {
    return Number(this.groups().several?.dataset.max) || 32
  },
  full() {
    const full = this.rows().length >= this.max()
    const add = this.el.querySelector("#secret-add-value")
    const line = this.el.querySelector("#secret-values-full")
    if (add) add.disabled = full
    if (line) line.hidden = !full
  },
}
