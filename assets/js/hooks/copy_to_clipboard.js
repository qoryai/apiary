// Copies `data-copy` (or the text content of the element `data-copy-target`
// points at, or the body the same-origin address `data-copy-url` answers) to the
// clipboard, flips the button into its "Copied" state for 1600 ms and announces it
// politely: in the status element `data-status` points at, else in its own live span,
// or, for a row's copy, which has none, in the shell's one announcer
// (`#copy-announcer`). A copy of an address that fails copies nothing and writes the
// line for its cause there instead, kept until the next click: `data-failed-network` when no answer came,
// `data-failed-gone` for 404, `data-failed-signed-out` for a redirect (to the log-in
// page), 401 or 403, `data-failed-server` for any other error status, and
// `data-failed-clipboard` when the browser did not allow the copy.
export const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
      const live =
        (this.el.dataset.status && document.querySelector(this.el.dataset.status)) ||
        this.el.querySelector("[aria-live]") ||
        document.getElementById("copy-announcer")
      if (this.el.dataset.copyUrl) {
        clearTimeout(this.timer)
        if (live) live.textContent = ""
        const failure = await copyAnswer(this.el.dataset.copyUrl)
        if (!failure) {
          this.copied(live)
        } else if (live) {
          live.textContent = this.el.dataset[failure] || ""
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
// the answer is read; else once it has arrived. Null once copied, else the dataset key
// of the line for why it failed.
async function copyAnswer(url) {
  let failure = null
  // No accept header: the route is in the browser pipeline, which takes HTML and `*/*`,
  // what fetch sends, and refuses `application/json` (406).
  const body = fetch(url, {credentials: "same-origin"})
    .catch((err) => {
      failure = "failedNetwork"
      throw err
    })
    .then((answer) => {
      if (answer.ok && !answer.redirected) return answer.text()
      // A signed-out reader is sent to the log-in page: its HTML is no answer to copy.
      if (answer.redirected || answer.status === 401 || answer.status === 403) {
        failure = "failedSignedOut"
      } else if (answer.status === 404) {
        failure = "failedGone"
      } else {
        failure = "failedServer"
      }
      throw new Error(`status ${answer.status}`)
    })
  try {
    if (window.ClipboardItem && navigator.clipboard?.write) {
      const blob = body.then((text) => new Blob([text], {type: "text/plain"}))
      await navigator.clipboard.write([new ClipboardItem({"text/plain": blob})])
    } else {
      await navigator.clipboard.writeText(await body)
    }
    return null
  } catch (_err) {
    // The answer may still be arriving when the browser refuses the copy: wait for it,
    // so that a failed answer is told rather than the refusal.
    await body.catch(() => {})
    return failure || "failedClipboard"
  }
}
