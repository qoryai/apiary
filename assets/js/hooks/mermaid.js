// The diagrams of an artifact's Document view and of a proposal on the work item page.
// The hook element (phx-update="ignore") contains blocks
// <pre class="q-mermaid-source"><code>…</code></pre>; the hook draws each
// block with Mermaid and shows the result as an <img> of the SVG, so no markup from the
// diagram enters the page and no script in it runs. The block's source moves into a
// <details> under the image. A block that does not parse stays as text, with the sentence
// from data-failed above it.
//
// Attributes of the hook element, translated on the server: data-script (the bundle URL),
// data-alt (the images' alt text), data-source (the label of the source's <details>) and
// data-failed. Nothing here assigns innerHTML: every element is built with createElement
// and every text is set through textContent.
//
// Mermaid is vendored (assets/vendor/mermaid) and built as a separate bundle; it is loaded
// on the first mount of this hook and by no other page.
//
// The settings (settings below): securityLevel "strict", htmlLabels false, at most 20,000
// characters and 200 edges, and the theme "base" with the app's colours, read from its
// CSS variables. A document can change Mermaid's settings in two ways, a directive
// (%%{init: …}%%) and a front matter config: block (--- … --- at its start). The hook
// drops both before a block is drawn, with its click, link, links and callback lines
// (source below). Every setting that changes HTML, CSS or links is also in Mermaid's
// secure list (secure below), which Mermaid removes, at every depth, from what a
// document sets. So a document cannot change these settings or add links.
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

const dark = () => {
  const theme = document.documentElement.dataset.theme
  return theme === "dark" || (theme !== "light" && matchMedia("(prefers-color-scheme: dark)").matches)
}

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
]

// What the hook passes to mermaid.initialize, with the theme's colours `themeVariables`.
export const settings = themeVariables => ({
  startOnLoad: false,
  securityLevel: "strict",
  secure,
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

const show = (el, pre, svg) => {
  const figure = document.createElement("figure")
  figure.className = "q-mermaid"
  const img = document.createElement("img")
  img.className = "q-mermaid-diagram"
  img.alt = el.dataset.alt ?? ""
  img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg)
  const pixels = width(svg)
  if (pixels) img.width = pixels
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
    const id = `q-mermaid-${++count}`
    try {
      const {svg} = await mermaid.render(id, text)
      show(el, pre, svg)
    } catch (_error) {
      // On an error, render can leave its temporary container in document.body.
      document.getElementById(`d${id}`)?.remove()
      fail(el, pre)
    }
  }
}

export const Mermaid = {
  mounted() {
    draw(this.el)
  },
  updated() {
    draw(this.el)
  },
}
