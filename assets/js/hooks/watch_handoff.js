// The Watch link of a film on the Verify tab (`ApiaryWeb.WorkItemLive.VerifyTab`): a click
// stores where the small player is, so the film's player page (`artifact_player.js`) opens
// at the same time and speed. The note is `{version, time, rate}` in `sessionStorage`: the
// version is the film's public id, the time in seconds, the rate the film plays at. The
// player page applies it and deletes it, so it is used once, by the next page only. The
// film is not started.
import {setRate} from "./video_speed.js"

export const HANDOFF_KEY = "qory:watch-handoff"

// The storage of the tab, nil where the browser has none or refuses it.
function session() {
  try {
    return globalThis.sessionStorage ?? null
  } catch {
    return null
  }
}

// Stores the note for the film `version`, where `video` is.
export function storeHandoff(storage, version, video) {
  try {
    storage?.setItem(
      HANDOFF_KEY,
      JSON.stringify({version, time: video.currentTime, rate: video.playbackRate}),
    )
  } catch {
    // A full or refused storage: the page opens at 0:00 and 1x.
  }
}

// The note for the film `version`, deleted whether it is for that film or not; nil for
// none, for another film, and for a note that is not a time and a rate.
export function takeHandoff(storage, version) {
  let note = null
  try {
    note = JSON.parse(storage?.getItem(HANDOFF_KEY) ?? "null")
    storage?.removeItem(HANDOFF_KEY)
  } catch {
    return null
  }
  if (!note || note.version !== version) return null
  if (!Number.isFinite(note.time) || note.time < 0) return null
  if (!Number.isFinite(note.rate) || note.rate <= 0) return null
  return {time: note.time, rate: note.rate}
}

// Opens `video` at the note's time and rate, once its length is known; it does not play.
export function applyHandoff(video, {time, rate}) {
  setRate(video, rate)
  if (video.readyState >= 1) {
    video.currentTime = time
  } else {
    video.addEventListener("loadedmetadata", () => (video.currentTime = time), {once: true})
  }
}

export const WatchHandoff = {
  mounted() {
    this.onClick = () => {
      const video = this.el.closest("figure")?.querySelector("video")
      if (video) storeHandoff(session(), this.el.dataset.version, video)
    }
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
}
