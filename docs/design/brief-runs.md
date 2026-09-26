# Qory console: design brief for runs and connections (M4)

Implementation spec for milestone M4: the runs list, the run page (Timeline, Terminal, Connections,
Details) and the connections pages. It extends `brief.md`; everything there (tokens, shell,
components, tone, accessibility) still holds and is not repeated. The rendered reference is
`runs-mock.html` beside this file; where the two disagree, this brief wins. Section letters
continue the pattern of `brief.md` with an `r` prefix so the two can be cited side by side.

Naming. The brand is **Qory**. The pages say **organisation** and **workspace**, plain
words with no term hover (`docs/lingo.md`); "apiary" and "hive" are words of the per-user
apiary skin, which is not built. Sample data is synthetic only: Acme, Platform,
`acme/shop`, `acme/tax-service`, `github.example`, `gitlab.example`, `api.example`,
`registry.example`, `files.cdn.example`, `build-01`. No people appear in a run.

## Amendment 2: rows hold still

21 Sep 2026. On a live run, the connections tables were ordered by last seen, so two denied
hosts retried every few seconds swapped places between an owner's look and their click, and
the Allow went to the other host. Both tables (rd13, the run's tab and the workspace's
page) now order by first seen after the denied group: a row moves only when a new
destination arrives. Marked **[A2]** where it stands.

## Amendment 1: state families

An owner's ruling after the first issue of this brief. **Run states read as three families on
every surface**: **alive** (`pending`, `running`, the amber quiet state included), **ended well**
(`succeeded`) and **ended badly** (`failed`, `timed_out`, `lost`, `closed`). `closed` reads as
"stopped by the workspace", not as a failure of the run, and sits in the last family for
scanning. The overview (`brief-overview.md`) counts and lists runs by these families. On
the runs list the amendment touches the State filter and the summary line, and nothing
else: the list, its rows and its badges are not redesigned, and the badges keep their
colours (green Succeeded, red and amber for the bad endings, blue Running, neutral Pending
and Closed).

**The State filter (rd7).** The `<.filter name="state" multiple>` menu is grouped under three
headings, in this order: **Alive**, **Ended well**, **Ended badly**. Each heading is itself a
checkbox row, "Every alive state" / "Every state that ended well" / "Every state that ended
badly", which checks or unchecks every state of its family in one click; under it, indented by
the checkbox's width, the family's states as today (Pending, Running · Succeeded · Failed, Timed
out, Lost, Closed) with their counts in `font-mono text-faint`. The heading's checkbox is checked
when every state of the family is, indeterminate (`aria-checked="mixed"`, the dash glyph) when
some are, unchecked otherwise. The URL does not change: `state=` takes the states, several
values, as today (`state=failed,timed_out,lost,closed`); the family choice fills them in, so a
shared link reproduces the view on any version of the page. No family word appears in the URL.

**The set chip.** When the chosen states are exactly one family, the chip reads the family:
"State **alive**", "State **ended well**", "State **ended badly**"; two whole families read
"State **alive, ended badly**"; anything else reads the states as today ("State **failed, lost**",
"State **3 selected**" past two). The remove button's name follows: "Remove filter: state ended
badly".

**The summary line (re1).** The facts after the count read the families in place of "2 alive"
alone: "11 runs in 4 repositories · 2 alive · 6 ended well · 3 ended badly · 3 with denials",
a family at zero left out. The legend of the runs table is this line; there is no other.

**Microcopy.**

| Where | Text |
|---|---|
| Menu headings | Alive · Ended well · Ended badly |
| Heading checkboxes (accessible names) | Every alive state · Every state that ended well · Every state that ended badly |
| States under them | Pending, Running · Succeeded · Failed, Timed out, Lost, Closed |
| Closed's tooltip in the menu | Stopped by the workspace: a member closed it after it went quiet. Counted with the runs that ended badly. |
| Set chip | State **alive** / State **ended well** / State **ended badly** / State **alive, ended badly** / State **failed, lost** / State **3 selected** |
| Remove button | Remove filter: state ended badly |
| Summary line | 11 runs in 4 repositories · 2 alive · 6 ended well · 3 ended badly · 3 with denials |
| Empty after a family filter | No runs ended badly in the last 7 days. (the neutral funnel state of re7, with the family in the sentence) |

The "quiet" running run stays in the alive family: it is running until the server says lost
(rd1). `lost` is ended badly the moment the server says so, even though the run may still be
going: the record ended, and the list reads the record.

---

Out of scope, not designed here: editing a security policy, allow and deny buttons on a connection
row (the row keeps a free trailing slot for them), billing, search across the logs of several runs.

---

## ra. Principles for reading a record

A run is a record: events a machine wrote, in an order it assigned. These pages are for reading
it. The eight principles of `brief.md` apply; these six are added.

1. **The record speaks, the page never guesses.** Every value on screen is a field of an event or
   a count of events. When the record does not say, the page says "n/a" or states what is missing
   and why. No inferred success, no "probably finished", no causal claim the events do not make: a
   connection is shown *while a tool call was open*, never as *caused by* it.
2. **Scan first, read second.** A row is one line. State is the first thing in the row, the
   denial count the last. Detail opens in place (a disclosure), never in a new page or a modal.
   40 px rows in tables, 36 px items in the timeline, 32 px connection rows.
3. **Sequence is the order, time is a column.** Items are ordered by the event's `sequence`, never
   by arrival and never by clock. Inside a run, time is an offset from `run.started` ("+0:08.1")
   in mono, right-aligned, with the absolute UTC time in a `title`. Across runs, time is relative
   up to seven days ("2 minutes ago", "Yesterday, 16:40"), then "17 Sep, 09:30".
4. **A clock that stops when the record stops.** A running duration counts up only while
   heartbeats arrive. After one missed interval it freezes at the last heartbeat's
   `elapsed_seconds` and reads "at least 8 m 30 s". A lost or closed run keeps "at least".
5. **Colour marks a decision, not a mood.** Green and red belong to the policy's decisions
   (allowed, denied) and to a run's end (succeeded, failed). Blue is "in progress". Amber is "the
   record has gone quiet". Lanes have their own hues, which are never status hues. The word is
   always beside the colour.
6. **Live without motion sickness.** New items append at the end. Nothing already on screen moves
   unless the reader is at the live end. Away from it, a pill counts what arrived.

---

## rb. Information architecture and URLs

### Sidebar

The nav splits in two sections. The record comes first because it is why people open the console.

```
Workspace
[#] Overview
[>] Runs            (o) 2      <- alive runs, info colour, 6 px ripple dot; absent at 0
[⇄] Connections
Manage
[k] Access keys        3
[u] Members            4
[s] Settings
```

Icons (16 px `-micro`): Runs `hero-play-circle-micro`, Connections `hero-arrows-right-left-micro`.
The labels "Workspace" and "Manage" share a style and carry no term hover. The Runs count
is `Runs.alive_count/1` (states `pending` and `running`), updated over PubSub; its `title` is
"2 runs alive now". `Layouts.app` gains `nav` values `:runs` and `:connections`; every run page
sets `nav={:runs}`. `counts` gains `:alive`.

### Routes

All inside `live_session :workspace`. Every filter is a query parameter, written with
`push_patch`, so the address bar is always a shareable link and the back button undoes a
filter.

| Page | Path | LiveView |
|---|---|---|
| Runs list | `/workspace/runs` | `RunLive.Index` |
| Run, timeline (default tab) | `/workspace/runs/:run_id` | `RunLive.Show, :timeline` |
| Run, terminal | `/workspace/runs/:run_id/terminal` | `RunLive.Show, :terminal` |
| Run, connections | `/workspace/runs/:run_id/connections` | `RunLive.Show, :connections` |
| Run, details | `/workspace/runs/:run_id/details` | `RunLive.Show, :details` |
| Workspace connections | `/workspace/connections` | `ConnectionLive.Index` |
| Raw log stream (not a page) | `/workspace/runs/:run_id/log` | `RunLogController` |

`:run_id` is the run's subject UUID (the id the runner prints), not the row id. The four tabs are
one LiveView with four live actions, so switching tabs is a `patch` and the header does not
re-render.

Query parameters, runs list:

| Param | Values | Default |
|---|---|---|
| `group` | `target`, `task`, `none` | `target` |
| `state` | comma list of `pending,running,succeeded,failed,timed_out,lost,closed` | all |
| `system`, `target` | the system and the path, e.g. `system=github.example&target=acme/shop`; `target=none` for unassigned | all |
| `task` | the label's value; `none` for runs without | all |
| `runtime` | e.g. `claude` | all |
| `host` | e.g. `build-01` | all |
| `since` | `1h`, `24h`, `7d`, `30d` | `7d` |
| `from`, `to` | `2026-09-14`, inclusive, UTC; replace `since` | |
| `denials` | `1` | off |
| `page` | integer | 1 |

Run page: `?seq=18` scrolls to and highlights event 18 (the permalink behind every `#0018`);
`?lane=main` or `?lane=agent-7c1e` isolates a lane; `?cx=0` hides inline connections. Run
connections: `?decision=allowed|denied`. Workspace connections: `decision`, `system`,
`target`, `host`, `since`, `from`, `to`, `page`. "Per repository" (C2) is the workspace
page with `target` set; the group header of the runs list links there.

Unknown parameter values are dropped silently and the URL is rewritten without them. A run id that
does not exist in this workspace renders the not-found state (rh7), never another
workspace's run.

### Breadcrumb

`brief.md` rules out breadcrumbs on the top-level pages; that stays. The run page is the console's
first second-level page and gets one line above its title: `Runs › github.example/acme/shop ›
0191f2a4`. "Runs" links to `/workspace/runs` with the filters the reader came from (kept
in the LiveView's `return_to`, default none); the repository links to
`/workspace/runs?target=…`; the last item is the short id with `aria-current="page"`. An
unassigned run drops the middle item.

### Content width

`Layouts.app` gains `width="full"`: `max-w-[1200px]`. The runs list, the run page and the
connections page use it. Gutters and top padding are unchanged.

---

## rc. Tokens added

Declare beside the other semantic tokens in `app.css`, for both themes and the no-script dark
block, and expose through `@theme inline`.

| Token | Use | `qory` | `qory-dark` |
|---|---|---|---|
| `--q-lane-main` | the main session's rail and node ring | `oklch(66% 0.01 80)` | `oklch(50% 0.01 70)` |
| `--q-lane-a` | first subagent | `oklch(52% 0.15 300)` | `oklch(76% 0.12 300)` |
| `--q-lane-b` | second subagent | `oklch(52% 0.085 205)` | `oklch(76% 0.09 205)` |
| `--q-lane-c` | third subagent; further subagents cycle a, b, c | `oklch(52% 0.12 265)` | `oklch(76% 0.1 265)` |
| `--q-denied-tint` | background of a denied connection row | `color-mix(in oklab, var(--q-error-soft) 55%, var(--color-base-100))` | same formula |
| `--q-term-bg` | terminal surface, dark in both themes | `oklch(20% 0.008 70)` | `oklch(13.5% 0.005 70)` |
| `--q-term-edge` | terminal border and inner dividers | `oklch(30% 0.008 70)` | `oklch(27% 0.008 70)` |
| `--q-term-fg` / `--q-term-dim` | terminal text, dimmed text | `oklch(90% 0.008 80)` / `oklch(66% 0.012 75)` | same |
| `--q-term-red` `-green` `-yellow` `-blue` `-magenta` `-cyan` | the ANSI palette handed to xterm.js | `oklch(74% 0.16 25)`, `oklch(80% 0.15 152)`, `oklch(84% 0.13 85)`, `oklch(78% 0.1 248)`, `oklch(78% 0.12 320)`, `oklch(82% 0.09 200)` | same |

```css
@theme inline {
  --color-lane-main: var(--q-lane-main); --color-lane-a: var(--q-lane-a);
  --color-lane-b: var(--q-lane-b);       --color-lane-c: var(--q-lane-c);
  --color-denied: var(--q-denied-tint);  --color-term: var(--q-term-bg);
  --color-term-edge: var(--q-term-edge); --color-term-content: var(--q-term-fg);
}
```

Amber is not a new token: it is the existing warning badge pair (`primary-soft` /
`primary-soft-content`). Amber dots and squares take `primary-soft-content` too: `warning` itself is
2.2:1 on the light surface and fails as a mark. The lane hues sit at 300°, 205° and 265°
so none can be mistaken for success (152°), error (27°), info (248° at a different chroma and
always with its own word) or honey (76°).

---

## rd. Components

All in `core_components.ex` unless a file is named. Attribute types follow `Phoenix.Component`.
Every component that renders inside a LiveView stream takes its `id` from the caller.

### rd1. Run state (`<.run_state>`)

One badge family for the seven states. It is `<.badge>` with a 12 px glyph in place of the 6 px dot
(`pl-[5px]`), so it lines up with the existing badges.

| State | Label | Colour | Glyph | Motion |
|---|---|---|---|---|
| `pending` | Pending | neutral | hollow 6 px ring | none |
| `running` | Running | info | solid 6 px dot with a 12 px ripple ring | ripple 1.6 s, `--q-ease-out`, infinite |
| `running`, quiet | Running | warning | solid dot, no ripple | none; the amber note sits beside it |
| `succeeded` | Succeeded | success | `hero-check-micro` | none |
| `failed` | Failed `exit 1` | error | `hero-x-mark-micro` | none |
| `timed_out` | Timed out | error | `hero-clock-micro` | none |
| `lost` | Lost | warning | `hero-signal-slash-micro` | none |
| `closed` | Closed | neutral | `hero-lock-closed-micro` | none |

```elixir
attr :state, :string, required: true, values: Apiary.Runs.Run.states()
attr :exit_code, :integer, default: nil   # shown in mono after "Failed" when not 0 and not -1
attr :signal, :string, default: nil       # shown instead of the exit code: "Failed SIGKILL"
attr :quiet_for, :integer, default: nil   # seconds since the last heartbeat, when over one interval
attr :interval, :integer, default: nil    # heartbeat_interval_seconds, for the tooltip
attr :class, :any, default: nil
```

"Quiet" is derived by the server, not the browser: `quiet_for` is set when `state == "running"` and
`now - last_heartbeat_at > heartbeat_interval_seconds`. The LiveView recomputes it on a 5 s timer
and on every batch. The amber note renders after the badge: `hero-exclamation-triangle-micro` 12 px
and "No heartbeat for 47 s" in `text-xs text-primary-soft-content`; the seconds tick in the browser
from `data-since` (hook `Ticker`, rd3). Tooltip: "Heartbeats are due every 30 s. After 90 s of
silence the run is marked lost." (interval and three times the interval, from the record). The
change to `lost` is made by `Apiary.Runs.Liveness` and arrives like any other update; the page
never flips the state by itself.

`pending` means only a ping has arrived: every other cell of the row is "n/a" and the run cell
reads "Ping only" in `text-faint`. `closed` is a member's act on a lost or pending run; its tooltip
is "Closed by a member on 14 Sep 2026. The run never posted its exit."

### rd2. Duration (`<.duration>`)

```elixir
attr :ms, :integer, default: nil            # run.exited duration_ms, or a tool's duration_ms
attr :running_since, :any, default: nil     # started_at, when the run is running and not quiet
attr :at_least_seconds, :integer, default: nil  # elapsed_seconds of the last heartbeat, when quiet, lost or closed
attr :class, :any, default: nil
```

Format, always `tabular-nums`: under 1 s "41 ms"; under 1 min "3.4 s" (tools) or "48 s" (runs);
under 1 h "6 m 51 s"; from 1 h "1 h 00 m". A running run renders `<time phx-hook="Ticker"
data-since={iso}>` followed by "so far" in `text-faint` (run header only; the list omits the
words). `at_least_seconds` renders "at least 8 m 30 s" with the tooltip "Elapsed at the last
heartbeat. The clock stops counting when heartbeats stop." Nothing given renders "n/a" in
`text-faint`.

### rd3. Relative time (`<.relative_time>`) and the offset (`<.offset>`)

```elixir
# <.relative_time>
attr :at, :any, required: true              # DateTime
attr :format, :string, default: "relative", values: ~w(relative clock)
# <.offset>
attr :at, :any, required: true              # the event's time
attr :from, :any, required: true            # the run's started_at
```

`<.relative_time>` renders `<time datetime={iso} title="20 Sep 2026, 14:02:11 UTC"
phx-hook="Ticker">`; the hook re-renders the text every 15 s in the browser's locale-free format of
`brief.md` (no server round trip). `clock` gives "Today, 14:02:11". `<.offset>` renders "+0:08.1"
(minutes, seconds, tenths; "+1:02:08" past an hour) in `font-mono text-[11.5px] text-faint
tabular-nums`, `title` the absolute time with milliseconds. An event timed before `run.started`
(the ping) renders "before start".

### rd4. Key and value strip (`<.kvs>`, `<.kv>`)

The run header's facts as one bordered object, like `<.stats>` but for words.

```elixir
# <.kvs>  slot :inner_block
attr :class, :any, default: nil
# <.kv>
attr :label, :string, required: true
attr :tip, :string, default: nil     # turns the label into a term hover
attr :mono, :boolean, default: false
slot :inner_block, required: true
slot :sub                            # faint second value on the same line (version, image, digest)
```

`dl.grid.grid-cols-[repeat(auto-fit,minmax(150px,1fr))] rounded-box border border-line bg-base-100
shadow-xs overflow-hidden`; each `<.kv>` `px-4 py-2.5` with a left and bottom hairline pulled in by
`-1px` so wrapped rows keep their dividers. `dt` Caption in `text-muted`; `dd` `text-[13.5px]/5
truncate`, full value in `title`. Below 768 px: two columns.

### rd5. Label chip (`<.label_chip>`)

```elixir
attr :key, :string, required: true
attr :value, :string, required: true
attr :navigate, :string, default: nil   # task and repository chips link to the filtered list
```

`inline-flex h-5 rounded-selector border border-line font-mono text-[11.5px] overflow-hidden`; key
`px-1.5 bg-base-200 text-muted border-r border-line`, value `px-1.5`. Values over 32 characters
truncate in the middle. Labels render in the record's order, with `forge`, `repository` and `task`
first.

### rd6. Alive indicator (`<.alive>`)

```elixir
attr :state, :string, required: true
attr :last_heartbeat_at, :any, default: nil
attr :last_event_at, :any, default: nil
attr :interval, :integer, default: nil
attr :quiet, :boolean, default: false
```

Right-aligned in the title row. Running and heard from: 8 px `success` dot with the 2.4 s ripple of
`<.listening>`, "Alive, 4 s ago" (`text-[13px] text-muted tabular-nums`, seconds ticking). After
one missed interval: `primary-soft-content` dot, no ripple, `text-primary-soft-content`, "No heartbeat for 47 s";
tooltip as in rd1. Before the first heartbeat it counts from `last_event_at` and reads "Alive, last
event 4 s ago". Terminal states render no dot: "Succeeded 18 m 02 s after it started", "Failed with
exit 1", "Timed out after 1 h 00 m", "Lost. Last heard 18 Sep 2026, 22:55", "Closed 14 Sep 2026".
`role="status"` with `aria-live="off"`; the state change itself is announced by the page's one
polite region (ri).

### rd7. Filter bar (`<.filter_bar>`, `<.filter>`, `<.filter_toggle>`)

```elixir
# <.filter_bar>
attr :id, :string, required: true
attr :clear, :string, default: nil          # patch target with no filters; shows "Clear" when any is set
slot :inner_block, required: true
slot :trailing                              # the group-by segmented control, the summary
# <.filter>
attr :name, :string, required: true         # the query parameter
attr :label, :string, required: true        # "State"
attr :value, :any, default: nil             # nil = unset; string or list
attr :options, :list, required: true        # [{label, value, count}]
attr :multiple, :boolean, default: false
attr :remove, :string, default: nil         # patch target without this filter
# <.filter_toggle>
attr :name, :string, required: true
attr :label, :string, required: true
attr :icon, :string, default: nil
attr :pressed, :boolean, default: false
attr :patch, :string, required: true
```

A `<.filter>` is a 28 px chip. **Unset**: `border border-dashed border-line-strong text-muted
rounded-field px-2.5 text-[13px] font-medium`, leading `hero-plus-micro` in `text-faint`. **Set**:
solid `border-line-strong bg-base-100 shadow-xs`, label in `text-muted`, value in `text-base-content`
("Runtime **claude**", "State **failed, lost**", more than two values: "State **3 selected**"), and a
20 px remove button (`aria-label="Remove filter: runtime claude"`). Clicking the chip opens a daisyUI
`dropdown` with the `menu` of `brief.md`: a checkbox list for `multiple`, a radio list otherwise,
each option with its count in `font-mono text-faint` on the right; lists over eight options get a
search input on top. Time range is a `<.filter>` whose menu is Last hour, Last 24 hours, Last 7 days,
Last 30 days, then two date inputs "From" and "To". `<.filter_toggle>` ("Has denials",
`hero-no-symbol-micro`) is a chip with `aria-pressed`; pressed: `bg-error-soft
text-error-soft-content border-transparent`. Every change is a `patch`. Below 768 px the bar is one
row that scrolls sideways (`overflow-x-auto`, bleeding into the 16 px gutters), chips 32 px.

The group-by control is the segmented control of the theme menu (`bg-base-300 p-0.5 rounded-field`,
items 24 px, `aria-pressed`): Repository, Task, None.

### rd8. Runs table (`<.runs_table>` in `run_live/components.ex`)

Built on `<.table>`'s classes with one `<tbody>` per group (a LiveView stream per group is not
needed: the list is paginated at 50 runs and re-rendered on patch; live changes update rows by id).

```elixir
attr :id, :string, required: true
attr :groups, :list, required: true   # [%{key, kind: :repository | :task | :none | :unassigned, forge, path, title, runs, alive, denials}]
attr :group_by, :string, required: true
```

Columns, grouped by repository: State · Run · Runtime · Host · Started · Duration · Denials. Grouped
by task or not grouped, a **Repository** column appears after Run (`forge` faint, `path` normal, both
mono 12.5) and, grouped by task, the Run cell leads with the repository instead of the task.

- **Group header row**: `bg-base-200`, 34 px, a full-width `button[aria-expanded]` holding a chevron,
  the forge in `font-mono text-xs text-faint`, the path in `font-mono text-[12.5px] font-medium`, and
  right-aligned `text-xs text-muted tabular-nums` facts: "5 runs", "1 alive", "3 denials" (the last
  two only when not zero). Two forges with the same path are two headers; the forge is what tells
  them apart, so it is never hidden. The unassigned group reads **Unassigned** "no forge or
  repository label" and sorts last. Task groups read the task in sans 500 with "2 runs in 2
  repositories"; the group without a task reads **No task** "no task label". Groups sort by their
  most recent run. Collapsed state is kept in the URL-free `localStorage` key
  `qory:runs:collapsed`; it is a reading preference, not a filter.
- **Run cell**: the `task` label in `font-medium`, under it the short id (first eight characters of
  the run id) in `font-mono text-xs text-faint`. Without a task: the command and arguments in mono
  400, truncated at 48 characters, and "· no task label" after the id. The task is the row's link
  (`<.link navigate>` with an `::after` covering the row), so the whole row is one target and one
  tab stop.
- **Runtime** "claude 2.1.273" in `text-muted`; **Host** mono; **Started** `<.relative_time>`;
  **Duration** `<.duration>` right-aligned; **Denials** right-aligned: 0 in `text-faint`, otherwise
  `hero-no-symbol-micro` 12 px in `error` and the count in `text-error-soft-content font-medium`.
  The count is `sum(connections.denied)` of the run.
- Row hover `bg-base-200`. No row actions in this milestone.
- **Below 640 px** each row reflows into a two-line block inside the same `<table>` (CSS grid on the
  `tr`; keep `role="row"` and `role="cell"` explicit so the semantics survive the display change):
  line one the run cell and the state badge, line two started and duration, line three the denial
  count when not zero. Runtime and host are dropped on the phone; they are one tap away.

Footer line under the table, `text-[12.5px] text-faint`: "Showing 50 of 214." with Previous and Next
as `btn-sm` default buttons on the right.

### rd9. Tabs (`<.tabs>`)

```elixir
attr :id, :string, required: true
attr :label, :string, required: true        # aria-label of the nav
slot :tab, required: true do
  attr :patch, :string, required: true
  attr :icon, :string
  attr :current, :boolean
  attr :count, :any                          # "24", or "2 denied"
  attr :tone, :string                        # "error" colours the count
end
```

Not daisyUI `tabs` (its lifted and boxed styles fight the flat header). `nav.flex gap-5 border-b
border-line`, items `h-10 text-[13px] font-medium text-muted` with a 2 px bottom border; current:
`text-base-content border-base-content`, icon `text-accent`, `aria-current="page"`. Counts in
`font-mono text-[11.5px] text-faint`. It is `sticky top-0 z-10` inside `<main>` with `bg-base-100/90
backdrop-blur`, bleeding to the gutters, so the tabs stay reachable in a long timeline. On a phone
the row scrolls sideways. These are links, not an ARIA tablist: each tab is a URL.

Tabs of a run: Timeline `hero-list-bullet-micro` (count of session items), Terminal
`hero-command-line-micro`, Connections `hero-arrows-right-left-micro` ("2 denied" in error tone, or
the destination count), Details `hero-document-text-micro`.

### rd10. Timeline (`<.timeline>`, `<.lane>`, `<.timeline_item>`)

A single column in sequence order with a rail gutter on the left, one rail per agent, in the manner
of a commit graph. One column keeps the phone layout identical and lets connections sit between
items at their sequence; the rails carry who did what.

```
 rails  content                                                     time
 0 1 2
 o      Prompt                                                 +0:02.0  #0007
 |        Add VAT handling to the checkout totals …
 |  [✓] api.example:443  POST /v1/messages   Allowed by rule …  +0:02.1
 o      > Read  app/checkout/totals.py                   8 ms  +0:04.6  #0012
 |-o    Subagent started  [Explore]  agent-7c1e                +0:06.2  #0014
 | o    > Grep  vat_rate in /work/shop                  41 ms  +0:07.0  #0015
 |-+-o  Subagent started  [general-purpose]  agent-b94f        +0:07.4  #0017
 | | x  v Bash  pip install tax-rates-client   Failed  3.4 s   +0:08.1  #0018
 | | |    | 2 connections while this call was open
 | | |    | [✓] registry.example:443   CONNECT   Allowed by rule …   Connected
 | | |    | [⊘] files.cdn.example:443  CONNECT   Denied. No rule …   Refused
 |-o |  Subagent finished  [Explore]                     6.1 s +0:12.3  #0026
```

```elixir
# <.timeline>
attr :id, :string, required: true
attr :lanes, :list, required: true     # [%{id: "main" | agent_id, type, index, color: :main | :a | :b | :c, started_seq, finished_seq}]
attr :stream, :any, required: true     # the LiveView stream of items
# <.lane>  (the key above the timeline: one toggle per lane)
attr :lane, :map, required: true
attr :pressed, :boolean, default: true
attr :patch, :string, required: true
# <.timeline_item>
attr :id, :string, required: true      # "e-#{sequence}"
attr :item, :map, required: true       # see "Items" below
attr :lanes, :list, required: true     # the lanes open at this sequence, for the rails
attr :started_at, :any, required: true
```

**Gutter.** `--lane: 22px` (16 px below 768), width `lanes × --lane`. Per item, one absolutely
positioned 2 px rail for every lane open at that sequence (`top-0 bottom-0`, colour `lane-*`). The
item's **node** sits on its own lane, 22 px (18 px on phones), `rounded-full border-[1.5px]
bg-base-100`, ring and 12 px glyph in the lane colour (main: `text-muted`). `subagent_started`
draws a 2 px horizontal link from the main rail to the new rail at the node's centre and starts
the new rail there; `subagent_finished` mirrors it and ends the rail. A failed tool's node is
`border-error bg-error-soft text-error`. The prompt's node is solid ink (`bg-base-content
text-base-100`): it is where the human spoke. Run-level items (run started, policy applied, run
exited) use a **square** node (`rounded-[6px]`) on the main rail: they are the runner's, not the
session's. Connections have **no node**: egress belongs to the run, not to an agent, and the
missing node says so. The last item of a running run fades its rail to transparent.

Lanes are assigned in order of `subagent_started`: main is 0, then 1, 2, 3. A lane index is reused
once its agent has finished, so the gutter is as wide as the most agents open at once, capped at
four rails; past that, items of the overflow agents show their `<.who>` chip and sit on the last
rail. Hues cycle a, b, c.

**Items.** The LiveView folds events into items before streaming them (`RunLive.Timeline.items/1`,
pure). Pairing uses ids only: `tool_use_id` for tools, `agent_id` for subagents.

| Item | From | Node glyph | Head | Body |
|---|---|---|---|---|
| Run started | `run.started` | play, square | **Run started** "claude 2.1.273 on build-01, behind a docker wall" | none |
| Policy applied | `run.policy_applied` | shield, square | **Policy applied** "enforce · 6 hosts allowed · fetched from the run configuration · reads requests to `api.example`" | none; again at each reload |
| Session started | `session.started` | command line | **Session started** "model … · startup · cwd" | none |
| Prompt | `prompt_submitted` | chat, solid | **Prompt** | the prompt in a `bg-base-200 border border-line rounded-field px-3 py-2.5` block, `max-w-[72ch]`, 14 / 21 |
| Tool | `tool_started` + `tool_finished` or `tool_failed` | code brackets; x when failed | mono **tool name** + a one-line summary of the input, then `Failed` (error tone) and the duration | disclosure: `input`, then `response` or `error`, each a code well |
| Tool, open | `tool_started` alone | 12 px spinner in the node | summary + "Running" in info tone | input only |
| Subagent started / finished | the subagent events | branch / check | **Subagent started** + `<.who>` chip + the `agent_id` in mono faint; finished adds the lane's duration | finished: the `message` as text |
| Notification | `notification` | bell | **Notification** "permission_prompt · Claude needs your permission to use Bash" | none |
| Turn finished | `turn_finished` | text lines | **Turn finished** | the `message`, 14 / 21, `max-w-[72ch]` |
| Turn failed | `turn_failed` | x, error node | **Turn failed** + `error` | `details` in an error well |
| Result | `session.result` | flag | **Result** "success · 7 turns · 2 m 41 s · $0.42" (`cost_usd` to two places, four when under a cent; absent fields are left out) | `result` as text |
| Session ended | `session.ended` | stop | **Session ended** + the runtime's `reason` | none |
| Run exited | `run.exited` | check or x, square | **Run exited** "exit 0 · 18 m 02 s" / "exit 1" / "SIGKILL" / "timeout" / "runner lost" | none |
| Connection | `run.egress` | none | `<.connection_row variant="inline">` | none |

The tool summary is chosen per tool from `input`, copied, never rewritten: `command` (Bash),
`file_path` (Read, Edit, Write), `pattern` "in" `path` (Grep, Glob), `url` (WebFetch), `description`
(Task); any other tool shows its first string field. A tool whose input has
`run_in_background: true` carries an info badge "In background". Heartbeats and log chunks are not
items. Enumerations (`kind`, `reason`, `outcome`, `source`) are shown in the runtime's own words.

**Head row**: `flex items-baseline gap-2 leading-[22px]`: kind `text-[13px] font-semibold` (mono
for tool names), summary `flex-1 truncate text-[13px] text-muted` (mono, `text-base-content` for
tools), then right-aligned in `font-mono text-[11.5px]`: status, duration in `text-muted`,
`<.offset>`, and the sequence `#0018` as a link to `?seq=18` in `text-faint`. Item body
`px-2.5 py-[7px] rounded-field`, hover `bg-base-200`. The targeted item (`?seq=`) gets
`bg-primary-soft` for as long as it is the target.

**Disclosure.** Tools are native `<details>`; the `<summary>` is the head row with a 12 px chevron
that turns 90°. A failed tool starts open; everything else starts closed. **Code well**:
`rounded-field border border-line bg-code`, a 24 px caption bar (`input`, `response`, `error`, and
on the right the size: "2.1 KB · 64 lines", "exit 1"), `pre` `p-2.5 font-mono text-[12.5px]/5
overflow-x-auto max-h-[220px]`. Objects render as indented JSON with keys in `text-accent`; a
`stdout`/`stderr` pair renders as two wells of plain text. A value over 8 KB is cut with a last
line "Show all 41 KB", which loads the rest from the event (rj). An error well takes a border mixed
35 % toward `error`.

**Connections inline (P4).** A connection row is placed by its sequence. When exactly one tool call
is open at that sequence (started, not yet finished or failed, in any lane), the row renders inside
that tool's item, above the wells, in a bracket: `pl-2.5 border-l-2 border-line-strong grid gap-0.5`
headed by "2 connections while this call was open" in `text-[11.5px] text-faint`. A tool with a
denied connection inside starts open, which puts the denial beside the call (the P4 requirement)
without the page claiming the cause. When no call or several calls are open, the row stands between
items at its sequence; with several open it carries the caption "while 2 calls were open". The
"Connections inline" toggle (`?cx=0`) hides all of them. Runs of allowed connections to one host
with nothing between them collapse: "api.example:443 · 12 allowed connections · +0:52 to +1:40",
expandable. Denied rows never collapse.

**Lane key and filter (P3).** Above the timeline, one `<.lane>` toggle per lane: a 10 px ring in
the lane colour, the agent type ("Main session", "Explore", "general-purpose") and the `agent_id`
in mono faint; `aria-pressed`. Switching a lane off dims its items to 28 % and removes them from the
keyboard path; `?lane=` isolates one. The key is the colour legend, so colour is never the only
carrier: every subagent item also carries a `<.who>` chip when it opens or closes a lane.

**Background tasks (P7).** A strip between the lane key and the timeline while any task is
outstanding: `rounded-box border border-line bg-base-100 shadow-xs px-3.5 py-2.5`, a 12 px info
spinner, "1 task still running in the background", the command or agent type in mono muted, and on
the right in faint "shell b3f1 · listed at #0038". The rule is the contract's: a task is running
from the first `background_tasks` list that names it until the first later list that leaves it out;
the page does not time it and shows no duration. When the run ends with tasks still listed, the
strip stays, the spinner becomes a static ring and the text reads "1 task was still listed when the
run ended". More than one task: the strip lists up to three rows, then "and 2 more".

**The live end (P6).** Under the last item of a running run: the `<.listening>` dot and "Listening
for the next batch. Last event #0041, 4 s ago." When the run has ended: "End of the record. 41
events." with no dot.

### rd11. Who chip (`<.who>`)

```elixir
attr :lane, :map, required: true
```

`font-mono text-[11px] px-[5px] rounded-selector border` in the lane colour (border at 45 %
opacity); main session: `text-muted border-line-strong`. Text is the `agent_type`.

### rd12. Connection row (`<.connection_row>`) and mark (`<.decision_mark>`)

One component, three variants, so a connection looks the same wherever it appears.

```elixir
attr :id, :string, required: true
attr :connection, :map, required: true   # host, port, method, request_method, path, decision, rule, path_rule,
                                         # credential, outcome, mode, attempts, allowed, denied, first/last seen
attr :variant, :string, default: "table", values: ~w(inline table workspace)
attr :started_at, :any, default: nil     # offsets instead of relative time, inside a run
slot :trailing                           # reserved: the later milestone's allow and deny buttons
```

- **Mark** (`<.decision_mark decision="allowed|denied" />`): an 18 px rounded square (5 px radius).
  Allowed: `bg-success-soft`, `hero-check-micro` in `success`. Denied: **solid** `bg-error`,
  `hero-no-symbol-micro` in `base-100`. The two differ in fill, glyph and word, not only hue.
  `title` and an `sr-only` word carry "Allowed" / "Denied".
- **Destination**: `font-mono text-[12.5px]`: host, `:port` in `text-faint`, then in `text-muted` the
  method: `CONNECT`, `HTTP`, or on a terminated host the request line "POST /v1/messages"
  (`request_method` + `path`). Paths truncate in the middle; full value in `title`.
- **Reason** (C3), one sentence built from `decision`, `rule`, `path_rule`, `mode`; see rf for the
  exact strings. The lead is `font-medium`, in `text-error-soft-content` on a denied row. Rules
  render as `<.mono>` chips that never break.
- **Outcome**: a 6 px shape and a word, `text-xs text-muted`: Connected (solid `success` dot), Dial
  failed (solid `primary-soft-content` **square**), Refused (hollow `error` ring).
- **Denied row**: `bg-denied` across the row (table: on every `td`); hover mixes `error-soft` to
  80 %.
- **Trailing slot**: a fixed `w-7` cell (`td.w-px` in tables), empty in M4. Do not put anything
  else there.

Variants: **inline** is a 32 px grid row `[18px | 1.1fr | 1.4fr | auto | auto | 28px]`: mark,
destination, reason, outcome, offset, slot; on phones it becomes two lines (destination and
outcome, then the reason) and the offset hides. **table** adds the Attempts, Allowed, Denied and
"First and last seen" cells. **workspace** adds the disclosure chevron, the Runs count and
the allowed/denied bar.

### rd13. Connections tables

`<.connections_table>` in `run_live/components.ex`, wrapper and header as `<.table>`, cell padding
12 px so nine columns fit 1200.

**Per run (C1)**, one row per (host, port, path): Destination · Attempts · Allowed · Denied · Reason ·
Outcome · First and last seen · (slot). Numbers right-aligned `tabular-nums`; a zero is `text-faint`;
a non-zero Denied is `text-error-soft-content font-medium`. "First and last seen" is two
`<.offset>`s joined by "to", one when they are equal. The Reason cell wraps to at most three lines
(`max-w-[400px]`); every other cell is one line. Sort **[A2]**: denied destinations first, then by
first seen, newest first: a row moves only when a new destination arrives, never because one
the page holds was seen again (a live run retries a denied host every few seconds, and an
order by last seen swapped two denied rows under the pointer between the look and the click;
the buttons in the slot are the reason the rows must hold still). Above the table: a segmented filter All 6 · Allowed 4 · Denied 2 (`?decision=`)
and the summary "37 attempts to 6 destinations · policy enforce `9f86d081884c`".

**Per workspace and per repository (C2)**, one row per (host, port, path) across the runs
in range: Destination · Runs · Attempts · Allowed / denied · Reason · Outcome · Last seen
· (slot). "Allowed / denied" is a 64 × 6 px split bar (`success` then `error`,
`aria-hidden`) followed by "65 / 8" with the denied part in error tone when not zero. The
chevron in the first cell (`button[aria-expanded] [aria-controls]`, label "Runs that
reached files.cdn.example") opens a sub-row on `bg-base-200`: "3 runs reached this
destination", then one link row per run: `<.run_state>`, task and short id, repository in
mono, "3 denied" or "9 allowed", last seen. Ten runs, then "Show 10 more" pages in place
(the runs list has no filter by destination in M4, so there is nowhere to link to). Reason
and outcome are those of the most recent attempt across the runs shown; when a destination
has both allowed and denied attempts, the reason ends with "· last attempt" in faint.

### rd14. Terminal (`<.terminal>` in `run_live/components.ex`, hook `Terminal`)

```elixir
attr :id, :string, required: true
attr :src, :string, required: true        # /workspace/runs/:run_id/log
attr :streams, :list, required: true      # ["terminal"] or ["stdout", "stderr"]
attr :live, :boolean, required: true
attr :bytes, :integer, required: true
attr :chunks, :integer, required: true
attr :through, :integer, required: true   # last sequence rendered
```

A `bg-term text-term-content border border-term-edge rounded-box overflow-hidden` box,
`color-scheme: dark`, **dark in both themes**: a terminal's colours are authored against a dark
ground and the light theme would break them. Three rows:

- **Bar** (38 px, bottom hairline): left, a segmented stream switch in mono 11.5 (`terminal`, or
  `stdout` | `stderr` | `both` on pipes; one item renders as a static chip). Right: the search field
  (26 px, `bg-white/6`, focus border `primary`), its "1 of 2" counter, then icon buttons with
  tooltips: "Wrap long lines" (`aria-pressed`), "Download the raw bytes", and the **Following**
  toggle (`hero-arrow-down-micro` + label, honey when on).
- **Screen**: xterm.js with the fit and search add-ons, `font-mono` 12.5 / 19, padding 12 × 14,
  `disableStdin: true`, `convertEol: false`, scrollback 100 000 lines, the theme object built from
  the `--q-term-*` tokens read with `getComputedStyle`. Height `min(640px, 100dvh - 330px)`, never
  under 380 px; on phones it bleeds to the screen edges and takes `100dvh - 200px`. Wide output
  scrolls inside the screen. Search matches use honey at 35 %, the current match solid honey.
- **Foot** (26 px, top hairline, mono 11.5 dim): a green "Live" with a 6 px dot while the run is
  alive ("Ended" in dim afterwards), "48.2 KB", "312 chunks", "through #0041", and right-aligned
  the terminal's size "120 × 32" when the record has it, otherwise nothing.

**Following.** On by default for a live run, off for an ended one (which opens at the top). Scrolling
up turns it off; "Jump to end" replaces the label and a pill "128 new lines" appears bottom-centre
inside the screen (same pill as rd15). `End` or the button turns it back on.

Under the box, `text-[12.5px] text-faint`: "The bytes as the runtime wrote them, terminal escapes
included. Nothing here is interpreted; the timeline is where the session is read."

Keys, when the screen has focus: `/` or `Ctrl/Cmd+F` focus search, `Enter` / `Shift+Enter` next and
previous match, `Esc` clears, `End` follows, `Home` goes to the start.

### rd15. New items pill (`<.new_items>`)

```elixir
attr :id, :string, required: true
attr :count, :integer, required: true
attr :noun, :string, default: "event"      # "3 new events", "128 new lines"
attr :target, :string, required: true      # the scroll container's selector
```

`sticky bottom-4 justify-self-center h-8 px-3 rounded-full bg-neutral text-neutral-content
text-[13px] font-medium shadow-pop`, leading `hero-arrow-down-micro`. Hidden at count 0. Click
scrolls to the end, resets the count and returns focus to the first new item. It is a `button`;
its text is not a live region (ri).

### rd16. Limits notice (`<.limits>`)

```elixir
attr :reason, :atom, required: true, values: [:no_hooks, :vm_wall, :other_runtime, :not_started, :no_egress, :no_log]
```

An info `<.notice>` when it sits above content that is there (rf has the sentences), or the body of
an `<.empty_state tone="neutral">` when it replaces content that is absent. It is never a toast and
never dismissible: it is a fact about the record.

---

## re. Page compositions

Copy is final. `{…}` is data. ~word~ carries the term hover; organisation and
workspace never do.

### re1. Runs list (`/workspace/runs`)

```
>= 768                                                           < 768
Runs                                                             Runs
Every run the machines of this workspace have posted, as their   Every run the machines …
events tell it.
                                                                 [+State][+Repository][+Task][Runt… >   (scrolls)
[+ State] [+ Repository] [+ Task] [Runtime claude x] [+ Host]    11 runs in 4 repositories · 2 alive
[Started last 7 days x] [⊘ Has denials] Clear     [Repository|Task|None]
                                                                 +---------------------------------+
11 runs in 4 repositories · 2 alive · 3 with denials ·           | v github.example acme/shop 5 runs|
Updated as batches land                                          |---------------------------------|
                                                                 | checkout-tax          (•) Running|
+--------------------------------------------------------------+ | 0191f2a4                         |
| State      Run            Runtime   Host   Started  Dur  Den | | 2 minutes ago           2 m 16 s |
|--------------------------------------------------------------| | ⊘ 2                              |
| v github.example acme/shop        5 runs · 1 alive · 3 denials| |---------------------------------|
| (•)Running checkout-tax   claude…   build… 2 min    2m14s ⊘2 | | checkout-tax        ✓ Succeeded  |
|            0191f2a4                                          | | …                                |
| ✓ Succeeded checkout-tax  …                                  | +---------------------------------+
| x Failed exit 1  fix-flaky-cart-test …                    ⊘1 |
| ◷ Timed out  upgrade-framework …                             |
| v gitlab.example acme/shop                  2 runs · 1 alive |
| (•)Running ⚠ No heartbeat for 47 s  mirror-sync … at least 8m|
| v github.example acme/tax-service         1 run · 4 denials |
| v Unassigned  no forge or repository label          3 runs  |
| ( )Pending  Ping only  n/a  n/a  40 seconds ago  n/a      0  |
+--------------------------------------------------------------+
Showing 11 of 11. A run's state comes from its events alone: a run that stops
posting is lost, never assumed finished.
```

Header: no action button (runs are started by machines, not here). Default view: grouped by
repository, last seven days. "Yesterday's run in one click" (U1) holds because the default range
includes it and the row is the link. Grouped by task (U3), the same `checkout-tax` appears once as
a group with its runs from `acme/shop` and `acme/tax-service` under it, each row leading with its
repository. The summary line counts what the filters return; "Updated as batches land" is the only
live cue on this page.

Live behaviour: a changed run updates in place by DOM id. A **new** run that matches the filters
is not inserted under the reader; the summary line gains a link "1 new run" (accent) that
re-queries. At the top of page 1 with nothing focused inside the table, new runs insert directly.

### re2. Run page header (all four tabs)

```
Runs › github.example/acme/shop › 0191f2a4
checkout-tax  (•) Running                                         (o) Alive, 4 s ago
+-----------+-----------+---------------+----------+---------------------+------------------+
| Started   | Duration  | Runtime       | Host     | ~Wall~              | Policy           |
| Today,    | 2 m 14 s  | claude 2.1.273| build-01 | docker registry.exa…| ~enforce~ 9f86d0…|
| 14:02:11  | so far    |               |          |                     |                  |
+-----------+-----------+---------------+----------+---------------------+------------------+
Labels [forge|github.example] [repository|acme/shop] [task|checkout-tax] [branch|feature/vat]
[ Timeline 24 ]  Terminal   Connections 2 denied   Details
```

`<h1>` is the task label; without one, "Run 0191f2a4" with the id in mono. `<title>`:
"checkout-tax · Runs · Qory". The strip shows, from `run.started`, `run.exited` and
`policy_applied`: Started · Duration · Runtime · Host · Wall · Policy. After exit a seventh cell
appears first in the strip: **Exit** "0", "1", "SIGKILL", "timeout" or "runner lost". Wall reads the
adapter and, as the sub value, the image; a run without a wall reads "None" with the tooltip "This
run had no wall. A program that ignores the proxy is not seen." Policy reads the mode and the first
twelve characters of the digest (full digest in `title`, copy button on hover); `source: none`
reads "observe" with the sub value "no policy" and no digest. Everything else from the two events
(command, arguments, directory, versions, interactive, the full allow list, terminated hosts,
credentials by name, run configuration digest) lives on the Details tab as three cards: **Command**,
**Policy in force**, **Record**.

Phone: the title row wraps (alive line under the title), the strip is two columns, labels wrap,
tabs scroll sideways.

### re3. Timeline tab

Order on the page: lane key and the "Connections inline" toggle; the limits notice when one
applies; the background-task strip when any; the timeline; the live end line; the pill. The
wireframe is in rd10. An ended run opens at the top. A live run opens at the top too (the reader
came to read what happened); the pill and `End` take them to the live end, and `?seq=` overrides
both.

### re4. Terminal tab

The terminal box and its one-line caption, nothing else. Wireframe:

```
+--------------------------------------------------------------------------+
| [terminal]                         [⌕ ERROR   1 of 2] [wrap] [↓raw] [↓ Following] |
|--------------------------------------------------------------------------|
|  ✻ Claude Code v2.1.273 · /work/shop                                     |
|  ● Bash(pip install tax-rates-client)                                    |
|    ERROR: Could not install packages …                                   |
|  > █                                                                     |
|--------------------------------------------------------------------------|
| • Live   48.2 KB   312 chunks   through #0041                  120 × 32  |
+--------------------------------------------------------------------------+
```

### re5. Run connections tab and re6. Workspace connections (`/workspace/connections`)

Both are rd13. The workspace page's header: **Connections** / "Where the runs of this
workspace reached out to, and what the policy made of it. One row per host, port and path,
across runs." Filters: the decision segmented control, Repository, Host, Seen (time range,
default last 7 days); summary on the right "8 destinations · 3 denied · 11 runs". With
`repo` set the description gains a second sentence: "Showing `github.example/acme/shop`
only." On phones both tables scroll sideways inside their wrapper; the sub-row's content
is pinned to the visible width (`sticky left-0`) so the list of runs reads without
scrolling.

### re7. Empty, loading and error states

| Where | State | What renders |
|---|---|---|
| Runs list | no runs in the workspace, no keys | `<.empty_state icon="hero-play-circle">` **No runs yet** "A run appears here when a machine with an access key of this workspace starts one. Create a key, paste its server block into the runner file on the machine, and start a run." `[Create an access key]` primary → `/workspace/keys/new` |
| Runs list | no runs, keys exist | same title; "No machine has posted a run to this workspace yet. The server block to paste into the runner file is on the access keys page." `[Go to access keys]` default → `/workspace/keys`; under it the listening line "Listening for the first run." |
| Runs list | filters match nothing | neutral hex tile `hero-funnel`: **No runs match these filters** "11 runs are hidden by them." `[Clear filters]` default |
| Runs list | loading (first mount, async) | the table header and eight skeleton rows shaped like the columns; never a spinner |
| Runs list | query failed | error `<.notice>`: "The runs could not be loaded. Reload the page; if it keeps happening, the server log has the reason." |
| Run page | run not found | `<.empty_state tone="neutral" icon="hero-magnifying-glass" heading="h1">` **This run is not in this workspace** "The link may be for another workspace, or the run id is mistyped." `[Back to runs]` |
| Run page | `pending` | header with "Ping only"; every tab body: neutral empty state **Waiting for the run to start** "The runner has pinged. The run's first event has not arrived." with the listening dot |
| Timeline | no session events | the limits empty state (rf), never a bare "No events" |
| Timeline | events not yet projected | info notice "12 events have arrived and are being read." (from `event_count - projected_sequence`) |
| Terminal | no log chunks | neutral empty state **No output yet** (live) / **This run wrote no output** (ended) |
| Terminal | stream fails | inside the box, centred, dim: "The log stream dropped. Reconnecting." then on the third failure "The log could not be loaded." `[Try again]` ghost |
| Connections | none | neutral empty state **No connections recorded** + the `:no_egress` sentence |
| Workspace connections | none in range | **No connections in the last 7 days** "Widen the range, or wait for a run to reach out." |
| Any | LiveView disconnected | the reconnect toast of `brief.md`; live dots lose their ripple and the alive line reads "Reconnecting" until the socket is back |

---

## rf. Microcopy

**Headings and descriptions**

| Page | Title | Description |
|---|---|---|
| Runs | Runs | Every run the machines of this workspace have posted, as their events tell it. |
| Connections | Connections | Where the runs of this workspace reached out to, and what the policy made of it. One row per host, port and path, across runs. |
| Run | the task, or "Run {short id}" | none; the strip is the description |

**Term hovers** (the `<.term>` treatment, first occurrence per page; `standard` attr carries the text)

| Term | Tooltip |
|---|---|
| wall | The enclosure the agent runs in. Its only route out leads to the runner's proxy. |
| enforce | Enforce: a connection no rule allows is denied. Observe: it is let through and recorded. |
| observe | the same sentence |
| outcome | What became of the connection. Connected: the dial succeeded. Dial failed: allowed, but the host did not answer. Refused: never dialled. |
| policy digest | The sha256 of the policy this run ran under. Two runs with the same digest had the same policy. |
| lost | Nothing was heard for three heartbeat intervals. The run may still be going; the record is not. |
| closed | A member closed this run after it went quiet. It never posted its exit. |
| pending | The runner has pinged, and the run's first event has not arrived. |
| terminated host | A host whose requests the proxy reads, because the run holds a credential or path rules for it. Every other host is a blind tunnel. |
| lane | One agent's events: the main session, or a subagent from its start to its finish. |

**Connection reasons (C3).** Built from the last egress event of the row. `{rule}` is a mono chip.

| Record | Sentence |
|---|---|
| allowed, `rule` set | Rule `{rule}` (inline variant: **Allowed** by rule `{rule}`) |
| allowed, `rule` and `path_rule` set | Rule `{rule}`, path `{path_rule}` |
| … and `credential` set | …, credential `{credential}` |
| allowed, `rule` empty (observe) | **No rule matches.** Observe mode lets it through. |
| denied, `rule` empty (enforce) | **No rule matches.** Enforce mode denies it. |
| denied, `rule` set, `path_rule` empty | **Host allowed, no path rule matches.** Enforce mode denies it. |
| denied, `rule` = `wall:own-address` | **The wall refuses the machine's own address,** in either mode. |
| denied, `path_rule` = `wall:ambiguous-path` | **The path can be read two ways.** The wall denies it in either mode. |
| outcome `refused` on an allowed row | add: "Closed when a new policy denied the host." |
| outcome `dial_failed` | Outcome reads "Dial failed"; the reason is unchanged: the policy allowed it, the network did not. |

The inline variant prefixes denied sentences with "**Denied.**".

**The limits (P5).** `<.limits reason=…>`; chosen from the record, in this order:

| Reason | When | Sentence |
|---|---|---|
| `:not_started` | state `pending` | The runner has pinged. The run's first event has not arrived. |
| `:other_runtime` | `runtime` is not `claude` | Session events exist only for Claude Code. This run used `{runtime}`, so it has a terminal and connections, and no timeline. |
| `:vm_wall` | walled run, no session event from a hook, run has ended or is older than 60 s | This run was behind a wall on an engine inside a virtual machine, where the runtime's hook socket does not reach the runner. It has a terminal and connections, and no session timeline. |
| `:no_hooks` | `claude`, no wall, no session events, older than 60 s | No session events arrived. They come from the runtime's hooks over a local socket; when the socket is not working the run still has its terminal and connections. |
| `:no_egress` | no egress events | No connection went through the runner's proxy. Only programs that honour the proxy variables are seen. |
| `:no_log` | no log chunks | see re7 |

`:vm_wall` is the one place the page could be accused of guessing, so it is worded as the
contract's known limit and only shown when the record fits it (wall set, zero hook events). If the
runner later records the engine kind, switch the condition to that field. When a walled run has a
`session.result` (structured output crosses the wall) and nothing else, the timeline shows that
one item under an info notice with the same sentence, ending "Only the result, read from the
runtime's output, is shown."

Footnotes under tables (12.5 px faint): run connections: "Counted per host, port and path from the
run's egress events. The reason and outcome are those of the last attempt. Only programs that
honour the proxy are seen; behind a wall, anything else fails unseen." Without a wall the last
clause reads "without a wall, anything else connects unseen." Workspace connections:
"Denied destinations come first, then the most recent. The reason and outcome are those of
the last attempt across the runs shown."

Announcements (the polite region, ri): "Run succeeded after 18 m 02 s." "Run failed with exit 1."
"Run timed out." "Run lost. No heartbeat for 90 s." "Heartbeats resumed." "3 new events." (at most
once every 10 s).

---

## rg. Motion

| What | Behaviour | Reduced motion |
|---|---|---|
| Running badge dot | 12 px ripple ring, 1.6 s, `--q-ease-out`, infinite | solid dot, no ring |
| Alive dot, live-end dot, sidebar alive dot | the 2.4 s ripple of `<.listening>` | static dot |
| Amber quiet state | none. The ripple stops: stillness is the signal | same |
| Open tool node, background strip | the 12 px spinner, 0.9 s linear | static three-quarter ring |
| New timeline item at the live end | opacity 0 → 1 over 180 ms; no height animation, no slide | appears |
| New items pill | 180 ms in (opacity, 4 px rise), 120 ms out | appears |
| Targeted item (`?seq=`) | `primary-soft` background, no fade | same |
| Disclosure chevron | 120 ms rotate; the body opens at once | instant |
| Row hover, chips, tabs | 120 ms colour, as `brief.md` | 0 |
| Terminal cursor | the recorded output's own, drawn by xterm.js; `cursorBlink: false` for an ended run | `cursorBlink: false` always |
| Ticking numbers (alive, duration, relative time) | text swap once a second at most; `tabular-nums` so width never changes | same |

This adds three looping animations to the list in `brief.md` e (running ripple, tool spinner, alive
ripple); all three mean "the record is still being written" and stop when it stops. Nothing else
loops. Scroll-to-end is `behavior: smooth` capped by the browser; `auto` under reduced motion.
Layout never animates: streamed inserts do not push content when the reader is away from the end
(rj), and a sticky tab bar does not change height.

---

## rh. Accessibility

**Contrast**, computed from the oklch values (WCAG 2.x). Text needs 4.5, non-text marks 3.0.

| Pair | `qory` | `qory-dark` |
|---|---|---|
| `success` (allowed glyph, outcome dot) on base-100 / base-200 | 4.87 / 4.63 | 8.39 / 8.84 |
| `success` on `success-soft` (the allowed mark itself; non-text, needs 3.0) | 4.41 | 7.03 |
| `error` (denied mark fill, denied count glyph) on base-100 / base-200 | 5.50 / 5.23 | 5.85 / 6.16 |
| base-100 glyph on `error` (the denied mark) | 5.50 | 5.85 |
| `error-soft-content` (denied lead, counts) on `denied-tint` | 7.46 | 8.48 |
| base-content / muted / `error` on `denied-tint` | 16.3 / 6.28 / 5.15 | 13.9 / 6.42 / 5.29 |
| `success-soft-content` on `success-soft` (Succeeded) | 7.80 | 9.19 |
| `error-soft-content` on `error-soft` (Failed, Timed out) | 7.05 | 7.86 |
| `info-soft-content` on `info-soft` (Running) | 7.37 | 8.94 |
| `primary-soft-content` on `primary-soft` (Lost, quiet) | 7.60 | 9.47 |
| `primary-soft-content` (amber note, quiet dot, dial-failed square) on base-100 | 8.50 | 11.46 |
| `warning` on base-100 (not used as a mark, for the record) | 2.16 | 9.61 |
| `lane-a` / `lane-b` / `lane-c` on base-100 (rail, ring, who chip text) | 5.77 / 5.20 / 5.49 | 8.20 / 8.81 / 8.47 |
| `lane-main` on base-100 (non-text rail) | 3.05 | 3.04 |
| `term-fg` / `term-dim` on `term-bg` | 13.4 / 5.8 | 14.9 / 6.4 |
| terminal red / green / yellow / blue / magenta / cyan on `term-bg` | 7.3 / 10.3 / 11.0 / 9.1 / 8.6 / 10.7 | 8.1 / 11.4 / 12.2 / 10.1 / 9.5 / 11.9 |
| search match: `primary-content` on `primary` | 8.5 | 9.6 |

Rules that follow. `success` is 4.24 on base-300 in the light theme, so a green glyph never sits on
base-300; rows hover to base-200. Green and red are never the only difference: allowed and denied
differ in fill (soft against solid), glyph (check against barred circle), word, and row tint; the
three outcomes differ in shape (dot, square, ring). Lane colour is doubled by rail position and the
who chip.

**Keyboard path through the run page.** Skip link → sidebar → breadcrumb → tabs → lane key →
timeline. The timeline is an `<ol aria-label="Session timeline, oldest first">`; each item an
`<li>`. Tab stops inside it are only the interactive parts: a tool's `<summary>`, a collapsed
connection group, the sequence permalink (which is `tabindex="-1"` and reached with the item
shortcut instead, to keep the tab path short). With focus in the timeline a roving shortcut layer
(hook `TimelineKeys`) adds: `j` / `k` next and previous item, `Enter` or `Space` open and close,
`o` open every tool, `x` next denied connection, `Shift+x` previous, `g` then `e` the live end,
`g` then `t` the top, `c` copy the permalink of the focused item. They are listed in a `?` popover
on the lane key row and are inactive while a field has focus. Items switched off by a lane toggle
are `inert`.

**Live regions.** A tailing log and a filling timeline must not talk.
- The terminal screen is `role="log"` with `aria-live="off"` and a label "Log, 96 lines". xterm.js's
  own `screenReaderMode` stays **off** while Following is on (it announces every line) and is
  turned on when the reader stops following, so the buffer is readable line by line on demand.
- The timeline `<ol>` has no `aria-live`. New items are counted by the pill.
- One page-level `div#run-announcer[aria-live="polite"][aria-atomic="true"].sr-only` carries the
  announcements of rf: state changes at once, "n new events" at most once every 10 s and only while
  the tab is visible. Ticking text (`Alive, 4 s ago`, durations, relative times) is `aria-live="off"`;
  its `<time>` carries the absolute value.
- The amber quiet state is announced once, on entry, and once on recovery.

**Names and roles.** State badges read as their word ("Running"); the exit code is part of the
text. The decision mark has an `sr-only` word, so a row reads "Denied, files.cdn.example port 443,
CONNECT, no rule matches, enforce mode denies it, refused". Group header buttons: `aria-expanded`
and "github.example acme/shop, 5 runs, 1 alive, 3 denials". Filter chips: the set chip's button is
"Runtime: claude, change", its remove button "Remove filter: runtime claude". The split bar is
`aria-hidden`; the numbers beside it carry the meaning. Table scroll regions stay focusable with a
label, as in `brief.md`.

**Focus order** follows the visual order; the sticky tab bar never covers the focused element
(`scroll-padding-top: 64px` on `<main>`). Opening a disclosure keeps focus on its summary. The pill
moves focus to the first new item. A `patch` between tabs keeps focus on the tab.

**Targets.** Chips, tabs and group headers are 32 px on a pointer and 40 px on touch; the 20 px chip
remove button and the 18 px disclosure chevron get `min-h-10 min-w-10` hit areas under
`@media (pointer: coarse)`.

**Reflow.** At 320 px and at 200 % zoom the page does not scroll sideways: the filter bar, the tab
row, code wells, the terminal screen and the connection tables scroll inside their own containers.

---

## ri. Phone layout (below 768 px)

16 px gutters, 20 px top padding, as `brief.md`. Per page: runs list rows reflow (rd8), the filter
bar is one scrolling row, the group-by control moves to the end of that row. Run header: title,
badge, then the alive line on its own row; strip in two columns; labels wrap; tabs scroll. Timeline:
16 px lanes and 18 px nodes (three lanes take 48 px); the head row wraps so the summary takes its own
line under the kind, offset stays on the first line, the sequence number hides (it is in the item's
`c` shortcut and in the URL when targeted); connection rows become two lines. Terminal: full bleed,
`100dvh - 200px`, icon-only bar buttons, the foot keeps Live and the size in bytes. Connection
tables scroll inside their wrapper, the first column is not sticky, the sub-row's content is pinned
to the visible width. Tooltips open on tap and close on the next tap anywhere.

---

## rj. Performance guidance for the builders

1. **Streams with stable ids.** Timeline items: `stream(:items, …)` with `dom_id` `"e-#{sequence}"`
   (a merged tool item uses the sequence of its `tool_started`; the later `tool_finished` re-inserts
   the same id, which updates it in place). Connection rows: `"cx-#{id}"` of the projection row;
   inline egress items: `"e-#{sequence}"`. Runs: `"run-#{run_id}"`. Workspace destination
   rows: `"dst-#{:erlang.phash2({host, port, path})}"`. Never an index. Never reset a
   stream on a batch.
2. **Window the timeline.** Mount renders at most **300 items**: the first 300 for an ended run, and
   for `?seq=` the 300 around it. A sentinel at each end (`phx-viewport-top` / `phx-viewport-bottom`)
   pages 200 more with `stream(..., at:, limit: ±600)`, so the DOM never holds more than 600 items.
   A row "1,240 earlier events" / "Load newer" is the visible fallback when a sentinel has not
   fired. The lane layout (which lanes are open at a sequence) is computed once per run on the
   server from the subagent events, not per window, so rails stay right at window edges.
3. **Payloads stay out of the socket.** An item carries the head row and at most 8 KB per well.
   "Show all 41 KB" fetches the event's `data` with a `phx-click` that streams the one item again.
   Closed `<details>` still render their wells (so find-in-page works) up to that cap.
4. **The log has its own endpoint.**
   `GET /workspace/runs/:run_id/log?stream=terminal&from={sequence}` answers
   `application/octet-stream`, chunked, the concatenated bytes of `log_chunks` in sequence
   order, authorised like the page. The last sequence sent is the `X-Qory-Log-Through`
   header on a finished response. For a live run the hook reads what exists, then opens
   `GET …/log/tail?from={sequence}` as `text/event-stream` (one event per chunk: `id` the
   sequence, `data` base64), reconnecting with `Last-Event-ID`. Bytes never cross the
   LiveView socket; the LiveView only pushes the foot's numbers. Write into xterm.js in
   slices of at most 256 KB per animation frame so a 20 MB log does not block input.
   Chunks may split a multibyte character: feed xterm.js `Uint8Array`s, never decoded
   strings. Download streams the same endpoint with
   `Content-Disposition: attachment; filename="{short id}.log"`.
5. **One subscription per page.** The projector broadcasts `{:run_projected, run_id, from_seq,
   to_seq}` on `"workspace:#{workspace_id}:runs"` and `"run:#{run_id}"`. The run page
   loads the items of that range and inserts them; the list updates the one row.
   Coalesce: handle at most one broadcast per run per 250 ms.
6. **Away from the end, count instead of insert.** The `LiveEnd` hook reports whether the reader is
   within 240 px of the end. When not, the LiveView keeps new items in the stream's pending range
   and only bumps `<.new_items count>`; the pill's click loads them. This is what keeps the layout
   from jumping under a reader (P6).
7. **Clocks tick in the browser.** `Ticker` updates every `<time data-since>` and `<time
   datetime>` from one `setInterval(1000)`, paused while the tab is hidden. The server sends
   instants, never rendered relative strings, and never re-renders for a clock.
8. **Queries.** The runs list reads `runs` only: state, labels, times and a denials count. Add
   `runs.denied_count` to the projection (sum of `connections.denied`), or the list needs a join per
   page. Index `(workspace_id, started_at desc)` and
   `(workspace_id, repository_id, started_at desc)`. The workspace connections page groups
   `connections` by `(host, port, path)` within the range; page at 50 destinations; load a
   destination's runs only when its row opens. Filter option counts come from one grouped
   query per facet, run in `assign_async`.
9. **xterm.js loads on demand.** The Terminal hook `import()`s xterm.js and its add-ons on first
   mount; no other tab pays for them. Self-host the files with the other assets; no CDN.

---

## rk. Done checklist

Navigation and URLs
- [ ] Sidebar in two sections; Runs with the alive count, Connections; `nav` set on every new page
- [ ] Every filter, grouping, tab and targeted event is in the URL; back undoes a filter; a copied URL reproduces the view
- [ ] Breadcrumb on the run page only; `width="full"` (1200) on the three new pages

States and truthfulness
- [ ] Seven states render as specified; amber after one missed interval with the seconds ticking; lost only when the server says so
- [ ] Durations freeze to "at least …" when heartbeats stop; "n/a" for what the record lacks
- [ ] Connections inside a tool only when exactly one call is open; the caption says "while", never "because"
- [ ] A limits sentence wherever a timeline, log or connection list is empty

Run page
- [ ] Header strip from `run.started`, `run.exited`, `policy_applied`; labels; alive indicator; Details holds the rest
- [ ] Timeline: all item kinds, three lanes for two subagents with start and finish brackets, lane key toggles, background strip, live end line, pill
- [ ] Terminal: dark in both themes, tailing, Following and jump to end, search with count, download, stream switch on pipes
- [ ] Connections: per-run table with reasons and outcomes, trailing slot empty; workspace
  table with the runs per destination; repository filter

Quality
- [ ] Both themes, at 1440, 1024, 768, 375; no page-level horizontal scroll at 320
- [ ] Keyboard-only pass of the timeline shortcuts; VoiceOver pass of a live run (no chatter from the log or the clocks; state changes announced once)
- [ ] `prefers-reduced-motion`: no ripple, no spinner rotation, no smooth scroll
- [ ] A 5,000-event run opens in under a second and holds 60 fps while scrolling; a 20 MB log streams without freezing the tab
- [ ] Synthetic sample data only; no customer, engagement or person named; no AI attribution; British spelling
