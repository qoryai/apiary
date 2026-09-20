# Qory console: design brief

Implementation spec for the Qory control plane console (the application whose Elixir modules are
named `Apiary`). Milestone: accounts, the apiary and its hive, members, access keys. The rendered
reference is `qory-style-guide.html` beside this file; where the two disagree, this brief wins.

Naming. The product and brand are **Qory**. The wordmark, `<title>`, emails and auth pages say
"Qory". Inside the product an organisation is an **apiary** and a workplace a **hive**; each shows its
standard term on hover. Module names (`Apiary`, `ApiaryWeb`) do not change. British spelling
everywhere. Sample data is synthetic only: Acme, Platform, build-01, `build-01.example.com`,
`beekeeper@example.com`, `dana@example.com`.

Stack. Phoenix LiveView 1.2, Tailwind CSS v4, daisyUI 5 as a Tailwind plugin with two custom
themes, heroicons, small LiveView hooks only. No external font, script or style loads.

---

## a. Principles

1. **Calm density.** 14 px body, 32 px controls, 40 px table rows. Much on screen, nothing shouting.
   If a screen feels busy, remove borders and colour before removing information.
2. **One drop of honey.** `primary` marks the single main action of a screen, the checked state of
   a checkbox, the current step and the mark. Nothing else is honey. Links and active nav icons use
   `accent` (a darker honey that passes contrast as text). Status colours are semantic, never
   decorative.
3. **Borders on the page, shadows in the air.** Everything resting on the page is drawn with a 1 px
   border and at most `shadow-xs`. Only things that float (menus, toasts, tooltips, modals, the
   drawer) get a real shadow.
4. **Honest states.** An empty page says what is missing and offers the one next step. A key that
   never posted says "Never posted". A page that waits says it is listening. No fake data, no
   placeholder navigation for features that do not exist yet.
5. **Words are the interface.** A button says what happens ("Send me a log-in link"). A toast says
   what happened ("build-01 is revoked."). A confirm states the consequence, then whether it can be
   undone.
6. **Dark is a first-class theme,** designed on its own: the sidebar is darker than the content,
   borders replace shadows, the soft fills are re-tuned rather than inverted.
7. **Vocabulary without theatre.** "apiary" and "hive" appear as ordinary nouns with a dotted
   underline and the standard term on hover. No bee puns, no mascots, no points, badges or streaks.
8. **Quiet motion.** Motion confirms cause and effect for floating things and nothing else. Layout
   never animates.

---

## b. Identity

### The mark

One cell of comb, its counter cut out, with a tail crossing the lower-right wall: a hexagon that
reads as a Q. Pointy-top regular hexagon, centre (16,16), circumradius 13.8; counter is the same
hexagon at radius 6.2; the tail is a 3 × 12.4 rectangle along 60° from horizontal, starting inside
the counter and ending just outside the wall.

```html
<svg viewBox="0 0 32 32" aria-hidden="true" class="size-[22px] shrink-0">
  <path fill="var(--color-primary)" fill-rule="evenodd"
    d="M16 2.2 27.95 9.1v13.8L16 29.8 4.05 22.9V9.1L16 2.2Zm0 7.6-5.37 3.1v6.2L16 22.2l5.37-3.1v-6.2L16 9.8Z"/>
  <path fill="var(--color-base-content)" d="m17.35 17.1 2.6-1.5 6.2 10.74-2.6 1.5z"/>
</svg>
```

- Body takes `primary`, tail takes `base-content`, so the mark is correct in both themes with no
  variant. Mono variant (emails in plain clients, print): both paths `currentColor`.
- Sizes: 16 favicon, 22 sidebar and mobile bar, 28 auth panel, 48 email header. Never below 16.
- Clear space: half the mark's width on every side. Never rotate, outline, add a gradient or a
  drop shadow.
- Favicon: the same SVG as `priv/static/favicon.svg` with literal fills `#eea82f` and `#1c1713`,
  plus a 32 px PNG fallback. Replace the current `logo_mark/1` (two nested hexagons) with this.

### The wordmark

"Qory" in Geist 600, letter-spacing -0.03em, sentence case, never capitals, never coloured. Beside
the mark: gap 8 px, wordmark cap-height optically centred on the mark. In the sidebar 16 px / 20 px;
on the auth panel 19 px with the 28 px mark.

`<.brand />` renders mark + wordmark as a link to `/`. `<.live_title default="Qory" suffix=" · Qory">`.

### The honeycomb pattern

Only on the auth brand panel. A stroke-only pointy-top comb, never filled, never animated.

```html
<svg class="absolute inset-0 size-full text-base-content opacity-[0.2]
            [mask-image:radial-gradient(130%_100%_at_0%_100%,#000_10%,transparent_75%)]" aria-hidden="true">
  <defs><pattern id="comb" width="24.25" height="42" patternUnits="userSpaceOnUse">
    <path d="M12.125 0 24.25 7v14l-12.125 7L0 21V7ZM12.125 28v14" fill="none" stroke="currentColor" stroke-width="1"/>
  </pattern></defs>
  <rect width="100%" height="100%" fill="url(#comb)"/>
</svg>
```

It fades from the bottom-left corner to nothing by three quarters of the panel.

### Microcopy tone

Plain, exact, a colleague at the next desk. Second person. Present tense. Full stops on sentences,
none on buttons, labels or headings. No exclamation marks, no "please", no "oops", no
"successfully". Sentence case everywhere. Dates as "12 Sep 2026", times 24-hour, relative time up to
seven days ("2 minutes ago", "Yesterday, 17:20") with the absolute timestamp in a `title`.

| Situation | Write | Not |
|---|---|---|
| Empty state | Nothing has posted to this hive yet. | Bzz! Your hive is looking a bit empty! |
| Destructive confirm | The key stops verifying at once. This cannot be undone. | Are you sure? This action is irreversible! |
| Success toast | build-01 is revoked. | Success! Your key was successfully revoked. |
| Error | That link has expired. Ask for a new one below. | Oops! Something went wrong. |
| Validation | Enter a full email address, such as dana@example.com. | Invalid email |
| Button | Send me a log-in link | Submit |
| In-flight button | Creating | Creating... (the spinner is the ellipsis) |
| Vocabulary | The hive of the Acme apiary. | Your buzzing hive! |

---

## c. Colour

Replace both themes in `assets/css/app.css`. Theme names change from `apiary` / `apiary-dark` to
`qory` / `qory-dark`; update the `dark` custom variant, the theme toggle CSS and the inline script in
`root.html.heex` (which today sets `data-theme="light"|"dark"`, names that match no theme: it must
set `qory` / `qory-dark`). Every neutral leans 65 to 85° toward the accent.

### daisyUI theme variables

| Variable | `qory` (light, default) | hex | `qory-dark` (prefersdark) | hex |
|---|---|---|---|---|
| `color-scheme` | `light` | | `dark` | |
| `--color-base-100` | `oklch(99.3% 0.003 85)` | #fefdfa | `oklch(19.5% 0.006 70)` | #171412 |
| `--color-base-200` | `oklch(97.6% 0.005 85)` | #f9f7f3 | `oklch(16.5% 0.006 70)` | #100e0c |
| `--color-base-300` | `oklch(94.6% 0.007 85)` | #efede8 | `oklch(24.5% 0.008 70)` | #23201c |
| `--color-base-content` | `oklch(21% 0.012 65)` | #1c1713 | `oklch(94% 0.008 80)` | #eeebe5 |
| `--color-primary` | `oklch(78% 0.15 76)` | #eea82f | `oklch(80% 0.145 78)` | #f0b13f |
| `--color-primary-content` | `oklch(22% 0.045 70)` | #281601 | `oklch(20% 0.04 70)` | #211201 |
| `--color-secondary` | `oklch(27% 0.012 65)` | #2b2520 | `oklch(92% 0.008 80)` | #e7e4df |
| `--color-secondary-content` | `oklch(98% 0.004 85)` | #faf8f5 | `oklch(19% 0.006 70)` | #161311 |
| `--color-accent` | `oklch(50% 0.11 66)` | #8d5403 | `oklch(82% 0.12 80)` | #edbb64 |
| `--color-accent-content` | `oklch(99% 0.004 85)` | #fdfcf9 | `oklch(20% 0.04 70)` | #211201 |
| `--color-neutral` | `oklch(24% 0.012 65)` | #231e19 | `oklch(28% 0.008 70)` | #2b2825 |
| `--color-neutral-content` | `oklch(96% 0.005 85)` | #f3f2ee | `oklch(94% 0.008 80)` | #eeebe5 |
| `--color-info` | `oklch(54% 0.13 248)` | #1f73b6 | `oklch(74% 0.11 248)` | #70b1ed |
| `--color-info-content` | `oklch(99% 0.01 248)` | #f7fdff | `oklch(18% 0.03 248)` | #06131e |
| `--color-success` | `oklch(53% 0.13 152)` | #198044 | `oklch(74% 0.14 152)` | #5dc47e |
| `--color-success-content` | `oklch(99% 0.01 152)` | #f7fef8 | `oklch(18% 0.04 152)` | #031608 |
| `--color-warning` | `oklch(76% 0.15 72)` | #eb9f2c | `oklch(80% 0.14 75)` | #f2af48 |
| `--color-warning-content` | `oklch(24% 0.05 70)` | #2e1a01 | `oklch(20% 0.04 70)` | #211201 |
| `--color-error` | `oklch(54% 0.2 27)` | #c92324 | `oklch(68% 0.18 25)` | #f3625d |
| `--color-error-content` | `oklch(99% 0.01 27)` | #fff9f8 | `oklch(16% 0.03 25)` | #180807 |
| `--radius-selector` | `0.25rem` | | same | |
| `--radius-field` | `0.375rem` | | same | |
| `--radius-box` | `0.625rem` | | same | |
| `--size-selector` | `0.25rem` | | same | |
| `--size-field` | `0.25rem` | | same | |
| `--border` | `1px` | | same | |
| `--depth` | `0` | | `0` | |
| `--noise` | `0` | | `0` | |

Surface roles: **base-100** content column, cards, modals, menus, inputs. **base-200** sidebar, auth
brand panel, table header, card footer, modal action bar. **base-300** hover and active fills,
segmented-control track. `secondary` is the ink fill (rare: a neutral solid button if ever needed).
`depth: 0` and `noise: 0` switch off daisyUI's bevel and grain; Qory draws its own 1 px highlight on
solid buttons.

### Semantic tokens

Declare as plain custom properties under `[data-theme="qory"]` and `[data-theme="qory-dark"]` (and
`:root` for the light defaults), then expose to Tailwind:

```css
@theme inline {
  --color-line: var(--q-border-subtle);      /* border-line */
  --color-line-strong: var(--q-border-strong);
  --color-line-field: var(--q-border-field);
  --color-muted: var(--q-muted);             /* text-muted */
  --color-faint: var(--q-faint);
  --color-ring: var(--q-ring);
  --color-code: var(--q-code-bg);            /* bg-code */
  --color-primary-soft: var(--q-primary-soft);   --color-primary-soft-content: var(--q-primary-soft-content);
  --color-success-soft: var(--q-success-soft);   --color-success-soft-content: var(--q-success-soft-content);
  --color-error-soft: var(--q-error-soft);       --color-error-soft-content: var(--q-error-soft-content);
  --color-info-soft: var(--q-info-soft);         --color-info-soft-content: var(--q-info-soft-content);
}
```

| Token | Use | `qory` | `qory-dark` |
|---|---|---|---|
| `--q-border-subtle` | card, table, divider, sidebar edge | `oklch(91.5% 0.008 80)` | `oklch(27% 0.008 70)` |
| `--q-border-strong` | default button border, dashed empty state, disabled field | `oklch(84% 0.01 80)` | `oklch(35% 0.01 70)` |
| `--q-border-field` | input, select, checkbox at rest (3:1 against base-100) | `oklch(66% 0.01 80)` | `oklch(50% 0.01 70)` |
| `--q-muted` | secondary text, descriptions, table meta | `oklch(47% 0.012 65)` | `oklch(71% 0.012 75)` |
| `--q-faint` | tertiary text, placeholders, idle nav icons, "Never posted" | `oklch(55% 0.01 65)` | `oklch(60% 0.012 75)` |
| `--q-ring` | focus ring | `oklch(62% 0.15 70)` | `oklch(80% 0.145 78)` |
| `--q-code-bg` | code block, inline code, key/secret wells | `oklch(96.8% 0.006 85)` | `oklch(15% 0.006 70)` |
| `--q-primary-soft` / `-content` | warning alert, Rotating badge, honey avatar, current-step halo | `oklch(95.5% 0.04 85)` / `oklch(42% 0.095 66)` | `oklch(27% 0.04 78)` / `oklch(85% 0.12 80)` |
| `--q-success-soft` / `-content` | Active badge | `oklch(95.5% 0.035 152)` / `oklch(40% 0.1 152)` | `oklch(26% 0.04 152)` / `oklch(82% 0.12 152)` |
| `--q-error-soft` / `-content` | error alert, Expired badge, destructive ghost hover | `oklch(95.5% 0.025 27)` / `oklch(45% 0.17 27)` | `oklch(27% 0.05 25)` / `oklch(80% 0.11 25)` |
| `--q-info-soft` / `-content` | info alert, Invited badge | `oklch(95.5% 0.025 248)` / `oklch(42% 0.12 248)` | `oklch(26% 0.04 248)` / `oklch(82% 0.09 248)` |
| `--q-overlay` | modal and drawer scrim | `oklch(21% 0.012 65 / 0.4)` | `oklch(8% 0.005 70 / 0.62)` |

The old utility names in the code (`bg-surface`, `border-line`, `text-ink-muted`, `bg-accent-soft`,
`shadow-low`, `shadow-pop`, `text-danger`, `bg-overlay`, `select-field` and the rest) compile to
nothing today. Remove every one; map: `surface`→`base-100`, `surface-2`→`base-200`, `ink`→
`base-content`, `ink-muted`→`muted`, `ink-faint`→`faint`, `line`→`line`, `line-strong`→`line-strong`,
`accent-soft(-ink)`→`primary-soft(-content)`, `danger`→`error`, `warn-soft`→`primary-soft`.

### Contrast (WCAG 2.x ratio, computed from the oklch values)

| Pair | `qory` | `qory-dark` |
|---|---|---|
| base-content on base-100 / base-200 / base-300 | 17.4 / 16.6 / 15.2 | 15.3 / 16.2 / 13.6 |
| muted on base-100 / base-200 | 6.7 / 6.4 | 7.1 / 7.5 |
| faint on base-100 / base-200 | 4.8 / 4.5 | 4.6 / 4.9 |
| primary-content on primary | 8.5 | 9.6 |
| accent (as text) on base-100 / base-200 | 6.1 / 5.8 | 10.4 / 10.9 |
| accent-content on accent | 6.0 | 10.3 |
| secondary-content on secondary | 14.3 | 14.6 |
| neutral-content on neutral (tooltip) | 14.7 | 12.3 |
| error-content on error | 5.4 | 6.2 |
| error (as text) on base-100 | 5.5 | 5.9 |
| success-content on success / info-content on info | 4.8 / 4.9 | 8.6 / 8.2 |
| warning-content on warning | 7.5 | 9.6 |
| primary-soft-content on primary-soft | 7.6 | 9.5 |
| success-soft / error-soft / info-soft pairs | 7.8 / 7.1 / 7.4 | 9.2 / 7.9 / 8.9 |
| base-content on code-bg | 16.2 | 16.5 |
| border-field on base-100 (non-text, needs 3.0) | 3.05 | 3.04 |
| ring on base-100 (non-text, needs 3.0) | 3.7 | 9.6 |

Rules that follow: honey (`primary`) is 2.0:1 on light surfaces, so it is **never** text, icon or
border on a light surface; use `accent`. `faint` is for text of 12 px and above that is not the only
carrier of meaning. Do not place `faint` on base-300.

---

## d. Typography

Family: **Geist** (variable, 100 to 900) and **Geist Mono** (variable), OFL, self-hosted:
`priv/static/fonts/Geist-Variable.woff2`, `priv/static/fonts/GeistMono-Variable.woff2`, with
`OFL.txt` beside them. Add `fonts` to `static_paths/0`.

```css
@font-face { font-family: "Geist"; src: url("/fonts/Geist-Variable.woff2") format("woff2");
  font-weight: 100 900; font-style: normal; font-display: swap; }
@font-face { font-family: "Geist Mono"; src: url("/fonts/GeistMono-Variable.woff2") format("woff2");
  font-weight: 100 900; font-style: normal; font-display: swap; }
@theme inline {
  --font-sans: "Geist", ui-sans-serif, system-ui, -apple-system, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
  --font-mono: "Geist Mono", ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
}
```

Preload the sans file in `root.html.heex` (`<link rel="preload" as="font" type="font/woff2" crossorigin>`).
`html { -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility }`, body `text-sm/5`.
Weights used: 400, 500, 600 only. Nothing is uppercase. No italics in the interface.

| Role | Use | Size / line | Weight | Tracking | Tailwind classes |
|---|---|---|---|---|---|
| Display | auth headings only | 30 / 36 (24 / 32 below 640) | 600 | -0.025em | `text-2xl/8 sm:text-3xl/9 font-semibold tracking-[-0.025em]` |
| Title | page `<h1>` | 20 / 28 | 600 | -0.017em | `text-xl/7 font-semibold tracking-[-0.017em]` |
| Heading | card, section and modal headings (modal: 16 / 24) | 15 / 22 | 600 | -0.006em | `text-[15px]/[22px] font-semibold tracking-[-0.006em]` |
| Body | default text, inputs, table cells (13.5 in tables is not used; keep 14) | 14 / 20 | 400, 500 for emphasis | 0 | `text-sm/5` |
| Small | descriptions, hints, errors, button labels, nav | 13 / 18 | 400, 500 | 0 | `text-[13px]/[18px]` |
| Caption | table headers, sidebar section label, stat title, badge (11.5) | 12 / 16 | 500 | +0.005em | `text-xs/4 font-medium tracking-[0.005em]` |
| Mono | key ids, secrets, versions, hostnames, file names, code | 12.5 / 20 | 400 | 0 | `font-mono text-[12.5px]/5` |

Numbers in tables and stats: `tabular-nums`. Stat value: `text-2xl/8 font-semibold tracking-[-0.02em] tabular-nums`.
Running text is capped at 62ch (`max-w-[62ch]`). Headings take `text-balance`.

---

## e. Spacing, radii, borders, shadows, motion

**Spacing.** 4 px grid; use only 4, 8, 12, 16, 20, 24, 32, 40, 48. Inside a badge 4 to 5. Icon to
label, button to button: 8. Field to field, table cell x-padding: 16. Card and modal padding: 20.
Between page blocks: 24. Page gutter: 16 below 768, 24 from 768, 40 from 1024. Page top padding 32
(20 below 768), bottom 48. Siblings are laid out with `flex`/`grid` and `gap`, not margins; remove
the `mb-4` baked into `<.input>` and let the form's `grid gap-4` space fields.

**Radii.** selector 4 px (checkbox, xs button, kbd, inline code, segmented item); field 6 px
(button, input, select, nav item, menu item, alert, tooltip); box 10 px (card, table wrapper, code
block, menu, toast, empty state); modal 12 px; avatar and badge full. Nothing else.

**Borders.** Always 1 px. `border-line` for containers and dividers, `border-line-strong` for
default buttons and the dashed empty state, `border-line-field` for form controls. No double
borders: a table inside a card drops its own wrapper border.

**Shadows.** Define as Tailwind theme shadows:

| Token | `qory` | `qory-dark` | Use |
|---|---|---|---|
| `shadow-xs` | `0 1px 2px oklch(21% 0.02 70 / 0.06)` | `0 1px 2px oklch(0% 0 0 / 0.4)` | cards, table wrapper, buttons, inputs |
| `shadow-pop` | `0 0 0 1px oklch(21% 0.02 70 / 0.06), 0 10px 28px -8px oklch(21% 0.02 70 / 0.18)` | `0 0 0 1px oklch(100% 0 0 / 0.07), 0 12px 32px -8px oklch(0% 0 0 / 0.6)` | menus, toasts, tooltips |
| `shadow-modal` | `0 0 0 1px oklch(21% 0.02 70 / 0.06), 0 28px 70px -18px oklch(21% 0.02 70 / 0.32)` | `0 0 0 1px oklch(100% 0 0 / 0.08), 0 32px 80px -16px oklch(0% 0 0 / 0.75)` | modal, drawer |
| `--q-highlight` | `inset 0 1px 0 oklch(100% 0 0 / 0.28)` | `inset 0 1px 0 oklch(100% 0 0 / 0.22)` | added to primary and error solid buttons |

Floating surfaces have no CSS border; the 1 px ring is part of the shadow.

**Motion.**

| What | Duration | Easing | Properties |
|---|---|---|---|
| Hover, focus, press | 120 ms | `cubic-bezier(0.2, 0, 0, 1)` | colour, background, border, box-shadow |
| Menu, tooltip (after a 300 ms hover delay), toast | 180 ms in, 120 ms out | out `cubic-bezier(0.2, 0, 0, 1)`, in `cubic-bezier(0.4, 0, 1, 1)` | opacity, 4 px translate |
| Modal, drawer | 240 ms in, 160 ms out | same pair | modal: opacity, 8 px rise, scale from 0.98; drawer: translateX by its width; scrim: opacity |
| Copy button "Copied" | instant swap, reverts after 1600 ms | | none |
| Topbar (page loading) | shown after 300 ms | | 2 px, `primary` |

Never animates: layout, height, table rows, streamed inserts, page content on navigation, numbers,
colour of text on theme change. No looping animation except the button spinner, the skeleton
shimmer and the "listening" dot. No `scale` on press. No parallax, no page transitions.

Reduced motion: keep the existing global block (all durations to 0.01 ms). In addition the spinner
renders as a static three-quarter ring, the skeleton as a flat `base-300` fill, the listening dot
without its ripple.

---

## f. App shell

```
>= 768 px                                              < 768 px
+------------------+-----------------------------+     +---------------------------+
| [Q] Qory         |                             |     | [=] [Q] Qory          (B) |  52 px bar
|------------------|  Page header                |     +---------------------------+
| [A] Acme      <> |  title · description  [CTA] |     |  Page header              |
|     Platform     |                             |     |  content, 16 px gutter    |
|                  |  content                    |     |                           |
| Hive             |  max 960 (tables)           |     +---------------------------+
| [#] Overview     |  max 640 (forms, settings)  |     drawer: the same sidebar, 288 px,
| [k] Access keys 3|                             |     slides from the left over a scrim
| [u] Members    4 |                             |
| [s] Settings     |                             |
|                  |                             |
| (B) beekeeper@.. |                             |
|     Owner     <> |                             |
+------------------+-----------------------------+
   240 px fixed        flex-1, base-100
```

**Structure.** Use daisyUI `drawer md:drawer-open`: `div.drawer.md:drawer-open` > hidden checkbox
`#nav-drawer.drawer-toggle` + `div.drawer-content` (mobile bar, `<main>`) + `div.drawer-side.z-40`
(`label.drawer-overlay` + the sidebar). One sidebar in the DOM, not two (today it is rendered twice
with duplicate ids). Breakpoint is **768 px** (`md`), not 1024.

**Sidebar.** `w-60` (240 px; 288 px / `w-72` inside the mobile drawer), `h-dvh sticky top-0`,
`bg-base-200 border-r border-line flex flex-col`. Top to bottom:

1. **Brand row.** `h-14 px-4 flex items-center`. `<.brand />`: 22 px mark, "Qory".
2. **Workspace block.** `mx-2 mb-2 px-2 py-1.5 grid grid-cols-[28px_1fr_auto] gap-2.5 items-center rounded-field`.
   A 28 px square avatar (`rounded-field bg-neutral text-neutral-content text-xs font-semibold`,
   first letter of the apiary name), then the apiary name (`text-[13px]/[18px] font-semibold truncate`,
   `title` = full name) over the hive name (`text-xs/4 text-muted truncate`).
   - **One membership:** a plain `div`, no border, no chevron, not focusable.
   - **Several memberships:** a `button` with `border border-line bg-base-100 shadow-xs hover:border-line-strong`
     and `hero-chevron-up-down-micro` in `text-faint`, opening a daisyUI `dropdown` (`menu menu-sm`,
     width of the sidebar minus 16 px). Title row "Switch apiary" (with the term hover); one item per
     membership: square avatar, apiary name, hive name in `text-faint`, a `hero-check-micro` on the
     current one. Each item is a `<button>` in a POST form to `/organisations/switch` with
     `organisation_id` (same endpoint and parameter as the current `<select>`; the `SubmitOnChange`
     hook goes away). `aria-label="Switch apiary, current: Acme"`.
3. **Nav.** Section label "Hive" (`px-4 pt-3 pb-1 text-[11.5px]/4 font-medium text-faint`; the word
   carries the term hover). Items: Overview `hero-squares-2x2`, Access keys `hero-key`, Members
   `hero-users`, Settings `hero-cog-6-tooth`, all from the 16 px `-micro` set at `size-4`.
   Item: `flex items-center gap-2.5 h-8 px-2 rounded-field text-[13px] font-medium text-muted
   hover:bg-base-300 hover:text-base-content transition-colors`, icon `text-faint`.
   **Active** (`aria-current="page"`): `bg-base-300 text-base-content`, icon `text-accent`. No left
   bar, no honey fill. Access keys and Members show a right-aligned count (`ml-auto font-mono
   text-[11.5px] text-faint`): active keys, members. In the drawer items are `h-10 text-sm`.
   `<nav aria-label="Main">`, `gap-px px-2`. Do not use daisyUI `menu` here; its paddings and active
   colour fight the spec.
4. **Spacer** `flex-1`.
5. **User card**, pinned to the bottom: `m-2 px-2 py-1.5 grid grid-cols-[24px_1fr_auto] gap-2.5
   items-center rounded-field hover:bg-base-300`. 24 px round avatar (`bg-primary-soft
   text-primary-soft-content`, first letter of the email), the email (`text-[13px] font-medium
   truncate`, `title` = email) over the level ("Owner" / "Member", `text-[11.5px] text-faint`), and
   `hero-chevron-up-down-micro`. It is a `button` opening a `dropdown dropdown-top` menu, 224 px:
   - header: email (500) and "Owner of Acme" (`text-xs text-faint`); divider
   - "Account settings" `hero-user-circle-micro` → `/users/settings`
   - label "Theme", then a three-segment control Auto / Light / Dark (`hero-computer-desktop-micro`,
     `hero-sun-micro`, `hero-moon-micro`), `aria-pressed` on the active one, dispatching
     `phx:set-theme` as today; divider
   - "Log out" `hero-arrow-right-start-on-rectangle-micro` → `DELETE /users/log-out`

   The standalone "Theme" row above the user card is removed. Replace the `<details>` menus with
   daisyUI `dropdown` on a focusable `button` + `ul[tabindex=0]`; close on Escape and outside click.

**No-hive variant.** When the user has no membership: brand row, no workspace block, no nav, user
card. The content column shows the no-hive page.

**Mobile bar** (below 768): `sticky top-0 z-30 h-13 (52 px) flex items-center justify-between pl-2
pr-4 border-b border-line bg-base-100/85 backdrop-blur`. Left: `label[for=nav-drawer]` as a 40 px
ghost square button with `hero-bars-3` (`aria-label="Open menu"`), then `<.brand />`. Right: the
24 px user avatar (decorative; the menu lives in the drawer).

**Drawer behaviour.** Slides in 240 ms over a `--q-overlay` scrim. Closes on scrim tap, Escape, the
X button in its brand row, and on any navigation (LiveView `phx:page-loading-stop` unchecks the
toggle; a six-line hook `CloseDrawerOnNav`). While open: focus moves to the drawer's close button,
`<main>` gets `inert`, body scroll is locked. On close, focus returns to the menu button.

**Page header.** `flex flex-wrap items-start justify-between gap-4`, 24 px below it.
Left: `<h1>` Title style; under it (2 px) the description in `text-sm/5 text-muted max-w-[62ch]`.
Right: at most one primary button and one default button. No breadcrumb, no icon, no divider under
the header. Below 480 px the action button goes full width under the text.

**Content widths.** `<main class="min-w-0 flex-1 bg-base-100">` > `div.mx-auto.w-full.px-4.md:px-6.lg:px-10.pt-5.md:pt-8.pb-12`
> inner `max-w-[960px]` for overview, access keys and members; `max-w-[640px]` for settings and
account settings (left-aligned within the 960 column so the title edge does not jump between
pages: wrap as `max-w-[960px] mx-auto` > `max-w-[640px]`).

---

## g. Components

All live in `core_components.ex`. Default control height in the console is daisyUI **sm (32 px)**;
auth pages and everything below 768 px use **md (40 px)**. Global overrides go in one
`@layer components` block in `app.css`.

### Button (`<.button>`)

Attrs: `variant` `primary | default | ghost | danger | danger-ghost | link`, `size` `xs | sm | md`,
`loading_text`.

| Variant | Classes |
|---|---|
| default | `btn btn-sm bg-base-100 border-line-strong text-base-content shadow-xs hover:bg-base-200 hover:border-line-field active:bg-base-300` |
| primary | `btn btn-sm btn-primary` + override: border `color-mix(in oklab, var(--color-primary) 82%, black)`, `box-shadow: var(--shadow-xs), var(--q-highlight)`; hover background `color-mix(in oklab, var(--color-primary) 92%, black)`; active 86% |
| ghost | `btn btn-sm btn-ghost text-muted hover:bg-base-300 hover:text-base-content shadow-none` |
| danger | `btn btn-sm btn-error` with the same border, highlight and hover treatment as primary |
| danger-ghost | ghost + `text-error hover:bg-error-soft hover:text-error-soft-content` |
| link | `text-accent font-medium underline decoration-transparent underline-offset-[3px] hover:decoration-current` (no `btn`) |

All: `font-medium text-[13px]` (`text-sm` at md), `gap-1.5`, `px-3` (md `px-4`, xs `px-2`), radius
field (xs: selector), icons `size-4` `-micro`, `transition-colors duration-[120ms]`, no transform on
press (switch daisyUI's press scale off: `.btn:active { transform: none }`).
Sizes: `btn-xs` 24 px for table row actions and code-block copy; `btn-sm` 32 px console default;
`btn-md` 40 px auth, mobile primary actions, `btn-block` on auth. Icon-only: `btn-square` with
`aria-label` and a tooltip.

States: **hover** as above. **focus-visible** `outline-2 outline-offset-2 outline-ring` (global
rule). **active** one step darker, no movement. **disabled** `opacity-50 cursor-not-allowed
shadow-none`, no hover. **loading** (`phx-submit-loading` / `phx-click-loading`): the leading icon is
replaced by `loading loading-spinner loading-xs`, label switches to the gerund without an ellipsis
("Creating", "Saving", "Sending", "Revoking", "Rotating", "Retiring", "Joining", "Confirming"),
`aria-busy="true"`, pointer events off, width must not change by more than the spinner (reserve
with `min-w` if needed). One primary button per view; a modal's primary counts as the view's.

### Input, select, checkbox

Wrapper: daisyUI `fieldset` reset to `grid gap-1.5 p-0 border-0 min-w-0`. Label: `<label
class="text-[13px]/[18px] font-medium">`; optional fields append " (optional)" in `text-faint
font-normal`. No asterisks.

- **Input**: `input input-sm w-full bg-base-100 border-line-field shadow-xs text-sm
  placeholder:text-faint max-md:input-md max-md:text-base`; auth: `input-md text-[15px]`.
  Override daisyUI's focus outline with: `focus:outline-none focus:border-ring
  focus:shadow-[0_0_0_3px_color-mix(in_oklab,var(--q-ring)_28%,transparent)]`.
  Hover `border-muted`. **Error**: `input-error border-error`, focus halo in error at 24%,
  `aria-invalid="true"`, `aria-describedby` the error id. **Disabled / readonly**: `bg-base-200
  text-muted border-line-strong shadow-none`, disabled adds `cursor-not-allowed`.
- **Hint**: `text-[12.5px]/[18px] text-muted`, directly under the field. **Error**: same position,
  replaces the hint: `text-error flex items-center gap-1.5` with `hero-exclamation-circle-micro`.
  Errors show after blur or submit, not while typing the first time (`phx-debounce="blur"`).
- **Select**: `select select-sm w-full` with the same border, focus and states; chevron is
  up-down. In table rows: `select-xs w-auto` (24 px), radius selector.
- **Checkbox**: `checkbox checkbox-sm checkbox-primary rounded-selector border-line-field` (16 px),
  label to the right `text-[13.5px]`, whole row clickable, gap 8. Checked: honey fill,
  `primary-content` tick. Focus ring as global. Disabled `opacity-50`.
- **Textarea** (not used yet): `textarea textarea-sm min-h-24`, same treatment.

### Form layout

One column, labels above, `grid gap-4`. Field width max 420 px (`max-w-[420px]`) even in wider
cards. In a **card**: fields in the body, actions in the footer bar, right-aligned, with a muted
helper sentence on the left. In a **modal**: fields in the body, actions in `modal-action`.
Order of actions: Cancel (default) then the primary, right-aligned; on phones they stack with the
primary on top (`flex-col-reverse sm:flex-row`). Submit on Enter. First field gets focus on mount.
A failed submit focuses the first invalid field. Server-side form errors that belong to no field
render as an `alert-error` at the top of the form.

### Table (`<.table>`)

Wrapper `overflow-x-auto rounded-box border border-line bg-base-100 shadow-xs`; `table` (daisyUI)
with overrides: `thead th` `bg-base-200 text-xs/4 font-medium text-muted px-4 py-[9px] text-left
whitespace-nowrap border-b border-line` (sentence case, no uppercase); `td` `px-4 py-2.5 text-sm
whitespace-nowrap align-middle border-b border-line`, last row no border; row hover `bg-base-200`
(120 ms); no zebra. Primary column `font-medium`; meta columns `text-muted tabular-nums`; absent
values `text-faint` ("Never posted", "n/a"). Actions column: `w-px text-right`, `btn-xs` ghost
buttons with 2 px gaps, header is `sr-only` "Actions". An inactive row (revoked key) sets all cells
to `text-faint` and replaces actions with a caption. The wrapper is focusable
(`tabindex="0" role="region" aria-label`) so keyboard users can scroll it. Below 640 px the table
scrolls sideways inside its wrapper; the first column is not sticky.

### Badge (`<.badge>`)

`badge badge-sm` overridden to `h-5 px-[7px] gap-[5px] rounded-full text-[11.5px] font-medium
border`. Status badges carry a 6 px dot (`::before`, `currentColor`), label badges do not.

| Colour | Classes | Used for |
|---|---|---|
| neutral | `bg-base-200 text-muted border-line` | Revoked; label badges "You", "Owner", "Member" |
| success | `bg-success-soft text-success-soft-content border-transparent` | Active |
| warning | `bg-primary-soft text-primary-soft-content border-transparent` | Rotating |
| info | `bg-info-soft text-info-soft-content border-transparent` | Invited |
| error | `bg-error-soft text-error-soft-content border-transparent` | Expired |

State is never colour alone: the word is always there.

### Card (`<.card>`)

`card card-border bg-base-100 border-line rounded-box shadow-xs`. Slots: `title` (header row `px-5
py-3.5 border-b border-line`, Heading style, optional actions right), body `p-5 grid gap-4`, `footer`
(`px-5 py-3 border-t border-line bg-base-200 rounded-b-box flex flex-wrap items-center
justify-between gap-3 text-[12.5px] text-muted`). A clickable card (stat) gets `hover:bg-base-200`
and a focus ring; static cards never react to hover. Do not nest cards.

### Stat (`<.stat>`)

daisyUI `stats` as one bordered object with internal dividers (`stats stats-horizontal border
border-line rounded-box shadow-xs bg-base-100`, wrapping to a column below 480 px). Each `stat`:
`px-5 py-4`, `stat-title` Caption in `text-muted`, `stat-value` `text-2xl/8 font-semibold
tracking-[-0.02em] tabular-nums` (override daisyUI's large size), `stat-desc` `text-[12.5px]
text-faint`. A stat that navigates is an `<a>` with `hover:bg-base-200`. No icons, no trend arrows.

### Steps (`<.steps>`)

A vertical list, not daisyUI `steps` (that one is horizontal and heavy). `<ol>`, each item a 24 px
number disc and text, discs joined by a 1 px `line-strong` connector. Disc: `size-6 rounded-full
border border-line-strong bg-base-100 font-mono text-[11.5px] text-muted`. States: **to do** as
described; **current** `border-primary text-base-content` with a 3 px `primary-soft` halo and
`aria-current="step"`; **done** `bg-primary` with a `primary-content` check, no number, plus
`sr-only` "Done:". Title `text-[13.5px] font-medium`, body `text-[13px]/[18px] text-muted`.
Attr `current` (1..3): overview empty = 1; with keys but no posts = 2.

### Empty state (`<.empty_state>`)

`rounded-box border border-dashed border-line-strong px-6 py-10 grid justify-items-center
text-center gap-1.5`. A 44 px hexagon tile (`clip-path: polygon(50% 0, 93.3% 25%, 93.3% 75%, 50%
100%, 6.7% 75%, 6.7% 25%)`, `bg-primary-soft text-primary-soft-content`) with a 20 px outline
heroicon; Heading-style title; one paragraph `text-muted max-w-[46ch]`; actions 14 px below. At most
one primary and one default button.

### Modal (`<.modal>`)

Native `<dialog>` with daisyUI: `dialog.modal` > `div.modal-box` + (when dismissable)
`form[method=dialog].modal-backdrop`. A small hook `Modal` calls `showModal()` on mount and
`close()` before removal; the dialog's `close` and `cancel` events run `on_cancel` (the existing
`JS.patch`). This gives focus trapping, Escape, inert background and top-layer stacking for free and
replaces the hand-built `fixed inset-0` overlay.

- `modal-box`: `p-0 rounded-[12px] bg-base-100 shadow-modal max-h-[calc(100dvh-2rem)]`, widths
  `sm` 400, `md` 480, `lg` 560. `::backdrop` `--q-overlay` with `backdrop-filter: blur(2px)`.
- Header `px-5 pt-5 flex items-start justify-between gap-3`: title 16 / 24 semibold (`id` wired to
  `aria-labelledby`), close button `btn btn-ghost btn-xs btn-square` `hero-x-mark-micro`
  `aria-label="Close"` (absent when not dismissable).
- Body `px-5 pt-2 pb-5 grid gap-4 text-[13.5px]`; prose in `text-muted`.
- Footer `modal-action` overridden: `m-0 px-5 py-3 border-t border-line bg-base-200
  rounded-b-[12px] flex justify-end gap-2`.
- Below 640 px: `modal-bottom` (sheet from the bottom edge, top corners 12 px, buttons stacked,
  40 px).
- `dismissable={false}` (reveal-once): no X, no backdrop form, `cancel` event `preventDefault`ed.
- Initial focus: first field, else the Cancel button in destructive confirms (never the destructive
  button), else the primary. Focus returns to the trigger on close.

### Toast (flash)

daisyUI `toast toast-end toast-bottom z-[60]` (bottom-right; below 640 px full width at the bottom
with 16 px gutters). Item: `grid grid-cols-[16px_1fr_auto] gap-2.5 items-start w-[360px]
max-w-full p-3 rounded-box bg-base-100 shadow-pop text-[13px]/[18px]`. Not daisyUI `alert`
colours: the surface stays neutral and only the icon carries colour: info `hero-check-circle-micro
text-success`, error `hero-exclamation-triangle-micro text-error`. Title `font-medium`, optional
second line `text-muted`. Dismiss: 20 px ghost X, `aria-label="Dismiss"`. Info toasts auto-dismiss
after 5 s (pause on hover and focus), error toasts stay. `role="status"` for info, `role="alert"`
for error; the group keeps `aria-live="polite"`. Enters 180 ms (opacity + 4 px up), leaves 120 ms.
Reconnect toasts: "Connection lost." / "Reconnecting. Your changes are safe." with the spinner in
place of the X; "Something went wrong on our side." / "Reconnecting." for the server error.

### Alert (inline notice, `<.notice>`)

`alert alert-soft` overridden: `grid grid-cols-[16px_1fr] gap-2.5 px-3 py-2.5 rounded-field
border-0 text-[13px]/[18px]`. warning: `bg-primary-soft text-primary-soft-content`
`hero-exclamation-triangle-micro`; info: info-soft pair `hero-information-circle-micro`; error:
error-soft pair. Lead sentence may be `font-semibold`. No close button.

### Tooltip and the term hover

**Tooltip**: daisyUI `tooltip` (`data-tip`), overridden: `bg-neutral text-neutral-content text-xs/4
font-medium px-2 py-1 rounded-field shadow-pop`, no arrow (`.tooltip::after { display: none }`),
6 px offset, 300 ms show delay, 0 ms hide, also shown on `:focus-visible`. Required on every
icon-only button (whose `aria-label` carries the same words). Never holds essential information.

**Term** (`<.term word="hive" />`): `<abbr class="term tooltip" tabindex="0" data-tip="workplace"
aria-label="hive (workplace)">hive</abbr>` with `underline decoration-dotted decoration-line-field
underline-offset-[3px] cursor-help no-underline-on-print`. Drop the native `title` (double tooltip,
no keyboard support). Mapping: apiary → organisation, hive → workplace. Apply the term treatment to the
**first** occurrence in a page header, description, empty state or modal body; never inside
buttons, nav items, table cells, toasts or form labels (plain word there). Capitalised forms keep
the hover ("Apiary name").

### Code block with copy (`<.code_block>`, `<.mono>`, `<.copy_button>`)

Block: `rounded-box border border-line bg-code overflow-hidden`; head `flex justify-between
items-center pl-3.5 pr-1.5 py-1.5 border-b border-line font-mono text-xs text-muted` with the file
name left (`qory.yaml`) and a `btn-xs` ghost copy button right; `pre` `p-3.5 overflow-x-auto
font-mono text-[12.5px]/5 [tab-size:2]`. YAML keys in `text-accent`, placeholders in `text-faint`;
no other syntax colour. Copy button: idle `hero-clipboard-document-micro` + "Copy" (or "Copy
block"); after click `hero-check-micro` + "Copied" in `text-success` for 1600 ms, announced through
an `aria-live="polite"` span; existing `CopyToClipboard` hook stays. Inline `<.mono>`: `font-mono
text-[12.5px] bg-code border border-line rounded-selector px-1.5 py-0.5`; in table cells no
background, just mono.

**Key/value well** (reveal screen): `dl grid grid-cols-[auto_1fr_auto] gap-x-3 gap-y-2
items-center`; `dt text-[13px] text-muted`; value `code block font-mono text-[12.5px]/5 px-2.5 py-1
bg-code border border-line rounded-field break-all select-all`; icon-only copy button with tooltip.
Below 640 px the `dt` sits on its own row.

### Dropdown

daisyUI `dropdown` (+ `dropdown-top` for the user card, `dropdown-end` where right-aligned);
content `ul.menu.menu-sm` overridden: `min-w-[220px] p-1 gap-px rounded-box bg-base-100 shadow-pop
text-[13px]`; items `h-[30px] px-2 gap-2 rounded-field hover:bg-base-200 focus-visible:bg-base-200`,
icons `size-4 text-faint`; dividers `-mx-1 my-[3px] border-t border-line`; section titles
`text-[11.5px] font-medium text-faint px-2 pt-1.5 pb-0.5`; destructive items `text-error`.
Trigger has `aria-haspopup="menu"` and `aria-expanded`; Escape closes and restores focus; arrow
keys move between items (hook `Menu`, about twenty lines). Enters 180 ms from 4 px towards the
trigger with scale 0.98.

### Avatar

`avatar avatar-placeholder` > `div`. Person: round, 24 px (32 px `lg`), `bg-base-300 text-muted
ring-1 ring-inset ring-line text-[11px] font-semibold uppercase`, first letter of the email. The
current user: `bg-primary-soft text-primary-soft-content`. Apiary: **square** `rounded-field
bg-neutral text-neutral-content`, 28 px. Pending invitation: dashed ring with
`hero-envelope-micro`. Decorative: `aria-hidden="true"`; the name is always beside it.

### Loading

- **Navigation**: topbar, 2 px, `primary`, after 300 ms. Set `barColors` from
  `getComputedStyle(document.documentElement).getPropertyValue("--color-primary")`.
- **Buttons**: inline spinner as above. This is the only place a spinner appears, besides the
  reconnect toast.
- **Regions** loaded async (none in this milestone): daisyUI `skeleton` bars, `h-3 rounded-selector`,
  in the shape of the content; never a centred spinner.
- **Listening dot** (overview): 8 px `line-field` dot with a slow ripple (2.4 s), text `text-muted`.
  When a machine has posted it is replaced by content, not recoloured.

---

## h. Page compositions

Copy below is final. `{hive}` etc. are data. Words marked ~like this~ carry the term hover.

### h1. Overview, empty (`/hive`, no keys)

```
Platform
The ~hive~ of the Acme ~apiary~.

+------------------------------------------+--------------------------------+
| Connect your first machine               | What you will paste            |
| Nothing has posted to this hive yet.     | +----------------------------+ |
| An access key is all a machine needs     | | qory.yaml                  | |
| to start.                                | | server:                    | |
|                                          | |   url: https://…           | |
| (1) Create an access key                 | |   key_id: qk_············  | |
|  |  Label it after the machine or        | |   secret: qs_live_·······  | |
|  |  environment.                         | +----------------------------+ |
| (2) Paste the server block into the      |                                |
|  |  runner file                          | (o) Listening for the first    |
|  |  The secret is shown once, in the     |     post from a machine.       |
|  |  dialog that creates it.              |                                |
| (3) See runs here                        |                                |
|     From the first post on, every run    |                                |
|     of that machine lands in this hive.  |                                |
|                                          |                                |
| [+ Create an access key]                 |            (bg base-200)       |
+------------------------------------------+--------------------------------+
```

One bordered object, two columns (`grid md:grid-cols-2`), right column `bg-base-200 border-l`.
The preview block uses the real endpoint URL and faint dots for the id and secret; no copy button.
Step 1 is current. Below 768 px the right column is dropped and the listening line sits under the
card. The button navigates to `/hive/keys/new`. Page title is the hive name.

### h2. Overview, with keys

```
Platform
The ~hive~ of the Acme ~apiary~.

+---------------------+---------------------+
| Access keys         | Members             |
| 3                   | 4                   |
| active, 1 revoked   | 2 owners            |
+---------------------+---------------------+

+-----------------------------------------------------------+
| Connect a machine                  [Manage access keys]   |
|-----------------------------------------------------------|
| (✓) Create an access key                                  |
| (2) Paste the server block into the runner file           |
| (3) See runs here                                         |
+-----------------------------------------------------------+
(o) Listening for the first post from a machine.
```

Stats are one joined object, each half links to its page. Step 1 done, step 2 current. Hints
unchanged from today ("active", "active, 1 revoked", "1 owner", "2 owners"). Replace "Runs will
appear here once a machine posts." with the listening line.

### h3. Access keys (`/hive/keys`)

Header: **Access keys** / "A key lets the machines of this ~hive~ post their runs. Create one per
machine or environment and paste its server block into the runner file." / primary
`[+ New access key]`.

List: columns Label · Key id · Status · Created · Last used · Runner · actions.

```
| build-01         qk_7f3a9c2e41d8 [copy]  • Active    12 Sep 2026  2 minutes ago     0.4.2   Rotate  Revoke |
| staging-runners  qk_b81d04f6a2c9 [copy]  • Rotating   3 Sep 2026  Yesterday, 17:20  0.4.1   Retire previous secret  Rotate  Revoke |
| dana-laptop      qk_29e6c7710b3f [copy]  • Active    19 Sep 2026  Never posted      n/a     Rotate  Revoke |
| old-ci           qk_0c44e1a97d52         • Revoked    1 Aug 2026  30 Aug 2026       0.3.9   Revoked 2 Sep 2026 |
```

Key id in mono with an icon-only copy button that appears on row hover and focus (always visible on
touch), tooltip "Copy key id". "Never posted" (capitalised, replaces "never posted") and "n/a"
(replaces the dash) in `text-faint`. Row actions `btn-xs` ghost; Revoke is `danger-ghost`. Revoked
rows fully faint.

Empty: hex icon `hero-key`, **No access keys yet**, "Create a key and paste its server block into
the runner file on a machine. It posts its runs to this ~hive~ from then on.",
`[Create an access key]`.

**Create modal** (md). Title **New access key**. Field "Label", placeholder `build-01`, hint "The
machine or environment this key is for." Footer: `[Cancel]` `[Create key]` → "Creating".

**Reveal-once** (lg, not dismissable). Title **Your new access key**, the label as a success badge
at the right of the header.

```
+--------------------------------------------------------------+
| Your new access key                              • build-01  |
| [!] This secret is shown once. Copy it now. Qory keeps only  |
|     an encrypted copy and cannot show it again.              |
| Key id  [ qk_7f3a9c2e41d8                          ] [copy]  |
| Secret  [ qs_live_Zk3vN8wq1LxT5rYb0HcA7mPd         ] [copy]  |
| Paste this `server` block into the runner file on the        |
| machine.                                                     |
| +----------------------------------------------------------+ |
| | qory.yaml                                   [Copy block] | |
| | server: …                                                | |
| +----------------------------------------------------------+ |
|--------------------------------------------------------------|
|                                  [I have copied the secret]  |
+--------------------------------------------------------------+
```

The only exit is the primary button (replaces "Done"); it patches to `/hive/keys`. Note the alert
says "Qory", not "Apiary".

**Rotate confirm** (md). **Rotate {label}** / "Rotating issues a new secret and shows it once. The
previous secret keeps working until you retire it, so machines can move over one at a time without
a gap." / `[Cancel]` `[Rotate key]` → "Rotating". **Rotate reveal**: the reveal-once layout, title
**New secret for {label}**, badge `• Rotating`, sentence above the block: "Update the `server`
block in the runner file of each machine that uses this key, then retire the previous secret."

**Retire confirm** (md). **Retire the previous secret of {label}** / "Only the secret issued at the
last rotation keeps working. A machine still on the previous secret fails its next request." /
`[Cancel]` `[Retire previous secret]` (primary) → "Retiring". Toast: "The previous secret of
{label} is retired."

**Revoke confirm** (md). **Revoke {label}** / "The key stops verifying at once. Machines still using
it fail their next request and do not start new runs. This cannot be undone; create a new key to
reconnect them." / `[Cancel]` (initial focus) `[Revoke key]` (danger) → "Revoking". Toast: "{label}
is revoked." with second line "Machines using it fail their next request." Error toasts unchanged:
"{label} is already revoked.", "{label} is revoked and cannot be rotated."

### h4. Members (`/hive/members`)

Header: **Members** / "The people in this ~hive~. Owners manage members, keys and settings; members
manage keys and see every run." / owners see primary `[+ Invite member]`.

```
| Member                                   Level        Joined                |
| (B) beekeeper@example.com  [You]         [Owner  v]   1 Sep 2026    Remove  |
| (D) dana@example.com                     [Owner  v]   4 Sep 2026    Remove  |
| (M) mirek@example.com                    [Member v]   9 Sep 2026    Remove  |

Pending invitations                        Invitations expire after seven days.
| Email                       Level      Sent          Expires               |
| (✉) noor@example.com        [Member]   18 Sep 2026   25 Sep 2026    Revoke |
```

Column header "Member" (was "Email"); avatar + email; "You" neutral label badge. Owners get the
`select-xs` level control (accessible name "Level of {email}"); members see a label badge. The
"Pending invitations" heading (Heading style) sits 32 px below with its caption on the same line,
right-aligned. No invitations: a single line in `text-muted`: "No pending invitations."

**Invite modal** (md). **Invite a member** / "We email an invitation link. It works for seven days
and brings the person into this ~hive~ when they accept." / fields "Email", "Level" (Member
default) with hint "Owners manage members and settings. Members manage keys and see every run." /
`[Cancel]` `[Send invitation]` → "Sending". Toast: "Invitation sent to {email}."

**Remove confirm** (md). **Remove {email}** / "They lose access to this ~hive~ and its runs at once.
Their account stays; you can invite them again." / `[Cancel]` (focus) `[Remove member]` (danger) →
"Removing". When the target is the last owner, keep the existing server refusal, shown as an error
toast: "The last owner cannot be removed or demoted." Revoking an invitation needs no confirm;
toast "Invitation to {email} revoked." (Keep whatever strings the LiveView already flashes if they
differ only in wording; align them to these.)

### h5. Settings (`/hive/settings`), 640 px column, stacked cards

```
Settings
The names of this ~apiary~ and its ~hive~, and who owns them.

[i] Only owners can change these settings. Ask an owner if a name needs to change.   (members only)

+ ~Apiary~ name --------------------------------------------+
| Name  [ Acme                         ]                   |
|----------------------------------------------------------|
| Shown in the sidebar and in invitations.          [Save] |
+----------------------------------------------------------+
+ ~Hive~ name ----------------------------------------------+
| Name  [ Platform                     ]                   |
|----------------------------------------------------------|
| Shown in the sidebar and as the overview title.   [Save] |
+----------------------------------------------------------+
+ Owners ------------------------------- [Manage members] -+
| (B) beekeeper@example.com [You]          since 1 Sep 2026 |
| (D) dana@example.com                     since 4 Sep 2026 |
|----------------------------------------------------------|
| The last owner cannot be removed or demoted.             |
+----------------------------------------------------------+
```

Cards stack in one column (today's two-column grid leaves uneven cards). Save buttons say "Save"
(the card title already names the object; "Save apiary name" with a dotted term inside a button
goes). Save is disabled while the form is invalid (the changeset already knows). Members see disabled fields and no
footer button. Toasts: "Apiary renamed to {name}." / "Hive renamed to {name}."

### h6. Account settings (`/users/settings`), inside the app shell, 640 px column

Header: **Account settings** / "Your email address and password." Two cards, same anatomy as h5:
**Email** (field "Email", footer "We send a confirmation link to the new address." `[Change email]`
→ "Sending") and **Password** (fields "New password", "Confirm new password", hint "At least 12
characters.", footer "Optional. Log-in links keep working either way." `[Save password]`). This
page uses `Layouts.app` with `nav={nil}`. Keep the existing sudo-mode redirect.

### h7. No-hive page

App shell in its no-hive variant. Centred in the content column, `max-w-[480px]`, an empty state
with `hero-envelope-open`: **You are not part of an apiary yet** / "An ~apiary~ is created when you
register, and you join someone else's through an invitation. Ask an owner to invite
**{email}**; the email they send brings you straight to their ~hive~." / `[Account settings]`
(default) `[Log out]` (ghost).

### h8. Invitation accept (`/invitations/:token`), auth split layout

Form side, left-aligned like the other auth pages (not centred text):

- **Signed in.** Display heading "Join {hive}" / "You are invited to the **{hive}** ~hive~ of the
  **{organisation}** ~apiary~, as {a member | an owner}." / a quiet identity row: avatar, "Signed in
  as {email}" / `[Accept invitation]` primary md block → "Joining" / link-style `Not you? Log out`.
- **Signed out.** Same heading and sentence / "Create an account with **{invitation email}** to
  join, or log in if you already have one." / `[Create an account]` primary md block /
  `[Log in]` default md block.
- **Invalid.** Hex icon `hero-envelope-open` in neutral (`bg-base-300 text-muted`) / heading "This
  invitation is no longer valid" / "It may have been accepted already, revoked, or it expired after
  seven days. Ask the person who invited you to send a new one." / `[Go to your hive]` (signed in)
  or `[Log in]`.

### h9. Auth pages: split view (`Layouts.auth`)

```
>= 1024 px
+-------------------------------+----------------------------------------+
| [Q] Qory                      |                          [theme ▾]     |
|                               |                                        |
|                               |        Log in to Qory                  |
|   . . honeycomb, fading . .   |        We will email you a link.       |
|                               |        No password needed.             |
|                               |        Email                           |
| Every run your coding agents  |        [ beekeeper@example.com    ]    |
| make, in one place you host   |        [x] Keep me signed in           |
| yourself.                     |        [  Send me a log-in link   ]    |
| Self-hosted. Your machines,   |        [  Use a password instead  ]    |
| your database, your keys.     |        New to Qory? Create an account  |
+-------------------------------+----------------------------------------+
   5fr, base-200, border-r            6fr, base-100, form 352 px wide
```

`div.grid.min-h-dvh.lg:grid-cols-[5fr_6fr]`. **Brand panel**: `bg-base-200 border-r border-line
p-8 lg:p-10 flex flex-col justify-between relative overflow-hidden`, the honeycomb behind; top:
28 px mark + "Qory" 19 px; bottom: the sentence in 26 / 32 semibold -0.025em, `max-w-[30ch]`, with
"one place" in `text-accent`, and under it in `text-[13px] text-muted`: "Self-hosted. Your
machines, your database, your keys." The same sentence on every auth page. **Form side**: centred
352 px column (`max-w-[352px]`), everything left-aligned, `grid gap-4`; theme control top-right
(icon-only ghost button opening the three-way menu). **Below 1024 px** the panel collapses to a
header strip: `h-14 px-4 border-b`, brand only, no pattern, no sentence; the form starts 40 px
below it with 16 px gutters. No card around the form at any width. All controls `md` (40 px).

The dev-only "local mail adapter" notice moves under the form as one `text-faint` line: "Dev: sent
mail is in the [mailbox](/dev/mailbox)." It must not sit between the heading and the field.

**Log in** (`/users/log-in`). ONE form, ONE email field.

- Heading "Log in to Qory"; sub "We will email you a link. No password needed."
- "Email" (`autocomplete="username"`, focused on mount, `readonly` in sudo mode).
- Password field, hidden by default, revealed by the toggle: label "Password",
  `autocomplete="current-password"`; when revealed it takes focus and the sub changes to "Enter the
  password you set in account settings."
- Checkbox "Keep me signed in", checked by default, posts `user[remember_me]=true`. In password
  mode this is the existing parameter. In link mode the session is created later, on the
  confirmation page, so carry the choice there: append `?remember_me=true|false` to the emailed
  URL and use it as the default of the confirmation page's own checkbox. This is the one small
  addition beyond markup; if it is not wanted, render the checkbox in password mode only and let
  the confirmation page's checkbox (checked by default) decide for link log-ins.
- Primary block: "Send me a log-in link" → "Sending"; in password mode "Log in" → "Logging in".
- Ghost block toggle: "Use a password instead" ⇄ "Email me a link instead"
  (`aria-expanded`, `aria-controls` the password wrapper).
- Foot: "New to Qory? [Create an account]".
- Sudo mode: heading "Confirm it is you", sub "Log in again to change sensitive account settings.",
  no foot line.

Implementation: `assign(:mode, :magic | :password)`; one `<.form id="login_form"
action={~p"/users/log-in"} phx-submit="submit" phx-trigger-action={@trigger_submit}>`. In `:magic`
mode `submit` does what `submit_magic` does today; in `:password` mode it sets `trigger_submit`.
The password input is rendered only in `:password` mode so it is never posted empty. The toggle is
a `phx-click="toggle_mode"`; it preserves the typed email. After sending the link, show an
in-place confirmation in the same layout instead of the flash-and-reload (an assign, no new route;
if that is out of scope for the pass, keep the current flash with the text "If {email} has an
account, a log-in link is on its way."): hex icon `hero-envelope`, heading
"Check your email", "If **{email}** has an account, a log-in link is on its way. It works for 15
minutes." (use the app's real token lifetime), ghost `[Use a different email]`.

**Register** (`/users/register`). Heading "Create your account"; sub "Start an ~apiary~ for your
workplace. We will email you a link to confirm; no password needed." With an invitation, an info alert
above the field: "You are invited to the **{hive}** ~hive~ at **{organisation}**. Your account joins
it as soon as you confirm." and the email prefilled. Field "Email". Primary block "Create account"
→ "Creating". Foot: "Already have an account? [Log in]". After submit, the same "Check your email"
confirmation: "We sent a confirmation link to **{email}**."

**Confirmation** (`/users/log-in/:token`). Heading "Welcome to Qory" (unconfirmed) or "Welcome
back" (confirmed); sub: the email in `text-muted`. Checkbox "Keep me signed in" (checked) and ONE
primary block button: "Confirm my account" → "Confirming", or "Log in" → "Logging in". This
replaces the two-button pair ("… and stay logged in" / "… only this time"); the same
`remember_me` parameter is posted, now from the checkbox. Invalid or expired token: heading "That
link has expired", "Log-in links work once and for a short time. Ask for a new one.",
`[Send a new link]` → `/users/log-in`.

---

## i. Accessibility

- **Contrast**: the table in section c is the contract. Text ≥ 4.5:1, large text and non-text
  (field borders, focus ring, checkbox) ≥ 3:1, in both themes. Honey is never text on light.
- **Focus**: one global rule, `:focus-visible { outline: 2px solid var(--q-ring); outline-offset:
  2px }`; inputs swap it for the border + 3 px halo. Never remove focus without replacing it. Focus
  order follows the visual order; the sidebar comes before main. A "Skip to content" link is the
  first focusable element (`sr-only focus:not-sr-only`, top-left, `btn btn-sm`).
- **Landmarks**: `<aside aria-label="Sidebar">`, `<nav aria-label="Main">`, one `<main id="main">`,
  one `<h1>` per page (the page header title; on auth pages the display heading). Card titles are
  `<h2>`, modal titles `<h2>`.
- **Keyboard**: every action reachable and operable; menus with arrows, Escape and focus return;
  native `<dialog>` traps focus; the drawer sets `inert` on main; tables' scroll regions are
  focusable; tooltips and term hovers appear on focus.
- **Names**: icon-only buttons have `aria-label`; row actions include the object ("Revoke
  build-01") via `aria-label` while the visible text stays short; selects in rows are labelled
  "Level of {email}"; the workspace switcher announces the current apiary.
- **State**: never colour alone (badges carry words, errors carry an icon and text, the active nav
  item has `aria-current`). Loading buttons set `aria-busy`. Copy success is announced politely.
  Toasts: `role="status"` / `role="alert"`; auto-dismiss pauses on hover and focus and is never less
  than 5 s.
- **Forms**: visible labels always; errors tied with `aria-describedby`, `aria-invalid`; first
  invalid field focused on failed submit; `autocomplete` set on every auth field; 16 px input text
  below 768 px.
- **Targets**: 32 px controls on pointer devices; at least 40 × 40 below 768 px (nav items, bar
  buttons, form controls, modal buttons). `btn-xs` row actions get `min-h-10` on touch
  (`@media (pointer: coarse)`).
- **Motion**: all of section e's reduced-motion rules. Nothing flashes. No content depends on an
  animation finishing.
- **Zoom and reflow**: usable at 200% zoom and at 320 px width without page-level horizontal
  scroll; only tables and code scroll, inside their own containers.
- **Theme**: `color-scheme` set per theme so native controls match; the toggle is a labelled group
  of three buttons with `aria-pressed`.
- **Language**: `<html lang="en-GB">`.

---

## j. Done checklist

Identity and naming
- [ ] "Qory" in the wordmark, `<title>` (default and suffix), auth pages, emails, the reveal alert; no user-facing "Apiary" as a product name remains (`grep -rn "Apiary" lib/apiary_web` shows only module names and the term component)
- [ ] New mark in `logo_mark/1`, `favicon.svg`, 32 px PNG fallback
- [ ] No consulting customer or counterparty anywhere; no AI attribution; British spelling; sample data synthetic

Tokens
- [ ] Themes `qory` and `qory-dark` with every variable from section c; semantic tokens declared for both and exposed through `@theme inline`
- [ ] Theme script sets `qory` / `qory-dark` (system, light, dark all verified; no flash on load; choice persists; follows the OS live in system mode)
- [ ] Zero legacy utilities: `grep -rnE "surface|ink-|border-line-strong bg-surface|accent-soft|shadow-low|text-danger|bg-overlay|select-field|warn-soft" lib/` is empty; every class used compiles (spot-check the built CSS)
- [ ] Geist and Geist Mono self-hosted under `priv/static/fonts` with `OFL.txt`; no external requests in the network panel

Shell
- [ ] Sidebar 240 px visible from 768 px; one sidebar in the DOM; sections in the specified order; active item per spec; counts shown
- [ ] Workspace block is static with one membership, a dropdown with several; switching posts to the same endpoint
- [ ] User card pinned to the bottom with Account settings, Theme (three-way), Log out; standalone theme row removed
- [ ] Drawer below 768 px: scrim, Escape, closes on navigation, focus managed, main inert
- [ ] Page header anatomy and content widths (960 / 640) on every page

Components
- [ ] Button variants, sizes and all five states; loading keeps width and sets `aria-busy`
- [ ] Input, select, checkbox: rest, hover, focus, error, disabled, readonly; hint and error placement; 40 px and 16 px text below 768 px
- [ ] Table, badge (five colours, dot rule), card with footer bar, joined stats, vertical steps with three states, dashed empty state with hex tile
- [ ] Modal on native `<dialog>` (sizes, bottom sheet on phones, non-dismissable variant, initial focus rules)
- [ ] Toasts bottom-right, neutral surface, auto-dismiss rules; reconnect toasts reworded
- [ ] Tooltip on every icon-only button; term hover works with mouse and keyboard, no native `title`
- [ ] Code block and key/value wells with copy feedback; dropdown keyboard behaviour; avatars; topbar in theme colour

Pages
- [ ] Overview empty (two-column onboarding card, listening line) and with keys (joined stats, steps with progress)
- [ ] Access keys: list with row-hover copy, "Never posted", "n/a", revoked row; create, reveal-once ("I have copied the secret"), rotate confirm and reveal, retire confirm, revoke confirm; all copy as written
- [ ] Members: list, level select, pending invitations with caption, invite modal, remove confirm
- [ ] Settings and account settings as stacked cards with footer actions; Save disabled while invalid
- [ ] No-hive page; invitation accept in its three states
- [ ] Auth split view from 1024 px, header strip below; log in with ONE email field, the password toggle, "Keep me signed in", "Send me a log-in link"; register; "Check your email"; confirmation with one button and the checkbox

Quality
- [ ] Both themes reviewed on every page and every modal; screenshots at 1440, 1024, 768, 375
- [ ] Keyboard-only pass of every flow; VoiceOver pass of log in, create key, invite member
- [ ] axe (or Lighthouse accessibility) reports no violations on each page in both themes
- [ ] `prefers-reduced-motion` verified; no layout shift when fonts load (check `size-adjust` if needed)
- [ ] Existing LiveView tests still pass; selectors that changed (`#login_form_magic`, `#login_form_password` → `#login_form`) updated
