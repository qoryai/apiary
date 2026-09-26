// Clocks tick in the browser (docs/ui.md). Every `<time data-tick>` on the page is
// re-rendered from one interval, once a second, paused while the tab is hidden, in the
// same words the server rendered (ApiaryWeb.RunComponents), which it also hands over.
//
//   data-tick="relative"  datetime=…    "2 minutes ago", "Yesterday, 16:40",
//                                       "17 Sept, 09:30"
//   data-tick="clock"     datetime=…    "Today, 14:02:11"
//   data-tick="duration"  data-base=… data-since=…  "2 m 14 s": the runner's elapsed seconds
//                                                   plus the server time since it said so
//   data-tick="seconds"   data-since=…  the same format, for "Alive, 4 s ago"
//
// The hook itself only re-renders its element after a LiveView patch put the server's
// text back; elements without the hook are picked up by the interval all the same.

// The words are the server's, in the reader's language (`RunComponents.clock_words/0`, on
// the body as `data-clock-words`); this script holds none. Without them an element keeps
// the text the server rendered.
let words
const loadWords = () => {
  if (words === undefined) {
    try {
      words = JSON.parse(document.body.dataset.clockWords || "null")
    } catch (_err) {
      words = null
    }
  }
  return words
}

// Dates and times are written with `Intl.DateTimeFormat` in the locale and the time zone
// the server formats in (`ApiaryWeb.Format`, on the body as `data-locale` and
// `data-time-zone`), never the browser's own: a page shows one zone, the reader's.
const reader = () => ({
  locale: document.body.dataset.locale || "en-GB",
  timeZone: document.body.dataset.timeZone || "UTC",
})

const formats = new Map()
const formatter = (options, r = reader()) => {
  const key = JSON.stringify([r.locale, r.timeZone, options])
  if (!formats.has(key)) {
    let format
    try {
      format = new Intl.DateTimeFormat(r.locale, {...options, timeZone: r.timeZone})
    } catch (_err) {
      format = new Intl.DateTimeFormat("en-GB", {...options, timeZone: "UTC"})
    }
    formats.set(key, format)
  }
  return formats.get(key)
}

const fill = (template, bindings) =>
  template.replace(/%\{(\w+)\}/g, (all, key) => (key in bindings ? String(bindings[key]) : all))

const pad = n => String(n).padStart(2, "0")
// A 24-hour clock writes the hour in two digits, as CLDR's patterns do ("09:30"); a
// 12-hour one does not ("9:30 AM").
const HM = () => {
  const cycle = formatter({hour: "numeric"}).resolvedOptions().hourCycle
  return {hour: cycle === "h23" || cycle === "h24" ? "2-digit" : "numeric", minute: "2-digit"}
}
const HMS = () => ({...HM(), second: "2-digit"})
const hm = d => formatter(HM()).format(d)
const hms = d => formatter(HMS()).format(d)

// The reader's calendar day of a moment, as a day number, and its year.
const calendar = d => {
  const parts = {}
  for (const {type, value} of formatter({year: "numeric", month: "numeric", day: "numeric"}, {
    locale: "en-GB",
    timeZone: reader().timeZone,
  }).formatToParts(d))
    parts[type] = Number(value)
  return {day: Date.UTC(parts.year, parts.month - 1, parts.day) / 86400000, year: parts.year}
}

export const formatSeconds = (s, w = loadWords()) => {
  if (!w) return null
  s = Math.max(0, Math.floor(s))
  if (s < 60) return fill(w.seconds, {seconds: s})
  if (s < 3600) return fill(w.minutesSeconds, {minutes: Math.floor(s / 60), seconds: pad(s % 60)})
  return fill(w.hoursMinutes, {hours: Math.floor(s / 3600), minutes: pad(Math.floor((s % 3600) / 60))})
}

// As `ApiaryWeb.Format.relative/2`.
export const formatRelative = (at, now, w = loadWords()) => {
  if (!w) return null
  const seconds = Math.max(0, Math.floor((now - at) / 1000))
  const [then, today] = [calendar(at), calendar(now)]
  const days = today.day - then.day
  if (seconds < 5) return w.justNow
  if (seconds < 60) return w.secondsAgo[seconds]
  if (seconds < 3600) return w.minutesAgo[Math.floor(seconds / 60)]
  // A missing count keeps the server's text rather than blanking it.
  if (days <= 0) return w.hoursAgo[Math.floor(seconds / 3600)] ?? null
  if (days === 1) return fill(w.yesterday, {time: hm(at)})
  const year = then.year === today.year ? {} : {year: "numeric"}
  return formatter({day: "numeric", month: "short", ...year, ...HM()}).format(at)
}

// As `ApiaryWeb.Format.clock/2`.
export const formatClock = (at, now, w = loadWords()) => {
  if (!w) return null
  const days = calendar(now).day - calendar(at).day
  if (days === 0) return fill(w.today, {time: hms(at)})
  if (days === 1) return fill(w.yesterday, {time: hms(at)})
  return formatter({day: "numeric", month: "short", year: "numeric", ...HMS()}).format(at)
}

// The browser's clock is never trusted. Every ticking element carries the server's now at
// the moment it was rendered (`data-now`); the first time an element is seen, the
// difference from the browser's clock is an estimate of the offset, short by the time the
// render took to arrive. The largest estimate is the one that travelled fastest, so it is
// kept. Everything on the page then counts on one clock, the server's: the quiet counter
// cannot disagree with the badge the server decided.
let offset = null
const seen = new WeakSet()

const learn = el => {
  if (seen.has(el)) return
  seen.add(el)
  const at = Date.parse(el.dataset.now || "")
  if (Number.isNaN(at)) return
  const estimate = at - Date.now()
  if (offset === null || estimate > offset) offset = estimate
}

const serverNow = () => new Date(Date.now() + (offset || 0))

const render = el => {
  learn(el)
  const now = serverNow()
  const kind = el.dataset.tick
  const at = new Date(kind === "relative" || kind === "clock" ? el.getAttribute("datetime") : el.dataset.since)
  if (Number.isNaN(at.getTime())) return
  // A duration counts from what the runner said had elapsed (`data-base`) at the server
  // time it said so (`data-since`).
  const base = kind === "duration" ? Number(el.dataset.base) || 0 : 0
  const text =
    kind === "relative" ? formatRelative(at, now)
    : kind === "clock" ? formatClock(at, now)
    : formatSeconds(base + Math.max(0, (now - at) / 1000))
  if (text !== null && el.textContent !== text) el.textContent = text
}

const tick = () => {
  if (document.hidden) return
  const els = document.querySelectorAll("time[data-tick]")
  // Learn from every new element before rendering any, so one pass is on one clock.
  els.forEach(learn)
  els.forEach(render)
}

let timer = null
const start = () => {
  if (timer === null) timer = setInterval(tick, 1000)
}
start()
document.addEventListener("visibilitychange", () => !document.hidden && tick())
window.addEventListener("phx:page-loading-stop", tick)

export const Ticker = {
  mounted() {
    start()
    render(this.el)
  },
  updated() {
    // A patch may carry a fresher `data-now`: let it be learnt again.
    seen.delete(this.el)
    render(this.el)
  },
}
