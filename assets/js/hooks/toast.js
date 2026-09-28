// Info toasts leave after 5 s; hovering or focusing one holds it.
export const autoDismiss = (el, dismiss) => {
  let timer
  const start = () => {
    clearTimeout(timer)
    timer = setTimeout(dismiss, 5000)
  }
  const hold = () => clearTimeout(timer)
  el.addEventListener("mouseenter", hold)
  el.addEventListener("focusin", hold)
  el.addEventListener("mouseleave", start)
  el.addEventListener("focusout", start)
  start()
  return hold
}

export const Toast = {
  mounted() {
    this.stop = autoDismiss(this.el, () => this.liveSocket.execJS(this.el, this.el.dataset.dismiss))
  },
  updated() {
    this.stop()
    this.mounted()
  },
  destroyed() {
    this.stop()
  },
}
