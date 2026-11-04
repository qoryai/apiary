// The diagrams of an artifact's Document view and of a proposal on the work item page.
// The hook element (phx-update="ignore") contains blocks
// <pre class="q-mermaid-source"><code>…</code></pre>; the hook draws each
// block with Mermaid and shows the result as an <img> of the SVG. Mermaid draws in a
// temporary element of the page, which it removes after the draw; the hook keeps what it
// puts there free of script, of elements and attributes that load an address or link,
// and of a document's styles and classes (the settings and checks below). After the
// draw, the page has only the <img>, which runs no script. The block's source moves into a
// <details> under the image. A block that does not parse stays as text, with the sentence
// from data-failed above it.
//
// Attributes of the hook element, translated on the server: data-script (the bundle URL),
// data-alt (the images' alt text), data-source (the label of the source's <details>) and
// data-failed. Nothing here assigns innerHTML: every element is built with createElement
// and every text is set through textContent.
//
// Mermaid is vendored (assets/vendor/mermaid) and built as a separate bundle
// (/assets/js/mermaid.js), not part of app.js. The hook adds its <script> the first time
// it finds a Mermaid block to draw, so a page with no diagram never loads it.
//
// The settings (settings below): securityLevel "strict", htmlLabels false, at most 20,000
// characters and 200 edges, and the theme "base" with the app's colours, read from its
// CSS variables. A document can change Mermaid's settings in two ways, a directive
// (%%{init: …}%%) and a front matter config: block (--- … --- at its start). The hook
// drops both before a block is drawn, with its click, link, links and callback lines
// (source below). Every setting that changes HTML, CSS or links is also in Mermaid's
// secure list (secure below), which Mermaid removes, at every depth, from what a
// document sets. So a document cannot change these settings or add links.
// A text that Mermaid puts into the page as HTML, such as an eventmodeling field or a
// sequence message with $$…$$, goes through Mermaid's sanitizer with the hook's
// dompurifyConfig (below): no element or attribute in it loads an address, links or
// styles the page. A block with a syntax that makes Mermaid load an address itself
// (loads below) is not drawn: it stays as text, with the sentence from data-failed.
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
// then each setting that changes the HTML, the CSS or the links of a drawing.
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
]

// What Mermaid's sanitizer (DOMPurify) removes from each text it puts into the page as
// HTML, such as an eventmodeling field or a sequence message with $$…$$: each element
// that loads an address or links, and the attributes style, class, id and those with an
// address, so a text cannot load, link, style the page or take an id of it while the
// diagram draws. Mermaid applies this site setting, which a document cannot change
// (secure above), to every text it sanitizes. It removes only what a document wrote:
// the markup Mermaid adds around a text, such as a label's <div style>, stays.
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

// What the hook passes to mermaid.initialize, with the theme's colours `themeVariables`.
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
  fontFamily: font,
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

// The text of a block as Mermaid draws it: without each line that contains a directive
// (%%{ … }%%, such as %%{init: …}%%), without each line with a click, link, links or
// callback statement, at its start or after a ";", and without a front matter block at
// its start, looked for after the other lines are dropped.
export const source = text =>
  withoutFrontMatter(
    text
      .split(/\r\n|\r|\n/)
      .filter(
        line => !line.includes("%%{") && !/(^|;)\s*(click|links?|callback)(\s|$)/i.test(line),
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

// Whether drawing `text` would load an address, by the syntaxes of the vendored Mermaid
// 11.17.2 that do: CSS with an address, in any style, classDef, linkStyle or C4 style
// (cssAddresses above); a flowchart node's image (A@{ img: "…" }), which Mermaid loads as
// an Image and draws as <image href>, so a node's data (@{) with "img", or with a
// backslash, which its YAML could use to write "img"; and a sequence diagram's
// properties line, whose "icon" Mermaid draws as <image xlink:href>.
export const loads = text => {
  const written = text.toLowerCase()
  const read = unescaped(text).toLowerCase()
  if (cssAddresses.some(css => written.includes(css) || read.includes(css))) return true
  const data = text.indexOf("@{")
  if (data !== -1 && (/img/i.test(text) || text.slice(data).includes("\\"))) return true
  return /(^|;)\s*properties(\s|$)/im.test(text)
}

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

const fail = (el, pre) => {
  const p = document.createElement("p")
  p.className = "q-mermaid-failed"
  p.textContent = el.dataset.failed ?? ""
  pre.before(p)
}

const draw = async el => {
  const blocks = [...el.querySelectorAll("pre.q-mermaid-source")].filter(pre => !handled.has(pre))
  if (blocks.length === 0) return
  blocks.forEach(pre => handled.add(pre))

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
    const text = source((pre.querySelector("code") ?? pre).textContent)
    if (loads(text)) {
      fail(el, pre)
      continue
    }
    const svg = await render(mermaid, text)
    if (svg) show(el, pre, svg)
    else fail(el, pre)
  }
}

// The SVG of `text`, or null where it does not parse.
const render = async (mermaid, text) => {
  const id = `q-mermaid-${++count}`
  try {
    return (await mermaid.render(id, text)).svg
  } catch (_error) {
    // On an error, render can leave its temporary container in document.body.
    document.getElementById(`d${id}`)?.remove()
    return null
  }
}

// Each diagram drawn in `el`, drawn again with the colours of the theme now; a diagram
// that does not draw keeps its image.
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
    const text = source((pre.querySelector("code") ?? pre).textContent)
    if (loads(text)) continue
    const svg = await render(mermaid, text)
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
