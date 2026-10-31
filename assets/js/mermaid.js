// The diagram bundle: Mermaid, vendored under assets/vendor/mermaid (see
// assets/vendor/README.md). A separate esbuild entry, so only an artifact's Document view
// downloads it: the Mermaid hook adds this script on first mount.
import mermaid from "../vendor/mermaid/mermaid.esm.min.mjs"

window.QoryMermaid = mermaid
