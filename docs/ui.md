# The console's pages

The rules the pages of the console follow, for a contributor who adds a page or changes
one. The words on them are in [lingo.md](lingo.md); where the code lives is in
[architecture.md](architecture.md).

## The shell

Every page behind sign-in renders inside `ApiaryWeb.Layouts.app/1`, which takes the
page's active navigation item (`nav`), the counts the sidebar shows (`counts`), the width
of its column (`width`) and, in `crumb` slots, the page's own segments of the breadcrumb.
The shell is section 4 of the v2 design brief (the knowledge vault's
`product/design/apiary/v2/`): it shows one scope at a time, the one the page belongs to.

- **A page belongs to one scope**: a workspace, an organisation or the person. The
  navigation is data, `ApiaryWeb.Nav.Entry` values, and the entry a page passes as `nav`
  names its scope (`place`) and so the sidebar it shows. A new item of the core goes in
  `nav_entries/1` of `ApiaryWeb.Layouts`, an edition's in its
  `ApiaryWeb.Edition.nav_entries/1`, and never in a page.
- **The top bar** is one `<header aria-label="Top bar">`, 48 px, across the window and
  above the sidebar, first in the tab order after Skip to content. From the left: the
  mark (home), the **breadcrumb** (`<nav id="breadcrumb">`: the organisation, the
  workspace, each a link to its home, and the page's own segments, a target or a record,
  the last one the page with `aria-current="page"`), then **Search or jump to**, **New**
  and the **account menu**. A page's title stays its `<h1>`; the breadcrumb is navigation.
- **The switcher.** With more than one place to go, or an edition's entry after the places
  (`ApiaryWeb.Edition.switcher_entries/1`), the chevrons beside the organisation and the
  workspace open one popover (`role="dialog"`, the `Switcher` hook): a search that filters
  as the reader types, the places opened last (kept in `localStorage`), then each
  organisation with its workspaces, a link to each at the section the reader is on, and
  the edition's groups of places under their own headings
  (`ApiaryWeb.Edition.place_group/1`). ↑ and ↓ move, Enter opens the first match, Escape
  closes and gives focus back. With one place the segments are links and nothing more.
- **Search or jump to** (⌘K, Ctrl+K, and / outside a field) is a `<dialog>` under the
  `Palette` hook, which asks `ApiaryWeb.JumpController` (`/:org/:workspace/jump`,
  `/:org/jump`) what matches, 150 ms after the reader stops typing: the pages of the
  navigation, targets, runs by id or task, places, and what New offers. Every word of it
  comes from the server; a runner's words are written as text.
- **New** offers only what the reader may do where the page is
  (`ApiaryWeb.Layouts.new_entries/1`). **The account menu** holds who they are and their
  level there, their settings and organisations, the theme (Auto, Light, Dark), the docs,
  the changelog, the source and the version, and Log out.
- **The sidebar** holds the scope's pages and nothing else, in groups, each a `<nav>` with
  its own name: a workspace's Overview, then Record (Runs, Connections) and Guard
  (Policy), then the targets the person pinned (`counts.pins`); an organisation's
  Overview, Activity and the edition's groups (`ApiaryWeb.Edition.nav_sections/0`); the
  person's Profile, Preferences and Organisations, which are their settings' list.
  Settings is at its foot, the scope's own; a page of Settings (an entry of the section
  `:settings`, such as Access keys) marks it as the current entry. The active item carries
  `aria-current="page"`. A group whose feature is off is absent, not greyed.
- **The sidebar folds to icons** from 768 px, by its Collapse control or the `[` key; the
  fold is a reading preference in `localStorage`, set before the first paint by the root
  layout's script, and while folded each item's name is its title.
- **Below 768 px the sidebar is a drawer** behind the bar's Open menu button. The
  `NavDrawer` hook moves focus into the drawer, makes the top bar and `#shell-content`
  inert and stops the page scrolling behind it; the scrim, Escape, the Close menu button
  and any navigation close it, and focus returns to the menu button. The bar names the last
  segment of the breadcrumb only.
- **Landmarks.** A Skip to content link is the first thing in the tab order and targets
  the one `<main id="main">`. A page has one `<h1>`, the title of its `<.header>`, which
  also holds a one-line description and at most one primary and one default action. Card
  and modal titles are `<h2>`.

## Settings

Configuration is not navigation: what is set up once and changed rarely lives in the
settings of its scope, GitHub's way, one section a page with the list of sections beside it
(`ApiaryWeb.SettingsComponents.layout/1`). The list is `sections/2`, entries of
`ApiaryWeb.Nav.Entry` a page reads when it mounts: a section the reader may not open is not
in it, and its path sends them to General and says why.

- **An organisation's** (`/:org/settings/…`): General (name, slug, owners), People
  (`/settings/people`: members, invitations, suspensions), Workspaces (owners and admins),
  Audit log (the Activity page, `/:org/activity`, which keeps its path), the edition's
  sections (`ApiaryWeb.Edition.settings_tabs/1`), and Danger zone (deleting it).
- **A workspace's** (`/:org/:workspace/settings/…`): General (name, slug), Access keys
  (`/settings/keys`), Retention, and Danger zone (deleting it, while it is one of several).
- **A person's** (`/users/settings`, `/users/settings/preferences`,
  `/users/organisations`): Profile (email, password, deleting the account), Preferences,
  Organisations; their list is the sidebar of a person's pages.

The list ends with the settings a person may want next ("Elsewhere": the organisation's or
the workspace's, and their own), from 1024 px; below, it is a row of links above the
section. A section of forms keeps a 720 px column, one that is a list (People, Access keys)
960 px. Invite, rotate, revoke, remove, suspend and the deletions stay dialogs over their
section, each at a path of its own. The old paths, `/:org/members/…` and
`/:org/:workspace/keys/…`, send on to the new ones (`ApiaryWeb.MovedController`).

An organisation's own path, `/:org`, is its overview (`ApiaryWeb.OrganisationLive`): the
workspaces the person reaches, what each is doing, and the organisation's people. The
breadcrumb's organisation leads there; `/` still sends a person to the workspace they
opened last.

## Widths

Every page starts at the same left edge, 32 px from the sidebar (24 px below 1024 px, 16
below 768); nothing is centred in the space beside it. `width` is one of three:

- `list` (the default): fluid, up to 1680 px, for the lists and the overviews. A list
  page with a rail or a preview pane beside its list takes `work` and caps itself at
  1680 px (`.q-lp`); from 1920 px an open preview is the one thing that takes more.
- `work`: fluid, with no cap, for a work surface such as a run.
- `read`: a 720 px column, for forms and settings; prose inside anything keeps 72ch.

A sticky tab bar (`.q-tabs`) sticks under the top bar and bleeds to the page's gutter
(`--q-gutter`). The classes of the shell are in `app.css`'s shell block, and they are
`@layer qory`: a Tailwind display utility on the same element loses to them, so the shell
hides its own parts on phones in that block.

## Lists

A long list is narrowed one way, GitHub's (the brief's principles 4 and 12): filters that
are written in the URL, never groups the reader has to open. The runs list
(`ApiaryWeb.RunLive.Index`) is the pattern, and the workspace's connections follow it; the
controls are `RunComponents`', and `Apiary.Runs.Filters` reads and writes every one of them.

- **Views** are tabs above the list (`<.views>`): a few fixed ones, each a link that sets the
  filters it stands for and keeps the others, with its count under the other filters; the
  current one is `aria-current="page"`, and All when no other is. The runs list's are All,
  Alive, Ended badly and With denials; the connections' are the decisions. The counts are
  the only numbers above the list; a line under the controls says how many match only when
  the list is narrowed ("87 runs match · Clear").
- **One query field** (`<.query_bar>`) shows the filters set as tokens, `qualifier:value`,
  each with its own remove button, and takes more on Enter: qualifiers (`repo:`, `state:`,
  `task:`, `runtime:`, `host:`, `key:`, `started:>2026-09-01`, `denied:yes` on the runs list)
  become the URL's parameters, the rest is the free text, `q`, matched as text and without
  regard to case. A word it cannot read is said in a notice, never dropped in silence. A
  view's own filter is not repeated as a token.
- **One Filter menu** (`<.filter_menu>`) writes the same filters: a dialog that lists its
  sections, then the one chosen, with a way back. A section's values are counted under
  the other filters and searched on the server over every value there is (`narrow`), fifty
  shown, more on asking. No row of facet buttons.
- **Sort** (`<.sort_menu>`) is a menu of orders, each a link.
- **The rail** (`<.target_rail>`, from 1280 px) is the targets with their counts under
  every filter but the target: a search on the server, every target, the pinned ones
  (`counts.pins`), then the busiest twenty and "n more". Choosing one sets the target; below
  1280 px the Filter menu's Target section does it instead, and never both.
- **A row is one line** (the brief's principle 9): the title, the only strong text; its
  target after it in muted mono until the table is 1000 px wide, then in a column; the
  other facts small and grey, the tertiary ones faint. Colour only for what needs someone:
  a run's state is a dot, with its word for a state that needs a look (never for one that
  ended well), and denials are red only when there are any. Columns join by the table's
  own width (container queries), so a table beside a rail or a preview reflows as a
  narrower screen would.
- **A target has one notation** (`<.target_name>`): its path in mono, its system faint
  before it only where the workspace has that path on more than one system
  (`Apiary.Runs.duplicate_paths/1`).
- **Pages** of 25, 50 or 100, "1–50 of 3,137", the page before and after named by the order
  (Newer, Older), and Jump to date on the orders by time; the page is a parameter, so a
  page is a link.
- **The preview** of the runs list is for 1920 px and more: a pane beside the list, a
  rule at its left and no card, of the run chosen (`?run=`; the first row until the
  reader chooses one). The `RunList` hook tells the page the width, turns a row's click
  into a choice there, and moves it with ↑ and ↓; Enter or a second click opens the run.
  Below 1920 px a row is a link to its page.
- **Nothing narrowing, nothing to show** is an empty state with no table and no pages:
  what the filters hide, the last filter to remove and Clear filters.

## Components

A page composes components; it does not write its own button, input, table, modal or
badge. The general ones are in `ApiaryWeb.CoreComponents` (`core_components.ex`); the
ones a group of pages shares are beside them: `RunComponents` for the controls of a list,
the runs list, the run page and the connections pages, `RunPageComponents` for the run page,
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

An edition adds to a core page only in the places the page gives it: a slot
(`ApiaryWeb.Extension`), a section of the organisation's settings (`ApiaryWeb.SettingsComponents`)
or a navigation entry. What it renders there links to its own pages, which handle its
events; a page whose behaviour differs is the edition's own at the same path.

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

**Scripts.** A hook lives under `assets/js/hooks/` and is registered in `hooks.js`, the
collection `app.js` and an edition's bundle import. It holds no words (see
[lingo.md](lingo.md)), and keeps in `localStorage` only a reading preference, such as
the sidebar's fold; filters, the order, the page and a chosen row are query parameters.

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
  undone. Deleting a workspace or an organisation asks for its slug, typed, and the
  button stays disabled until it matches; a control that cannot act, such as the only
  owner's Delete account, is disabled and the page says why beside it.
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
