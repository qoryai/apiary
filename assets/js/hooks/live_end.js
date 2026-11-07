// The live end of a timeline (docs/ui.md). Tells the LiveView whether the reader is
// within 240 px of the end of the page, so that it inserts new items only there and
// counts them elsewhere; and takes the reader to the end when the pill is pressed,
// opening the closed row the timeline is inside, if any.
//
// The page scrolls, not an element: the measure is the document's. The hook is on
// `#live-end`, outside the timeline's stream: LiveView locks a hook's element until the
// acknowledgement of its event arrives, and a stream patched inside a locked element
// appends new rows at the end. A patch of the timeline runs no `updated` here, so a
// change of the page's height measures again.
import {openAround} from "./timeline_keys.js"

const NEAR = 240
const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches

export const LiveEnd = {
  mounted() {
    this.atEnd = null
    this.measure = () => {
      this.frame = null
      const doc = document.documentElement
      const atEnd = window.innerHeight + window.scrollY >= doc.scrollHeight - NEAR
      if (atEnd !== this.atEnd) {
        this.atEnd = atEnd
        this.pushEvent("live_end", {at_end: atEnd})
      }
    }
    this.schedule = () => {
      if (!this.frame) this.frame = requestAnimationFrame(this.measure)
    }
    window.addEventListener("scroll", this.schedule, {passive: true})
    window.addEventListener("resize", this.schedule, {passive: true})
    this.observer = new ResizeObserver(this.schedule)
    this.observer.observe(document.body)
    this.handleEvent("timeline:end", ({focus}) => this.toEnd(focus))
    this.schedule()
  },

  // A new socket has forgotten where the reader is.
  reconnected() {
    this.atEnd = null
    this.schedule()
  },

  updated() {
    this.schedule()
  },

  destroyed() {
    window.removeEventListener("scroll", this.schedule)
    window.removeEventListener("resize", this.schedule)
    this.observer.disconnect()
    if (this.frame) cancelAnimationFrame(this.frame)
  },

  toEnd(focus) {
    openAround((focus && document.getElementById(focus)) || document.querySelector("ol.q-tl"))
    requestAnimationFrame(() => {
      window.scrollTo({
        top: document.documentElement.scrollHeight,
        behavior: reducedMotion() ? "auto" : "smooth",
      })
      const first = focus && document.getElementById(focus)
      if (first) first.focus({preventScroll: true})
    })
  },
}
