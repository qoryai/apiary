// The Speed row under a film's player (`ArtifactComponents.view/1` for a video type): a
// click on a button plays the film in the same `<figure>` at the button's `data-rate`, and
// the button of the rate the film plays at is pressed (`aria-pressed`). A rate chosen in
// the browser's player menu presses its button too, or none for a rate the row lacks.
//
// The row is `phx-update="ignore"`, so a patch of the page keeps the pressed button. The
// rate is not stored: every page load plays the film at 1x.

// Plays `video` at `rate`; the default rate too, so a reload of the source keeps it.
export function setRate(video, rate) {
  video.defaultPlaybackRate = rate
  video.playbackRate = rate
}

// Presses the button whose `data-rate` is `current`, and no other.
export function mark(buttons, current) {
  for (const button of buttons) {
    button.setAttribute("aria-pressed", String(Number(button.dataset.rate) === current))
  }
}

export const VideoSpeed = {
  mounted() {
    this.video = this.el.closest("figure")?.querySelector("video")
    if (!this.video) return
    const buttons = [...this.el.querySelectorAll("button[data-rate]")]
    this.mark = () => mark(buttons, this.video.playbackRate)

    this.el.addEventListener("click", e => {
      const button = e.target.closest("button[data-rate]")
      if (!button) return
      setRate(this.video, Number(button.dataset.rate))
      this.mark()
    })
    this.video.addEventListener("ratechange", this.mark)
    this.mark()
  },

  destroyed() {
    if (this.video) this.video.removeEventListener("ratechange", this.mark)
  },
}
