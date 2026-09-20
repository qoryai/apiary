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

// Copies `data-copy` (or the text content of the element `data-copy-target`
// points at) to the clipboard and flips the button into its "copied" state
// for a moment.
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
      clearTimeout(this.timer)
      this.timer = setTimeout(() => this.el.removeAttribute("data-copied"), 1600)
    })
  },
  destroyed() {
    clearTimeout(this.timer)
  },
}

// Submits the closest form when the element changes (apiary switcher).
const SubmitOnChange = {
  mounted() {
    this.el.addEventListener("change", () => this.el.form?.submit())
  },
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, CopyToClipboard, SubmitOnChange},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "oklch(78% 0.16 75)"}, shadowColor: "rgba(0, 0, 0, .15)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
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

