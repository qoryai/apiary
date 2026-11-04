// The diagrams of an artifact's Document view and of a proposal on the work item page.
// The hook element (phx-update="ignore") contains blocks
// <pre class="q-mermaid-source"><code>…</code></pre>. The hook draws only five types
// (types below): flowchart (flowchart and graph), sequence, state (stateDiagram and
// stateDiagram-v2), class (classDiagram and classDiagram-v2) and ER diagrams. It draws
// each such block with Mermaid and shows the result as an <img> of the SVG. Mermaid
// draws the SVG in a temporary element of the page and removes that element after the
// draw. After the draw, the page has only the <img>: a browser runs no script of an SVG
// shown as an image and loads no address from it. The block's source moves into a
// <details> under the image.
// A block of another type, or one that fails the checks below, stays as text, with the
// sentence from data-not-drawn above it. A block of one of the five types that does not
// parse stays as text, with the sentence from data-failed above it.
//
// Attributes of the hook element, translated on the server: data-script (the bundle
// URL), data-alt (the images' alt text), data-source (the label of the source's
// <details>), data-not-drawn and data-failed. Nothing here assigns innerHTML: every
// element is built with createElement and every text is set through textContent.
//
// Mermaid is vendored (assets/vendor/mermaid) and built as a separate bundle
// (/assets/js/mermaid.js), not part of app.js. The hook adds its <script> the first time
// it finds a block that it draws, so a page with no such block never loads it.
//
// The settings (settings below): securityLevel "strict", htmlLabels false, at most 20,000
// characters and 200 edges, the theme "base" with the app's colours, read from its CSS
// variables, and the hand-drawn look with a fixed seed. A document can change Mermaid's
// settings in two ways, a directive (%%{init: …}%%) and a front matter config: block
// (--- … --- at its start). The hook drops both before a block is drawn (source below).
// Mermaid also removes, at every depth, each setting of its secure list from what a
// document sets; the hook's list (secure below) has every setting that changes the HTML,
// the CSS or the links of a drawing, and the look and its seed.
// The hook drops each click, link, links and callback statement of Mermaid 11.17.2
// (linkStatements below) before a block is drawn.
// Mermaid passes each text that it puts into the temporary element as HTML, such as a
// sequence message with $$…$$, through its sanitizer, with the hook's dompurifyConfig
// (below), which removes the elements and attributes that load an address, link or
// style.
// The hook does not draw a block with a syntax that makes Mermaid load an address
// (loads below).
// When the app's theme changes (data-theme on <html>), the hook draws each diagram again
// with the new colours (watchTheme below).
// The <img> gets the diagram's width from the SVG's max-width (width below): Mermaid
// writes width="100%", so without it the CSS width rule of .q-mermaid-diagram has no
// effect.

let library = null

const load = script => {
  if (window.QoryMermaid) return Promise.resolve(window.QoryMermaid)
  if (library) return library
  library = new Promise((resolve, reject) => {
    const tag = document.createElement("script")
    tag.src = script
    tag.onload = () => (window.QoryMermaid ? resolve(window.QoryMermaid) : reject(new Error("mermaid bundle")))
    tag.onerror = () => {
      library = null
      tag.remove()
      reject(new Error("mermaid bundle"))
    }
    document.head.appendChild(tag)
  })
  return library
}

// Blocks already drawn or being drawn, so a second pass skips them.
const handled = new WeakSet()
let count = 0

// The layout sets data-theme on <html> to qory-dark or qory-light, from the reader's
// choice or the system's (root.html.heex).
const dark = () => (document.documentElement.dataset.theme ?? "").includes("dark")

const font = "ui-sans-serif, system-ui, sans-serif"

// The settings a document may not set (Mermaid's "secure" list): Mermaid's six defaults,
// then each setting that changes the HTML, the CSS or the links of a drawing, then the
// look and its seed (settings below).
export const secure = [
  "secure",
  "securityLevel",
  "startOnLoad",
  "maxTextSize",
  "suppressErrorRendering",
  "maxEdges",
  "htmlLabels",
  "dompurifyConfig",
  "themeCSS",
  "theme",
  "themeVariables",
  "darkMode",
  "fontFamily",
  "altFontFamily",
  "fontSize",
  "arrowMarkerAbsolute",
  "legacyMathML",
  "forceLegacyMathML",
  "ticketBaseUrl",
  "look",
  "handDrawnSeed",
]

// What Mermaid's sanitizer (DOMPurify) removes from each text it sanitizes, such as a
// sequence message with $$…$$: the elements listed, which load an address or link, and
// the attributes style, class, id and those with an address. Mermaid applies this site
// setting, which a document cannot change (secure above), to every text it sanitizes.
// It removes only what a document wrote: the markup Mermaid adds around a text, such as
// a label's <div style>, stays.
export const dompurifyConfig = {
  FORBID_TAGS: [
    "style",
    "img",
    "image",
    "picture",
    "source",
    "video",
    "audio",
    "iframe",
    "object",
    "embed",
    "form",
    "input",
    "a",
    "svg",
    "use",
  ],
  FORBID_ATTR: [
    "style",
    "class",
    "id",
    "src",
    "srcset",
    "href",
    "xlink:href",
    "background",
    "poster",
  ],
}

// The CSS the hook adds to each drawing: an edge label's box opaque, so the edge's line
// does not show through its text. Mermaid's flowchart and state themes draw that box
// half transparent; the state theme's rule is .edgeLabel .label rect, so the hook's
// rule has that selector too.
export const labelCSS = ".edgeLabel rect, .edgeLabel .label rect { opacity: 1; }"

// What the hook passes to mermaid.initialize, with the theme's colours `themeVariables`.
// look "handDrawn" draws the shapes and lines of flowchart, state, class and ER diagrams
// as sketched lines; Mermaid 11.17.2 draws a sequence diagram in its classic look with
// any look. The text keeps the font below. handDrawnSeed fixes the sketch's random
// strokes, so a diagram looks the same on every draw.
export const settings = themeVariables => ({
  startOnLoad: false,
  securityLevel: "strict",
  secure,
  dompurifyConfig,
  htmlLabels: false,
  maxTextSize: 20000,
  maxEdges: 200,
  theme: "base",
  themeVariables,
  themeCSS: labelCSS,
  fontFamily: font,
  look: "handDrawn",
  handDrawnSeed: 1,
})

const fence = line => /^\s*-{3}\s*$/.test(line)

// Leading front matter blocks (--- to ---, after blank lines), dropped; an opening ---
// with no closing one drops the rest.
const withoutFrontMatter = lines => {
  let start = 0
  while (start < lines.length && lines[start].trim() === "") start++
  if (start === lines.length || !fence(lines[start])) return lines
  const end = lines.findIndex((line, at) => at > start && fence(line))
  return end === -1 ? [] : withoutFrontMatter(lines.slice(end + 1))
}

// The statements of Mermaid 11.17.2 that add a link or a call, at a line's start or
// after a ";": click (flowchart, class, state and gantt diagrams); a class diagram's
// link <class> "<url>" and callback <class> "<function>", with the class name plain or
// in backticks; a sequence diagram's link <actor>: … and links <actor>: …. A flowchart
// node whose id is link, links or callback, as in "link --> B", matches none of them.
const linkStatements = [
  /(^|;)\s*click(\s|$)/i,
  /(^|;)\s*(link|callback)(\s*`[^`]*`|\s+[^\s"`]+)\s*"/i,
  /(^|;)\s*links?\s+[^\s:;|"<>-][^\s:;|"<>]*\s*:/i,
]

// The text of a block as Mermaid draws it: without each line that contains a directive
// (%%{ … }%%, such as %%{init: …}%%), without each line with a link statement
// (linkStatements above), and without a front matter block at its start, looked for
// after the other lines are dropped.
export const source = text =>
  withoutFrontMatter(
    text
      .split(/\r\n|\r|\n/)
      .filter(
        line => !line.includes("%%{") && !linkStatements.some(statement => statement.test(line)),
      ),
  ).join("\n")

// The CSS that loads an address: url(), image-set() (and -webkit-image-set()) and
// @import, looked for in lowercase, in the text as written and with its CSS comments
// dropped and its CSS escapes (\75 rl, u\rl) read.
const cssAddresses = ["url(", "image-set(", "@import"]

const unescaped = text =>
  text
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\\([0-9a-f]{1,6})[ \t\n\f\r]?|\\([\s\S])/gi, (_, code, char) => {
      if (code === undefined) return char === "\n" ? "" : char
      const point = parseInt(code, 16)
      return point > 0 && point <= 0x10ffff ? String.fromCodePoint(point) : "\ufffd"
    })

// The node data blocks of `text` (A@{ … }), each from its "@{" to the "}" that closes
// it, outside quotes; a block with no end runs to the end of the text.
const dataBlocks = text => {
  const blocks = []
  let at = text.indexOf("@{")
  while (at !== -1) {
    let depth = 0
    let quote = null
    let end = text.length
    for (let i = at + 1; i < text.length; i++) {
      const char = text[i]
      if (quote) {
        if (char === "\\" && quote === '"') i++
        else if (char === quote) quote = null
      } else if (char === '"' || char === "'") quote = char
      else if (char === "{") depth++
      else if (char === "}" && --depth === 0) {
        end = i + 1
        break
      }
    }
    blocks.push(text.slice(at, end))
    at = text.indexOf("@{", end)
  }
  return blocks
}

// Whether a node data block contains the word img anywhere: in a key, a value or a
// label, quoted or not. Its YAML can write a key in many ways, such as after a plain
// scalar with an apostrophe (label: it's, img: "…"), so the hook does not try to find
// only the keys.
const imgWord = block => /\bimg\b/i.test(block)

// The first line of `text` that is not blank and not a %% comment, trimmed, which
// starts with the diagram's type; "" for none. Mermaid reads the type from the start of
// the text that is left after it drops its %% comments and the blank space before them.
const firstLine = text =>
  text
    .split(/\r\n|\r|\n/)
    .map(line => line.trim())
    .find(line => line !== "" && !line.startsWith("%%")) ?? ""

// The diagram types that the hook draws, as the first word of a block's first line
// (type below). Mermaid draws more types; the hook leaves those as text.
export const types = [
  "flowchart",
  "graph",
  "sequenceDiagram",
  "stateDiagram",
  "stateDiagram-v2",
  "classDiagram",
  "classDiagram-v2",
  "erDiagram",
]

// The type of `text`: the first word of its first line that is not blank and not a
// comment (firstLine above), up to a space or a ";".
export const type = text => firstLine(text).split(/[\s;]/)[0]

// Whether drawing `text` would load an address, by the syntaxes of the vendored Mermaid
// 11.17.2 that do: CSS with an address, in any style, classDef, linkStyle or C4 style
// (cssAddresses above); a flowchart node's image (A@{ img: "…" }), which Mermaid loads as
// an Image and draws as <image href>, so a node data block with the word img in it, or
// with a backslash, which its YAML could use to write "img"; and a sequence diagram's
// properties line, whose "icon" Mermaid draws as <image xlink:href>; and a sequence
// diagram's details line, for which Mermaid reads the HTML of the page element with
// that id and applies it as JSON properties and links. Also an
// eventmodeling diagram with a "<" in it: Mermaid sanitizes its fields, then wraps them
// and writes &nbsp; into the result, which it puts into the page as HTML, so markup can
// pass the sanitizer and change after it. eventmodeling is not in types (above), so the
// hook draws no eventmodeling diagram; this check stays in case the list changes.
export const loads = text => {
  if (/^eventmodeling/i.test(firstLine(text)) && text.includes("<")) return true
  const written = text.toLowerCase()
  const read = unescaped(text).toLowerCase()
  if (cssAddresses.some(css => written.includes(css) || read.includes(css))) return true
  if (dataBlocks(text).some(block => imgWord(block) || block.includes("\\"))) return true
  return /(^|;)\s*(properties|details)(\s|$)/im.test(text)
}

// Whether the hook draws `text`, a block's source (source above): a type in types and
// no syntax that loads an address.
export const draws = text => types.includes(type(text)) && !loads(text)

// Calls `changed` each time the value of data-theme on `root` changes, and returns a
// function that stops it. `Observer` is the MutationObserver class.
export const watchTheme = (root, changed, Observer = globalThis.MutationObserver) => {
  if (!Observer) return () => {}
  let theme = root.getAttribute("data-theme")
  const observer = new Observer(() => {
    const now = root.getAttribute("data-theme")
    if (now === theme) return
    theme = now
    changed()
  })
  observer.observe(root, {attributes: true, attributeFilter: ["data-theme"]})
  return () => observer.disconnect()
}

// The width in pixels of a drawn SVG, from its max-width style, rounded up; null for none.
export const width = svg => {
  const max = /max-width:\s*([\d.]+)px/.exec(svg)
  return max ? Math.ceil(Number(max[1])) : null
}

// A CSS colour as #rrggbb, through a canvas, as Mermaid reads no oklch(); undefined where
// the variable is not set or the colour does not parse.
const hex = (context, value) => {
  if (!value) return undefined
  context.fillStyle = "#010203"
  context.fillStyle = value
  if (context.fillStyle === "#010203" && value !== "#010203") return undefined
  context.clearRect(0, 0, 1, 1)
  context.fillRect(0, 0, 1, 1)
  const [r, g, b] = context.getImageData(0, 0, 1, 1).data
  return "#" + [r, g, b].map(n => n.toString(16).padStart(2, "0")).join("")
}

// The theme's colours, from the CSS variables that apply at the hook element.
const colours = el => {
  const canvas = document.createElement("canvas")
  canvas.width = canvas.height = 1
  const context = canvas.getContext("2d", {willReadFrequently: true})
  const style = getComputedStyle(el)
  const v = name => (context ? hex(context, style.getPropertyValue(name).trim()) : undefined)
  const variables = {
    darkMode: dark(),
    fontFamily: font,
    fontSize: "13px",
    background: v("--color-base-100"),
    primaryColor: v("--color-base-200"),
    primaryBorderColor: v("--q-border-strong"),
    primaryTextColor: v("--color-base-content"),
    textColor: v("--color-base-content"),
    lineColor: v("--q-muted"),
    edgeLabelBackground: v("--color-base-100"),
    tertiaryColor: v("--color-base-100"),
  }
  return Object.fromEntries(Object.entries(variables).filter(([, value]) => value !== undefined))
}

const paint = (img, svg) => {
  img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg)
  const pixels = width(svg)
  if (pixels) img.width = pixels
  else img.removeAttribute("width")
}

const show = (el, pre, svg) => {
  const figure = document.createElement("figure")
  figure.className = "q-mermaid"
  const img = document.createElement("img")
  img.className = "q-mermaid-diagram"
  img.alt = el.dataset.alt ?? ""
  paint(img, svg)
  figure.appendChild(img)
  pre.before(figure)
  const details = document.createElement("details")
  details.className = "q-mermaid-details"
  const summary = document.createElement("summary")
  summary.textContent = el.dataset.source ?? ""
  details.append(summary, pre)
  figure.appendChild(details)
}

// The block `pre` left as text, under the sentence `line`.
const fail = (pre, line) => {
  const p = document.createElement("p")
  p.className = "q-mermaid-failed"
  p.textContent = line ?? ""
  pre.before(p)
}

// The text of the block `pre` as Mermaid draws it (source above).
const blockText = pre => source((pre.querySelector("code") ?? pre).textContent)

const draw = async el => {
  const found = [...el.querySelectorAll("pre.q-mermaid-source")].filter(pre => !handled.has(pre))
  found.forEach(pre => handled.add(pre))
  const blocks = found.filter(pre => draws(blockText(pre)))
  found.filter(pre => !blocks.includes(pre)).forEach(pre => fail(pre, el.dataset.notDrawn))
  if (blocks.length === 0) return

  let mermaid
  try {
    mermaid = await load(el.dataset.script)
  } catch (_error) {
    // The blocks stay as text; the next pass tries the bundle again.
    blocks.forEach(pre => handled.delete(pre))
    return
  }

  mermaid.initialize(settings(colours(el)))

  for (const pre of blocks) {
    if (!pre.isConnected) continue
    const {svg, line} = await drawing(mermaid, blockText(pre))
    if (svg) show(el, pre, svg)
    else fail(pre, el.dataset[line])
  }
}

// The SVG of `text`, or null where it does not parse.
const render = async (mermaid, text) => {
  const id = `q-mermaid-${++count}`
  try {
    return (await mermaid.render(id, text)).svg
  } catch (_error) {
    // On an error, render can leave its temporary container in document.body.
    globalThis.document?.getElementById(`d${id}`)?.remove()
    return null
  }
}

// What the hook shows for `text`, a block's source (source above), with the library
// `mermaid`: {svg} for a drawn diagram; else {line}, the data attribute of the sentence
// above the text: "notDrawn" for a block that the hook does not draw (draws above), and
// "failed" for one that does not parse.
export const drawing = async (mermaid, text) => {
  if (!draws(text)) return {line: "notDrawn"}
  const svg = await render(mermaid, text)
  return svg ? {svg} : {line: "failed"}
}

// Each diagram drawn in `el`, drawn again with the colours of the theme now; a diagram
// that does not draw stays as its image.
const redraw = async el => {
  const figures = [...el.querySelectorAll("figure.q-mermaid")]
  if (figures.length === 0) return

  let mermaid
  try {
    mermaid = await load(el.dataset.script)
  } catch (_error) {
    return
  }

  mermaid.initialize(settings(colours(el)))

  for (const figure of figures) {
    const img = figure.querySelector("img.q-mermaid-diagram")
    const pre = figure.querySelector("pre.q-mermaid-source")
    if (!figure.isConnected || !img || !pre) continue
    if (!draws(blockText(pre))) continue
    const svg = await render(mermaid, blockText(pre))
    if (svg) paint(img, svg)
  }
}

export const Mermaid = {
  mounted() {
    draw(this.el)
    this.stopTheme = watchTheme(document.documentElement, () => redraw(this.el))
  },
  updated() {
    draw(this.el)
  },
  destroyed() {
    this.stopTheme?.()
  },
}
