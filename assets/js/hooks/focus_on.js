// Moves focus to its element when the server says so ("run:focus" with the element's id):
// after an action removed the control that had focus, so that focus does not fall to the
// body. The element carries tabindex="-1".

export const FocusOn = {
  mounted() {
    this.handleEvent("run:focus", ({id}) => {
      if (id === this.el.id) requestAnimationFrame(() => this.el.focus({preventScroll: false}))
    })
  },
}
