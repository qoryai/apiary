// One item of the Scenarios queue on a version page (`ApiaryWeb.ArtifactLive.Show`): a
// film's item has a muted thumbnail, the film's first frame, and no length is stored, so the
// browser reads it. When the thumbnail's metadata loads, the item's `[data-length]` line,
// whose attribute is "Demo video · %{length}", reads "Demo video · 0:10". A patch of the
// page puts the server's text back, so the hook writes the length again after each patch.

// The length in seconds as "m:ss", nil for a length the browser does not give.
export function formatLength(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return null
  const whole = Math.floor(seconds)
  return `${Math.floor(whole / 60)}:${String(whole % 60).padStart(2, "0")}`
}

export const QueueMedia = {
  mounted() {
    this.length = null
    this.video = this.el.querySelector("video")
    if (!this.video) return
    this.video.muted = true
    this.read = () => {
      this.length = formatLength(this.video.duration)
      this.write()
    }
    this.video.addEventListener("loadedmetadata", this.read)
    if (this.video.readyState >= 1) this.read()
  },

  updated() {
    this.write()
  },

  write() {
    const line = this.el.querySelector("[data-length]")
    if (line && this.length) line.textContent = line.dataset.length.replace("%{length}", this.length)
  },

  destroyed() {
    this.video?.removeEventListener("loadedmetadata", this.read)
  },
}
