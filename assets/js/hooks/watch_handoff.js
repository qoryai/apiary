// The Watch link of a film on the Verify tab (`ApiaryWeb.WorkItemLive.VerifyTab`): a click
// stores where the small player is, so the film's player page (`artifact_player.js`) opens
// at the same time and speed. The note is `{version, index, time, rate}` in
// `sessionStorage`: the version is the film's public id, the index the film's place among
// the films of the version (from 0), the time in seconds, the rate the film plays at. The
// player page applies it to the film with that index and deletes it, so it is used once, by
// the next page only. The film is not started.
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

// Whether `event` is a click that opens the link in this tab: the main button, no modifier
// key, and no handler has taken it over. A click that opens a new tab or window, or saves
// the link, leaves the film's page for the browser to open and stores nothing.
export function plainClick(event) {
  return (
    event.button === 0 &&
    !event.ctrlKey &&
    !event.metaKey &&
    !event.shiftKey &&
    !event.altKey &&
    !event.defaultPrevented
  )
}

// Stores the note for film number `index` (from 0) of the version `version`, where `video`
// is: a version may have several films, and the player page controls the first.
export function storeHandoff(storage, version, index, video) {
  try {
    storage?.setItem(
      HANDOFF_KEY,
      JSON.stringify({version, index, time: video.currentTime, rate: video.playbackRate}),
    )
  } catch {
    // A full or refused storage: the page opens at 0:00 and 1x.
  }
}

// The note for film number `index` of the version `version`, deleted whether it is for that
// film or not, and whether it can be read or not; nil for none, for another film, and for a
// note that is not a time and a rate.
export function takeHandoff(storage, version, index) {
  let raw = null
  try {
    raw = storage?.getItem(HANDOFF_KEY) ?? null
  } catch {
    return null
  }
  try {
    storage?.removeItem(HANDOFF_KEY)
  } catch {
    // A refused storage keeps the note; the next page reads it again.
  }
  let note = null
  try {
    note = JSON.parse(raw ?? "null")
  } catch {
    return null
  }
  if (!note || note.version !== version || note.index !== index) return null
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
    this.onClick = event => {
      if (!plainClick(event)) return
      const video = this.el.closest("figure")?.querySelector("video")
      if (video) storeHandoff(session(), this.el.dataset.version, Number(this.el.dataset.film), video)
    }
    this.el.addEventListener("click", this.onClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.onClick)
  },
}
