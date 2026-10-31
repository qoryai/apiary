// The Collapsed view of a run's terminal (docs/ui.md, The terminal), without a page:
// the Terminal hook (terminal.js) feeds the log's bytes in and writes what comes out to
// xterm.js. A log's line of up to 16 MiB that is a JSON object becomes one row; every other
// line stays its bytes.
//
// JSON escapes control characters, so a decoded string is more dangerous than the line it
// came from: "\u001b[2J" is six plain characters in the raw log and a live escape sequence
// once decoded. Every decoded text that reaches xterm.js passes through `clean` or `label`
// here, and the opened form through `opened`.

const NEWLINE = 10
const BRACE = 123
const CLOSING_BRACE = 125
const MAX_LABEL = 40
// The most of a preview a row keeps: no row is wider.
const MAX_PREVIEW = 1000

const decoder = new TextDecoder()
const encoder = new TextEncoder()

// A text as a new string: a slice keeps the whole string it came from in memory, so a short
// preview of a long value would keep that value past `MOST_KEPT`.
const flat = text => decoder.decode(encoder.encode(text))

// The bytes of a stream as lines, each with its line feed. A chunk may end inside a
// character or inside a line, so lines are found in bytes and only a whole line is decoded;
// no line feed occurs inside a UTF-8 character. `rest` marks what follows a line given back
// unfinished by `flush`: the end of a line, which is no line's start.
export class LineBuffer {
  constructor() {
    this.parts = []
    this.rest = false
  }

  push(chunk) {
    const lines = []
    let start = 0
    for (;;) {
      const end = chunk.indexOf(NEWLINE, start)
      if (end < 0) break
      this.parts.push(chunk.subarray(start, end + 1))
      lines.push(this.line())
      start = end + 1
    }
    if (start < chunk.length) this.parts.push(chunk.subarray(start))
    return lines
  }

  // Whether the held partial line can still become an object's row.
  holdsObject() {
    return !this.rest && this.parts.length > 0 && this.parts[0][0] === BRACE
  }

  // The held partial line, or null: reading stopped, and the reader sees what has arrived.
  flush() {
    if (this.parts.length === 0) return null
    const line = this.line()
    this.rest = true
    return line
  }

  line() {
    const parts = this.parts
    const start = !this.rest
    this.parts = []
    this.rest = false
    if (parts.length === 1) return {bytes: parts[0], start}
    const bytes = new Uint8Array(parts.reduce((total, part) => total + part.length, 0))
    let at = 0
    for (const part of parts) {
      bytes.set(part, at)
      at += part.length
    }
    return {bytes, start}
  }
}

// The longest line read as JSON: JSON.parse runs on the page's thread, 2.9 s and 1.3 GB for
// 100 MB. A longer line passes through as its bytes.
export const MOST_READ = 16 * 1024 * 1024

// A line's object, or null. A line that does not start with `{`, or whose last byte before
// its line ending is not `}`, is not read as JSON at all.
const object = bytes => {
  if (bytes.length > MOST_READ || bytes[0] !== BRACE) return null
  let end = bytes.length - 1
  while (end > 0 && (bytes[end] === NEWLINE || bytes[end] === 13)) end -= 1
  if (bytes[end] !== CLOSING_BRACE) return null
  try {
    return JSON.parse(decoder.decode(bytes))
  } catch (_err) {
    return null
  }
}

// A decoded text without C0, C1 and DEL characters; a line break or a tab is a space.
export const clean = text => text.replace(/[\t\n\r]+/g, " ").replace(/[\u0000-\u001f\u007f-\u009f]/g, "")

// A `type` or `subtype`: letters, digits and `_.:-`, at most 40 characters.
export const label = value =>
  typeof value === "string" ? flat(value.replace(/[^A-Za-z0-9_.:-]/g, "").slice(0, MAX_LABEL)) : ""

// What a row shows of an object: its top-level `result`, else the first text in
// `message.content`.
const previewText = value => {
  if (typeof value.result === "string" && value.result) return value.result
  const content = value.message?.content
  if (typeof content === "string") return content
  if (!Array.isArray(content)) return ""
  for (const part of content) {
    if (typeof part === "string" && part) return part
    if (typeof part?.text === "string" && part.text) return part.text
  }
  return ""
}

// A line as the view keeps it: an object's row, with its summary, or `{bytes}` alone for a
// line that passes through.
export const entry = ({bytes, start}) => {
  const value = start ? object(bytes) : null
  if (!value) return {bytes}
  return {
    bytes,
    open: false,
    names: [label(value.type), label(value.subtype)].filter(Boolean).join(" "),
    preview: flat(clean(previewText(value).slice(0, MAX_PREVIEW)).trim()),
  }
}

// How many columns a character may take: two from the first wide block on. A character
// counted too wide cuts a row short and never wraps it.
const cells = text => {
  let count = 0
  for (const character of text) count += character.codePointAt(0) >= 0x1100 ? 2 : 1
  return count
}

const cut = (text, room) => {
  if (cells(text) <= room) return text
  let kept = ""
  let count = 0
  for (const character of text) {
    count += cells(character)
    if (count > room - 3) break
    kept += character
  }
  return room >= 3 ? `${kept}...` : ""
}

// "1.1 kB", as `ApiaryWeb.Format.bytes/1` writes it: `words` has the server's words, and
// `number(n, digits)` writes a number in the reader's locale.
export const size = (bytes, words, number) => {
  const tenths = unit => Math.floor((bytes * 10 + Math.floor(unit / 2)) / unit)
  if (bytes < 1000) return words.bytes.replace("%{number}", number(bytes, 0))
  const [template, unit] = tenths(1000) < 10000 ? [words.kilobytes, 1000] : [words.megabytes, 1000000]
  return template.replace("%{number}", number(tenths(unit) / 10, 1))
}

// A row in `width` columns: the marker, the names, the preview and the size, on one line of
// the screen. It starts by ending any sequence, hyperlink and colour a line before it left
// open, so what passes through cannot swallow a row, link it or colour it.
export const row = (line, width, sizeWords) => {
  const mark = line.open ? "v" : ">"
  const head = line.names ? `${mark} ${line.names}` : mark
  const room = width - 1 - cells(head) - cells(sizeWords) - 4
  const preview = line.preview && room >= 8 ? cut(line.preview, room) : ""
  const middle = preview ? `  ${preview}` : ""
  return (
    `\x1b\\\x1b]8;;\x1b\\\x1b[0m\x1b[90m${mark}\x1b[39m\x1b[1m${head.slice(1)}\x1b[22m${middle}` +
    `  \x1b[90m${sizeWords}\x1b[0m\r\n`
  )
}

const escaped = character => `\\u${character.codePointAt(0).toString(16).padStart(4, "0")}`

// The most of a printed object a row opens to.
export const MOST_OPENED = 1024 * 1024

// Whether a value printed with two spaces can stay within `most`, found before it is
// printed: each line has its depth's indent, so 10 KB of nested arrays print to 52 MB.
const fits = (value, most) => {
  const left = [[value, 1]]
  let room = most
  while (left.length > 0 && room >= 0) {
    const [item, depth] = left.pop()
    room -= depth * 2 + 2
    if (typeof item === "string") {
      room -= item.length
    } else if (item !== null && typeof item === "object") {
      room -= depth * 2 + 2
      for (const [key, value] of Object.entries(item)) {
        room -= key.length
        left.push([value, depth + 1])
      }
    }
  }
  return room >= 0
}

// The object of a line, printed with two spaces, or null when it cannot be or when it is
// over `MOST_OPENED`. JSON.stringify escapes C0 characters and leaves C1 and DEL as they
// are, and xterm.js acts on a C1 character as on its escape sequence, so those are escaped
// here.
export const opened = bytes => {
  if (bytes.length > MOST_OPENED) return null
  try {
    const value = JSON.parse(decoder.decode(bytes))
    if (!fits(value, MOST_OPENED)) return null
    const text = JSON.stringify(value, null, 2).replace(/[\u007f-\u009f]/g, escaped)
    return text.length > MOST_OPENED ? null : `${text.replace(/\n/g, "\r\n")}\r\n`
  } catch (_err) {
    return null
  }
}

// How many rows share one marker. xterm.js calls every marker's listener each time a full
// scrollback drops a line, so a marker per row freezes the tab.
export const ANCHOR_ROWS = 1000

// The places of rows in xterm.js's buffer. One marker in `ANCHOR_ROWS` rows moves with the
// buffer, and a row is its offset from that marker. Each anchor has its distance from the
// first anchor (`at`), so a row whose marker the scrollback dropped is found from a later
// one.
export class Anchors {
  constructor() {
    this.all = []
  }

  // The anchor and offset of a new row on line `y`, or null. `mark` makes a marker on `y`.
  place(y, mark) {
    const last = this.all[this.all.length - 1]
    if (last && last.rows < ANCHOR_ROWS && last.marker.line >= 0) {
      last.rows += 1
      return {anchor: last, offset: y - last.marker.line}
    }
    const marker = mark()
    if (!marker) return null
    const anchor = {marker, at: 0, next: null, rows: 1}
    if (last && last.marker.line >= 0) {
      anchor.at = last.at + marker.line - last.marker.line
      last.next = anchor
    }
    this.all.push(anchor)
    return {anchor, offset: 0}
  }

  clear() {
    for (const {marker} of this.all) marker.dispose()
    this.all = []
  }
}

// A row's line in the buffer, or -1 when the scrollback dropped it.
export const rowLine = ({anchor, offset}) => {
  if (anchor.marker.line >= 0) return anchor.marker.line + offset
  for (let next = anchor.next; next; next = next.next) {
    if (next.marker.line >= 0) return Math.max(next.marker.line - (next.at - anchor.at) + offset, -1)
  }
  return -1
}

// The index in `rows`, ordered by `lineOf`, of the row on `line` (`exact`), or of the last
// row at or before it; -1 for none.
export const rowAt = (rows, line, exact = false, lineOf = row => row.line) => {
  let low = 0
  let high = rows.length - 1
  let found = -1
  while (low <= high) {
    const middle = (low + high) >> 1
    if (lineOf(rows[middle]) <= line) {
      found = middle
      low = middle + 1
    } else {
      high = middle - 1
    }
  }
  return exact && found >= 0 && lineOf(rows[found]) !== line ? -1 : found
}
