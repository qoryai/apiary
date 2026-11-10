// The confirmation before an action that spends (ApiaryWeb.SpendDialog), a native
// <dialog>. Mounted, it opens modal, so the page under it is inert and Tab stays in it,
// and focus goes to the element whose id is in data-focus, else to Cancel: an Enter held
// down from the action's button then lands on Cancel, not on the confirm button. Escape
// sends the dialog's cancel event through phx-window-keydown, so the close that the
// browser makes on Escape is prevented: the server removes the dialog. Before that
// cancel, the field with focus loses it, so a change LiveView holds back for its
// phx-debounce is sent first. Once the dialog is removed, the hook moves focus back to
// the action's button (data-return), else to what had focus before it opened.

// open/2 opens `dialog` modal and focuses the element whose id is in data-focus; it returns
// the element to give focus back to when the dialog closes. `frame/1` always renders
// data-focus, set to Cancel's id unless `focus` is set, so the fallback to Cancel
// (`<id>-cancel`) covers only a data-focus id that is not on the page.
export const open = (dialog, doc) => {
  const back = (dialog.dataset.return && doc.getElementById(dialog.dataset.return)) || doc.activeElement
  if (!dialog.open) dialog.showModal()
  const first = dialog.dataset.focus && doc.getElementById(dialog.dataset.focus)
  ;(first || doc.getElementById(`${dialog.id}-cancel`))?.focus()
  return back
}

// keep/1 stops the browser's close on Escape; phx-window-keydown sends the cancel.
export const keep = e => e.preventDefault()

// flush/2 takes the focus from the field in `dialog` that has it, on Escape: LiveView then
// sends the field's held-back change, before the cancel that phx-window-keydown sends.
export const flush = (e, dialog, doc) => {
  const field = doc.activeElement
  if (e.key === "Escape" && field && field !== dialog && dialog.contains(field)) field.blur()
}

// giveBack/2 focuses `back`, where it is still on the page.
export const giveBack = (back, doc) => {
  if (back && doc.contains(back)) back.focus()
}

export const SpendDialog = {
  mounted() {
    this.back = open(this.el, document)
    this.el.addEventListener("cancel", keep)
    this.el.addEventListener("keydown", e => flush(e, this.el, document))
  },

  destroyed() {
    // Looked up again: the server may have drawn the action's button anew.
    const back = (this.el.dataset.return && document.getElementById(this.el.dataset.return)) || this.back
    giveBack(back, document)
  },
}
