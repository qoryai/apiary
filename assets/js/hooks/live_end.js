// The live end of a timeline (docs/design/brief-runs.md). Tells the LiveView whether the
// reader is within 240 px of the end of the page, so that it inserts new items only there
// and counts them elsewhere; and takes the reader to the end when the pill is pressed.
//
// The page scrolls, not an element: the measure is the document's.

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
    if (this.frame) cancelAnimationFrame(this.frame)
  },

  toEnd(focus) {
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
