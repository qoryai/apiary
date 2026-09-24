// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/apiary"
import topbar from "../vendor/topbar"
import {Ticker} from "./hooks/ticker"
import {RunGroups} from "./hooks/runs"
import {LiveEnd} from "./hooks/live_end"
import {TimelineKeys} from "./hooks/timeline_keys"
import {Terminal} from "./hooks/terminal"
import {FocusOn} from "./hooks/focus_on"
import {PolicyPage, RuleComposer, ChangeRow} from "./hooks/policy"
import {RulePopover} from "./hooks/rule_popover"
import {DaysChart, OverviewPage} from "./hooks/overview"
import {FamilyBoxes} from "./hooks/family_boxes"

// Copies `data-copy` (or the text content of the element `data-copy-target`
// points at) to the clipboard, flips the button into its "Copied" state for
// 1600 ms and announces it politely.
const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const target = this.el.dataset.copyTarget
      const text = target
        ? (document.querySelector(target)?.textContent ?? "")
        : (this.el.dataset.copy ?? "")
      try {
        await navigator.clipboard.writeText(text)
      } catch (_err) {
        const area = document.createElement("textarea")
        area.value = text
        area.setAttribute("readonly", "")
        area.style.position = "absolute"
        area.style.left = "-9999px"
        document.body.appendChild(area)
        area.select()
        document.execCommand("copy")
        area.remove()
      }
      this.el.setAttribute("data-copied", "")
      const live = this.el.querySelector("[aria-live]")
      if (live) live.textContent = this.el.dataset.copiedWords || ""
      clearTimeout(this.timer)
      this.timer = setTimeout(() => {
        this.el.removeAttribute("data-copied")
        if (live) live.textContent = ""
      }, 1600)
    })
  },
  destroyed() {
    clearTimeout(this.timer)
  },
}

// A native <dialog> shown as a modal while it is in the page. Escape and the
// backdrop run the `data-cancel` JS command (a patch back to the index); a
// dialog without one cannot be dismissed.
const Modal = {
  mounted() {
    this.trigger = document.activeElement
    this.el.addEventListener("cancel", e => {
      e.preventDefault()
      this.cancel()
    })
    // The backdrop is a form[method=dialog]; the server closes the dialog.
    this.el.addEventListener("submit", e => {
      if (e.target.method === "dialog") {
        e.preventDefault()
        this.cancel()
      }
    })
    // Chrome lets a second Escape through: the server decides when it closes.
    this.el.addEventListener("close", () => this.el.isConnected && this.el.showModal())
    if (!this.el.open) this.el.showModal()
    this.focusFirst()
    // The dialog may still be becoming visible on a fresh page load.
    setTimeout(() => this.el.contains(document.activeElement) && document.activeElement !== this.el || this.focusFirst(), 80)
  },
  focusFirst() {
    const first =
      this.el.querySelector("[data-autofocus]") ||
      this.el.querySelector(".modal-body input:not([type=hidden]), .modal-body select, .modal-body textarea") ||
      this.el.querySelector(".modal-action [data-cancel-button]") ||
      this.el.querySelector(".modal-action .btn-primary")
    first?.focus()
  },
  updated() {
    if (!this.el.open) this.el.showModal()
  },
  cancel() {
    const js = this.el.dataset.cancel
    if (js) this.liveSocket.execJS(this.el, js)
  },
  destroyed() {
    if (this.trigger?.isConnected) this.trigger.focus({preventScroll: true})
  },
}

// A daisyUI dropdown with menu manners: a click toggles and leaves focus on the
// trigger (nothing jumps under the cursor); Enter, Space and ArrowDown open and
// focus the first item, ArrowUp the last; arrows wrap, Home and End go to the
// ends; Escape closes and gives focus back; focus leaving closes.
const Menu = {
  mounted() {
    const trigger = () => this.el.querySelector("[aria-haspopup]")
    const items = () =>
      [...this.el.querySelectorAll(".dropdown-content :is(a, button):not([disabled])")]
    const set = open => {
      this.el.classList.toggle("dropdown-open", open)
      trigger()?.setAttribute("aria-expanded", String(open))
    }
    const close = refocus => {
      set(false)
      if (this.el.contains(document.activeElement)) {
        refocus ? trigger()?.focus() : document.activeElement.blur()
      }
    }
    this.el.addEventListener("click", e => {
      const t = trigger()
      if (t && t.contains(e.target)) {
        this.el.classList.contains("dropdown-open") ? close(false) : set(true)
      } else if (e.target.closest("a, [data-menu-close]")) {
        close(false)
      }
    })
    this.el.addEventListener("keydown", e => {
      const list = items()
      const at = list.indexOf(document.activeElement)
      const t = trigger()
      const open = this.el.classList.contains("dropdown-open") || this.el.matches(":focus-within")
      if ((e.key === "Enter" || e.key === " ") && e.target === t) {
        // Not the button's own click: that would open with focus still on the trigger.
        e.preventDefault()
        if (this.el.classList.contains("dropdown-open")) {
          close(true)
        } else {
          set(true)
          list[0]?.focus()
        }
      } else if (e.key === "Escape" && open) {
        e.preventDefault()
        e.stopPropagation()
        close(true)
      } else if (e.key === "ArrowDown" || e.key === "ArrowUp") {
        e.preventDefault()
        set(true)
        const step = e.key === "ArrowDown" ? 1 : -1
        const next = at < 0 ? (step > 0 ? 0 : list.length - 1) : (at + step + list.length) % list.length
        list[next]?.focus()
      } else if (e.key === "Home" || e.key === "End") {
        e.preventDefault()
        list[e.key === "Home" ? 0 : list.length - 1]?.focus()
      }
    })
    this.el.addEventListener("focusout", e => {
      if (!this.el.contains(e.relatedTarget)) set(false)
    })
    this.outside = e => {
      if (!this.el.contains(e.target)) set(false)
    }
    document.addEventListener("pointerdown", this.outside)
  },
  destroyed() {
    document.removeEventListener("pointerdown", this.outside)
  },
}

// The sidebar as a drawer below 768 px: focus moves in and back out, the page
// behind is inert and does not scroll, Escape and navigation close it.
const NavDrawer = {
  mounted() {
    const toggle = this.el.querySelector(".drawer-toggle")
    const wide = matchMedia("(min-width: 768px)")
    const sync = focus => {
      const open = toggle.checked && !wide.matches
      const main = this.el.querySelector(".drawer-content")
      main.toggleAttribute("inert", open)
      document.documentElement.style.overflow = open ? "hidden" : ""
      this.el.querySelector("[data-drawer-open]")?.setAttribute("aria-expanded", String(open))
      if (focus) {
        // The drawer is still hidden in this frame; focus once it shows.
        const target = this.el.querySelector(open ? "[data-drawer-close]" : "[data-drawer-open]")
        let tries = 0
        const go = () => {
          target?.focus()
          if (document.activeElement !== target && tries++ < 30) requestAnimationFrame(go)
        }
        go()
      }
    }
    const set = (open, focus = true) => {
      if (toggle.checked === open) return
      toggle.checked = open
      sync(focus)
    }
    this.el.addEventListener("click", e => {
      if (e.target.closest("[data-drawer-open]")) set(true)
      else if (e.target.closest("[data-drawer-close]")) set(false)
    })
    toggle.addEventListener("change", () => sync(true))
    this.onKey = e => {
      if (e.key === "Escape" && toggle.checked && !wide.matches && !e.defaultPrevented) set(false)
    }
    document.addEventListener("keydown", this.onKey)
    this.onNav = () => set(false, false)
    window.addEventListener("phx:page-loading-stop", this.onNav)
    this.onWide = () => wide.matches && set(false, false)
    wide.addEventListener("change", this.onWide)
    this.wide = wide
  },
  destroyed() {
    window.removeEventListener("phx:page-loading-stop", this.onNav)
    document.removeEventListener("keydown", this.onKey)
    this.wide.removeEventListener("change", this.onWide)
    document.documentElement.style.overflow = ""
  },
}

// Info toasts leave after 5 s; hovering or focusing one holds it.
const autoDismiss = (el, dismiss) => {
  let timer
  const start = () => {
    clearTimeout(timer)
    timer = setTimeout(dismiss, 5000)
  }
  const hold = () => clearTimeout(timer)
  el.addEventListener("mouseenter", hold)
  el.addEventListener("focusin", hold)
  el.addEventListener("mouseleave", start)
  el.addEventListener("focusout", start)
  start()
  return hold
}

const Toast = {
  mounted() {
    this.stop = autoDismiss(this.el, () => this.liveSocket.execJS(this.el, this.el.dataset.dismiss))
  },
  updated() {
    this.stop()
    this.mounted()
  },
  destroyed() {
    this.stop()
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CopyToClipboard, Modal, Menu, NavDrawer, Toast, Ticker, RunGroups, LiveEnd, TimelineKeys, Terminal, FocusOn, RulePopover, PolicyPage, RuleComposer, ChangeRow, DaysChart, OverviewPage, FamilyBoxes},
  dom: {
    // showModal() sets `open` on the client; keep it across patches.
    onBeforeElUpdated(from, to) {
      if (from.tagName === "DIALOG" && from.open) to.setAttribute("open", "")
    },
  },
})

// Pages rendered by a controller have no hooks: run the toast timer by hand.
window.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-dismiss]").forEach(el => {
    if (!el.closest("[data-phx-session]")) {
      autoDismiss(el, () => liveSocket.execJS(el, el.dataset.dismiss))
    }
  })
})

// Buttons with a gerund (`data-busy`) show it while their form submits. The
// button may sit outside the form (a modal footer), so the form's loading
// class cannot reach it from CSS.
const busyButtons = form => {
  const inside = [...form.querySelectorAll(".btn[data-busy]:not([type=button])")]
  const outside = form.id ? [...document.querySelectorAll(`.btn[data-busy][form="${form.id}"]`)] : []
  return [...inside, ...outside]
}
document.addEventListener("submit", e => {
  const form = e.target
  if (!(form instanceof HTMLFormElement)) return
  const buttons = busyButtons(form)
  if (buttons.length === 0) return
  buttons.forEach(b => {
    b.classList.add("is-busy")
    b.setAttribute("aria-busy", "true")
  })
  if (!form.hasAttribute("phx-submit")) return
  // LiveView marks the form while it waits; clear the buttons when it stops.
  const done = () => {
    busyButtons(form).forEach(b => {
      b.classList.remove("is-busy")
      b.removeAttribute("aria-busy")
    })
    // A failed submit puts the caret in the first invalid field.
    setTimeout(() => form.isConnected && form.querySelector("[aria-invalid=true]")?.focus(), 0)
  }
  let seen = false
  const watch = new MutationObserver(() => {
    const loading = form.classList.contains("phx-submit-loading")
    if (loading) seen = true
    if ((seen && !loading) || !form.isConnected) {
      watch.disconnect()
      done()
    }
  })
  watch.observe(form, {attributes: true, attributeFilter: ["class"]})
  setTimeout(() => {
    if (!seen) {
      watch.disconnect()
      done()
    }
  }, 600)
}, true)
document.addEventListener("click", e => {
  const button = e.target.closest?.(".btn[data-busy][phx-click]")
  if (!button) return
  button.setAttribute("aria-busy", "true")
  const watch = new MutationObserver(() => {
    if (!button.classList.contains("phx-click-loading")) {
      watch.disconnect()
      button.removeAttribute("aria-busy")
    }
  })
  setTimeout(() => watch.observe(button, {attributes: true, attributeFilter: ["class"]}), 0)
})

// The theme control is a group of three buttons; the script in the root
// layout owns the theme, this keeps `aria-pressed` honest.
const syncThemeButtons = () => {
  const root = document.documentElement
  const current =
    root.getAttribute("data-theme-source") === "system"
      ? "system"
      : root.getAttribute("data-theme") === "qory-dark" ? "dark" : "light"
  document.querySelectorAll("[data-phx-theme]").forEach(b => {
    const state = b.getAttribute("role") === "menuitemradio" ? "aria-checked" : "aria-pressed"
    b.setAttribute(state, String(b.dataset.phxTheme === current))
  })
}
window.addEventListener("DOMContentLoaded", syncThemeButtons)
window.addEventListener("phx:set-theme", () => setTimeout(syncThemeButtons, 0))
window.addEventListener("storage", e => e.key === "phx:theme" && setTimeout(syncThemeButtons, 0))
window.addEventListener("phx:page-loading-stop", syncThemeButtons)

// Show progress bar on live navigation and form submits, in the theme's honey.
const honey = () =>
  getComputedStyle(document.documentElement).getPropertyValue("--color-primary").trim() || "#eea82f"
topbar.config({barThickness: 2, barColors: {0: honey()}, shadowColor: "rgba(0, 0, 0, 0)"})
window.addEventListener("phx:page-loading-start", _info => {
  topbar.config({barColors: {0: honey()}})
  topbar.show(300)
})
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

