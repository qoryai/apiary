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

## Mermaid (`mermaid/`)

The diagrams of an artifact's Document view. Bundled through the separate entry
`assets/js/mermaid.js`, so only artifact pages download it.

The files are Mermaid's ES module build: `mermaid.esm.min.mjs` and the 103 modules it
imports from `chunks/mermaid.esm.min/`. esbuild bundles them into one file. The package's
single-file build, `dist/mermaid.min.js`, is not used: it declares a top-level `var` and then
reads it back from `globalThis`, which fails once esbuild wraps the file in a module scope.

| File | Package | Version | From the tarball | sha256 of the file |
|---|---|---|---|---|
| `mermaid/mermaid.esm.min.mjs` | `mermaid` | 11.17.2 | `package/dist/mermaid.esm.min.mjs` | `462d6f73fc9833044bca6dc08e62e0ee83f5a2b09583f588f95d5fd91b1960ed` |
| `mermaid/chunks/mermaid.esm.min/*.mjs` (103 files) | `mermaid` | 11.17.2 | `package/dist/chunks/mermaid.esm.min/*.mjs` | see below |
| `mermaid/LICENSE` | `mermaid` | 11.17.2 | `package/LICENSE` | `ec9fb67dcb25eccc416ed56e1aab819222c805a2a4bfe4cb19e7556bf2ffde80` |

The 104 module files have one combined checksum,
`821b16a5cfcfe38973846fe1064198701b8db5f6a2afc8b5608c747300ec1b04`. Check it from
`assets/vendor/mermaid/`:

```sh
shasum -a 256 mermaid.esm.min.mjs chunks/mermaid.esm.min/*.mjs | LC_ALL=C sort | shasum -a 256
```

Tarball, from the npm registry:

- `https://registry.npmjs.org/mermaid/-/mermaid-11.17.2.tgz`
  (sha256 `6ad2f42c3fc26bbf9e45cbb6d11898972573ea52b33a5f4ff51952899f950ffd`)

Licence: MIT.

The source maps (`*.map`) beside the files in the tarball are not vendored.

To update: download the tarball with `curl` and check it against `dist.integrity` in the
registry. Delete `mermaid/chunks/` (the chunk names change with each release), then copy
`package/dist/mermaid.esm.min.mjs`, the `.mjs` files of `package/dist/chunks/mermaid.esm.min/`
and `package/LICENSE`. Replace the version and checksums above.

## Others

`heroicons.js` and `topbar.js` came with the Phoenix generator; their headers say what they are.
