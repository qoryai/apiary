// The diagrams of an artifact's Document view. The hook element (phx-update="ignore")
// contains blocks <pre class="q-mermaid-source"><code>…</code></pre>; the hook draws each
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

const show = (el, pre, svg) => {
  const figure = document.createElement("figure")
  figure.className = "q-mermaid"
  const img = document.createElement("img")
  img.className = "q-mermaid-diagram"
  img.alt = el.dataset.alt ?? ""
  img.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(svg)
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

  mermaid.initialize({
    startOnLoad: false,
    securityLevel: "strict",
    theme: dark() ? "dark" : "default",
    fontFamily: "ui-sans-serif, system-ui, sans-serif",
  })

  for (const pre of blocks) {
    if (!pre.isConnected) continue
    const text = (pre.querySelector("code") ?? pre).textContent
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
