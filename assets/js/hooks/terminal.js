// The terminal of a run (brief-runs rd14, rj4, rj9). The bytes of the log never cross the
// LiveView socket: this hook reads them from the run's log endpoint,
//
//   GET {data-src}?after=<sequence>&limit=<chunks>[&stream=stdout|stderr|terminal]
//
// which answers the raw bytes and names the last sequence it sent in x-qory-log-through.
// It reads until the answer is empty, and again whenever the LiveView says
// "log_advanced" (a number, nothing else). Bytes go to xterm.js as Uint8Arrays, never as
// strings, because a chunk may end inside a character; nothing here interprets them and
// nothing of them touches the DOM outside xterm.js.
//
// xterm.js is vendored (assets/vendor/xterm) and built as its own bundle; it is loaded
// on the first mount of this hook and by no other page.

const LIMIT = 2000
const SLICE = 256 * 1024
const UNWRAPPED_COLS = 200
const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches

// A hidden tab gets no animation frames; the log still loads there.
const nextFrame = run => (document.hidden ? setTimeout(run, 16) : requestAnimationFrame(run))

let library = null

const load = (script, stylesheet) => {
  if (window.QoryTerminal) return Promise.resolve(window.QoryTerminal)
  if (library) return library
  library = new Promise((resolve, reject) => {
    const link = document.createElement("link")
    link.rel = "stylesheet"
    link.href = stylesheet
    document.head.appendChild(link)
    const tag = document.createElement("script")
    tag.src = script
    tag.onload = () => (window.QoryTerminal ? resolve(window.QoryTerminal) : reject(new Error("terminal bundle")))
    tag.onerror = () => {
      library = null
      tag.remove()
      reject(new Error("terminal bundle"))
    }
    document.head.appendChild(tag)
  })
  return library
}

// Any CSS colour (the tokens are oklch) as [r, g, b], through a canvas.
const rgb = color => {
  const canvas = document.createElement("canvas")
  canvas.width = canvas.height = 1
  const ctx = canvas.getContext("2d", {willReadFrequently: true})
  ctx.fillStyle = color
  ctx.fillRect(0, 0, 1, 1)
  const [r, g, b] = ctx.getImageData(0, 0, 1, 1).data
  return [r, g, b]
}
const hex = ([r, g, b]) => "#" + [r, g, b].map(n => n.toString(16).padStart(2, "0")).join("")
const mix = (a, b, share) => a.map((n, i) => Math.round(n * share + b[i] * (1 - share)))

export const Terminal = {
  async mounted() {
    const q = selector => this.el.querySelector(selector)
    this.screen = q("[data-screen]")
    this.find = q("[data-find]")
    this.findCount = q("[data-find-count]")
    this.followButton = q("[data-follow]")
    this.followLabel = q("[data-follow-label]")
    this.wrapButton = q("[data-wrap]")
    this.pill = q("[data-pill]")
    this.pillText = q("[data-pill-text]")
    this.message = q("[data-message]")
    this.messageText = q("[data-message-text]")
    this.retry = q("[data-retry]")

    this.live = this.el.dataset.live === "true"
    this.following = this.live
    this.wrap = false
    this.stream = ""
    this.through = 0
    this.failures = 0
    this.generation = 0
    this.unseen = 0
    this.dead = false

    this.handleEvent("log_advanced", () => this.pull())
    this.retry.addEventListener("click", () => {
      this.failures = 0
      this.say(null)
      this.term ? this.pull() : this.boot()
    })
    await this.boot()
  },

  async boot() {
    let lib
    try {
      lib = await load(this.el.dataset.script, this.el.dataset.stylesheet)
    } catch (_err) {
      return this.fail(true)
    }
    if (this.dead) return

    const style = getComputedStyle(this.el)
    const token = name => rgb(style.getPropertyValue(name).trim() || "#000")
    const bg = token("--q-term-bg")
    const honey = token("--color-primary")
    this.decorations = {
      matchBackground: hex(mix(honey, bg, 0.35)),
      activeMatchBackground: hex(honey),
      activeMatchColorOverviewRuler: hex(honey),
      matchOverviewRuler: hex(mix(honey, bg, 0.35)),
    }

    // Pipes carry bare line feeds; a pseudo-terminal's output has its own carriage returns.
    const pipes = this.el.dataset.pty !== "true"

    this.term = new lib.Terminal({
      disableStdin: true,
      convertEol: pipes,
      scrollback: 100000,
      cursorBlink: this.live && !reducedMotion(),
      cursorInactiveStyle: this.live ? "outline" : "none",
      fontFamily: style.getPropertyValue("--font-mono").trim() || "ui-monospace, monospace",
      fontSize: 12.5,
      lineHeight: 1.52,
      allowProposedApi: true,
      screenReaderMode: !this.following,
      theme: {
        background: hex(bg),
        foreground: hex(token("--q-term-fg")),
        cursor: hex(token("--q-term-fg")),
        cursorAccent: hex(bg),
        selectionBackground: hex(mix(honey, bg, 0.4)),
        black: hex(token("--q-term-edge")),
        brightBlack: hex(token("--q-term-dim")),
        red: hex(token("--q-term-red")),
        brightRed: hex(token("--q-term-red")),
        green: hex(token("--q-term-green")),
        brightGreen: hex(token("--q-term-green")),
        yellow: hex(token("--q-term-yellow")),
        brightYellow: hex(token("--q-term-yellow")),
        blue: hex(token("--q-term-blue")),
        brightBlue: hex(token("--q-term-blue")),
        magenta: hex(token("--q-term-magenta")),
        brightMagenta: hex(token("--q-term-magenta")),
        cyan: hex(token("--q-term-cyan")),
        brightCyan: hex(token("--q-term-cyan")),
        white: hex(token("--q-term-fg")),
        brightWhite: "#ffffff",
      },
    })
    this.fitter = new lib.FitAddon()
    this.search = new lib.SearchAddon()
    this.term.loadAddon(this.fitter)
    this.term.loadAddon(this.search)
    this.term.open(this.screen)
    this.fit()

    this.resize = new ResizeObserver(() => this.fit())
    this.resize.observe(this.screen)

    this.search.onDidChangeResults(({resultIndex, resultCount}) => {
      this.findCount.textContent =
        !this.find.value ? "" : resultCount === 0 ? "0 of 0" : `${resultIndex + 1} of ${resultCount}`
    })
    // The reader scrolled away from the end: stop following, and let a screen reader in.
    this.term.onScroll(() => {
      const buffer = this.term.buffer.active
      if (this.following && buffer.viewportY < buffer.baseY) this.follow(false)
    })

    this.bind()
    this.showFollowing()
    this.pull()
  },

  updated() {
    this.live = this.el.dataset.live === "true"
    if (this.term && Number(this.el.dataset.through) > (this.asked || 0)) this.pull()
  },

  // Whatever was missed while the socket was away is behind the same question.
  reconnected() {
    this.pull()
  },

  destroyed() {
    this.dead = true
    clearTimeout(this.retryTimer)
    if (this.resize) this.resize.disconnect()
    if (this.term) this.term.dispose()
  },

  bind() {
    this.find.addEventListener("input", () => this.findNext(true))
    this.find.addEventListener("keydown", e => {
      if (e.key === "Enter") {
        e.preventDefault()
        e.shiftKey ? this.findPrevious() : this.findNext(false)
      } else if (e.key === "Escape") {
        e.preventDefault()
        this.clearFind()
        this.term.focus()
      }
    })
    // Keys, when the screen has focus. xterm.js sees them first; none of them is input.
    this.term.attachCustomKeyEventHandler(e => {
      if (e.type !== "keydown") return true
      const findKey = e.key === "/" || ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f")
      if (findKey) {
        e.preventDefault()
        this.find.focus()
        this.find.select()
        return false
      }
      if (e.key === "End") return this.follow(true), false
      if (e.key === "Home") return this.follow(false), this.term.scrollToTop(), false
      if (e.key === "Escape") return this.clearFind(), false
      if (e.key === "Enter" && this.find.value) return e.shiftKey ? this.findPrevious() : this.findNext(false), false
      return true
    })
    this.followButton.addEventListener("click", () => this.follow(!this.following))
    this.pill.addEventListener("click", () => this.follow(true))
    this.wrapButton.addEventListener("click", () => {
      this.wrap = !this.wrap
      this.wrapButton.setAttribute("aria-pressed", String(this.wrap))
      this.fit()
    })
    this.el.querySelectorAll("[data-stream]").forEach(button =>
      button.addEventListener("click", () => {
        this.el.querySelectorAll("[data-stream]").forEach(b => b.setAttribute("aria-pressed", String(b === button)))
        this.stream = button.dataset.stream
        this.restart()
      }),
    )
  },

  // Unwrapped, the screen is as wide as the output may be and scrolls sideways inside
  // the box; wrapped, it is as wide as the box.
  fit() {
    if (!this.term) return
    const size = this.fitter.proposeDimensions()
    if (!size || !size.cols || !size.rows) return
    const cols = this.wrap ? size.cols : Math.max(size.cols, UNWRAPPED_COLS)
    if (cols !== this.term.cols || size.rows !== this.term.rows) this.term.resize(cols, size.rows)
  },

  restart() {
    this.generation += 1
    this.through = 0
    this.unseen = 0
    this.pulling = false
    this.term.reset()
    this.clearFind()
    this.pull()
  },

  async pull() {
    if (!this.term || this.pulling || this.dead) return
    this.pulling = true
    const generation = this.generation
    const first = this.through === 0
    // How far the page said the log had come when this read began: a later word asks again.
    this.asked = Number(this.el.dataset.through) || 0
    this.initial = first

    try {
      for (;;) {
        const url = new URL(this.el.dataset.src, window.location.href)
        url.searchParams.set("after", String(this.through))
        url.searchParams.set("limit", String(LIMIT))
        if (this.stream) url.searchParams.set("stream", this.stream)

        const response = await fetch(url, {credentials: "same-origin", headers: {accept: "application/octet-stream"}})
        if (!response.ok) throw new Error(`log ${response.status}`)
        const through = Number(response.headers.get("x-qory-log-through"))
        const bytes = new Uint8Array(await response.arrayBuffer())
        if (generation !== this.generation || this.dead) return

        await this.write(bytes)
        const advanced = Number.isFinite(through) && through > this.through
        if (advanced) this.through = through
        if (!advanced || bytes.length === 0) break
      }
      this.failures = 0
      this.say(null)
      // An ended run is read from its start; a live one is followed.
      if (first && !this.following) this.toTop()
    } catch (_err) {
      if (generation === this.generation) this.fail(false)
    } finally {
      if (generation === this.generation) {
        this.pulling = false
        this.initial = false
      }
    }

    // The log may have advanced while this was reading.
    if (!this.dead && generation === this.generation && Number(this.el.dataset.through) > this.asked && this.failures === 0) {
      this.pull()
    }
  },

  // At most 256 KB per animation frame, so a long log does not freeze the tab.
  write(bytes) {
    return new Promise(resolve => {
      let offset = 0
      const before = this.term.buffer.active.length
      const step = () => {
        if (this.dead) return resolve()
        if (offset >= bytes.length) return resolve(this.wrote(before))
        const slice = bytes.subarray(offset, offset + SLICE)
        offset += slice.length
        this.term.write(slice, () => nextFrame(step))
      }
      step()
    })
  },

  wrote(before) {
    const lines = this.term.buffer.active.length
    const label = this.screen
    label.setAttribute("aria-label", `Log, ${lines.toLocaleString("en-GB")} lines`)
    if (this.following) {
      this.term.scrollToBottom()
    } else if (!this.initial && lines > before) {
      this.unseen += lines - before
      this.showPill()
    }
  },

  // After xterm.js has laid the new lines out, or its viewport puts the end back.
  toTop() {
    nextFrame(() => setTimeout(() => !this.dead && !this.following && this.term.scrollToTop(), 30))
  },

  follow(on) {
    this.following = on
    if (on) {
      this.unseen = 0
      this.term.scrollToBottom()
    }
    // xterm's screen reader mode announces every line: on only when not following.
    this.term.options.screenReaderMode = !on
    this.showFollowing()
    this.showPill()
  },

  showFollowing() {
    this.followButton.setAttribute("aria-pressed", String(this.following))
    this.followLabel.textContent = this.following ? "Following" : "Jump to end"
  },

  showPill() {
    const show = !this.following && this.unseen > 0
    this.pill.classList.toggle("q-newpill-show", show)
    this.pill.setAttribute("aria-hidden", String(!show))
    this.pill.tabIndex = show ? 0 : -1
    this.pillText.textContent = `${this.unseen.toLocaleString("en-GB")} new ${this.unseen === 1 ? "line" : "lines"}`
  },

  findNext(incremental) {
    if (!this.find.value) return this.clearFind()
    this.search.findNext(this.find.value, {incremental, decorations: this.decorations})
  },

  findPrevious() {
    if (this.find.value) this.search.findPrevious(this.find.value, {decorations: this.decorations})
  },

  clearFind() {
    this.find.value = ""
    this.findCount.textContent = ""
    if (this.search) this.search.clearDecorations()
  },

  // "The log stream dropped. Reconnecting.", then on the third failure the button.
  fail(final) {
    this.failures += 1
    if (final || this.failures >= 3) {
      this.say("The log could not be loaded.", true)
    } else {
      this.say("The log stream dropped. Reconnecting.", false)
      clearTimeout(this.retryTimer)
      this.retryTimer = setTimeout(() => this.pull(), 1000 * 2 ** (this.failures - 1))
    }
  },

  say(text, retry = false) {
    this.message.hidden = !text
    this.messageText.textContent = text || ""
    this.retry.hidden = !retry
  },
}
