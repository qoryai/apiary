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
  **breadcrumb** (`<nav id="breadcrumb">`: the organisation first, its tile and its name,
  then the workspace, each a link to its home, and the page's own segments, a target or a
  record, the last one the page with `aria-current="page"`), then **Search or jump to**,
  **New** and the **account menu**. The bar has no mark: Qory Apiary is the sidebar's
  foot. A page's title stays its `<h1>`; the breadcrumb is navigation. A page without a
  person has no sidebar, and the Qory Apiary menu opens downward from the bar's left.
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
  (`ApiaryWeb.Layouts.new_entries/2`): on a workspace's page a new access key and an
  invitation, on an organisation's own the invitation, and before the core's whatever
  the edition offers there (`ApiaryWeb.Edition.new_entries/2`), each entry asked of the
  workspace or the organisation as its place says. **The account menu** holds who they are and their
  level there, their settings and organisations, the theme (Auto, Light, Dark), and Log
  out; nothing about Qory Apiary itself.
- **The sidebar** holds the scope's pages and nothing else, in groups, each a `<nav>` with
  its own name: a workspace's Overview, then Record (Runs, Targets) and Guard (Network
  access, then Policy; without `security` Network access alone, the record of it), then
  the targets the person pinned (`counts.pins`, the first seven in the
  order pinned, `Apiary.Targets.list_pins/2`; on a target's page its pin is the current
  entry); an organisation's
  Overview, Activity and the edition's groups (`ApiaryWeb.Edition.nav_sections/0`); the
  person's Profile, Preferences and Organisations under Your settings, which are their
  settings' list. It is never replaced: a page of a scope's settings keeps the scope's
  sidebar. The active item carries `aria-current="page"`. A group whose feature is off is
  absent, not greyed.
- **The sidebar's foot** holds the scope's Settings, a workspace's or an organisation's,
  the current entry on every page of them (Settings itself, or an entry of the section
  `:settings`, such as Access keys), then, under a rule, **the Qory Apiary menu**
  (`#brand-menu`): the mark, the name and the
  version, opening upward to Docs, Changelog (on an instance with every feature) and
  Source on GitHub, what is about the product rather than the person; and at the right of
  it the fold.
- **The sidebar folds to icons** from 768 px, by the fold (`#sidebar-collapse`, an icon
  button named Collapse sidebar, or Expand sidebar while folded, in its label and its
  tooltip) or the `[` key; the fold is a reading preference in `localStorage`, set before
  the first paint by the root layout's script, and while folded each item's name is its
  title. Folded, the foot is the fold over the mark alone, which still opens the menu,
  upward and to the right; the groups are split by rules, their headings gone.
- **Below 768 px the sidebar is a drawer** behind the bar's Open menu button, its head a
  Close menu button and its foot the same, without the fold. Open, it is a modal dialog
  (`role="dialog"`, `aria-modal`). The `NavDrawer` hook moves focus into the drawer, makes
  the top bar, `#shell-content` and Skip to content inert and stops the page scrolling
  behind it; the scrim, Escape, the Close menu button and any navigation close
  it, and focus returns to the menu button. The bar names the last segment of the
  breadcrumb only.
- **Landmarks.** A Skip to content link is the first thing in the tab order and targets
  the one `<main id="main">`. A page has one `<h1>`, the title of its `<.header>`, which
  also holds a one-line description and at most one primary and one default action. Card
  and modal titles are `<h2>`.

## Settings

Configuration is not navigation: what is set up once and changed rarely lives in the
settings. There are three kinds, GitHub's repository, organisation and personal settings,
and each is a place of its own, reached from its own scope, that lists its own sections
and no other kind's: no "Elsewhere", no link across. A navigation item never replaces the
navigation it is in.

- **A workspace's** (`/:org/:workspace/settings/…`), from the workspace sidebar's
  Settings: General (name, slug, and its danger zone), Access keys (`/settings/keys`),
  Retention.
- **An organisation's** (`/:org/settings/…`), from the organisation's pages (the
  breadcrumb's organisation leads to its overview, whose sidebar has Settings): General
  (name, slug, owners, and its danger zone), People (`/settings/people`: members,
  invitations, suspensions), Workspaces (owners and admins;
  `SettingsComponents.workspace_list/1`, which an edition's page over the same list
  renders too, with the edition's way of adding one in the section's actions, the
  `:workspaces_heading` slot), Audit log (the Activity page,
  `/:org/activity`, which keeps its path), and the edition's sections
  (`ApiaryWeb.Edition.settings_tabs/1`). From a workspace the palette's Go to and New ›
  Invite people lead there too; nothing else in a workspace does.
- **A person's** (`/users/settings`, `/users/settings/preferences`,
  `/users/organisations`), from the account menu's Your settings: Profile (email,
  password, and its danger zone), Preferences, Organisations. A person has no pages but
  these, so their sidebar is the list, under the heading Your settings, and a page's
  `<h1>` is its section's title.

A workspace's and an organisation's settings keep the scope's sidebar, its Settings the
current entry, and are one section a page (`ApiaryWeb.SettingsComponents.layout/1`): the
`<h1>` "Workspace settings" or "Organisation settings", at the page's left edge the list
of the kind's sections (`#settings-tabs`, `settings-tab-<key>`; `sections/2`, which a page
reads when it mounts), and beside it the section, its title an `<h2>`, one sentence of
what it is for, then its content, a 720 px column for forms and 960 px for a list (People,
Access keys). Below 1024 px the list is a row of links above the section. A section the
reader may not open is not in the list, and its path sends them to General and says why.
The breadcrumb ends with Settings (`8wonders / Main / Settings`, `8wonders / Settings`); a
person's page names itself.

**The danger zone** ends its scope's General page, and Profile, GitHub's way
(`SettingsComponents.danger_zone/1`): after a rule, the heading Danger zone, the page's
only red words, then a line for each act that cannot be undone (`danger_action/1`), its
title, one muted sentence of what it does and what cannot be undone, and at the right a
default button in the error colour, Delete organisation…, Delete workspace… or Delete
account…. No box, and never an entry of a list. The button opens the confirm dialog, where
the red button is, at a path of its own over the page: `/:org/settings/danger`,
`/:org/:workspace/settings/danger` and `/users/settings/delete` (the older
`/…/settings/delete` paths open the same dialogs). Where the act is not there, the line
says why in place of the button: the instance's own organisation, the organisation's only
workspace. A reader who may not delete the scope sees no danger zone, and the dialog's
path sends them to General and says why.

Invite, rotate, revoke, remove, suspend and the deletions stay dialogs over their
section, each at a path of its own. The old paths, `/:org/members/…` and
`/:org/:workspace/keys/…`, send on to the new ones (`ApiaryWeb.MovedController`).

An organisation's own path, `/:org`, is its overview (`ApiaryWeb.OrganisationLive`): the
workspaces the person reaches, what each is doing, and the organisation's people. The
breadcrumb's organisation leads there; `/` still sends a person to the workspace they
opened last.

## Lists

A page that lists things reads top down, and every level of it has a look of its own
(principles 8 to 12 of the v2 brief): a summary, the largest numbers on the page, only
where the page has one; then blocks or tables, each one box; then rows. Two levels that
look alike are one level too many, and nothing is boxed inside a row.

- **A row is one line.** Its title, the thing's name, is the only strong text: 14 px,
  medium, in the text colour. Every other cell is 12.5 px and muted; what is tertiary is
  faint; the one fact that needs someone is lifted to the text colour (`q-hot`). `<.table>`
  does this by default: a column says `kind="title"`, `"hot"`, `"faint"` or `"num"`, and a
  secondary word beside the title (an id, a slug, "you") takes `q-side`. A row out of use
  (revoked, suspended) is `row-off`, its title muted.
- **A state is said only when it is not the usual one.** An active key, a member in use,
  a run that ended well say nothing (a screen reader hears the word); a rotated key, a
  suspended member, a revoked key say so in words (`<.state_word>`), with a dot and the
  text colour when the state needs someone. A pill is for a state of at most two words
  that needs someone, and never on every row.
- **A row's acts.** The one act its state asks for is a text action (`<.button
  variant="link">`, "Retire previous secret"); the rest are in its ⋯ menu
  (`<.row_menu>` with `<.menu_item>`s, a heading and dividers between groups), which
  floats in the top layer so the table's scroll region never clips it. A choice of one,
  such as a person's level, is a set of `menuitemradio` items with what each means. A
  destructive item opens its confirm dialog at a path of its own; red is for that
  dialog's button only. No bordered button on every row.
- **Columns grow with the table**, not the screen: `from="sm" | "md" | "lg"` shows a
  column from 600, 1000 or 1300 px of the table's own width (a container query), so a
  table in a narrow pane reflows as it would on a narrow screen.
- **A target** is its path in mono, with its system in faint type before it only where the
  same path is on more than one system (`<.target_name>`, `Apiary.Runs.shared_paths/2`).
- **One way to narrow a list**: views as tabs with their counts (`<.views>`), one search
  (`<.list_search>`), one Filter menu whose sections write the filters
  (`<.filter_menu>`), Sort (`<.sort_menu>`), and the filters in force as removable tokens
  under the bar (`<.filter_tokens>`). Every choice is in the URL. No row of facet buttons;
  a rail never repeats a menu.

### The runs list and Network access

A long record is narrowed by filters written in the URL, never folded into groups the
reader has to open (the brief's principle 4). The runs list (`ApiaryWeb.RunLive.Index`)
and the workspace's Network access (`ApiaryWeb.ConnectionLive.Index`,
`/:org/:workspace/network`: every destination the runs reached, what decided it, and the
way to allow or deny it) are one flat list each, and `Apiary.Runs.Filters` reads and
writes every control of them. The page was Connections: `/:org/:workspace/connections`
and a run's `/runs/:run_id/connections` send on to the new paths with their query, moved
permanently (`ApiaryWeb.MovedController`). A connection as a thing keeps its word: a row is
a destination and the connections made to it. The Policy page's hosts and paths are its
Network access section, which links to the page ("See what the runs reached"); the page's
rule links lead to the rule there.

The policy's lists of rules (`PolicyComponents.rule_list/1`, on the workspace's Rules tab
and on a target's Policy tab) are on the same pattern, their query read and written by
`ApiaryWeb.PolicyLive.RuleList`, pure over the rows the page holds: views All, Allowed,
Denied and Locked, each counted under the search and the other filters, the Rules tab's
count the All view's with nothing narrowed (the rules, not the credentials); "Find a host" with the qualifiers `seen:`, `paths:`, `by:` and
`source:` as tokens, sent as the reader types and read whole on Enter; one Filter menu
whose sections come from the rows' sources and people (an edition that adds rules of
another holder gives them a source, and the menu, the qualifier and the order take it);
Sort (the list's own order, Host, Most used, Recently added); pages of 50; and `?rule=`,
which Network access links with, landing on the page that holds the rule and marking it.
A target's Policy tab shows each rule's Source; its own rules come first and have the ⋯
menu's acts, the workspace's are read there and lead to the workspace's page. A rule of
the level above the workspace has that level's tile in its Source, which says whose it is;
the faint lock is a locked rule of the workspace's alone, what the Locked view counts.
Above the rules, the workspace's mode is one line, as a target's is
(`PolicyComponents.mode_switch/1`, `target_mode/1`): Mode, Observe | Enforce as a
segmented radio group, a required mode's lock and whose it is, then one sentence of what
the mode does and who follows it, and the record of the last 7 days with its link, beside
the control and never inside it.

- **Views** are the runs list's All, Alive, Ended badly and With denials, and Network
  access's decisions, each counted under every other filter; All is current when no
  other is. A view's own filter is not repeated as a token. The number that matches is a
  line over the list, only when the list is narrowed ("87 runs match"), in the list's
  status region (`role="status"`, `.q-status`), which is always rendered, empty and taking
  no place otherwise, so a screen reader hears what a view, a filter or a search left; an
  empty list says its empty state's title there too.
- **The search is a query** (`<.list_search live={false}>`, sent on Enter): qualifiers
  (`repo:`, `state:`, `task:`, `runtime:`, `host:`, `key:`, `started:>2026-09-01`,
  `denied:yes`; `decision:`, `tools:`, `seen:` on Network access) become the URL's
  parameters and show as tokens, and the other words are the free text, `q`, matched as
  text without regard to case (a run's id, task or target; a destination's host or
  path). A word it cannot read is said in a notice, never dropped in silence.
- **The Filter menu has sections** (`<.filter_menu>` with `section`s): too many values for
  a menu, each section searches its values on the server over every value there is,
  fifty shown and more on asking, each counted under the other filters
  (`RunComponents.filter_options/1`).
- **The rail** (`<.target_rail>`, from 1280 px) holds the targets with their counts under
  every filter but the target, in the list's unit: runs on the runs list ("Most runs"),
  destinations on Network access ("Most destinations"), as its views and its Filter
  menu's Target section count them. A search on the server, every target, the pinned ones
  first under Pinned (`counts.pins`), then the busiest twenty and "n more", its own
  headings under an `<h2>` for a screen reader so the outline never skips a level.
  Choosing one sets the target; below 1280 px the Filter menu's Target section does it,
  never both.
- **A run is one line** (`<.runs_table>`): its task, else its id, the only strong text; its
  target after it until the table is 1000 px wide, then in a column; its state a dot
  (`<.run_mark>`) with its word where the state needs a look, and its denials red only
  when there are any.
- **A destination is one line** (`<.connections_table>`, `RunComponents.connection_row/1`):
  its host in mono, the port faint and the path muted, the only strong text; its runs and
  attempts muted numbers; allowed and denied a thin split with its two numbers, the denied
  one red only when there is one, and the words for a screen reader; the reason of the last
  attempt one muted line, the rule in mono and nothing bold, whole on hover, a line under
  the destination below 600 px of table. No tint and no decision mark (a run's tab keeps
  its marks). Columns join as the table widens, so nothing is cut at the right: the reason
  from 600 px, the last seen from 780, the runs from 840, the attempts and the outcome from
  1300. Allow and Deny are text shown on hover, on focus inside the row and while the
  row's popover or menu is open (always on a touch screen, in the menu alone below 600 px
  of table); the ⋯ menu (`rule_menu/1`) holds Allow…, Deny…, Only this host and Copy the
  host. A locked rule, and the wall, are a faint lock: the menu says who locked it and
  when, or why no rule changes it, and leads to the rule. A row opened by its chevron
  lists the runs that reached it as lines under it, a dot for each state, no box. The
  default order, Denied first, puts the destinations whose last attempt was denied
  first, the most denied attempts first and then the most recently seen, as Needs
  attention weighs them; the rest by when they were first seen, so they hold still.
- **Pages** of 25, 50 or 100 (`<.pager>`), "1–50 of 3,137", the page before and after named
  by the order (Newer, Older), and Jump to date on the orders by time.
- **The preview** is for 1920 px and more: a pane beside the list, a rule at its left and no
  card, of the run chosen (`?run=`; the first row until the reader chooses one), with the
  last lines of its log as plain text. The `RunList` hook tells the page the width, turns
  a row's click into a choice there, and moves it with ↑ and ↓; Enter or a second click
  opens the run. Below 1920 px a row is a link to its page.
- **Nothing to show** is an empty state with no table and no pages: what the filters hide,
  the last filter to remove and Clear filters.

## The overviews

The workspace overview (`ApiaryWeb.WorkspaceLive.Overview`, `OverviewComponents`) answers
what needs the reader, then what their agents did, and never grows with the data:

- **The summary**: alive now, runs, runs that ended badly and denied attempts over
  fourteen days, each a link to the list it counts.
- **Needs attention**: one line an item, its mark, its subject, where it is, the reason
  in a few words (the longer sentence on hover), when, and the one text act that settles
  it; five shown and "and n more". Its Allow is Network access's: where the level above
  the workspace denies the host, or allows only its own hosts, no allow here would be in
  force, so the item offers the way to that level's page to one who may change it there,
  and a lock with the reason to the rest. A resolved item stays, struck, until the next
  navigation; one that arrives is announced (`#overview-announcer`), never inserted above
  what is read.
- **Activity**: runs and denied attempts per day on one day axis, drawn for the width the
  `DaysChart` hook measured, with its table twin a text action away.
- **Active targets**: the eight with the most runs, each with its last run (a dot, and a
  word only when it is running or ended badly), a sparkline of its days and its denials.
- **Guard**: a few lines of key and value, each with a muted detail and one link: the
  policy's mode and version, the targets with rules of their own, retention.
- A workspace no run has reached is one box: the steps from a key to the first run and
  the server block to paste.

An organisation's overview lists its workspaces one line each, six at most and a link to
all, with its people and details as lines beside them.

## Targets

A workspace's targets have an index and a page each, GitHub's organisation repositories
and repository page in the target's words (`ApiaryWeb.TargetLive.Index`, `…Show`; the
reads are `Apiary.Targets`'s, the looks `ApiaryWeb.TargetComponents`'s).

- **The notation.** A target is its path in mono (`<.target_name>`); its system goes
  before it, faint, only where the same path is in another system of the workspace
  (`Apiary.Runs.shared_paths/2`), and always on its own header and crumb. A run's state
  is a dot and, when the run needs a look, its word (`<.state_mark>`), never a pill.
- **The index** (`/:org/:workspace/targets`, width `list`) is narrowed the way every list
  is (Lists, above): views with the workspace's counts (All, Active this week, Never ran),
  one search, one Filter menu (System, Activity, Policy, Pinned) and Sort (Last run, Name,
  Most runs in 14 days, Most denials in 7), with the filters in force as tokens under the
  bar. A filter is a qualifier of the search (`forge:` in the software domain, `mode:`,
  `activity:`, `is:pinned`; `ApiaryWeb.TargetLive.Query`): the menu writes it, and one
  the reader types becomes a token on Enter, never half typed. All of it is the URL; a
  value the page does not know is left out. A row is one line on the row spec: the
  reader's ★, the path the title, the last run as a dot and a time (its word when it is
  running or went badly), a 14-day sparkline of runs with their number, the share that
  ended well (in the error colour below 80 %), the denied attempts of 7 days in red when
  there are any, and the policy mode only where the target sets its own. Pages of 50.
  Below 600 px of table the last run is a line under the path. It reads in one query
  bounded by the fourteen days, and re-reads at most once a second as runs land, changing
  the rows it holds in place.
- **A target's page** is `/:org/:workspace/targets/:system/*path`, its tabs after a `-`
  segment, GitLab's way (`target_path/4`): Overview at the bare path, then `…/-/runs`,
  `…/-/network` (once `…/-/connections`, which the page sends on with its query, moved
  permanently) and, with `security`, `…/-/policy` with the policy's own paths after it
  (`/history`, `/document`, `/versions/:n`, `/export`). A path with a segment that
  would be misread (empty, `-`, `.`, `..`) is one segment, its slashes escaped. A target
  the workspace does not have, and a tab the page does not know, are not found. The header
  is the target in full with the reader's pin, one muted line (its runs since it was first
  seen, its last run, and its mode only where it sets its own) and Open on the system when
  the system is a host name; the breadcrumb's third segment is the target.
  - **Overview**: two cards, each one list, the few with a link to the many (its last
    runs; the destinations it was denied in 14 days), beside a plain About column (the
    system and path, when it was first seen and by which run, the same path elsewhere,
    its runs a day, its machines and runtimes). A run that lands is counted, never
    inserted, and comes in when asked.
  - **Runs**: its latest runs, one line each, and all of them in the runs list.
  - **Network access**: the Network access page's content with the target fixed
    (`ApiaryWeb.ConnectionLive.Index.fix_target/3`): its own path, no Target section,
    token or rail, and "New activity" leading the tab.
  - **Policy**: the target's view of the policy (`ApiaryWeb.PolicyLive.Target`): its
    mode on one line (Follow the workspace, by its name, Observe or Enforce, and whose
    the mode is), the rules in force for it on the list pattern with their Source, its
    credentials with theirs, and its history and document as views under the page's
    tabs. Its old paths, `/policy/targets/:target_id/…`, send on here
    (`ApiaryWeb.TargetMovedController`).

  A tab is its own mount; a tab another page's module answers is handed the page's
  parameters, events and messages while it is open.
- **Pins** are the person's own (`target_pins`): the ★ of a row and of the header, and the
  sidebar's Pinned group.

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

## Components

A page composes components; it does not write its own button, input, table, modal or
badge. The general ones are in `ApiaryWeb.CoreComponents` (`core_components.ex`); the
ones a group of pages shares are beside them: `RunComponents` for the runs list (its
Filter menu's sections, the rail, the pager, the runs table and the preview), the run page
and Network access, `RunPageComponents` for the run page,
`PolicyComponents` and `OverviewComponents` for theirs, and `ApiaryWeb.RichText` for a
translated sentence with markup in it. A look a second page needs becomes a component,
or an attribute of one, not a copy.

- **`<.button>`** has the variants `primary`, `default`, `ghost`, `danger`,
  `danger-ghost` and `link`, and renders a link styled as a button when given `navigate`,
  `patch` or `href`, unless it is `disabled`: a disabled one is a `<button disabled>`
  whatever its path, never a link that still focuses and patches to itself (the pager's
  Newer on its first page). `primary` marks the one main action of a screen. `loading_text` is
  the gerund ("Saving") the button shows, with a spinner and `aria-busy`, while its form
  submits; the button keeps its width.
- **`<.input>`** is every field; with `prefix` a text input shows, in mono before the
  value and as one field, what the value completes: the path of the organisation before
  a workspace's slug.
- **`<.modal>`** is a native `<dialog>` under the `Modal` hook. Escape and the backdrop
  run its `data-cancel` command, usually a patch back to the page beneath; a dialog
  without one cannot be dismissed. Focus returns to what opened it. From 640 px it sits
  near the top over a plain scrim, never a blur, so what it acts on stays legible behind
  it; while it is open the window's title names it before the page's.
- **Menus** are daisyUI dropdowns under the `Menu` hook: a click opens and leaves focus on
  the trigger; Enter, Space and ArrowDown open and focus the first item, ArrowUp the last;
  the arrows wrap, Home and End go to the ends, Escape closes and returns focus. The items
  are not tab stops (`tabindex="-1"`, as `<.menu_item>` renders them): Tab closes the menu
  and moves on from its trigger. A field inside a Filter section keeps its own keys, and
  ArrowDown from a section's search goes to its first option. With
  `data-float` the list is a popover in the top layer, placed under its trigger, so no
  scroll region clips it (a row's menu, a list's Filter and Sort).
- **`<.table>`** is a scroll region of its own, focusable and named by its `label`, which
  is required, so a wide table scrolls inside the page and never the page sideways; its
  rows follow the row spec (Lists, above). A column of icons has a header for a screen
  reader (`sr_label`). A settings section is not a named region of its own, so its list
  is the one landmark with the section's name.
- **Tooltips** (`.tooltip` with `data-tip`) take no box while hidden, so a right-hand one
  never widens a phone's page; shown, they wrap at 36ch or the window. Escape hides the
  one under the pointer or focus until the pointer leaves or focus moves (`app.js`).
- **`<.row_menu>`** is a row's ⋯ menu; `<.views>`, `<.list_search>`, `<.filter_menu>`,
  `<.sort_menu>` and `<.filter_tokens>` are a list's controls; `<.state_word>` says a
  row's state in words; `<.sparkline>` draws runs a day.
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
  `dark:` variant is rarely needed. Faint text reaches 4.5:1 on the page and the
  sidebar, not on a fill: the current view's pill, a rail's current target, the current
  version and a row marked by `?rule=` redefine `--q-faint` as `--q-muted`, so every faint
  word on them is drawn muted.
- **Honey is for one thing.** `primary` marks the main action of a screen, a checked box,
  the current step and the mark. It is too light to be text on the light theme: links and
  the active navigation icon use `accent`.
- **Colour marks a state, never a mood,** and is never the only carrier: a badge has its
  word, an error its icon and sentence, an allowed or denied connection of a run its glyph
  and word, a destination's denied number the words of its split.
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

## The run page

A run is a work surface (`ApiaryWeb.RunLive.Show`, width `work`): the column takes the
width, and from 1440 px the **Details rail** (320 px, sticky under the top bar, scrolling
on its own) sits beside it. The top bar's breadcrumb ends with the run's target, a link to
the target's page, and `Run 0191f2a4`; the page has no breadcrumb of its own.

- **The header is two lines**: the title (the task, or the run's short id) alone, then
  one muted meta line that starts with the state as a dot and its word
  (`ApiaryWeb.TargetComponents.state_mark/1`), then, each after a faint middle dot, how
  alive the run is while it runs, the target (its page), the runtime, the host, when it
  started, how long it took and its denials, in red, which lead to its denied
  connections. At the right: Close run while the run may be closed, and a ⋯ menu (Copy
  run id, Raw log, Download log). The seven cells of v1 are the rail's.
- **The tabs**, Timeline, Terminal, Network access and, below 1440 px, Details, stick under
  the top bar; each is a live action of the one LiveView, so a tab is a patch.
- **The Details rail** is key and value lines under small headings (Run, Labels, Command,
  Record, Policy in force), no card and no chip; the run's labels are its own
  identifiers, in mono, and one that names the target leads to its page. Below 1440 px the
  Details tab shows this same element in the column, its sections as cards
  (`q-run-on-details`), so the two never disagree and no id is drawn twice.
- **The timeline's open items are flat**: a rule in the item's state's colour under the
  chevron, the content indented beside it, code with a faint label and no border, a
  connection line with a plain glyph and no row tint, the prompt as quoted text with a
  rule.

## The terminal

`<.terminal>` in `RunPageComponents` is dark in both themes: the recorded output's colours
are written against a dark ground. It fills the window below the tab bar, never under
380 px. The `Terminal` hook reads the bytes from the run's log endpoint and hands them to
xterm.js as `Uint8Array`s, never decoded strings, in slices per frame so a long log does
not block input. The bytes never cross the LiveView socket: the LiveView sends the foot's
numbers and a signal that the log advanced. xterm.js is vendored under
`assets/vendor/xterm`, built as its own bundle and loaded on the hook's first mount, by no
other page. The screen is `role="log"` with `aria-live="off"`.

- **The recorded width is kept.** A run whose record says its pseudo-terminal's size is
  drawn at those columns and rows, centred only inside the box's own darker ground, which
  fills the column; it scrolls inside the box when it is larger. A run on pipes is fitted
  to the box, with Wrap.
- **The bar**: the stream, search (`/`), follow (End), wrap, the **text size** (A−, A+,
  11 to 18 px, and Fit, the largest size at which a recorded screen's columns fit), a
  reading preference kept in `localStorage`; download; **Focus** (`f` outside a field;
  Escape leaves), a class on the root that folds the shell, the header, the tabs and the
  rail away so the box takes the window; and **Full screen**, the browser's, on the box,
  shown only where the browser has it. A narrow box names its buttons on hover only
  (a container query), so the bar never wraps.

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
  `tabindex`. A failed submit puts the caret in the first invalid field. A live navigation
  gives focus to the new page's `<h1>` (`tabindex="-1"`, as `<.header>` renders it) unless
  the page put it somewhere itself, so a screen reader says where the reader landed.
- **Names.** An icon-only button has an `aria-label`. A row action names its object
  ("Revoke build-01") while its visible text stays short. A field has a visible label, and
  its error is tied to it with `aria-invalid` and `aria-describedby`. Each `<nav>` of the
  sidebar has a name of its own: its heading, Main for the first group, else its first
  entry's. No control sits inside another: a timeline item's number inside its
  `<summary>` is text that carries its path, which `c` copies.
- **Live regions.** A page that changes while it is read has one polite announcer
  (`#run-announcer`, `#overview-announcer`, `#policy-announce`) for the few things worth
  saying. Ticking text, a filling timeline and the terminal are `aria-live="off"`. Toasts
  are `role="status"` or `role="alert"`; an info toast leaves after 5 s, and hovering or
  focusing it holds it. A copy is announced politely: a button by its own live span, a
  row's copy by the shell's one `#copy-announcer`, never a live region a row.
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
