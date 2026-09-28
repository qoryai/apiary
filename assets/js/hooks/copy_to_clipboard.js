// Copies `data-copy` (or the text content of the element `data-copy-target`
// points at) to the clipboard, flips the button into its "Copied" state for
// 1600 ms and announces it politely.
export const CopyToClipboard = {
  mounted() {
    this.el.addEventListener("click", async () => {
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
      this.el.setAttribute("data-copied", "")
      const live = this.el.querySelector("[aria-live]")
      if (live) live.textContent = this.el.dataset.copiedWords || ""
      clearTimeout(this.timer)
      this.timer = setTimeout(() => {
        this.el.removeAttribute("data-copied")
        if (live) live.textContent = ""
      }, 1600)
    })
  },
  destroyed() {
    clearTimeout(this.timer)
  },
}
