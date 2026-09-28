// The terminal bundle: xterm.js and its fit and search add-ons, vendored under
// assets/vendor/xterm (see assets/vendor/README.md). A separate esbuild entry, so only the
// terminal tab of a run downloads it: the Terminal hook adds this script and the
// stylesheet esbuild writes beside it (terminal.css) on first mount.
import {Terminal} from "../vendor/xterm/xterm.mjs"
import {FitAddon} from "../vendor/xterm/addon-fit.mjs"
import {SearchAddon} from "../vendor/xterm/addon-search.mjs"
import "../vendor/xterm/xterm.css"

window.QoryTerminal = {Terminal, FitAddon, SearchAddon}
