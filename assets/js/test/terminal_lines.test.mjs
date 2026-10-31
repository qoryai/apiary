// The Collapsed view of a run's terminal (assets/js/hooks/terminal_lines.js): how a stream
// becomes lines and rows, and what of a decoded value can reach xterm.js.
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"

import {ANCHOR_ROWS, Anchors, LineBuffer, MOST_OPENED, MOST_READ, clean, entry, label, opened, row, rowAt, rowLine, size} from "../hooks/terminal_lines.js"

const encode = text => new TextEncoder().encode(text)
const decode = bytes => new TextDecoder().decode(bytes)
const lineOf = text => new LineBuffer().push(encode(`${text}\n`))[0]

const words = {bytes: "%{number} B", kilobytes: "%{number} kB", megabytes: "%{number} MB"}
const number = (n, digits) => n.toFixed(digits)
// A row without the sequences the view adds, which hold its only ESC, and its line ending.
const visible = text => text.replace(/\x1b\\/g, "").replace(/\x1b\[[0-9;]*m/g, "").replace(/\r\n$/, "")

test("a chunk that ends inside a line keeps the line whole", () => {
  const lines = new LineBuffer()
  assert.deepEqual(lines.push(encode('{"type":')), [])
  const [line] = lines.push(encode('"system"}\nnext'))
  assert.equal(decode(line.bytes), '{"type":"system"}\n')
  assert.equal(line.start, true)
  assert.equal(decode(lines.flush().bytes), "next")
  assert.equal(lines.flush(), null)
})

test("a chunk that ends inside a character keeps the character whole", () => {
  const bytes = encode('{"result":"héllo €"}\n')
  const lines = new LineBuffer()
  const seen = []
  for (let at = 0; at < bytes.length; at += 1) seen.push(...lines.push(bytes.subarray(at, at + 1)))
  assert.equal(seen.length, 1)
  assert.equal(entry(seen[0]).preview, "héllo €")
})

test("what follows a flushed partial line is no line's start", () => {
  const lines = new LineBuffer()
  lines.push(encode('progress {"type":'))
  lines.flush()
  const [rest] = lines.push(encode('{"type":"system"}\n'))
  assert.equal(rest.start, false)
  assert.equal(entry(rest).names, undefined)
  const [after] = lines.push(encode('{"type":"system"}\n'))
  assert.equal(after.start, true)
  assert.equal(entry(after).names, "system")
})

test("a held line that starts with a brace is said to hold an object", () => {
  const lines = new LineBuffer()
  lines.push(encode('{"type"'))
  assert.equal(lines.holdsObject(), true)
  lines.flush()
  lines.push(encode('{"type"'))
  assert.equal(lines.holdsObject(), false)
})

test("every other line passes through as its bytes", () => {
  for (const text of ["plain words", "[tag] {\"a\":1}", " {\"a\":1}", "{not json}", "{", "[1,2]", "12", "\"text\"", ""]) {
    const line = lineOf(text)
    const kept = entry(line)
    assert.equal("names" in kept, false, text)
    assert.equal(decode(kept.bytes), `${text}\n`)
  }
})

test("a line over 16 MiB is not read as JSON", () => {
  const object = size => {
    const bytes = new Uint8Array(size).fill(0x20)
    bytes.set(encode('{"type":"system"'))
    bytes.set(encode("}\n"), size - 2)
    return bytes
  }
  assert.equal("names" in entry({bytes: object(MOST_READ), start: true}), true)
  assert.equal("names" in entry({bytes: object(MOST_READ + 1), start: true}), false)
})

test("a row has the marker, the type and subtype, the preview and the size", () => {
  const line = entry(lineOf('{"type":"result","subtype":"success","result":"API Error: 400 no"}'))
  assert.equal(line.names, "result success")
  assert.equal(line.preview, "API Error: 400 no")
  assert.equal(visible(row(line, 80, "1.1 kB")), "> result success  API Error: 400 no  1.1 kB")
  assert.equal(visible(row({...line, open: true}, 80, "1.1 kB")), "v result success  API Error: 400 no  1.1 kB")
})

test("a row without strings for a type and subtype shows neither", () => {
  const line = entry(lineOf('{"type":7,"subtype":["x"],"other":true}'))
  assert.equal(line.names, "")
  assert.equal(visible(row(line, 80, "20 B")), ">  20 B")
})

test("the preview is the first text in message.content when there is no result", () => {
  const text = entry(lineOf('{"type":"assistant","message":{"content":[{"type":"tool_use"},{"type":"text","text":"Hello"}]}}'))
  assert.equal(text.preview, "Hello")
  assert.equal(entry(lineOf('{"type":"user","message":{"content":"Plain"}}')).preview, "Plain")
  assert.equal(entry(lineOf('{"type":"user","message":"not an object"}')).preview, "")
  assert.equal(entry(lineOf('{"result":7,"message":{"content":[null,7]}}')).preview, "")
})

test("a row stays on one line of the screen, wide characters included", () => {
  const line = entry(lineOf(`{"type":"result","result":"${"界".repeat(300)}"}`))
  for (const width of [20, 40, 80, 200]) {
    const shown = visible(row(line, width, "1.1 kB"))
    let cells = 0
    for (const character of shown) cells += character.codePointAt(0) >= 0x1100 ? 2 : 1
    assert.ok(cells < width, `${cells} cells in ${width}`)
    assert.ok(shown.endsWith("1.1 kB"))
  }
  assert.ok(visible(row(line, 80, "1.1 kB")).includes("..."))
})

test("a preview cut in a pair of surrogates leaves no half of a character", () => {
  const line = entry(lineOf(`{"result":"${"😀".repeat(50)}"}`))
  assert.equal(visible(row(line, 30, "1 kB")).includes("�"), false)
})

// SECURITY: raw JSON escapes these, so the raw view shows them as text. Decoded, they would
// be live sequences: the first sets the window's title, the second clears the screen.
const HOSTILE = '{"type":"re\\u001b[2Jsult","subtype":"\\u001b]0;x\\u0007","result":"A\\u001b]0;x\\u0007B\\u001b[2JC\\u009b2JD\\u007fE\\u0090F"}'

const controls = text => [...text].filter(c => /[\u0000-\u001f\u007f-\u009f]/.test(c))

test("no decoded value in a row has a control character", () => {
  const line = entry(lineOf(HOSTILE))
  assert.deepEqual(controls(line.names), [])
  assert.deepEqual(controls(line.preview), [])
  assert.equal(line.preview, "A]0;xB[2JC2JDEF")
  assert.equal(line.names, "re2Jsult 0x")
  assert.deepEqual(controls(visible(row(line, 80, "1 kB"))), [])
})

test("a decoded line break in a preview is a space", () => {
  assert.equal(clean("one\r\ntwo\tthree"), "one two three")
})

test("a type and a subtype keep letters, digits and _.:- up to 40 characters", () => {
  assert.equal(label("hook_started:v1.2-3"), "hook_started:v1.2-3")
  assert.equal(label("a b;c/d"), "abcd")
  assert.equal(label("x".repeat(90)).length, 40)
  assert.equal(label(7), "")
})

test("the opened form escapes every control character", () => {
  const text = opened(encode(`${HOSTILE}\n`))
  assert.deepEqual(controls(text.replace(/\r\n/g, "")), [])
  assert.match(text, /\\u001b\[2J/)
  assert.match(text, /\\u009b2J/)
  assert.match(text, /\\u007f/)
  assert.match(text, /^\{\r\n {2}"type"/)
  assert.ok(text.endsWith("}\r\n"))
})

test("a value that cannot be printed opens to nothing", () => {
  assert.equal(opened(encode("{not json}")), null)
})

test("an object that prints over 1 MiB opens to nothing, before it is printed", () => {
  const depth = 5100
  const nested = encode(`{"a":${"[".repeat(depth)}${"]".repeat(depth)}}\n`)
  assert.ok(nested.length < 11000)
  const began = performance.now()
  assert.equal(opened(nested), null)
  assert.ok(performance.now() - began < 200)
  assert.equal(opened(encode(`{"a":"${"x".repeat(MOST_OPENED)}"}\n`)), null)
})

test("a C1 character's escape counts toward the most a row opens to", () => {
  const line = encode(`{"a":"${"\u0085".repeat(Math.floor(MOST_OPENED / 4))}"}\n`)
  assert.ok(line.length < MOST_OPENED)
  assert.equal(opened(line), null)
})

test("an object just under the limit opens", () => {
  const text = opened(encode(`{"a":"${"x".repeat(MOST_OPENED - 100)}"}\n`))
  assert.ok(text.length <= MOST_OPENED + 10)
})

test("a size is written as the server writes it", () => {
  assert.equal(size(999, words, number), "999 B")
  assert.equal(size(1000, words, number), "1.0 kB")
  assert.equal(size(2449, words, number), "2.4 kB")
  assert.equal(size(2450, words, number), "2.5 kB")
  assert.equal(size(999949, words, number), "999.9 kB")
  assert.equal(size(999950, words, number), "1.0 MB")
  assert.equal(size(5242880, words, number), "5.2 MB")
})

test("a row is found by its line in the buffer", () => {
  const rows = [{line: 2}, {line: 5}, {line: 9}]
  assert.equal(rowAt(rows, 5, true), 1)
  assert.equal(rowAt(rows, 6, true), -1)
  assert.equal(rowAt(rows, 6), 1)
  assert.equal(rowAt(rows, 1), -1)
  assert.equal(rowAt(rows, 1, true), -1)
  assert.equal(rowAt(rows, 40), 2)
  assert.equal(rowAt([], 4), -1)
})

// A buffer as far as markers see it: lines scroll out of the top.
const buffer = () => {
  const markers = []
  return {
    markers,
    mark: y => () => {
      const marker = {line: y, dispose: () => (marker.line = -1)}
      markers.push(marker)
      return marker
    },
    trim: amount => {
      for (const marker of markers) marker.line = marker.line >= amount ? marker.line - amount : -1
    },
  }
}

test("rows share one marker in a thousand", () => {
  const screen = buffer()
  const anchors = new Anchors()
  const rows = []
  for (let y = 0; y < ANCHOR_ROWS * 3 + 1; y += 1) rows.push(anchors.place(y * 2, screen.mark(y * 2)))
  assert.equal(screen.markers.length, 4)
  assert.equal(rowLine(rows[0]), 0)
  assert.equal(rowLine(rows[999]), 1998)
  assert.equal(rowLine(rows[1000]), 2000)
  assert.equal(rowLine(rows[3000]), 6000)
})

test("rows move with the buffer as it trims", () => {
  const screen = buffer()
  const anchors = new Anchors()
  const rows = []
  for (let y = 0; y < 2500; y += 1) rows.push(anchors.place(y, screen.mark(y)))
  screen.trim(1500)
  assert.equal(rowLine(rows[2499]), 999)
  assert.equal(rowAt(rows, 999, true, rowLine), 2499)
})

test("a row whose marker was trimmed is found from a later marker", () => {
  const screen = buffer()
  const anchors = new Anchors()
  const rows = []
  for (let y = 0; y < 2500; y += 1) rows.push(anchors.place(y, screen.mark(y)))
  screen.trim(10)
  assert.equal(screen.markers[0].line, -1)
  assert.equal(rowLine(rows[9]), -1)
  assert.equal(rowLine(rows[10]), 0)
  assert.equal(rowLine(rows[999]), 989)
  assert.equal(rowAt(rows, 0, true, rowLine), 10)
})

test("a row with no marker left is on no line, and the next row starts a new anchor", () => {
  const screen = buffer()
  const anchors = new Anchors()
  const first = anchors.place(0, screen.mark(0))
  screen.trim(5)
  assert.equal(rowLine(first), -1)
  const second = anchors.place(7, screen.mark(7))
  assert.equal(second.offset, 0)
  assert.equal(rowLine(second), 7)
  assert.equal(rowLine(first), -1)
})

test("clearing the anchors disposes every marker", () => {
  const screen = buffer()
  const anchors = new Anchors()
  anchors.place(3, screen.mark(3))
  anchors.clear()
  assert.equal(screen.markers[0].line, -1)
  assert.deepEqual(anchors.all, [])
})

test("a 5 MiB log of JSON lines is split in slices of a frame's budget", () => {
  const text = `${JSON.stringify({type: "assistant", message: {content: [{type: "text", text: "word ".repeat(100)}]}})}\n`
  const log = encode(text.repeat(Math.ceil((5 * 1024 * 1024) / text.length)))
  const lines = new LineBuffer()
  const SLICE = 256 * 1024
  let longest = 0
  let count = 0
  for (let at = 0; at < log.length; at += SLICE) {
    const began = performance.now()
    for (const line of lines.push(log.subarray(at, at + SLICE))) {
      row(entry(line), 200, "1.1 kB")
      count += 1
    }
    longest = Math.max(longest, performance.now() - began)
  }
  assert.ok(count >= 1000)
  assert.ok(longest < 100, `the slowest slice took ${longest} ms`)
})
