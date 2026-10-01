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
// The console's hooks, in one collection another bundle can import too (hooks.js).
import {hooks, autoDismiss} from "./hooks.js"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...hooks},
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

// A live navigation replaces the page under the reader: give focus to its title, so a
// screen reader says where they are and the keyboard goes on from there, unless the
// new page put focus somewhere itself (a dialog's first field, say).
window.addEventListener("phx:page-loading-stop", ({detail}) => {
  if (detail?.kind !== "redirect") return
  setTimeout(() => {
    const now = document.activeElement
    if (now && now !== document.body && now.isConnected) return
    document.querySelector("main h1[tabindex]")?.focus({preventScroll: true})
  }, 0)
})

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

