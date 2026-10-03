// Search or jump to: the palette of the top bar, a native <dialog>. The bar's button
// ([data-palette-open]), ⌘K or Ctrl+K anywhere and / outside a field open it. What the
// reader types is asked of the page's scope (the dialog's data-url, answered by
// ApiaryWeb.JumpController) 150 ms after they stop, and the answer is listed as links in
// groups: ↑ and ↓ move, Enter opens, Escape and the backdrop close, and focus goes back
// to where it was. Every word comes from the server; what a runner reported (a path, a
// task) is written as text, never as markup.
import {singleKeys} from "./shortcuts"
const DEBOUNCE = 150

export const Palette = {
  mounted() {
    this.input = this.el.querySelector("input")
    this.results = this.el.querySelector("[role=listbox]")
    this.status = this.el.querySelector("[role=status]")
    this.active = -1
    this.seq = 0

    this.onKeyDown = e => {
      const typing = e.target.closest?.("input, textarea, select, [contenteditable]")
      if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === "k") {
        e.preventDefault()
        this.el.open ? this.el.close() : this.open()
      } else if (e.key === "/" && singleKeys() && !typing && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault()
        this.open()
      }
    }
    this.onClick = e => {
      if (e.target.closest("[data-palette-open]")) {
        e.preventDefault()
        this.open()
      }
    }
    document.addEventListener("keydown", this.onKeyDown)
    document.addEventListener("click", this.onClick)

    this.input.addEventListener("input", () => {
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.ask(), DEBOUNCE)
    })
    this.input.addEventListener("keydown", e => this.onKey(e))
    // The backdrop is the dialog itself around its box. A result opens as a link of the
    // page would, in this tab through LiveView, beside it with a modifier.
    this.el.addEventListener("click", e => {
      const option = e.target.closest("a[role=option]")
      if (e.target === this.el) {
        this.el.close()
      } else if (option && !(e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1)) {
        e.preventDefault()
        this.go(option.getAttribute("href"))
      }
    })
    this.el.addEventListener("close", () => {
      this.opener?.focus?.()
      this.opener = null
    })
  },

  destroyed() {
    document.removeEventListener("keydown", this.onKeyDown)
    document.removeEventListener("click", this.onClick)
    clearTimeout(this.timer)
  },

  open() {
    if (this.el.open) return this.input.focus()
    this.opener = document.activeElement
    this.input.value = ""
    this.el.showModal()
    this.input.focus()
    this.ask()
  },

  async ask() {
    const seq = ++this.seq
    const url = new URL(this.el.dataset.url, window.location.origin)
    url.searchParams.set("q", this.input.value)
    try {
      const response = await fetch(url, {
        headers: {accept: "application/json"},
        credentials: "same-origin",
      })
      if (!response.ok || seq !== this.seq) return
      this.render(await response.json(), this.input.value.trim())
    } catch (_e) {
      // A failed read leaves the last answer on screen.
    }
  },

  render(answer, text) {
    const frag = document.createDocumentFragment()
    let n = 0
    answer.groups.forEach((group, g) => {
      const box = document.createElement("div")
      box.setAttribute("role", "group")
      box.setAttribute("aria-labelledby", `palette-group-${g}`)
      const heading = document.createElement("div")
      heading.id = `palette-group-${g}`
      heading.className = "q-palette-heading"
      heading.textContent = group.label
      box.append(heading)
      for (const item of group.items) {
        const link = document.createElement("a")
        link.id = `palette-option-${n++}`
        link.href = item.href
        link.className = "q-palette-opt"
        link.setAttribute("role", "option")
        link.setAttribute("aria-selected", "false")
        link.tabIndex = -1
        const icon = document.createElement("span")
        icon.className = `${item.icon || "hero-arrow-right-micro"} size-4`
        icon.setAttribute("aria-hidden", "true")
        const label = document.createElement("span")
        label.className = "q-palette-label"
        label.textContent = item.label
        link.append(icon, label)
        if (item.detail) {
          const detail = document.createElement("span")
          detail.className = "q-palette-detail"
          detail.textContent = item.detail
          link.append(detail)
        }
        box.append(link)
      }
      frag.append(box)
    })
    if (n === 0 && text !== "") {
      const empty = document.createElement("p")
      empty.className = "q-palette-empty"
      empty.textContent = answer.empty
      frag.append(empty)
    }
    this.results.replaceChildren(frag)
    this.status.textContent = n === 0 && text !== "" ? answer.empty : answer.status
    this.select(n > 0 ? 0 : -1)
  },

  options() {
    return [...this.results.querySelectorAll("[role=option]")]
  },

  select(index) {
    const options = this.options()
    options.forEach((o, i) => o.setAttribute("aria-selected", String(i === index)))
    this.active = index
    if (index >= 0) {
      this.input.setAttribute("aria-activedescendant", options[index].id)
      options[index].scrollIntoView({block: "nearest"})
    } else {
      this.input.removeAttribute("aria-activedescendant")
    }
  },

  onKey(e) {
    const options = this.options()
    if (e.key === "ArrowDown" || e.key === "ArrowUp") {
      e.preventDefault()
      if (options.length === 0) return
      const step = e.key === "ArrowDown" ? 1 : -1
      this.select((this.active + step + options.length) % options.length)
    } else if (e.key === "Enter") {
      e.preventDefault()
      const option = options[this.active] || options[0]
      if (!option) return
      // With a modifier the browser opens it beside this page, as a click would.
      if (e.metaKey || e.ctrlKey) {
        window.open(option.href, "_blank", "noopener")
      } else {
        this.go(option.getAttribute("href"))
      }
    }
  },

  go(href) {
    this.opener = null
    this.el.close()
    this.js().navigate(href)
  },
}
