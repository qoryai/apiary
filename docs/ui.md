# The console's pages

The rules the pages of the console follow, for a contributor who adds a page or changes
one. The words on them are in [lingo.md](lingo.md); where the code lives is in
[architecture.md](architecture.md).

## The shell

Every page behind sign-in renders inside `ApiaryWeb.Layouts.app/1`, which takes the
page's active navigation item (`nav`), the counts the sidebar shows (`counts`) and the
width of its column (`width`): `wide` is 960 px, `narrow` 640 px for settings, and `full`
1200 px for the runs, run and connections pages.

- **The sidebar is the organisation's.** At its top the organisation and the workspace,
  which become the switcher when the person has more than one membership; then the
  navigation, two groups, each a `<nav>` with its own label; at its foot the Qory Apiary
  menu with the version. The active item carries `aria-current="page"`. A new item goes in
  `nav_items` and `nav_path/3` of `ApiaryWeb.Layouts`, not in a page.
- **The top bar** is one `<header aria-label="Top bar">`, 52 px, level with the sidebar's
  top row. It holds the theme menu and the account menu at its right end and nothing of
  the page: no title, no breadcrumb.
- **Below 768 px the sidebar is a drawer** behind the bar's Open menu button. The drawer's
  side comes before the content in the DOM, so the tab order is sidebar, top bar, main at
  every width without a `tabindex`. The `NavDrawer` hook moves focus into the drawer,
  makes `#shell-content` inert and stops the page scrolling behind it; the scrim, Escape,
  the Close menu button and any navigation close it, and focus returns to the menu button.
- **Without a membership** there is no sidebar and no drawer: the bar carries the Qory
  Apiary menu at its left.
- **Landmarks.** A Skip to content link is the first thing in the tab order and targets
  the one `<main id="main">`. A page has one `<h1>`, the title of its `<.header>`, which
  also holds a one-line description and at most one primary and one default action. Card
  and modal titles are `<h2>`.

## Components

A page composes components; it does not write its own button, input, table, modal or
badge. The general ones are in `ApiaryWeb.CoreComponents` (`core_components.ex`); the
ones a group of pages shares are beside them: `RunComponents` for the runs list, the run
page and the connections pages, `RunPageComponents` for the run page,
`PolicyComponents` and `OverviewComponents` for theirs, and `ApiaryWeb.RichText` for a
translated sentence with markup in it. A look a second page needs becomes a component,
or an attribute of one, not a copy.

- **`<.button>`** has the variants `primary`, `default`, `ghost`, `danger`,
  `danger-ghost` and `link`, and renders a link styled as a button when given `navigate`,
  `patch` or `href`. `primary` marks the one main action of a screen. `loading_text` is
  the gerund ("Saving") the button shows, with a spinner and `aria-busy`, while its form
  submits; the button keeps its width.
- **`<.modal>`** is a native `<dialog>` under the `Modal` hook. Escape and the backdrop
  run its `data-cancel` command, usually a patch back to the page beneath; a dialog
  without one cannot be dismissed. Focus returns to what opened it.
- **Menus** are daisyUI dropdowns under the `Menu` hook: a click opens and leaves focus on
  the trigger; Enter, Space and ArrowDown open and focus the first item, ArrowUp the last;
  the arrows wrap, Home and End go to the ends, Escape closes and returns focus.
- **`<.table>`** is a scroll region of its own, focusable and labelled (`label`), so a
  wide table scrolls inside the page and never the page sideways.
- **`<.empty_state>`** says what is missing and offers the one next step.

The styles are in `assets/css/app.css`. Overrides of daisyUI are in `@layer utilities`,
wrapped in `:where()` so a Tailwind utility on the element still wins; the classes a group
of pages owns are in `@layer qory` and start with `q-`, clear of daisyUI's names.

A component does not ask `Apiary.Features` what the instance serves: the page asks with
its scope and passes the answer, as the connection row's `security` attribute does. What a
runner reported is untrusted: a component interpolates it and never passes it to `raw/1`.

## Colour and themes

`app.css` defines two daisyUI themes, `qory` (light, the default) and `qory-dark`. The
script in `root.html.heex` sets `data-theme` from the theme menu (Auto, Light or Dark,
kept in `localStorage`); Auto follows the system, and without JavaScript the
`prefers-color-scheme` block does the same. The dark theme is designed on its own, not
inverted.

- **Colours are tokens.** Beside daisyUI's theme colours, the `--q-*` custom properties
  are exposed to Tailwind as `line`, `line-strong` and `line-field` for borders, `muted`
  and `faint` for secondary and tertiary text, `ring`, `code`, `overlay`, the soft fills
  (`primary-soft`, `success-soft`, `error-soft`, `info-soft`, each with `-content`), the
  lanes, the terminal and the chart series; and as the shadows `xs`, `pop` and `modal`.
  A template names a token, never a literal colour. A new token is defined
  in all three places: `[data-theme="qory"]`, `[data-theme="qory-dark"]`, and the
  `prefers-color-scheme: dark` block for a page without the script. With tokens a
  `dark:` variant is rarely needed.
- **Honey is for one thing.** `primary` marks the main action of a screen, a checked box,
  the current step and the mark. It is too light to be text on the light theme: links and
  the active navigation icon use `accent`.
- **Colour marks a state, never a mood,** and is never the only carrier: a badge has its
  word, an error its icon and sentence, an allowed or denied row its glyph and word.
- **Borders on the page, shadows in the air.** What rests on the page has a 1 px border
  and at most `shadow-xs`; only what floats (menus, toasts, tooltips, modals, the drawer)
  has a real shadow.

## First paint and live pages

**The first paint is never blocked.** A mount reads only what the shell and the top of
the page need; every other region is read with `assign_async`, `start_async` or
`stream_async` and shows a skeleton until it lands. These are the ones of
`ApiaryWeb.Async`, which `use ApiaryWeb, :live_view` imports in place of LiveView's, so
the read logs under the page's organisation and workspace. A later read keeps what is on
screen until the new data arrives, and a read that fails says so in a sentence.

**Rows are patched in place, and nothing moves under the reader.** A live page follows
its context's topic and applies what arrives at most every 250 ms. Every row has a
stable DOM id taken from the record (`run-#{id}`), never an index, so a change to a row
on the page updates that row and nothing else. A row that did not exist when the reader
arrived is never inserted above what they are reading: the page says it in words instead
("1 new run", or the new-items pill, `<.new_items>`), and the reader asks for it. The run
timeline is a stream: the `LiveEnd` hook tells the LiveView whether the reader is within
240 px of the end; there new items append, anywhere else the pill counts them, and the DOM
never holds more than 600 items.

**Times tick in the browser.** A relative time, a clock or a running duration is a
`<time>` with the instant in `datetime` (ISO 8601, UTC), a `data-tick` kind (`relative`,
`clock`, `duration`, `seconds`) and the server's now in `data-now`; `<.relative_time>`
and `<.duration>` render them. The `Ticker` hook re-renders every one from a single
interval, once a second, paused while the tab is hidden, and counts on the server's clock
rather than the browser's. It writes in the words, locale and time zone the server put on
`<body>`, so the server never re-renders for a clock. The full time with its zone is the
`title`. Everything else a person reads as a date, time or number goes through
`ApiaryWeb.Format`.

**Scripts.** A hook lives under `assets/js/hooks/` and is registered in `app.js`. It
holds no words (see [lingo.md](lingo.md)), and keeps in `localStorage` only a reading
preference, such as which groups of the runs list are collapsed; filters, grouping and
the page are query parameters.

## The terminal

`<.terminal>` in `RunPageComponents` is dark in both themes: the recorded output's colours
are written against a dark ground. The `Terminal` hook reads the bytes from the run's log
endpoint and hands them to xterm.js as `Uint8Array`s, never decoded strings, in slices per
frame so a long log does not block input. The bytes never cross the LiveView socket: the
LiveView sends the foot's numbers and a signal that the log advanced. xterm.js is vendored
under `assets/vendor/xterm`, built as its own bundle and loaded on the hook's first mount,
by no other page. The screen is `role="log"` with `aria-live="off"`.

## Words

Every visible or announced string goes through Gettext in engine words, one whole
sentence per msgid, and markup inside a sentence goes through `ApiaryWeb.RichText`; the
rules are in [lingo.md](lingo.md). A page says organisation and workspace as plain words,
and names the product Qory Apiary.

- Plain and exact: second person, present tense, sentence case. Full stops on sentences,
  none on buttons, labels or headings. No exclamation marks, no "oops", no "successfully".
- A button says what happens ("Send me a log-in link"); a toast says what happened
  ("build-01 is revoked."); a confirm states the consequence, then whether it can be
  undone.
- The page says what the record says and infers nothing. A value the record lacks reads
  "n/a"; a key that never posted says so.

## Accessibility

- **Focus.** One global `:focus-visible` ring in `--q-ring`; a control never loses its
  focus style without a replacement. The tab order is the visual order, with no positive
  `tabindex`. A failed submit puts the caret in the first invalid field.
- **Names.** An icon-only button has an `aria-label`. A row action names its object
  ("Revoke build-01") while its visible text stays short. A field has a visible label, and
  its error is tied to it with `aria-invalid` and `aria-describedby`.
- **Live regions.** A page that changes while it is read has one polite announcer
  (`#run-announcer`, `#overview-announcer`, `#policy-announce`) for the few things worth
  saying. Ticking text, a filling timeline and the terminal are `aria-live="off"`. Toasts
  are `role="status"` or `role="alert"`; an info toast leaves after 5 s, and hovering or
  focusing it holds it. A copy is announced politely.
- **Motion.** Motion shows cause and effect for what floats; layout, rows and streamed
  inserts never animate. The only loops mean "still being written": the spinner, the
  skeleton and the alive ripple. Under `prefers-reduced-motion: reduce` the global block
  in `app.css` zeroes every duration, the loops stand still, and a hook that scrolls uses
  `behavior: "auto"`.

## Phones and touch

The breakpoint is 768 px (Tailwind's `md`). Below it the sidebar is the drawer, the
gutter is 16 px, controls are 40 px high and inputs take 16 px text so the browser does
not zoom. On a touch screen (`pointer: coarse`) a small control gets a 40 px hit area
whatever its drawn size. At 320 px wide, and at 200% zoom, the page never scrolls
sideways: tables, code, the filter bar and the terminal scroll inside their own
containers.
