// Clocks tick in the browser (brief-runs rj7). Every `<time data-tick>` on the page is
// re-rendered from one interval, once a second, paused while the tab is hidden, in the
// same words the server rendered (ApiaryWeb.RunComponents). All times are UTC.
//
//   data-tick="relative"  datetime=…    "2 minutes ago", "Yesterday, 16:40", "17 Sep, 09:30"
//   data-tick="clock"     datetime=…    "Today, 14:02:11"
//   data-tick="duration"  data-since=…  "2 m 14 s", counting up
//   data-tick="seconds"   data-since=…  the same format, for "Alive, 4 s ago"
//
// The hook itself only re-renders its element after a LiveView patch put the server's
// text back; elements without the hook are picked up by the interval all the same.

const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
const pad = n => String(n).padStart(2, "0")
const hm = d => `${pad(d.getUTCHours())}:${pad(d.getUTCMinutes())}`
const hms = d => `${hm(d)}:${pad(d.getUTCSeconds())}`
const day = d => Math.floor(d.getTime() / 86400000)

export const formatSeconds = s => {
  s = Math.max(0, Math.floor(s))
  if (s < 60) return `${s} s`
  if (s < 3600) return `${Math.floor(s / 60)} m ${pad(s % 60)} s`
  return `${Math.floor(s / 3600)} h ${pad(Math.floor((s % 3600) / 60))} m`
}

export const formatRelative = (at, now) => {
  const seconds = Math.max(0, Math.floor((now - at) / 1000))
  const days = day(now) - day(at)
  if (seconds < 5) return "Just now"
  if (seconds < 60) return `${seconds} seconds ago`
  if (seconds < 120) return "1 minute ago"
  if (seconds < 3600) return `${Math.floor(seconds / 60)} minutes ago`
  if (days <= 0 && seconds < 7200) return "1 hour ago"
  if (days <= 0) return `${Math.floor(seconds / 3600)} hours ago`
  if (days === 1) return `Yesterday, ${hm(at)}`
  const date = `${at.getUTCDate()} ${MONTHS[at.getUTCMonth()]}`
  return at.getUTCFullYear() === now.getUTCFullYear()
    ? `${date}, ${hm(at)}`
    : `${date} ${at.getUTCFullYear()}, ${hm(at)}`
}

export const formatClock = (at, now) => {
  const days = day(now) - day(at)
  if (days === 0) return `Today, ${hms(at)}`
  if (days === 1) return `Yesterday, ${hms(at)}`
  return `${at.getUTCDate()} ${MONTHS[at.getUTCMonth()]} ${at.getUTCFullYear()}, ${hms(at)}`
}

const render = (el, now) => {
  const kind = el.dataset.tick
  const at = new Date(kind === "relative" || kind === "clock" ? el.getAttribute("datetime") : el.dataset.since)
  if (Number.isNaN(at.getTime())) return
  const text =
    kind === "relative" ? formatRelative(at, now)
    : kind === "clock" ? formatClock(at, now)
    : formatSeconds((now - at) / 1000)
  if (el.textContent !== text) el.textContent = text
}

const tick = () => {
  if (document.hidden) return
  const now = new Date()
  document.querySelectorAll("time[data-tick]").forEach(el => render(el, now))
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
    render(this.el, new Date())
  },
  updated() {
    render(this.el, new Date())
  },
}
