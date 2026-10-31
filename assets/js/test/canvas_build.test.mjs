// The esbuild line in config/config.exs that bundles the Stages canvas: React reaches
// the bundle through aliases to the vendored production files, with no --define, so dev
// builds of app.js and terminal.js keep their development code (the live reload).
// `node --test 'assets/js/test/*.test.mjs'` (no npm).

import {test} from "node:test"
import assert from "node:assert/strict"
import {existsSync, readFileSync} from "node:fs"
import {fileURLToPath} from "node:url"

const assets = fileURLToPath(new URL("../../", import.meta.url))
const config = readFileSync(new URL("../../../config/config.exs", import.meta.url), "utf8")
const args = config.match(/apiary: \[\s*args:\s*~w\(([^)]*)\)/)[1].split(/\s+/)

const aliases = Object.fromEntries(
  args.filter(a => a.startsWith("--alias:")).map(a => a.slice("--alias:".length).split("=")),
)

test("the build defines nothing, so app.js and terminal.js build as before", () => {
  assert.deepEqual(args.filter(a => a.startsWith("--define")), [])
  assert.ok(args.includes("js/canvas.js"))
})

test("each React package goes to a vendored production file", () => {
  for (const name of ["react", "react/jsx-runtime", "react-dom", "react-dom/client", "scheduler"]) {
    const path = aliases[name]
    assert.match(path, /^\.\/vendor\/flow\/.+\.production\.js$/, name)
    assert.ok(existsSync(assets + path), path)
  }
})

test("no vendored file reads process.env, so none needs a define", () => {
  for (const path of [...Object.values(aliases).filter(p => p.includes("/flow/")), "./vendor/flow/xyflow-react/index.js"]) {
    assert.doesNotMatch(readFileSync(assets + path, "utf8"), /process\.env/, path)
  }
})
