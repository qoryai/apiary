// The controls at the right end of the line under a version page's player
// (`ApiaryWeb.ArtifactComponents.view/1`, `player`): Cinema and Full screen. The element is
// `phx-update="ignore"`, so a patch of the page keeps what this hook set.
//
// Cinema is kept in `localStorage` (`qory:artifact-cinema`, "on" or absent) and read on
// mount, so it stays on from one page to the next. The hook sets `aria-pressed` on the
// button and `data-cinema` on its element; the page's CSS moves the player above the two
// columns from the pressed button, so the film is not loaded again. A patch of the page
// removes the element's `data-*` attributes that the server did not render, so the hook
// sets `data-cinema` again from the button after each patch and each reconnect.
//
// Full screen asks the browser to show the player's `<figure>` (the film or the picture, the
// line under it and the button) alone, and the button reads Leave full screen while it does.
// Escape leaves, and so does the button. A browser with no full screen hides the button.
//
// A Watch link on the Verify tab leaves a note (`watch_handoff.js`): where the film is
// opened at the note's time and speed, the film is not started.
import {applyHandoff, takeHandoff} from "./watch_handoff.js"

export const CINEMA_KEY = "qory:artifact-cinema"

function local() {
  try {
    return globalThis.localStorage ?? null
  } catch {
    return null
  }
}

function session() {
  try {
    return globalThis.sessionStorage ?? null
  } catch {
    return null
  }
}

// Whether Cinema is on in `storage`.
export function readCinema(storage) {
  try {
    return storage?.getItem(CINEMA_KEY) === "on"
  } catch {
    return false
  }
}

// Keeps Cinema on, or off, in `storage`.
export function writeCinema(storage, on) {
  try {
    if (on) storage?.setItem(CINEMA_KEY, "on")
    else storage?.removeItem(CINEMA_KEY)
  } catch {
    // A refused storage: Cinema holds for this page only.
  }
}

const OUT = "hero-arrows-pointing-out-micro"
const IN = "hero-arrows-pointing-in-micro"

export const ArtifactPlayer = {
  mounted() {
    const el = this.el
    this.box = el.closest("figure")
    this.video = this.box?.querySelector("video") ?? null
    this.cinema = el.querySelector("[data-cinema-toggle]")
    this.full = el.querySelector("[data-full-screen]")

    this.setCinema(readCinema(local()))
    this.onCinema = () => {
      const on = this.cinema.getAttribute("aria-pressed") !== "true"
      this.setCinema(on)
      writeCinema(local(), on)
    }
    this.cinema?.addEventListener("click", this.onCinema)

    if (this.full) {
      if (typeof this.box?.requestFullscreen !== "function") {
        this.full.hidden = true
      } else {
        this.onFull = () => {
          if (document.fullscreenElement === this.box) document.exitFullscreen()
          else this.box.requestFullscreen()
        }
        this.onFullChange = () => this.setFull(document.fullscreenElement === this.box)
        this.full.addEventListener("click", this.onFull)
        document.addEventListener("fullscreenchange", this.onFullChange)
        this.setFull(document.fullscreenElement === this.box)
      }
    }

    const note = this.video && takeHandoff(session(), el.dataset.version)
    if (note) applyHandoff(this.video, note)
  },

  updated() {
    this.setCinema(this.cinema?.getAttribute("aria-pressed") === "true")
  },

  reconnected() {
    this.updated()
  },

  setCinema(on) {
    this.el.dataset.cinema = String(on)
    this.cinema?.setAttribute("aria-pressed", String(on))
  },

  setFull(on) {
    const button = this.full
    button.setAttribute("aria-pressed", String(on))
    button.setAttribute("title", on ? button.dataset.leaveTitle : button.dataset.title)
    const text = button.querySelector("[data-text]")
    if (text) text.textContent = on ? button.dataset.leaveLabel : button.dataset.label
    const icon = button.querySelector('[class^="hero-"]')
    icon?.classList.toggle(OUT, !on)
    icon?.classList.toggle(IN, on)
  },

  destroyed() {
    this.cinema?.removeEventListener("click", this.onCinema)
    this.full?.removeEventListener("click", this.onFull)
    if (this.onFullChange) document.removeEventListener("fullscreenchange", this.onFullChange)
  },
}
