// Copies `data-copy` (or the text content of the element `data-copy-target`
// points at, or the body the same-origin address `data-copy-url` answers) to the
// clipboard, flips the button into its "Copied" state for 1600 ms and announces it
// politely: in its own live span, or, for a row's copy, which has none, in the shell's
// one announcer (`#copy-announcer`). A copy of an address that fails announces
// `data-failed-words` instead, and copies nothing.
export const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const live = this.el.querySelector("[aria-live]") || document.getElementById("copy-announcer")
      if (this.el.dataset.copyUrl) {
        if (await copyAnswer(this.el.dataset.copyUrl)) {
          this.copied(live)
        } else if (live) {
          live.textContent = this.el.dataset.failedWords || ""
        }
        return
      }
      const target = this.el.dataset.copyTarget
      const text = target
        ? (document.querySelector(target)?.textContent ?? "")
        : (this.el.dataset.copy ?? "")
      try {
        await navigator.clipboard.writeText(text)
      } catch (_err) {
        const area = document.createElement("textarea")
        area.value = text
        area.setAttribute("readonly", "")
        area.style.position = "absolute"
        area.style.left = "-9999px"
        document.body.appendChild(area)
        area.select()
        document.execCommand("copy")
        area.remove()
      }
      this.copied(live)
    })
  },
  copied(live) {
    this.el.setAttribute("data-copied", "")
    if (live) live.textContent = this.el.dataset.copiedWords || ""
    clearTimeout(this.timer)
    this.timer = setTimeout(() => {
      this.el.removeAttribute("data-copied")
      if (live) live.textContent = ""
    }, 1600)
  },
  destroyed() {
    clearTimeout(this.timer)
  },
}

// The body `url` answers, copied as text: through a ClipboardItem whose text is still
// arriving where the browser has one, so the copy keeps the click's permission while
// the answer is read; else once it has arrived. True once copied.
async function copyAnswer(url) {
  const body = fetch(url, {credentials: "same-origin", headers: {accept: "application/json"}})
    .then((answer) => {
      if (!answer.ok) throw new Error(`status ${answer.status}`)
      return answer.text()
    })
  try {
    if (window.ClipboardItem && navigator.clipboard?.write) {
      const blob = body.then((text) => new Blob([text], {type: "text/plain"}))
      await navigator.clipboard.write([new ClipboardItem({"text/plain": blob})])
    } else {
      await navigator.clipboard.writeText(await body)
    }
    return true
  } catch (_err) {
    return false
  }
}
