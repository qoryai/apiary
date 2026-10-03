// A native <dialog> shown as a modal while it is in the page. Escape and the
// backdrop run the `data-cancel` JS command (a patch back to the index); a
// dialog without one cannot be dismissed.
export const Modal = {
  mounted() {
    this.trigger = document.activeElement
    this.el.addEventListener("cancel", e => {
      e.preventDefault()
      this.cancel()
    })
    // The backdrop is a form[method=dialog]; the server closes the dialog.
    this.el.addEventListener("submit", e => {
      if (e.target.method === "dialog") {
        e.preventDefault()
        this.cancel()
      }
    })
    // Chrome lets a second Escape through: the server decides when it closes.
    this.el.addEventListener("close", () => this.el.isConnected && this.el.showModal())
    if (!this.el.open) this.el.showModal()
    this.nameWindow()
    this.focusFirst()
    // The dialog may still be becoming visible on a fresh page load.
    setTimeout(() => this.el.contains(document.activeElement) && document.activeElement !== this.el || this.focusFirst(), 80)
  },
  focusFirst() {
    const first =
      this.el.querySelector("[data-autofocus]") ||
      this.el.querySelector(".modal-body input:not([type=hidden]), .modal-body select, .modal-body textarea") ||
      this.el.querySelector(".modal-action [data-cancel-button]") ||
      this.el.querySelector(".modal-action .btn-primary")
    first?.focus()
  },
  updated() {
    if (!this.el.open) this.el.showModal()
  },
  // The dialog has a path of its own, so the window's title names it before the page's
  // ("New access key · Access keys · …"), and gets the page's back when it closes.
  nameWindow() {
    const heading = document.getElementById(this.el.getAttribute("aria-labelledby"))
    const name = heading?.textContent.trim()
    if (!name) return
    this.pageTitle = document.title
    this.ownTitle = `${name} · ${document.title}`
    document.title = this.ownTitle
  },
  cancel() {
    const js = this.el.dataset.cancel
    if (js) this.liveSocket.execJS(this.el, js)
  },
  destroyed() {
    if (this.ownTitle && document.title === this.ownTitle) document.title = this.pageTitle
    if (this.trigger?.isConnected) this.trigger.focus({preventScroll: true})
  },
}
