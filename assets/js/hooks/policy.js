// The policy pages: what the server cannot do once the page is there.
//
// PolicyPage, on the page's root:
//   "policy:focus"  {id}       focus after an action, so that it never falls to the body
//   "policy:fields" {fields}   values the server put into a field that may have focus,
//                              which a patch alone would leave as the reader typed it
//   "policy:rule" {host}     scroll to the rule ?rule= points at
//   keys, while no field has focus:  a  the composer's host field, Add rule while it is shut
//                                    ?  shows or hides the list of keys, a panel in the
//                                       page (#policy-keys), never an overlay; Escape and
//                                       its Close hide it
//   Escape, with the focus in the mode's choices (#policy-mode-form), closes them
//   (`mode_cancel`): an Escape elsewhere, the palette's or a search's, leaves them open
//
// RuleComposer, on the composer's form: a pasted list of hosts, one per line, goes to the
// server as a list, which fills the composer with the first and queues the rest.
//
// ChangeRow, on a change's <details>: the URL decides what is open, so the native toggle
// is held back and the summary's click only patches.
import {singleKeys} from "./shortcuts"

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
    this.onClick = e => {
      if (e.target.closest?.("[data-keys-close]")) this.keys(false)
    }
    this.el.addEventListener("click", this.onClick)
    this.reveal()
  },

  destroyed() {
    document.removeEventListener("keydown", this.onKey)
    this.el.removeEventListener("click", this.onClick)
  },

  // The list of keys, shown or hidden in place. Shown, it takes the focus so that it is
  // read; hidden from inside, the focus goes back to where it was before.
  keys(show) {
    const panel = document.getElementById("policy-keys")
    if (!panel) return
    if (show) {
      this.keysFrom = document.activeElement
      panel.hidden = false
      panel.focus({preventScroll: false})
    } else if (!panel.hidden) {
      const inside = panel.contains(document.activeElement)
      panel.hidden = true
      if (inside && this.keysFrom?.isConnected) this.keysFrom.focus()
    }
  },

  // An element drawn by the next patch is not there yet: ask again for a few frames.
  focus(id, tries = 0) {
    requestAnimationFrame(() => {
      const el = document.getElementById(id)
      if (el && !el.disabled && el.offsetParent !== null) {
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
    if (e.key === "Escape" && e.target.closest?.("#policy-mode-form")) {
      e.preventDefault()
      this.pushEvent("mode_cancel", {})
      return
    }
    if (e.key === "Escape" && !document.querySelector("dialog[open]")) {
      const panel = document.getElementById("policy-keys")
      if (panel && !panel.hidden) this.keys(false)
      return
    }
    if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey || typing(e.target)) return
    if (document.querySelector("dialog[open]") || !singleKeys()) return
    if (e.key === "a") {
      const host = document.getElementById("policy-composer-host")
      const add = document.getElementById("policy-rules-add") || document.getElementById("policy-first-rule")
      if (host) {
        e.preventDefault()
        host.focus()
      } else if (add) {
        e.preventDefault()
        add.click()
      }
    } else if (e.key === "?") {
      const keys = document.getElementById("policy-keys")
      if (keys) {
        e.preventDefault()
        this.keys(keys.hidden)
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
