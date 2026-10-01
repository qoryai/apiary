// Whether the single-key shortcuts are on: a reading preference of the browser, set in
// Preferences (Keyboard shortcuts) and written on <html> as `data-shortcuts="off"` before
// the first paint by the root layout's script. Shortcuts with ⌘ or Ctrl, such as ⌘K, do
// not ask: they are never typed by accident or by a speech-input user dictating words.
export const singleKeys = () => document.documentElement.getAttribute("data-shortcuts") !== "off"
