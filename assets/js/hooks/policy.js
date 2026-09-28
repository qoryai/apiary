// The policy pages (brief-policy ph): what the server cannot do once the page is there.
//
// PolicyPage, on the page's root:
//   "policy:focus"  {id}       focus after an action, so that it never falls to the body
//   "policy:fields" {fields}   values the server put into a field that may have focus,
//                              which a patch alone would leave as the reader typed it
//   "policy:rule" {host}     scroll to the rule ?rule= points at
//   keys, while no field has focus:  a  the composer's host field    ?  the list of keys
//   arrows inside a [data-roving] radiogroup move between its radios
//
// RuleComposer, on the composer's form: a pasted list of hosts, one per line, goes to the
// server as a list, which fills the composer with the first and queues the rest.
//
// ChangeRow, on a change's <details>: the URL decides what is open, so the native toggle
// is held back and the summary's click only patches.

const typing = el => el && el.closest("input, textarea, select, [contenteditable='true']")

export const PolicyPage = {
  mounted() {
    this.handleEvent("policy:focus", ({id}) => this.focus(id))
    this.handleEvent("policy:fields", ({fields}) => {
      for (const [id, value] of Object.entries(fields)) {
        const el = document.getElementById(id)
        if (el && el.value !== value) el.value = value
      }
    })
    this.handleEvent("policy:rule", () => this.reveal())
    this.onKey = e => this.key(e)
    document.addEventListener("keydown", this.onKey)
    this.reveal()
  },

  destroyed() {
    document.removeEventListener("keydown", this.onKey)
  },

  // A closing modal gives focus back to what opened it, a frame later: ask after that.
  focus(id, tries = 0) {
    requestAnimationFrame(() => {
      const el = document.getElementById(id)
      if (el && !el.disabled && el.offsetParent !== null && !document.querySelector("dialog[open].modal")) {
        el.focus({preventScroll: false})
        if (el.select && el.value) el.select()
      } else if (tries < 12) {
        this.focus(id, tries + 1)
      }
    })
  },

  reveal() {
    requestAnimationFrame(() => {
      const row = this.el.querySelector(".q-ruled")
      if (!row) return
      const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches
      row.scrollIntoView({block: "center", behavior: reduce ? "auto" : "smooth"})
    })
  },

  key(e) {
    const roving = e.target.closest?.("[data-roving]")
    if (roving && ["ArrowRight", "ArrowDown", "ArrowLeft", "ArrowUp"].includes(e.key)) {
      const radios = [...roving.querySelectorAll("[role=radio]")]
      const at = radios.indexOf(document.activeElement)
      if (at < 0) return
      e.preventDefault()
      const step = e.key === "ArrowRight" || e.key === "ArrowDown" ? 1 : -1
      radios[(at + step + radios.length) % radios.length].focus()
      return
    }
    if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey || typing(e.target)) return
    if (document.querySelector("dialog[open]")) return
    if (e.key === "a") {
      const host = document.getElementById("policy-composer-host")
      const first = document.getElementById("policy-first-rule")
      if (host) {
        e.preventDefault()
        host.focus()
      } else if (first) {
        e.preventDefault()
        first.click()
      }
    } else if (e.key === "?") {
      const keys = document.getElementById("policy-keys")
      if (keys?.showModal) {
        e.preventDefault()
        keys.showModal()
      }
    }
  },
}

export const RuleComposer = {
  mounted() {
    this.onPaste = e => {
      if (!e.target.matches?.("input[id$='-host']")) return
      const text = e.clipboardData?.getData("text") || ""
      const hosts = text.split(/[\r\n]+/).map(line => line.trim()).filter(Boolean)
      if (hosts.length < 2) return
      e.preventDefault()
      this.pushEvent("composer_paste", {hosts: hosts.slice(0, 50).map(host => host.slice(0, 300))})
    }
    this.el.addEventListener("paste", this.onPaste)
  },
  destroyed() {
    this.el.removeEventListener("paste", this.onPaste)
  },
}

export const ChangeRow = {
  mounted() {
    this.summary = this.el.querySelector("summary")
    this.hold = e => e.preventDefault()
    this.summary?.addEventListener("click", this.hold)
    this.sync()
  },
  updated() {
    this.sync()
  },
  destroyed() {
    this.summary?.removeEventListener("click", this.hold)
  },
  sync() {
    const open = this.el.dataset.open === "true"
    if (this.el.open !== open) this.el.open = open
    if (open && !this.shown) {
      this.shown = true
      requestAnimationFrame(() => this.el.scrollIntoView({block: "nearest"}))
    }
    if (!open) this.shown = false
  },
}
