# Vendored browser libraries

Files here are copied from released packages, unmodified, and bundled by esbuild. Nothing is
loaded from a CDN at run time.

## xterm.js (`xterm/`)

The terminal of the run page. Bundled through the separate entry `assets/js/terminal.js`, so
only the terminal tab downloads it.

| File | Package | Version | From the tarball | sha256 of the file |
|---|---|---|---|---|
| `xterm/xterm.mjs` | `@xterm/xterm` | 6.0.0 | `package/lib/xterm.mjs` | `b336ec65a086c056d4804b3d4c2347da5663d3f23c3f25be866467bd8857ad59` |
| `xterm/xterm.css` | `@xterm/xterm` | 6.0.0 | `package/css/xterm.css` | `854a7c0fb70e8b1a083c16797ab827299fb18744f5ad34f227b48337e33293c6` |
| `xterm/addon-fit.mjs` | `@xterm/addon-fit` | 0.11.0 | `package/lib/addon-fit.mjs` | `2d87e1bddc73be9111de8beee5370c3bb7aac9c94e18e6f245f02ca741ef1769` |
| `xterm/addon-search.mjs` | `@xterm/addon-search` | 0.16.0 | `package/lib/addon-search.mjs` | `3ea90162233f867b938cd29b8ad98f589643436bbb5445bd11b825dc99ff0c04` |

Tarballs, from the npm registry:

- `https://registry.npmjs.org/@xterm/xterm/-/xterm-6.0.0.tgz`
  (sha256 `908e66e04af6c8dc6b00dd3b54de088e2e81e5ed866284fd6c2fb3c2d1c7a3f6`)
- `https://registry.npmjs.org/@xterm/addon-fit/-/addon-fit-0.11.0.tgz`
  (sha256 `26003b4517a132b64e4ff228fd88a5fda3fff5e606c76093f6dcff772e9ecec0`)
- `https://registry.npmjs.org/@xterm/addon-search/-/addon-search-0.16.0.tgz`
  (sha256 `e9d0795c72f4de749ed996ad7868f0738b44f37cee1e483be81977cefd7f4f81`)

Licence: MIT, for all three packages. `xterm/LICENSE` is the licence file of `@xterm/xterm`;
the add-ons carry the same text with "Copyright (c) 2019, The xterm.js authors" (fit) and
"Copyright (c) 2017, The xterm.js authors" (search).

The source maps the files name in their last line are not vendored.

To update: download the three tarballs with `curl`, copy the four files over these, and
replace the versions and checksums above.

## React Flow (`flow/`)

The canvas of Workspace settings › Stages: `@xyflow/react` with React and React DOM.
Bundled through the separate entry `assets/js/canvas.js`, so only the Stages page
downloads it. Core has no npm and no `package.json`: the `--alias` arguments in
`config/config.exs` point `react`, `react/jsx-runtime`, `react-dom`, `react-dom/client`
and `scheduler` straight at the production files below, in dev builds too. The build sets
no `process.env.NODE_ENV`, so a dev build of `app.js` and `terminal.js` keeps the code that
runs only in development, such as the live reload in `app.js`.

| File | Package | Version | From the tarball | sha256 of the file |
|---|---|---|---|---|
| `flow/xyflow-react/index.js` | `@xyflow/react` | 12.12.0 | `package/dist/umd/index.js` | `c418896c3d0cc63498e724df7ed9698532c58523c04d30ebcd3ff7fa0bf3ecff` |
| `flow/xyflow-react/style.css` | `@xyflow/react` | 12.12.0 | `package/dist/style.css` | `7ed5ae87a6c9bd664fce1802ce33fbe84faaefe33e21c82be35529df06e0c686` |
| `flow/xyflow-react/LICENSE` | `@xyflow/react` | 12.12.0 | `package/LICENSE` | `023119ac20fb1c8c9930abe0bcd196989a1960388529a96fc43cebf96f07c9ff` |
| `flow/xyflow-react/LICENSE-zustand` | `zustand` | 4.5.7 | `package/LICENSE` | `c1e6e266563517467b1bf874817d23e426f3149252bd7d42758cd697514b8417` |
| `flow/xyflow-react/LICENSE-classcat.md` | `classcat` | 5.0.5 | `package/LICENSE.md` | `f101c761d255d0dddc77dd8a9327733b03d381798ec54a1bb718367207b48a8e` |
| `flow/xyflow-react/LICENSE-d3` | `d3-dispatch` 3.0.1, `d3-drag` 3.0.0, `d3-interpolate` 3.0.1, `d3-selection` 3.0.0, `d3-timer` 3.0.1, `d3-transition` 3.0.1, `d3-zoom` 3.0.0 | | `package/LICENSE`, the same file in all seven | `e008c5e25a6be382593089c29bfabbc553c6378eee02895aec46ce396cc404ee` |
| `flow/xyflow-react/LICENSE-d3-color` | `d3-color` | 3.1.0 | `package/LICENSE` | `faa682e3e430941f958d26180458f5934a62f58dac4d70ccdd15608c15d0f884` |
| `flow/xyflow-react/LICENSE-d3-ease` | `d3-ease` | 3.0.1 | `package/LICENSE` | `b989d9085148d21ff64a75e14462aefa06b2589a55553b07b1460c70081c7d08` |
| `flow/react/cjs/react.production.js` | `react` | 19.3.1 | `package/cjs/react.production.js` | `0b5529981841afa1b58c76ba85c29bb681ff5f07cd8cde6a10b967d3915b8e1c` |
| `flow/react/cjs/react-jsx-runtime.production.js` | `react` | 19.3.1 | `package/cjs/react-jsx-runtime.production.js` | `1e46f15002696985e80c61d47aaa30dabb03c954270a690f5f7dfbbacfa9002b` |
| `flow/react/LICENSE` | `react` | 19.3.1 | `package/LICENSE` | `da6d3703ed11cbe42bd212c725957c98da23cbff1998c05fa4b3d976d1a58e93` |
| `flow/react-dom/cjs/react-dom.production.js` | `react-dom` | 19.3.1 | `package/cjs/react-dom.production.js` | `7a05d7f7bb2b02aae84018a88d4815a2181eef48d2cb8172d403eaa2b131eefd` |
| `flow/react-dom/cjs/react-dom-client.production.js` | `react-dom` | 19.3.1 | `package/cjs/react-dom-client.production.js` | `a319b413b7a19ee34422d9a12a8e7afd003c07846716d278ba1a0898e8cb6251` |
| `flow/react-dom/LICENSE` | `react-dom` | 19.3.1 | `package/LICENSE` | `da6d3703ed11cbe42bd212c725957c98da23cbff1998c05fa4b3d976d1a58e93` |
| `flow/scheduler/cjs/scheduler.production.js` | `scheduler` | 0.28.0 | `package/cjs/scheduler.production.js` | `679adff761d31e9426604f80c0e99be44a3e6f4c6834b0218ecf0312a67c171f` |
| `flow/scheduler/LICENSE` | `scheduler` | 0.28.0 | `package/LICENSE` | `da6d3703ed11cbe42bd212c725957c98da23cbff1998c05fa4b3d976d1a58e93` |

Tarballs, from the npm registry, each matching the registry's `dist.integrity`:

- `https://registry.npmjs.org/@xyflow/react/-/react-12.12.0.tgz`
  (sha256 `b61b1486935902dc9c2002395004591873733ba48276a63622ce62cb13833fac`)
- `https://registry.npmjs.org/react/-/react-19.3.1.tgz`
  (sha256 `56936913918dcf1f7a6fe58784e79df54b18200a88655ce809cf5e9c4ef871aa`)
- `https://registry.npmjs.org/react-dom/-/react-dom-19.3.1.tgz`
  (sha256 `8b49975821eec6311e00d2b3f4b8337923253c876517388a33f9839c61ab262e`)
- `https://registry.npmjs.org/scheduler/-/scheduler-0.28.0.tgz`
  (sha256 `302995d590e3c0a11eeb40d1d0f299c1df1800135d599d85cdd5faeb614f32d6`)

Licence: MIT, for all four packages; each folder has the licence file of its package.
The UMD build of `@xyflow/react` contains the packages it depends on, and
`flow/xyflow-react/` has a licence file for each: `@xyflow/system` 0.0.83 (MIT, the same
text as `LICENSE`), `zustand` and `classcat` (MIT), and nine d3 modules (ISC; `d3-ease`
also BSD-3-Clause, for its easing functions by Robert Penner). The versions are the newest
that the ranges in `@xyflow/react` 12.12.0 and `@xyflow/system` 0.0.83 allow, on
2026-10-31; each tarball matches the registry's `dist.integrity`. The development files
of React and the package entry files that choose between them are not vendored.

To update: download the four tarballs with `curl`, check each against `dist.integrity`
in the registry's metadata, copy the files over these, and replace the versions and
checksums above.

## Others

`heroicons.js` and `topbar.js` came with the Phoenix generator; their headers say what they are.
