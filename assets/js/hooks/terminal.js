// The terminal of a run (docs/ui.md). It has two views. Transcript is the session drawn
// by the LiveView from the run's runtime events, as HTML inside this box; this hook only
// keeps it scrolled, takes it to its end, wraps its tool lines or cuts them at the box's
// edge, sizes its text and follows its links to Raw. Raw is the log's bytes
// in xterm.js. The bytes never cross the LiveView socket: this hook reads them from the
// run's log endpoint,
//
//   GET {data-src}?after=<sequence>&limit=<chunks>[&stream=stdout|stderr|terminal]
//
// which answers the raw bytes and names the sequence it reached in x-qory-log-through.
// It reads until the answer reaches nothing further, and again whenever the LiveView says
// "log_advanced" (a number, nothing else). The bytes go to xterm.js as Uint8Arrays, never
// as strings, because a chunk may end inside a character; nothing of them touches the DOM
// outside xterm.js. xterm.js starts the first time Raw shows.
//
// The view is on the root as data-view, which the LiveView sets once and leaves to this
// hook. A run on pipes with a Transcript keeps the reader's choice in localStorage; a run
// on a pseudo-terminal, or with no Transcript, opens in Raw. Search reads Raw's screen, so
// typing in it shows Raw.
//
// A line of the Transcript read from the session's output has a link to that line in Raw
// (data-raw-line, data-session). The `raw_line` event returns where the line starts in the
// bytes Raw reads, and Raw is read again from the start with a marker at that byte.
//
// A run whose record says the pseudo-terminal's size (data-cols, data-rows) is replayed
// at it: every answer of the endpoint names in x-qory-log-size the size its bytes were
// written to and stops short of the next resize, so the screen is set to that size before
// the bytes are written and xterm.js reflows as a terminal does. The columns and rows are
// the record's, never the box's: the screen is drawn at them inside the box's dark ground,
// which fills the page's width, and scrolls inside it when it is larger. A run without a
// size, on pipes or recorded before Forager reported one, is fitted to the box, with the
// wrap toggle.
//
// The text size is the reader's (A−, A+, 11 to 18 px, or Fit, the largest at which a
// recorded screen's columns fit the box), a reading preference kept in localStorage, for
// both views. Focus (the f key, or its button) puts a class on the root that folds the
// shell away and gives the window to the box, and Escape gives it back; Full screen is the
// browser's, on the box.
//
// xterm.js is vendored (assets/vendor/xterm) and built as its own bundle; it is loaded
// on the first Raw view of this hook and by no other page.
import {singleKeys} from "./shortcuts.js"

const LIMIT = 2000
const SLICE = 256 * 1024
const UNWRAPPED_COLS = 200
const FONT_SIZE = 13
const MIN_FONT_SIZE = 7
// The sizes a reader chooses between, and where the choice is kept.
const SMALLEST = 11
const LARGEST = 18
const SIZE_KEY = "qory:terminal-size"
const VIEW_KEY = "qory:terminal-view"
const SCROLLBACK = 100000
const FOCUS_CLASS = "q-term-focus"
// What the box keeps beside a recorded screen's columns: the screen's padding, xterm's
// scrollbar and a little air.
const SIDE_ROOM = 48
// The full reset of a terminal (ESC c).
const RESET = "\x1bc"
// How far the Transcript may be from its end and still follow it, in pixels.
const NEAR_END = 24
// The largest count xterm.js is left to carry out for a sequence that scrolls, inserts or
// deletes lines (CSI S, T, L, M) or repeats a character (CSI b). A larger one is dropped:
// `CSI 10000000 S` (16 bytes) held the page for 7.2 s. No program draws more lines than
// its screen has, and these counts are far above any screen.
export const MOST_LINES_MOVED = 10000
export const MOST_REPEATS = 65536
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
    tag.onload = () =>
      window.QoryTerminal ? resolve(window.QoryTerminal) : reject(new Error("terminal bundle"))
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

// "120x40" as [120, 40], or null: a size is two integers a terminal can be.
export const size = text => {
  const match = /^(\d{1,5})x(\d{1,5})$/.exec(text || "")
  if (!match) return null
  const [cols, rows] = [Number(match[1]), Number(match[2])]
  return cols >= 1 && cols <= 65535 && rows >= 1 && rows <= 65535 ? [cols, rows] : null
}

// Whether a CSI sequence's count is over `most`, so that it is dropped. xterm.js gives the
// parameters as numbers, or arrays of numbers for sub-parameters; a missing count is 0.
export const overCount = (params, most) => {
  const first = Array.isArray(params[0]) ? params[0][0] : params[0]
  return typeof first === "number" && first > most
}

// Where a write of `length` bytes, starting at byte `at` of the log, stops: at its end,
// or before byte `mark` when the mark falls inside it, so the marker goes on that byte.
export const stopAt = (at, length, mark) =>
  mark != null && mark > at && mark < at + length ? mark - at : length

// The view a box opens in. A link to a line of the Transcript (`targeted`, the Transcript
// box's data-target) opens the Transcript, whatever the reader chose, and the choice stays.
// Otherwise: Raw without a Transcript or on a pseudo-terminal, else the reader's choice.
// The Collapsed view kept as a choice before it was removed is Transcript.
// Whether the Transcript's end button reads "Following": a live run, read at its end.
export const transcriptFollowing = (live, atEnd) => live && atEnd

// The buttons that open or close subagents' lines in the Transcript: a head's caret, its
// Show or Hide, and Expand all and Collapse all in the bar.
export const SUBAGENT_BUTTONS = "[phx-click=subagent_toggle], [phx-click=subagents_all]"

export const openingView = (initial, stored, choice, targeted = false) => {
  if (targeted) return "transcript"
  if (!choice || initial === "raw") return initial
  if (stored === "raw") return "raw"
  return "transcript"
}

// The words are the server's, in the domain's language (`RunPageComponents.terminal_words/0`,
// on the box as `data-words`); this script has none. A count's words are [one, other].
export const fill = (template, bindings) =>
  template.replace(/%\{(\w+)\}/g, (all, key) => (key in bindings ? String(bindings[key]) : all))

// The width of one cell per pixel of font size: xterm.js measures its cell on "W" too.
const cellRatio = family => {
  const ctx = document.createElement("canvas").getContext("2d")
  ctx.font = `100px ${family}`
  return ctx.measureText("W").width / 100
}

// The reader's size: a number of pixels, "fit", or null for the page's choice.
const storedSize = () => {
  try {
    const value = localStorage.getItem(SIZE_KEY)
    if (value === "fit") return "fit"
    const n = Number(value)
    return value && n >= SMALLEST && n <= LARGEST ? n : null
  } catch (_err) {
    return null
  }
}
const storeSize = value => {
  try {
    localStorage.setItem(SIZE_KEY, String(value))
  } catch (_err) {}
}
const storedView = () => {
  try {
    return localStorage.getItem(VIEW_KEY)
  } catch (_err) {
    return null
  }
}
const storeView = value => {
  try {
    localStorage.setItem(VIEW_KEY, value)
  } catch (_err) {}
}
// A key that is typed into a field, not a shortcut.
const typing = el =>
  !!el && (el.isContentEditable || /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName))

// A number is grouped as the server groups it, in the reader's locale
// (`ApiaryWeb.Format`, on the body as `data-locale`).
const grouped = n => n.toLocaleString(document.body.dataset.locale || "en-GB")
const counted = ([one, other], n) => fill(n === 1 ? one : other, {number: grouped(n)})

export const Terminal = {
  mounted() {
    const q = selector => this.el.querySelector(selector)
    this.words = JSON.parse(this.el.dataset.words)
    this.screen = q("[data-screen]")
    this.find = q("[data-find]")
    this.findCount = q("[data-find-count]")
    this.followButton = q("[data-follow]")
    this.followLabel = q("[data-follow-label]")
    this.wrapButton = q("[data-wrap]")
    this.trEndButton = q("[data-tr-end]")
    this.trEndLabel = q("[data-tr-end-label]")
    this.trWrapButton = q("[data-tr-wrap]")
    this.pill = q("[data-pill]")
    this.pillText = q("[data-pill-text]")
    this.message = q("[data-message]")
    this.messageText = q("[data-message-text]")
    this.retry = q("[data-retry]")
    this.polite = q("[data-announce]")
    this.sizeLabel = q("[data-size-label]")
    this.fitButton = q("[data-size-fit]")
    this.focusButton = q("[data-focus]")
    this.fullButton = q("[data-fullscreen]")
    this.transcript = q("[data-transcript-scroll]")
    this.preference = storedSize()
    this.viewButtons = [...this.el.querySelectorAll("[data-view-button]")]
    this.hasRaw = this.el.dataset.raw !== "false"
    const box = this.transcript && this.transcript.querySelector("[data-transcript]")
    this.view = openingView(
      this.el.dataset.view || "raw",
      storedView(),
      this.viewButtons.length > 0 && this.hasRaw,
      !!(box && box.dataset.target),
    )

    this.live = this.el.dataset.live === "true"
    this.following = this.live
    this.wrap = false
    this.sized = false
    this.stream = ""
    this.through = 0
    this.at = 0
    this.mark = null
    this.failures = 0
    this.generation = 0
    this.unseen = 0
    this.dead = false

    this.handleEvent("log_advanced", () => this.term && this.pull())
    if (this.retry) {
      this.retry.addEventListener("click", () => {
        this.failures = 0
        this.say(null)
        this.term ? this.pull() : this.boot()
      })
    }
    this.bind()
    // The view shows before the Transcript scrolls to its target.
    this.showView()
    this.bindTranscript()
    if (this.view === "raw" && this.hasRaw) this.boot()
  },

  async boot() {
    if (this.booting || this.term) return
    this.booting = true
    let lib
    try {
      lib = await load(this.el.dataset.script, this.el.dataset.stylesheet)
    } catch (err) {
      console.error("terminal: the bundle did not load", err)
      this.booting = false
      return this.fail(true)
    }
    this.booting = false
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
    this.markColor = hex(mix(honey, bg, 0.3))

    // Pipes carry bare line feeds; a pseudo-terminal's output has its carriage returns.
    const pipes = this.el.dataset.pty !== "true"

    this.term = new lib.Terminal({
      disableStdin: true,
      convertEol: pipes,
      scrollback: SCROLLBACK,
      cursorBlink: this.live && !reducedMotion(),
      cursorInactiveStyle: this.live ? "outline" : "none",
      fontFamily: style.getPropertyValue("--font-mono").trim() || "ui-monospace, monospace",
      fontSize: typeof this.preference === "number" ? this.preference : FONT_SIZE,
      lineHeight: 1.52,
      // The search add-on marks its matches with decorations, and the line a Transcript link
      // opens is marked with one: xterm.js keeps them behind this flag (registerDecoration).
      allowProposedApi: true,
      // Off, always: xterm's screen reader mode reads every line aloud as it lands. The log
      // is offered as text beside the box, and a summary is announced at most every 10 s.
      screenReaderMode: false,
      // The log is not a place for links: an OSC 8 hyperlink in the bytes does nothing.
      linkHandler: {activate() {}, hover() {}, leave() {}, allowNonHttpProtocols: false},
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
    // A count too large to carry out is dropped, before xterm.js loops over it.
    for (const final of ["S", "T", "L", "M"]) {
      this.term.parser.registerCsiHandler({final}, params => overCount(params, MOST_LINES_MOVED))
    }
    this.term.parser.registerCsiHandler({final: "b"}, params => overCount(params, MOST_REPEATS))
    this.fitter = new lib.FitAddon()
    this.search = new lib.SearchAddon()
    this.term.loadAddon(this.fitter)
    this.term.loadAddon(this.search)
    this.term.open(this.screen)
    // How wide a cell is per pixel of font size, for the font xterm.js draws with.
    this.cellRatio = cellRatio(this.term.options.fontFamily)
    const recorded = size(`${this.el.dataset.cols}x${this.el.dataset.rows}`)
    if (recorded) this.size(...recorded)
    else this.fit()
    this.labelInput(0)

    this.resize = new ResizeObserver(() => this.fit())
    this.resize.observe(this.screen)

    this.search.onDidChangeResults(({resultIndex, resultCount}) => {
      this.findCount.textContent =
        !this.find.value ? ""
        : fill(this.words.found, {
            index: grouped(resultCount === 0 ? 0 : resultIndex + 1),
            total: grouped(resultCount),
          })
    })
    // The reader scrolled away from the end: stop following, and let a screen reader in.
    this.term.onScroll(() => {
      const buffer = this.term.buffer.active
      if (this.following && buffer.viewportY < buffer.baseY) this.follow(false)
    })

    this.bindTerm()
    this.showFollowing()
    this.showSize()
    this.pull()
  },

  updated() {
    this.live = this.el.dataset.live === "true"
    if (this.term && Number(this.el.dataset.through) > (this.asked || 0)) this.pull()
  },

  // Whatever was missed while the socket was away is behind the same question.
  reconnected() {
    if (this.term) this.pull()
  },

  destroyed() {
    this.dead = true
    this.focus(false)
    if (this.onKey) document.removeEventListener("keydown", this.onKey)
    if (this.onFullscreen) document.removeEventListener("fullscreenchange", this.onFullscreen)
    if (document.fullscreenElement === this.el) document.exitFullscreen?.()
    clearTimeout(this.retryTimer)
    clearTimeout(this.saying)
    if (this.watch) this.watch.disconnect()
    if (this.resize) this.resize.disconnect()
    if (this.term) this.term.dispose()
  },

  // The bar's controls that do not need xterm.js.
  bind() {
    if (this.find) {
      this.find.addEventListener("input", () => {
        if (!this.find.value) return this.clearFind()
        if (this.view === "raw" && this.term && !this.pulling) return this.findNext(true)
        // Search reads Raw's screen: the match is looked for once the log is read.
        this.searching = true
        this.pickView("raw")
      })
      this.find.addEventListener("keydown", e => {
        if (e.key === "Enter") {
          e.preventDefault()
          e.shiftKey ? this.findPrevious() : this.findNext(false)
        } else if (e.key === "Escape") {
          e.preventDefault()
          this.clearFind()
          if (this.term) this.term.focus()
        }
      })
    }
    if (this.followButton) {
      this.followButton.addEventListener("click", () => this.follow(!this.following))
    }
    if (this.pill) this.pill.addEventListener("click", () => this.follow(true))
    // A sized run has no wrap: its columns are the record's.
    if (this.wrapButton) {
      this.wrapButton.addEventListener("click", () => {
        this.wrap = !this.wrap
        this.wrapButton.setAttribute("aria-pressed", String(this.wrap))
        this.fit()
      })
    }
    this.el.querySelectorAll("[data-size-step]").forEach(button =>
      button.addEventListener("click", () => this.step(Number(button.dataset.sizeStep))),
    )
    if (this.fitButton) this.fitButton.addEventListener("click", () => this.choose("fit"))
    this.el.querySelectorAll("[data-stream]").forEach(button =>
      button.addEventListener("click", () => this.pickStream(button.dataset.stream)),
    )
    this.viewButtons.forEach(button =>
      button.addEventListener("click", () => {
        storeView(button.dataset.viewButton)
        this.pickView(button.dataset.viewButton)
      }),
    )
    this.bindWindow()
  },

  // Keys, when Raw's screen has focus. xterm.js sees them first; none of them is input.
  bindTerm() {
    this.term.attachCustomKeyEventHandler(e => {
      if (e.type !== "keydown") return true
      const findKey =
        (e.key === "/" && singleKeys()) ||
        ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "f")
      if (findKey && this.find) {
        e.preventDefault()
        this.find.focus()
        this.find.select()
        return false
      }
      if (e.key === "End") return this.follow(true), false
      if (e.key === "Home") return this.follow(false), this.term.scrollToTop(), false
      if (e.key === "Escape") return this.clearFind(), false
      if (e.key === "Enter" && this.find && this.find.value) {
        e.shiftKey ? this.findPrevious() : this.findNext(false)
        return false
      }
      return true
    })
  },

  // Focus and Full screen: the box and the window, whether or not there is a log.
  bindWindow() {
    this.focusButton.addEventListener("click", () => this.focus(!this.focused))
    // f anywhere on the page but in a field, Raw's input included; Escape leaves.
    this.onKey = e => {
      if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return
      if (e.key === "Escape" && this.focused) {
        if (document.querySelector("dialog[open]")) return
        this.focus(false)
      } else if (e.key === "f" && singleKeys() && !document.querySelector("dialog[open]")) {
        const target = e.target
        const screen = this.term && target === this.term.textarea
        if (typing(target) && !screen) return
        e.preventDefault()
        this.focus(!this.focused)
      }
    }
    document.addEventListener("keydown", this.onKey)
    if (document.fullscreenEnabled && this.el.requestFullscreen) {
      this.fullButton.hidden = false
      this.fullButton.addEventListener("click", () =>
        document.fullscreenElement === this.el ?
          document.exitFullscreen()
        : this.el.requestFullscreen(),
      )
      this.onFullscreen = () => {
        const on = document.fullscreenElement === this.el
        this.fullButton.setAttribute("aria-pressed", String(on))
        const words = on ? this.words.leaveFullScreen : this.words.fullScreen
        this.fullButton.setAttribute("aria-label", words)
        this.fullButton.title = words
      }
      document.addEventListener("fullscreenchange", this.onFullscreen)
    }
  },

  // The Transcript: its links to Raw, its end followed while the reader is there, and the
  // line `?seq=` points at brought into view. The LiveView patches the list; a mutation
  // observer sees each patch, as the hook's `updated` is not called for its children.
  bindTranscript() {
    if (!this.transcript) return
    this.transcript.addEventListener("click", e => {
      const link = e.target.closest("[data-raw-line]")
      if (!link) return
      e.preventDefault()
      this.toLine(Number(link.dataset.session), Number(link.dataset.rawLine))
    })
    this.transcriptAtEnd = this.live
    // A click that opens or closes subagents' lines keeps a line where it is on screen
    // (`holdLine`), until the reader scrolls, presses a key or clicks again.
    this.held = null
    this.el.addEventListener("click", e => this.holdLine(e))
    for (const type of ["pointerdown", "wheel", "touchstart", "keydown"])
      this.transcript.addEventListener(type, () => (this.held = null), {passive: true})
    this.transcript.addEventListener("scroll", () => {
      const {scrollTop, scrollHeight, clientHeight} = this.transcript
      this.transcriptAtEnd = scrollHeight - scrollTop - clientHeight <= NEAR_END
      this.showTranscriptEnd()
    })
    this.transcript.addEventListener("keydown", e => {
      if (e.key === "End" && !e.metaKey && !e.ctrlKey && !e.altKey) {
        e.preventDefault()
        this.transcriptToEnd()
      }
    })
    if (this.trEndButton) this.trEndButton.addEventListener("click", () => this.transcriptToEnd())
    // Wrap is on the root, which the LiveView leaves to this hook (data-tr-wrap).
    if (this.trWrapButton) {
      this.trWrapButton.addEventListener("click", () => {
        const on = this.el.dataset.trWrap !== "true"
        this.el.dataset.trWrap = String(on)
        this.trWrapButton.setAttribute("aria-pressed", String(on))
      })
    }
    this.watch = new MutationObserver(() => this.placeTranscript())
    this.watch.observe(this.transcript, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ["data-target"],
    })
    this.placeTranscript()
  },

  placeTranscript() {
    const box = this.transcript.querySelector("[data-transcript]")
    const target = box && box.dataset.target
    if (target && target !== this.shownTarget) {
      const line = document.getElementById(target)
      if (line) {
        this.shownTarget = target
        // The line is in the Transcript: it shows, and the reader's choice stays as it was.
        if (this.view !== "transcript") this.pickView("transcript")
        this.transcript
          .querySelectorAll(".q-tr-target")
          .forEach(el => el.classList.remove("q-tr-target"))
        line.classList.add("q-tr-target")
        line.scrollIntoView({block: "center"})
        this.transcriptAtEnd = false
        return
      }
    }
    if (this.held && !this.transcriptAtEnd) {
      const line = this.transcript.querySelector(`[id="${this.held.id}"]`)
      if (!line) return
      const top = line.getBoundingClientRect().top - this.transcript.getBoundingClientRect().top
      if (top !== this.held.top) this.transcript.scrollTop += top - this.held.top
      return
    }
    if (this.transcriptAtEnd) this.transcript.scrollTop = this.transcript.scrollHeight
  },

  // A click on a subagent's caret, Show or Hide, or on Expand all or Collapse all: the end
  // is no longer followed, and the line clicked in, or the first line on screen for the
  // bar's buttons, stays at its offset in the box while the lines open or close.
  holdLine(e) {
    const button = e.target && e.target.closest && e.target.closest(SUBAGENT_BUTTONS)
    if (!button || this.view !== "transcript") return
    const boxTop = this.transcript.getBoundingClientRect().top
    const line =
      button.closest("li") ||
      [...this.transcript.querySelectorAll("ol > li")].find(
        li => li.getBoundingClientRect().bottom > boxTop,
      )
    if (!line) return
    this.held = {id: line.id, top: line.getBoundingClientRect().top - boxTop}
    this.transcriptAtEnd = false
    this.showTranscriptEnd()
  },

  // The Transcript's end: the lines after the window are loaded first, and the end is
  // followed from then on, until the reader scrolls away from it.
  transcriptToEnd() {
    this.held = null
    if (this.transcript.querySelector("[data-later]")) this.pushEvent("show_new", {})
    this.transcriptAtEnd = true
    this.transcript.scrollTop = this.transcript.scrollHeight
    this.showTranscriptEnd()
  },

  showTranscriptEnd() {
    if (!this.trEndButton) return
    const on = transcriptFollowing(this.live, this.transcriptAtEnd)
    this.trEndButton.setAttribute("aria-pressed", String(on))
    this.trEndLabel.textContent = on ? this.words.following : this.words.jumpToEnd
  },

  // A link of the Transcript: Raw from its start, both streams when it showed stderr only,
  // with the session's output line `line` marked and scrolled to the top.
  toLine(session, line) {
    if (!this.hasRaw || !Number.isInteger(session) || !Number.isInteger(line)) return
    if (this.stream === "stderr") this.showStream("")
    this.pushEvent("raw_line", {session, line, stream: this.stream || null}, reply => {
      if (this.dead) return
      this.mark = reply && Number.isInteger(reply.offset) ? reply.offset : null
      this.goto = this.mark != null
      if (this.goto && this.following) this.follow(false)
      this.searching = false
      this.pickView("raw", true)
    })
  },

  // Unsized: the box decides. Unwrapped, the screen is as wide as the output may be and
  // scrolls sideways inside the box; wrapped, it is as wide as the box. Sized: the
  // record decides the columns and rows, and only the font follows the box.
  fit() {
    if (!this.term || this.view !== "raw") return
    if (this.sized) return this.scale()
    this.showSize()
    const proposed = this.fitter.proposeDimensions()
    if (!proposed || !proposed.cols || !proposed.rows) return
    const cols = this.wrap ? proposed.cols : Math.max(proposed.cols, UNWRAPPED_COLS)
    if (cols !== this.term.cols || proposed.rows !== this.term.rows) {
      this.term.resize(cols, proposed.rows)
    }
  },

  // The screen at the recorded size: what the runtime drew to, as the endpoint said it.
  size(cols, rows) {
    if (!this.term) return
    if (!this.sized) {
      this.sized = true
      this.el.dataset.sized = "true"
      if (this.wrapButton) this.wrapButton.hidden = true
    }
    if (cols !== this.term.cols || rows !== this.term.rows) this.term.resize(cols, rows)
    this.scale()
  },

  // A recorded screen at the reader's size, the usual one until they choose, scrolling
  // sideways inside the box when it is wider; Fit takes the largest size, up to the
  // largest, at which its columns fit the box, and never one below the floor.
  scale() {
    if (this.preference !== "fit") return this.apply(this.preference || FONT_SIZE)
    const room = this.screen.clientWidth - SIDE_ROOM
    if (room <= 0 || !this.cellRatio) return
    const fits = Math.floor((10 * room) / (this.term.cols * this.cellRatio)) / 10
    this.apply(Math.max(MIN_FONT_SIZE, Math.min(LARGEST, fits)))
  },

  apply(fontSize) {
    if (fontSize !== this.term.options.fontSize) this.term.options.fontSize = fontSize
    this.showSize()
  },

  // The size on screen: Raw's, else the reader's for the Transcript, which has no Fit.
  fontSize() {
    if (this.term && this.view === "raw") return this.term.options.fontSize
    return typeof this.preference === "number" ? this.preference : FONT_SIZE
  },

  // A− and A+: a whole size smaller or larger than the one on screen, within the range.
  step(by) {
    const now = this.fontSize()
    const next = by < 0 ? Math.ceil(now) - 1 : Math.floor(now) + 1
    this.choose(Math.max(SMALLEST, Math.min(LARGEST, next)))
  },

  choose(value) {
    this.preference = value
    storeSize(value)
    if (this.term) {
      if (typeof value === "number") this.term.options.fontSize = value
      this.sized ? this.scale() : this.fit()
    }
    this.showSize()
  },

  showSize() {
    const px = this.fontSize()
    const transcriptPx = typeof this.preference === "number" ? this.preference : FONT_SIZE
    this.el.style.setProperty("--q-tr-size", `${transcriptPx}px`)
    if (!this.sizeLabel) return
    this.sizeLabel.textContent = fill(this.words.size, {size: grouped(Math.round(px * 10) / 10)})
    this.el.querySelector('[data-size-step="-1"]').disabled = px <= SMALLEST
    this.el.querySelector('[data-size-step="1"]').disabled = px >= LARGEST
    if (this.fitButton) {
      this.fitButton.setAttribute("aria-pressed", String(this.preference === "fit"))
    }
  },

  // The terminal takes the window: the root's class folds the shell, the header, the tabs
  // and the rail away (app.css), and gives them back.
  focus(on) {
    this.focused = on
    document.documentElement.classList.toggle(FOCUS_CLASS, on)
    if (this.focusButton) this.focusButton.setAttribute("aria-pressed", String(on))
    if (on && this.term && this.view === "raw") this.term.focus()
  },

  pickStream(stream) {
    this.showStream(stream)
    if (this.term) this.restart()
  },

  showStream(stream) {
    this.stream = stream
    this.el.querySelectorAll("[data-stream]").forEach(button =>
      button.setAttribute("aria-pressed", String(button.dataset.stream === stream)),
    )
  },

  restart() {
    this.generation += 1
    this.through = 0
    this.at = 0
    this.unseen = 0
    this.pulling = false
    this.clearMarker()
    // Through the write queue, so what is in it lands before the reset and not on top of it.
    this.term.write(RESET)
    if (!this.searching) this.clearFind()
    this.pull()
  },

  // The view. Raw is read from the start when it shows for the first time, and when a
  // Transcript link marks a line in it (`again`).
  pickView(view, again = false) {
    if (view === "raw" && !this.hasRaw) return
    const changed = view !== this.view
    this.view = view
    this.showView()
    if (view !== "raw") return
    if (!this.term) return this.boot()
    if (changed) this.fit()
    if (again) this.restart()
    else if (this.searching && !this.pulling) {
      this.searching = false
      this.findAfterRead()
    }
  },

  showView() {
    this.el.dataset.view = this.view
    this.viewButtons.forEach(button =>
      button.setAttribute("aria-pressed", String(button.dataset.viewButton === this.view)),
    )
    this.showSize()
  },

  clearMarker() {
    if (this.marked) this.marked.dispose()
    if (this.marker) this.marker.dispose()
    this.marked = null
    this.marker = null
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

        // No Accept header is set: the route sits behind the browser pipeline, which
        // answers 406 to anything that does not take html, and a fetch's default */* does.
        const response = await fetch(url, {credentials: "same-origin"})
        if (!response.ok) throw new Error(`log ${response.status}`)
        const through = Number(response.headers.get("x-qory-log-through"))
        const recorded = size(response.headers.get("x-qory-log-size"))
        const bytes = new Uint8Array(await response.arrayBuffer())
        if (generation !== this.generation || this.dead) return

        // The bytes of one answer were all written to a terminal of this size.
        if (recorded) this.size(...recorded)
        await this.write(bytes, generation)
        if (generation !== this.generation || this.dead) return
        const advanced = Number.isFinite(through) && through > this.through
        if (advanced) this.through = through
        // An empty answer that still advanced is a resize with nothing drawn before it.
        if (!advanced) break
      }
      this.failures = 0
      this.say(null)
      // A marked line goes to the top of the screen. An ended run is read from its start,
      // or, sized, from its last screen: the screen is what a full-screen program left,
      // and its scrollback is the reflowed rest. A live one is followed. The search that
      // showed Raw goes where its match is.
      if (this.goto) {
        this.goto = false
        this.showMarker()
      } else if (this.searching) {
        this.searching = false
        this.findAfterRead()
      } else if (first && !this.following) {
        this.sized ? this.term.scrollToBottom() : this.toTop()
      }
    } catch (err) {
      console.error("terminal: the log was not read", err)
      if (generation === this.generation) this.fail(false)
    } finally {
      if (generation === this.generation) {
        this.pulling = false
        this.initial = false
      }
    }

    // The log may have advanced while this was reading.
    const behind = Number(this.el.dataset.through) > this.asked
    if (!this.dead && generation === this.generation && behind && this.failures === 0) {
      this.pull()
    }
  },

  // At most 256 KB per animation frame, so a long log does not freeze the tab. A write
  // stops at the marked byte, and the marker goes on the line the cursor is then on.
  write(bytes, generation) {
    return new Promise(resolve => {
      let offset = 0
      const before = this.term.buffer.active.length
      const step = () => {
        if (this.dead || generation !== this.generation) return resolve()
        if (this.mark != null && this.mark === this.at + offset) this.placeMarker()
        if (offset >= bytes.length) {
          this.at += bytes.length
          return resolve(this.wrote(before))
        }
        const room = Math.min(SLICE, bytes.length - offset)
        const slice = bytes.subarray(offset, offset + stopAt(this.at + offset, room, this.mark))
        offset += slice.length
        this.term.write(slice, () => nextFrame(step))
      }
      step()
    })
  },

  placeMarker() {
    this.mark = null
    this.clearMarker()
    this.marker = this.term.registerMarker(0)
  },

  // The marked line, at the top of the screen, with a band of the accent across it.
  showMarker() {
    const marker = this.marker
    if (!marker || marker.isDisposed) return
    this.marked = this.term.registerDecoration({
      marker,
      width: this.term.cols,
      backgroundColor: this.markColor,
      layer: "bottom",
    })
    nextFrame(() => {
      if (this.dead || marker.isDisposed) return
      if (this.following) this.follow(false)
      this.term.scrollToLine(Math.max(0, marker.line))
    })
  },

  wrote(before) {
    const lines = this.term.buffer.active.length
    this.screen.setAttribute("aria-label", counted(this.words.log, lines))
    this.labelInput(lines)
    if (!this.initial && lines > before) this.announce(lines - before)
    if (this.following) {
      this.term.scrollToBottom()
    } else if (!this.initial && lines > before) {
      this.unseen += lines - before
      this.showPill()
    }
  },

  // After xterm.js has laid the new lines out, or its viewport puts the end back.
  toTop() {
    nextFrame(() =>
      setTimeout(() => !this.dead && !this.following && this.term.scrollToTop(), 30),
    )
  },

  // One tab stop: xterm's input element, named for what it is, with its keys.
  labelInput(lines) {
    const input = this.term.textarea
    if (!input) return
    input.setAttribute("aria-label", counted(this.words.input, lines))
    input.setAttribute("aria-readonly", "true")
  },

  // "128 new lines", politely, at most once every ten seconds.
  announce(lines) {
    this.unsaid = (this.unsaid || 0) + lines
    if (this.saying) return
    const say = () => {
      this.saying = null
      if (this.dead || !this.unsaid) return
      this.polite.textContent = counted(this.words.newLines, this.unsaid)
      this.unsaid = 0
      this.saying = setTimeout(say, 10000)
    }
    say()
  },

  follow(on) {
    this.following = on
    if (on && this.term) {
      this.unseen = 0
      this.term.scrollToBottom()
    }
    this.showFollowing()
    this.showPill()
  },

  showFollowing() {
    if (!this.followButton) return
    this.followButton.setAttribute("aria-pressed", String(this.following))
    this.followLabel.textContent = this.following ? this.words.following : this.words.jumpToEnd
  },

  showPill() {
    if (!this.pill) return
    const show = !this.following && this.unseen > 0
    this.pill.classList.toggle("q-newpill-show", show)
    this.pill.setAttribute("aria-hidden", String(!show))
    this.pill.tabIndex = show ? 0 : -1
    this.pillText.textContent = counted(this.words.newLines, this.unseen)
  },

  // The search typed before the log was read. With no match, an ended run shows its
  // start, as it does without a search.
  findAfterRead() {
    if (!this.find.value) return
    const found = this.findNext(true)
    if (!found && !this.following) this.toTop()
  },

  findNext(incremental) {
    if (!this.find.value) return this.clearFind(), false
    if (!this.search) return false
    return this.search.findNext(this.find.value, {incremental, decorations: this.decorations})
  },

  findPrevious() {
    if (this.find.value && this.search) {
      this.search.findPrevious(this.find.value, {decorations: this.decorations})
    }
  },

  clearFind() {
    if (!this.find) return
    this.find.value = ""
    this.findCount.textContent = ""
    if (this.search) this.search.clearDecorations()
  },

  // "The log stream dropped. Reconnecting.", then on the third failure the button.
  fail(final) {
    this.failures += 1
    if (final || this.failures >= 3) {
      this.say(this.words.notLoaded, true)
    } else {
      this.say(this.words.dropped, false)
      clearTimeout(this.retryTimer)
      this.retryTimer = setTimeout(() => this.pull(), 1000 * 2 ** (this.failures - 1))
    }
  },

  say(text, retry = false) {
    if (!this.message) return
    this.message.hidden = !text
    this.messageText.textContent = text || ""
    this.retry.hidden = !retry
  },
}
