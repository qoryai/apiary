# Qory console: design brief for the workspace overview (M8)

Implementation spec for the workspace overview, `/workspace`: the page a member lands on
after sign-in. It extends `brief.md`, `brief-runs.md` and `brief-policy.md`; everything
there (tokens, shell, components, tone, accessibility) still holds and is not repeated.
The rendered reference is `overview-mock.html` beside this file; where the two disagree,
this brief wins. Section letters continue the pattern with an `o` prefix.

Naming. The brand is **Qory**. The page says **organisation** and **workspace**, plain
words with no term hover (`docs/lingo.md`); "apiary" and "hive" are words of the per-user
apiary skin, which is not built. Sample data is synthetic only: Acme, Platform,
`acme/shop`, `acme/tax-service`, `acme/docs`, `github.example`, `gitlab.example`,
`files.cdn.example`, `flags.example`, `telemetry.example`, `*.paste.example`, `build-01`,
`build-02`, `dev-laptop`, `beekeeper@example.com`, `dana@example.com`.

What the page replaces. Today's overview
(`lib/apiary_web/live/workspace_live/overview.ex`) shows three stat tiles and a "Connect a
machine" checklist that never leaves and whose third step never ticks. Both go. The stat
tiles become the Activity strip; the checklist becomes the empty-workspace state (oe6) and
collapses to one link once the first run has landed.

Out of scope, not designed here: editing rules beyond the one-click allow of a suggestion row,
closing a run from anywhere but the Needs attention item, members and settings (they keep their
pages and their sidebar counts), a time-range filter on the overview (it is a fixed window, see
oa 4).

---

## oa. Principles for a landing page

The principles of the three earlier briefs apply. These five are added.

1. **Two questions, no click.** The page answers "what did my agents do" and "what needs me"
   above the fold, in that order of urgency: what needs you comes first, because it is why you
   would open the console twice a day; what they did comes second, because it is why you opened it
   the first time. Everything else (policy, machines, retention) is a glance and a link.
2. **Only from the record.** Every number is a count the workspace already keeps: `runs`
   columns the projector folded, `connections` counters, `access_keys` timestamps,
   `retention_runs` rows, the policy's mode and version. The page infers nothing: no
   "healthy", no "trend", no estimate. When a count cannot be made (the activity read is
   over its cap) the page says so in a sentence and drops the number; it never shows a
   part as a whole.
3. **Attention is a list of acts.** An item is on the Needs attention list only when there is a
   button beside it that resolves it, or a link to the one place where it is resolved. A fact
   without an act is activity, not attention. When there is nothing to do the section is absent:
   no green tick, no "all clear" card, nothing to learn to ignore.
4. **Bounded, then a link.** Every list shows at most five rows and ends with "and 12 more" as a
   link to the page that holds them all. The chart is fourteen days and no more. The overview is
   never the page where a list is read to its end; it is where one learns which page to open.
5. **Nothing moves under the reader.** Live updates change numbers and rows in place. New rows
   append, resolved items stay struck until the next navigation, and a section never appears or
   disappears while the page is open unless the reader caused it. What is new arrives as words
   ("1 new run"), never as a layout jump.
6. **Runs are counted in three families.** An owner's ruling, for every surface: **alive**
   (`pending`, `running`, the amber quiet state included), **ended well** (`succeeded`) and
   **ended badly** (`failed`, `timed_out`, `lost`, `closed`; closed reads as "stopped by
   the workspace", not as a failure of the run, and sits in this family for scanning). On
   the overview every count and list that groups runs uses the families: the strip's
   sub-line, the chart's tooltip and table, the Alive now block. A badge keeps its own
   state word and colour (`brief-runs.md` rd1); a family is how runs are counted, never
   how one run is named. The runs list's State filter is grouped by the same families
   (`brief-runs.md`, Amendment 1).

---

## ob. Information architecture and URLs

### Route and width

`/workspace`, `WorkspaceLive.Overview`, `nav={:overview}`, `width="full"` (1200, as the
runs and policy pages): the Activity card and the two glance cards sit side by side from a
1280 px viewport (the content column is then 1000 px wide; below that the page is one
column), and the two tables under them take the full width, which 960 cannot hold without
scrolling them sideways. `<title>`: "Platform · Qory" (the workspace name; today's
"Overview" goes: the sidebar already says Overview, and the tab should say which
workspace).

No query parameters. The overview has one view; every filtered view lives on the page the link
opens. The only state kept is the reading preference of the chart's table toggle
(`localStorage` `qory:overview:table`, see od5).

### Where every link goes

| From | To |
|---|---|
| Needs attention, a denied destination | the suggestion row's own **Allow** (in place, od2); "See them" → `/workspace/connections?decision=denied` |
| Needs attention, a quiet run | `/workspace/runs/:run_id` |
| Needs attention, a lost run | **Close** (in place, the existing `Runs.close_run/2` and its confirm); "Open" → the run |
| Needs attention, a run behind the policy | `/workspace/runs/:run_id` and "What changed" → `/workspace/policy/targets/:id/versions/:n?compare=:m` |
| Needs attention, observing with rules ready | `/workspace/policy?confirm=enforce` (opens the pe1 confirm on arrival; ol 3) |
| Needs attention, no policy yet | `/workspace/policy` |
| Needs attention, an idle key | `/workspace/keys/:id/revoke` (the keys page with its revoke confirm open; the existing patch route) |
| Activity, a run row | `/workspace/runs/:run_id` |
| Activity, "n alive" / "and n more" | `/workspace/runs?state=pending,running` |
| Activity, "All runs" | `/workspace/runs` |
| Activity, a chart column | `/workspace/runs?from=2026-09-14&to=2026-09-14` (that day); a denial column adds `&denials=1` |
| Policy at a glance | `/workspace/policy`, `/workspace/policy/targets`, `/workspace/policy/targets?mode=own`, `/workspace/policy/targets/:id`, `/workspace/policy/versions/:n` |
| Access keys, a key row | `/workspace/keys` (the key row is not its own page; the row's last run links to the run) |
| Access keys, "Create another access key" | `/workspace/keys/new` |
| Retention | `/workspace/settings#retention` |

### Sidebar

Unchanged. The overview is the first item of the Workspace section. The alive count on
Runs and the mode word on Policy already ride their PubSub topics; the overview subscribes
to the same two (`Runs.topic/1` and `Policy.topic/1`) and to nothing else (oj 2).

---

## oc. Tokens added

Two, for the chart, declared beside the other semantic tokens in `app.css` for both themes and
the no-script dark block, and exposed through `@theme inline` as `--color-series-runs` and
`--color-series-runs-today`.

| Token | Use | `qory` | `qory-dark` |
|---|---|---|---|
| `--q-series-runs` | the columns of runs per day, past days | `oklch(62% 0.014 75)` | `oklch(58% 0.014 75)` |
| `--q-series-runs-today` | today's column, the one the reader is living in | `oklch(21% 0.012 65)` (= base-content) | `oklch(94% 0.008 80)` (= base-content) |

Denials per day take the existing `error`. Runs are a count, not a decision, so their series is
a neutral: the chart follows `brief-runs.md` ra 5 (red belongs to the policy's decisions) and the
`dataviz` rule that a single series needs no legend and no hue of its own. The two series never
share a plot (od5), so no adjacency check applies; contrast of each mark on base-100 / base-200:
`series-runs` 3.9 / 3.7 in light, 4.6 / 5.0 in dark; `error` 5.5 / 5.2 and 5.9 / 6.2 (all above
the 3.0 a non-text mark needs). Gridlines are `line` (a hairline one step off the surface, never
dashed). No token is added for the attention list: the marks are the decision marks of
`brief-runs.md` rd12, the dashed mark of `brief-policy.md` pd6, and the amber pair.

---

## od. Components

In `lib/apiary_web/components/overview_components.ex` unless a file is named. Every component
that renders inside a stream takes its `id` from the caller.

### od1. Attention list (`<.attention>`, `<.attention_item>`)

```elixir
# <.attention>
attr :id, :string, required: true
attr :items, :list, required: true     # ordered; empty renders nothing at all
attr :more, :map, default: nil         # %{count: 3, navigate: "/workspace/connections?decision=denied"}
# <.attention_item>
attr :id, :string, required: true      # stable: "att-denied-#{phash2({host, port, path})}", "att-run-#{run_id}", "att-key-#{id}", "att-policy-enforce"
attr :kind, :atom, required: true      # :denied | :quiet | :lost | :behind | :enforce | :unmanaged | :idle_key
attr :subject, :map, required: true
attr :resolved, :map, default: nil     # %{text: "Allowed here", at: dt} after the in-place act; the row stays, struck, until the next navigation
slot :inner_block, required: true      # the sentence (of)
slot :actions, required: true
```

One section card, `<section aria-labelledby="attention-h">`, headed **Needs attention** with the
count in mono faint ("4", never a red badge: the marks in the rows carry the tone) and, when the
list is bounded, "and 3 more" as the header's trailing link. Rows are `<li>` in a `<ul>`, 44 px
minimum, the `.sugg-row` grid of `brief-policy.md` pd6: a mark, a subject, a sentence, the actions.

| Kind | Mark | Subject | Sentence (of) | Actions |
|---|---|---|---|---|
| `:denied` | dashed red barred circle (pd6: nothing is decided) | host, `:port` faint, path if held to paths; all mono | Denied 9 times in 3 runs of `acme/shop`, last 2 minutes ago. | split `btn-xs` **Allow here** with a caret menu (Allow for the workspace, Allow with paths…): the pd8 popover with the repository preset; with runs of several repositories, **Allow** opens the popover with nothing chosen (pd8: the page does not guess a scope) |
| `:denied`, a locked deny covers it | closed padlock | as above | A locked workspace rule denies `*.paste.example`. Only an owner can change it. | link **Open the rule** |
| `:quiet` | amber solid dot (rd1 quiet) | `<.run_state>` running-quiet, the task, the short id | No heartbeat for 47 s. Heartbeats are due every 30 s; after 90 s of silence it is marked lost. | default `btn-xs` **Open** |
| `:lost` | amber `hero-signal-slash-micro` | `<.run_state state="lost">`, the task, the short id | Lost. Last heard Yesterday, 22:55, at least 8 m 30 s in. The run never posted its exit. | default `btn-xs` **Close** (the existing confirm; the row then reads "Closed") and ghost **Open** |
| `:behind` | the drift badge (pd9) | the task, the short id | Still on `v9` after 2 heartbeats; `v10` has been in force for 1 m 40 s. A run reloads at its next heartbeat. | ghost `btn-xs` **What changed**, default **Open** |
| `:enforce` | `hero-shield-exclamation-micro` in muted | **Observe is the workspace's default** | 6 allow rules are in force and every destination reached in the last 7 days is covered. Enforce would deny nothing today. | primary `btn-xs` **Set the default to enforce** (to `/workspace/policy?confirm=enforce`) |
| `:enforce`, something uncovered | the same | the same | 6 rules are in force. Enforce would deny 2 destinations reached in the last 7 days. | default `btn-xs` **Review on the policy page** |
| `:unmanaged` | `hero-shield-micro` in muted | **Qory serves no policy yet** | 11 runs landed under the machines' own policies. The first rule you add, or a mode you set, puts them under the workspace's. | default `btn-xs` **Open policy** |
| `:idle_key` | `hero-key-micro` in faint | the label, the key id mono | Not seen for 34 days; last runner 0.4.1. A key nobody uses is a key to revoke. | danger-ghost `btn-xs` **Revoke** (to `/workspace/keys/:id/revoke`) |

Order: denied destinations first (most denials first), then lost, quiet, behind (most recent
first), then the one policy item, then idle keys (longest idle first). At most five rows; the
sixth and later are the header's "and n more", which links to the connections page with
`decision=denied` when the overflow is denials, to the runs list filtered by state when it is
runs, to the keys page when it is keys (the overflow is counted per kind, and the link goes to the
kind that overflowed first in this order).

**Rules that decide inclusion**, all from the record:

| Kind | Included when |
|---|---|
| `:denied` | a destination of `Runs.page_destinations/3` with `decision=denied`, `since=7d`, that today's effective policy still does not allow, and that no locked deny covers (the locked case is its own row, at most one). One row per host, port and path; `runs`, `denied` and `last_seen_at` are the row's. When the activity read answers `:unavailable`, no denied rows: the Activity card's foot says so (of) |
| `:quiet` | `state == "running"` and `now - last_heartbeat_at > heartbeat_interval_seconds` (30 when the run named none), recomputed on a 5 s timer as the run page does (rd1) |
| `:lost` | `state == "lost"` and `lost_at` within the last 7 days. Older lost runs are not on this list: they are on the runs list under their state, and a week-old loss is a fact, not a task |
| `:behind` | `state in ["pending", "running"]` and `Policy.digests/2` says `drift: true` for more than two heartbeat intervals (a run that reloads within one is on time and is not listed; the second interval is grace). Never for an ended run (pd9) |
| `:enforce` | `Policy.mode_summary/1` says `managed?: true, mode: "observe"`, at least one allow rule is in force in the baseline, and at least one run landed in the last 7 days. The sentence reads `Policy.uncovered/2` over 7 days: the count of destinations enforce would deny, or "nothing" |
| `:unmanaged` | `managed?: false` and at least one run has landed (a workspace with no run is the empty state, oe6) |
| `:idle_key` | an active key (not revoked) with `last_used_at` older than 30 days, or `last_used_at` nil and `inserted_at` older than 30 days (of: "Never used in 34 days") |

**After an act.** The row stays where it is with its mark swapped (the soft green check for
Allowed, the neutral `hero-lock-closed-micro` for Closed) and the actions replaced by the words
"✓ Allowed here" / "Closed", as `brief-policy.md` pd6 does; it leaves at the next navigation. The
count in the header drops at once. Focus moves to the next row's first action, or to the Activity
card's "All runs" link after the last (ph). A refusal (a lock, a concurrent change) renders in the
pd8 popover, never as a toast alone.

### od2. Suggestion row reuse

The `:denied` row **is** `<.suggestions>`' row of `brief-policy.md` pd6 with two differences: the
subject carries the port and path, because it is a destination, not a declared host; and the
sentence names the repository, because the overview is not inside one. The split button and
its popover are pd8's, called with the destination's repositories from
`Runs.destination_repositories/3`. Nothing is redesigned.

### od3. Alive rows (`<.alive_rows>`, `<.alive_row>`)

```elixir
# <.alive_rows>
attr :id, :string, required: true
attr :runs, :list, required: true      # at most 5, most recently started first
attr :count, :integer, required: true  # Runs.count_alive/1
# <.alive_row>
attr :id, :string, required: true      # "alive-#{run_id}"
attr :run, :map, required: true
attr :quiet_for, :integer, default: nil
```

A 40 px grid row `[auto | minmax(0,1fr) | minmax(0,1fr) | auto]`: `<.run_state>` (running,
running-quiet or pending), the task in 500 with the short id in mono faint under it (rd8's run
cell), one cell with the repository in mono (forge faint, path normal; "no repository" faint) over
the host in mono muted, and `<.alive>` (rd6) right-aligned: "Alive, 4 s ago", "No heartbeat for 47 s" in amber, or
"Ping only" faint for a pending run. The row is one link to the run (the task's `::after` covers
it, as rd8). The head of the block reads **Alive now** with the count; the foot "and 2 more" when
`count > 5`, linking to the runs list filtered by state. With no alive run the block is one faint
line: "No run alive now." (never hidden: a reader who comes to check that nothing is running
must find the words).

### od4. Last runs (`<.recent_runs>`)

A full-width card under the two-column grid, headed **Last runs** with the link **All runs** on
the right: `<.runs_table>` of `brief-runs.md` rd8 with `group_by="none"`, at most five rows, no
group header, no footer pagination, and the Repository column in (it is what tells the rows apart
here). The columns: State · Run · Repository · Host · Started · Duration · Denials. It takes the
full width because seven columns do not fit beside a second column, and a table that scrolls
sideways on a 1440 px screen is a table nobody reads. The rows are the five most recently started runs
of the workspace, alive ones included (an alive run is in both blocks; the alive block is
for "now", the table for "last"; a reader who finds this odd finds the same run twice, not
a lie). Below 640 px the rows reflow as rd8 does.

### od5. Fourteen-day chart (`<.days_chart>`)

```elixir
attr :id, :string, required: true
attr :days, :list, required: true      # 14 maps %{date, runs, denied}, oldest first, today last; zeros filled in
attr :today, :any, required: true      # Date, UTC
attr :unavailable, :boolean, default: false
```

The form, chosen by the `dataviz` heuristic: two counts over time, of different scale and
different meaning (runs are runs; denials are attempts), so **never one plot with two axes**. It
is two small multiples stacked, sharing the x axis: **Runs per day** above, **Denied attempts per
day** below, each fourteen columns. Runs by the day they started (`runs.started_at`, UTC; a
pending run by `inserted_at`), with the count of those that ended well beside it in the tooltip
and the table; denials are `sum(runs.denied_count)` of the runs of that day, so
the two rows read the same set of runs and a column of the lower chart is always about the runs
of the column above it.

- **Marks**: columns at most 24 px wide, 4 px rounded at the top, square at the baseline, a 2 px
  surface gap between neighbours (the column never fills its slot). Runs in `series-runs`, today's
  column in `series-runs-today`; denials in `error` on every day (a denial is a decision, and the
  colour is the decision's). A day with zero draws a 2 px hairline stub in `line` so the day is
  visibly there and visibly empty. Heights are linear from zero; the y scale of each plot is its
  own, with the maximum labelled once at the top left in `text-[11px] text-faint tabular-nums`
  ("max 12", "max 5") and no other tick: fourteen columns do not need a grid, and the numbers are
  in the tooltip and the table.
- **Axis**: one hairline baseline per plot in `line`; day labels under the lower plot in
  `text-[11px] text-faint tabular-nums`: "7 Sep", then every second day, then "Today" in
  `text-muted` 500. Above the upper plot, at the right, the totals as words: "41 runs · 7 denied
  attempts, 14 days" in `text-[12.5px] text-muted` with the numbers in 500.
- **Hover and focus**: the column's whole slot is the hit target (24 px wide at least, the full
  plot height), one tooltip for both plots at that x (`dataviz`: one tooltip, every series): the
  date in 500, then "6 runs" and "2 denied attempts" as two lines with a 10 px line key in the
  series colour before each; the slot's `aria-label` adds the families: "6 runs (5 ended well,
  1 ended badly)" (today's reads "alive or ended badly": an alive run has not ended). The hovered slot lifts with a `base-200` wash behind both columns
  (the crosshair of a column chart). Each slot is a `<a>` to that day's runs list, so the columns
  are tab stops with the same tooltip on focus; `aria-label` "14 Sep: 6 runs, 2 denied attempts".
- **Table twin**: the chart's card foot has a toggle **As a table** (`aria-pressed`, `aria-controls`)
  that replaces the SVG with a 14-row table (Day · Runs · Ended well · Denied attempts), kept in
  `localStorage`. The SVG is `role="img"` with an `aria-label` that says the totals and the peak
  ("41 runs and 7 denied attempts in 14 days; most runs on 18 Sep, 12") so a screen reader gets the
  shape without the table, and the table for the values.
- **Live**: today's column grows in place when a run starts or a denial lands; nothing else
  moves. At midnight UTC the window shifts by one day on the next update (the columns slide by
  one slot, drawn anew; no animation).
- **Empty**: fourteen stubs, the totals read "No run in the last 14 days", the plots keep their
  height (the card never changes height with its data).
- **Unavailable**: the runs plot always draws (it is one grouped count over `runs`); if the
  denials come from a read that can be unavailable, the lower plot is dropped and its title
  replaced by the sentence of of. In this design the denials come from `runs.denied_count`, which
  is never unavailable, so this state is reserved.

### od6. Activity strip (`<.kvs>`, reused)

The `<.kvs>` of `brief-runs.md` rd4, four cells: **Alive now** (the count, sub "starting or
running" / "none"), **Runs, 14 days** (count, sub the families: "36 ended well · 3 ended badly · 2 alive"; a single
run that has not ended reads "in 1 repository"), **Denied attempts, 14
days** (count in `error-soft-content` when not zero, sub "to 3 destinations"), **Cost reported, 14
days** ("$12.40", sub "by 38 of 41 runs"). Cost is the sum of `cost_usd` of the `session.result`
events of the runs of the window, two decimals, four when the sum is under a cent; the sub value
says how many runs reported one, because runs that did not are not free, they are unrecorded.
When no run reported a cost the cell reads "n/a" faint with the sub "no run reported one".
The fold that puts `cost_usd` on the run row is ol 1; until it exists the cell is absent, not
zero.

### od7. Policy at a glance (`<.policy_glance>`)

A card headed **Policy** with the link **Open policy** on the right, and a `<dl>` of four rows,
each a fact on the left (Caption) and its value on the right:

| Row | Value |
|---|---|
| Mode | the word in 500 ("enforce"), then the neutral badge **Workspace default**, then in muted: "3 repositories follow it · 1 sets its own: `acme/tax-service` observes" (the `mode_summary` of the sidebar and `list_repositories/1`; the repository is a link; several are "2 set their own" as a link to `?mode=own`) |
| In force | `<.version_pill size="sm" navigate>` (v14, the short digest) and "since 16 Sep" in muted; a new workspace reads "No version yet" faint and the sub "machines use their own policy until the first change" |
| Repositories | "4 have posted runs · 2 with rules of their own" as links |
| To review | "3 declared hosts in 2 repositories" as an info chip **3 to review** linking to Repositories, or "Nothing declared and unallowed" in faint. From `Policy.suggestions/3` of the repositories that posted a run in the last 14 days, at most 5 repositories read (oj 6) |

Nothing on this card is a control: the mode is set on the policy page, where the confirm and the
list of what enforce would deny live. The `:enforce` attention item is the one place the overview
nudges.

### od8. Access keys (`<.access_keys>`)

An access key is not a machine: one key often serves many hosts (a pool of ephemeral CI
instances shares one), so the card is about keys and counts their hosts. A full-width card
under Last runs, headed **Access keys** with the count of active keys in mono faint and, once
the first run has landed, the link **Create another access key** on the right (to
`/workspace/keys/new`). A `<.table>` of at most five active keys, most recently seen
first, then the never-seen: **Key** (the label in 500, the key id in mono faint under it)
· **Last seen** (`<.relative_time at={last_used_at}>`; "Never posted" faint) · **Runner**
(`last_runner_version` mono, then `last_contract_version` as `v1` in mono faint 11.5
beside it with the title "Contract version 1"; "n/a" faint when the key never posted) ·
**Hosts, 7 days** (the distinct `runs.host` of the key's runs in the last seven days: the
one host's name in mono when there is one, "3 hosts" when more, "none" faint when the key
posted no run with a host in the window) · **Last run** (`<.run_state>` and the task or
short id, the start relative; a link to the run; "No run yet" faint). "and 2 more" under
the table when the workspace has more active keys, to `/workspace/keys`. Revoked keys are
not here (they are on the keys page). A key rotating shows the warning badge **Rotating**
after its label, as the keys page does. The last run per key is one query
(`DISTINCT ON (access_key_id)` ordered by `started_at desc`, oj 5) and the hosts another,
grouped by key over the same index and the window. Below 640 px the rows reflow: label and
last seen on the first line, the last run on the second; the runner and hosts cells are
dropped (one tap away).

### od9. Retention (`<.retention_glance>`)

A card headed **Retention** with the link **Settings** on the right. Two lines: the setting in
the settings page's own words (`retention_summary/1`: "Log output is pruned after 30 days,
events after 90 days." / "This workspace keeps everything."), then the last prune from
`Retention.list_retention_runs(scope, 1)`: "Last night pruned 12 runs: 4,120 events and 38.2 MB
of log output." (the settings page's `pruned_sentence/1`, prefixed by when: "Last night", "On 14
Sep", from `finished_at`), or "Nothing was old enough to prune last night.", or "No prune has run
yet." A job that did not finish adds "; not finished, the next night goes on." A workspace
that keeps everything has one line. Members read the same card with the same link (the
settings page tells them who can change it).

---

## oe. Page compositions

Copy is final. `{…}` is data. ~word~ carries the term hover; organisation and
workspace never do.

### oe1. Overview, a busy workspace (`/workspace`)

```
>= 1280
Platform
The workspace of the Acme organisation.

+ Needs attention  5 ----------------------------------------------------- and 2 more +
| [⦸] files.cdn.example :443   Denied 9 times in 3 runs of acme/shop, …   [Allow here|v] |
| [⦸] flags.example :443       Denied 4 times in 1 run of acme/tax-service…[Allow here|v] |
| [•] (•) Running  mirror-sync 0191f29d   No heartbeat for 47 s. …               [Open] |
| [⌁] Lost  nightly-mirror 0191c001   Lost. Last heard Yesterday, 22:55 … [Close][Open]|
| [k] old-runner qk_0c44…   Not seen for 34 days; last runner 0.4.1. …          [Revoke] |
+----------------------------------------------------------------------------------------+

+-------------+-----------------------------------+--------------------+------------------+
| Alive now   | Runs, 14 days                     | Denied, 14 days    | Cost reported    |
| 2           | 41                                | 7                  | $12.40           |
| running     | 36 ended well · 3 ended badly · 2 | to 3 destinations  | by 38 of 41 runs |
+-------------+-----------------------------------+--------------------+------------------+

+ Activity ---------------------------------------+ + Policy ------------ Open policy +
| Alive now 2                                     | | Mode      enforce [Workspace default] |
| (•) Running checkout-tax  github.example/acme/… | |           3 follow · 1 own       |
|             0191f2a4      build-01  (o) Alive…  | | In force  [v14 · e3b0c44298fc]   |
| (•) Running mirror-sync   gitlab.example/acme/… | | Repos     4 posted · 2 own rules |
|             0191f29d      build-03  • No heartb…| | To review [3 to review]          |
|-------------------------------------------------| +----------------------------------+
| 41 runs · 7 denied attempts, 14 days   [table]  | + Retention ---------- Settings +
| Runs per day                            max 12  | | Log 30 days, events 90 days.     |
| ▁▂▃▁▅▂▃▇▃▂▁▄▂▃                                  | | Last night pruned 12 runs: …     |
| Denied attempts per day                  max 3  | +----------------------------------+
| ▁ ▁   ▂ ▅   ▁                                   |
| 7 Sep  9  11  13  15  17  19  Today             |
|-------------------------------------------------|
| Counted from the workspace's runs by the day …       |
+-------------------------------------------------+

+ Last runs ------------------------------------------------------------------- All runs +
| State        Run              Repository            Host      Started    Duration  Den |
| (•) Running  checkout-tax     github.example/acme…  build-01  2 min ago  2 m 14 s  ⊘ 2 |
| (•) Running ⚠ No heartbeat…   mirror-sync  gitlab…  build-03  9 min ago  at least…   0 |
| ✓ Succeeded  checkout-tax     github.example/acme…  build-01  Yesterday  11 m 37 s ⊘ 4 |
| x Failed exit 1  fix-flaky-cart-test  github.exa…   build-02  Yesterday  6 m 51 s  ⊘ 1 |
| ✓ Succeeded  claude -p "bump the changelog"  no repository  dev-laptop  16 Sep  48 s  0 |
+----------------------------------------------------------------------------------------+
+ Access keys  3 --------------------------------------------- Create another access key +
| Key                 Last seen         Runner     Hosts, 7 days  Last run                |
| build-01 ak_7f3a…   4 s ago           0.4.2 v1   build-01       (•) Running checkout-tax |
| ci-pool ak_b81d…    Yesterday, 17:20  0.4.2 v1   12 hosts       x Failed exit 1  fix-fl… |
| dev-laptop ak_29e…  16 Sep, 18:05     0.4.1 v1   dev-laptop     ✓ Succeeded  claude -p … |
+----------------------------------------------------------------------------------------+
```

Header: the workspace name as `<h1>`, the description "The workspace of the Acme
organisation." (plain words, no term hover), no action button: the page's acts are in its
rows. Order top to bottom: Needs attention (od1), the Activity strip
(od6), then a two-column grid `minmax(0, 1.55fr) minmax(0, 1fr)` with the **Activity** card (alive
rows and the chart, divided by a hairline inside one card) on the left and the two glance cards
(Policy, Retention) stacked on the right, then **Last runs** (od4) and **Access keys** (od8) at full
width. The right column is `align-start`; the Activity card sets the height and the right column
never stretches to match it. Below a 1280 px viewport the grid is one column in the order
Activity, Policy, Retention, and the two tables follow as before.

The Activity card's foot, `text-[12.5px] text-faint`: "Counted from the workspace's runs
by the day they started, UTC. Updated as batches land." When the denied destinations could
not be counted the foot gains the sentence of of.

### oe2. Overview, nothing needs attention

The same page without the Needs attention section: the Activity strip is the first thing under
the header. No placeholder, no "all clear". The `<h1>` does not move: the section is between the
header and the strip, and its absence closes the gap.

### oe3. Overview, a member

Identical. Every act on this page is a member's (allow a host, close a run, revoke a key) except
the `:enforce` item, which a member sees with the sentence and the link **Open policy** in place
of the primary button (pe1: a mode is an owner's, and the policy page says so).

### oe4. Overview, a workspace that serves no policy yet

The `:unmanaged` attention item, the Policy card with "No version yet" and the sub sentence, and
the Mode row reading "observe" with the badge **Not served** in place of Workspace
default. Everything else as oe1.

### oe5. Overview, loading and unavailable

Mount renders the header, the strip with "…" skeleton values, the Activity card with eight
skeleton rows in the shape of the alive rows and the table, the chart's card at its full height
with the fourteen stubs, and the three glance cards with two skeleton lines each. Needs attention
renders nothing until its reads land (oa 3: it is absent, then present; this is the one section
that appears after mount, and it is at the top, so it pushes the page down once, before the
reader has read anything). Every region is `assign_async`; none blocks the first paint (oj 1).

When `Runs.page_destinations/3` or `Policy.uncovered/2` answer `:unavailable`: no `:denied` rows and
no `:enforce` count; the Activity foot says "Denied destinations were not counted: this
workspace recorded more than 20,000 connections in 7 days. The connections page counts
them by destination." The number in the strip's Denied cell is `sum(runs.denied_count)`,
which is not subject to the cap, so it stays.

### oe6. The empty workspace, in three steps

The checklist is the page while no run has landed. It is one bordered card, two columns from 768
px (`brief.md` h1), with the steps of `<.steps>` and the state of each step read from the record:

| Step | Done when | Current when |
|---|---|---|
| 1 Create an access key | the workspace has an active key | no key |
| 2 Paste the server block into the runner file | any key has `last_used_at` (a machine verified with it: a ping, a heartbeat, a batch) | keys exist, none used |
| 3 See runs here | any run has landed (`Runs.list_runs(scope, limit: 1) != []`) | a key was used, no run yet |

- **No key** (`/workspace`, nothing posted, no keys): `brief.md` h1 as it is: title **Send
  your first run**, "Nothing has posted to this workspace yet. An access key is all a
  machine needs to start.", step 1 current, the primary button **Create an access key**,
  the right column with the server block preview and the listening line "Listening for the
  first post from a machine." Step 2's sub-line reads "The secret is shown once, in the
  dialog that creates it. One key can serve many hosts: a pool of ephemeral instances
  shares one."
- **Keys, nothing posted**: the same card, the same title, step 1 done, step 2
  current, the sentence "The key is made. Paste its server block into the runner file on the
  machine; the secret was shown once, when the key was created." Actions: default **Manage access
  keys**. Listening line unchanged. The right column shows the preview with the real key id of the
  most recent key and the secret as dots.
- **A key was used, no run yet**: step 2 done, step 3 current with the body "The machine has
  verified with its key. The first run it starts lands here." and the listening line reads
  "Listening for the first run. `build-01` verified 2 minutes ago." (the label of the key with the
  latest `last_used_at`, the time ticking). Actions: default **Manage access keys**.
- **The first run lands**: step 3 ticks (the bug in today's page: `posted` never advanced the
  step) and the card leaves at the next navigation, not under the reader: while the page is open
  the card stays with all three steps done and a line under the steps "The first run has landed.
  Open it" (link to the run), and the Activity strip and cards render under it. On the next mount
  the card is gone and the Access keys card header holds the link **Create another access key**.

Under the checklist, while it shows, nothing else renders except the Access keys card once a key
exists (so the key just created is visible with "Never posted"); no chart, no policy card, no
retention card: an empty workspace has nothing to glance at, and the three cards would say
"nothing" three times.

### oe7. States, all of them

| Where | State | What renders |
|---|---|---|
| Needs attention | nothing to do | the section is absent |
| Needs attention | more than five | five rows and "and n more" in the header |
| Needs attention | an item resolved in place | the row stays, mark swapped, "✓ Allowed here" / "Closed"; leaves on the next navigation |
| Needs attention | a new item arrives | appended at the end (the list is not re-sorted under the reader); the header count updates; the polite region says "1 more item needs attention." at most once per 10 s |
| Needs attention | an item resolves elsewhere (the run reloaded, a heartbeat resumed, someone else allowed the host) | the row stays with the resolution in words ("Heartbeats resumed", "Reloaded to v10", "Allowed for the workspace by dana@example.com") and no actions; leaves on the next navigation |
| Alive now | none | "No run alive now." faint, one line |
| Alive now | more than five | five rows and "and n more" |
| Chart | no run in 14 days | fourteen stubs and "No run in the last 14 days" |
| Chart | today's first run | today's column appears from the stub; no animation |
| Strip, Cost | no run reported one | "n/a" faint, "no run reported one" |
| Strip, Cost | the fold does not exist yet (ol 1) | the cell is absent; the strip has three cells |
| Last runs | fewer than five | the rows there are; no filler |
| Policy | new workspace | "No version yet", **Not served**, the sub sentence |
| Policy | nothing to review | "Nothing declared and unallowed." faint |
| Policy | suggestions unavailable (a repository's read over its cap) | that repository is left out of the count, and the row ends "· 1 repository not counted" faint with the title "More connections than one read counts; open the repository to see its suggestions." |
| Access keys | no active key | the card is absent (the checklist is the page) |
| Access keys | a key never used | "Never posted" faint, "n/a", "none", "No run yet" |
| Access keys | more than five | five rows and "and n more" |
| Retention | keeps everything | "This workspace keeps everything." one line, the link |
| Retention | set, no prune yet | the setting, then "No prune has run yet. The job runs nightly." |
| Retention | last prune found nothing | "Nothing was old enough to prune last night." |
| Retention | last prune did not finish | "… ; not finished, the next night goes on." |
| Any region | loading | skeletons in the shape of the content; never a spinner |
| Any region | query failed | an info `<.notice>` in the card: "This could not be loaded. Reload the page; if it keeps happening, the server log has the reason." |
| Any | LiveView disconnected | the reconnect toast of `brief.md`; ripples stop; "Updated as batches land" reads "Reconnecting" |

---

## of. Microcopy

**Header**

| Where | Text |
|---|---|
| Title | {workspace name} |
| Description | The workspace of the {organisation name} organisation. |
| `<title>` | {workspace name} · Qory |

**Needs attention**

| Where | Text |
|---|---|
| Heading | Needs attention · `4` · and 2 more |
| Denied | Denied **9 times** in 3 runs of `acme/shop`, last 2 minutes ago. |
| Denied, several repositories | Denied **9 times** in 3 runs of 2 repositories, last 2 minutes ago. |
| Denied, path held | Host allowed, no path rule matches `/v2/upload`. Denied **3 times** in 1 run of `acme/shop`, last Yesterday, 16:40. |
| Denied, locked | A locked workspace rule denies `*.paste.example`. Only an owner can change it. |
| Quiet | No heartbeat for **47 s**. Heartbeats are due every 30 s; after 90 s of silence it is marked lost. |
| Lost | Lost. Last heard Yesterday, 22:55, at least 8 m 30 s in. The run never posted its exit. |
| Lost, closed here | Closed. |
| Behind | Still on `v9` after 2 heartbeats; `v10` has been in force for 1 m 40 s. A run reloads at its next heartbeat. |
| Behind, resolved | Reloaded to `v10` at `#0046`. |
| Enforce, all covered | **Observe is the workspace's default.** 6 allow rules are in force and every destination reached in the last 7 days is covered. Enforce would deny nothing today. |
| Enforce, uncovered | **Observe is the workspace's default.** 6 rules are in force. Enforce would deny **2** destinations reached in the last 7 days. |
| Enforce, member | … Only an owner sets a mode. |
| Unmanaged | **Qory serves no policy yet.** 11 runs landed under the machines' own policies. The first rule you add, or a mode you set, puts them under the workspace's. |
| Idle key | Not seen for **34 days**; last runner 0.4.1. A key nobody uses is a key to revoke. |
| Idle key, never used | Never used since it was created 34 days ago. A key nobody uses is a key to revoke. |
| Buttons | Allow here · Allow · Open · Close · What changed · Set the default to enforce · Review on the policy page · Open policy · Open the rule · Revoke |
| Announcements | 1 more item needs attention. / files.cdn.example is allowed for acme/shop. / mirror-sync is closed. |

**Activity**

| Where | Text |
|---|---|
| Strip | Alive now · Runs, 14 days · Denied attempts, 14 days · Cost reported, 14 days |
| Strip subs | starting or running / none · 36 ended well · 3 ended badly · 2 alive (a family at zero is left out; one run that has not ended reads "in 1 repository") · to 3 destinations / none · by 38 of 41 runs / no run reported one |
| Alive head | Alive now `2` · and 2 more |
| Alive, none | No run alive now. |
| Alive line | Alive, 4 s ago / No heartbeat for 47 s / Ping only |
| Chart totals | **41** runs · **7** denied attempts, 14 days |
| Chart, empty | No run in the last 14 days |
| Chart titles | Runs per day · Denied attempts per day · max 12 |
| Chart axis | 7 Sep … Today |
| Chart tooltip | **14 Sep** / 6 runs / 2 denied attempts; slot label "14 Sep: 6 runs (5 ended well, 1 ended badly), 2 denied attempts, open that day's runs" |
| Chart table | Day · Runs · Ended well · Denied attempts |
| Chart toggle | As a table / As a chart |
| Chart `aria-label` | 41 runs and 7 denied attempts in 14 days; most runs on 18 Sep, 12. |
| Last runs head | Last runs · All runs |
| Card foot | Counted from the workspace's runs by the day they started, UTC. Updated as batches land. |
| Foot, unavailable | Denied destinations were not counted: this workspace recorded more than 20,000 connections in 7 days. The connections page counts them by destination. |

**Policy, Access keys, Retention**

| Where | Text |
|---|---|
| Policy rows | Mode · In force · Repositories · To review |
| Mode value | **enforce** [Workspace default] 3 repositories follow it · 1 sets its own: `acme/tax-service` observes |
| Mode value, all follow | **enforce** [Workspace default] Every repository follows it. |
| Mode value, new workspace | **observe** [Not served] Machines use their own policy until the first change here. |
| In force | [v14 · e3b0c44298fc] since 16 Sep / No version yet |
| Repositories | **4** have posted runs · **2** with rules of their own |
| To review | [3 to review] in 2 repositories / Nothing declared and unallowed. |
| Access keys head | Access keys `3` · Create another access key |
| Access keys columns | Key · Last seen · Runner (0.4.2 v1) · Hosts, 7 days (build-01 / 12 hosts / none) · Last run |
| Access keys cells | Never posted · n/a · none · No run yet · and 2 more |
| Retention lines | Log output is pruned after 30 days, events after 90 days. / This workspace keeps everything. |
| Last prune | Last night pruned **12 runs**: 4,120 events and 38.2 MB of log output in 610 chunks. Pruned log output from before 21 Aug, events from before 22 Jun. |
| Last prune, on a date | On 14 Sep pruned … |
| Last prune, nothing | Nothing was old enough to prune last night. |
| No prune | No prune has run yet. The job runs nightly. |
| Not finished | …; not finished, the next night goes on. |

**The empty workspace**

| Where | Text |
|---|---|
| No key, title | Send your first run |
| No key, lead | Nothing has posted to this workspace yet. An access key is all a machine needs to start. |
| Keys, title | Send your first run |
| Keys, lead | The key is made. Paste its server block into the runner file on the machine; the secret was shown once, when the key was created. |
| Step 3 current | The machine has verified with its key. The first run it starts lands here. |
| Listening | Listening for the first post from a machine. / Listening for the first run. `build-01` verified 2 minutes ago. |
| First run landed | The first run has landed. `Open it` |
| Steps | Create an access key · Paste the server block into the runner file · See runs here |
| Buttons | Create an access key · Manage access keys · Create another access key |

**Term hovers** (the first occurrence per page): on the attention rows `lost`, `enforce`,
`observe` with the sentences of `brief-runs.md` rf. Organisation and workspace take none.

---

## og. Motion

| What | Behaviour | Reduced motion |
|---|---|---|
| Alive dots (rows, listening line) | the 2.4 s ripple of `<.listening>` | static dot |
| Running badge | the 1.6 s ripple of rd1 | solid dot |
| Chart column on hover | the `base-200` wash appears at once; the tooltip 180 ms as the tooltip of `brief.md` | appears |
| Chart, today's column growing | no animation: the height changes on the next render | same |
| Attention row resolved | mark and words swap at once; the row does not slide, fade or collapse | same |
| New attention row, new alive row | opacity 0 → 1 over 180 ms, appended, no height animation | appears |
| Skeleton → content | swap at once | same |
| Ticking text | once a second at most, `tabular-nums` | same |

No looping animation is added beyond the ripples already in the system. Layout never animates: the
chart card has a fixed height, the attention list only appends, the strip's cells have a
`min-width` so a number growing a digit does not reflow the row.

---

## oh. Accessibility

**Landmarks and order.** One `<h1>` (the workspace name). Sections:
`<section aria-labelledby>` for Needs attention, Activity, Policy, Access keys, Retention;
the strip is a `<dl>`. Keyboard path: skip link → sidebar → Needs attention rows (each
row's actions, in order) → the strip's links → alive rows → the chart's slots (fourteen
tab stops; `Home` and `End` jump; the table toggle) → All runs → the last-runs rows → the
policy card's links → the access key rows → the retention link. A row's link covers the
row (rd8), so a row is one tab stop plus its buttons.

**Names.** Attention actions name their object: "Allow files.cdn.example for acme/shop", "Close
mirror-sync", "Revoke dev-laptop", "Open upgrade-framework". The header count is text ("4 items").
Chart slots: "14 Sep: 6 runs, 2 denied attempts, open that day's runs". The table toggle:
"Show the chart as a table", `aria-pressed`. The version pill's copy button is
"Copy the digest" as pd1.

**Live regions.** One `div#overview-announcer[aria-live="polite"][aria-atomic="true"].sr-only`
carries: "1 more item needs attention.", the resolutions ("mirror-sync is closed."), and "1 new
run" at most once every 10 s while the tab is visible. Ticking text (alive lines, relative times)
is `aria-live="off"` with the absolute value in the `<time>`. Nothing else talks; the chart's
update is silent.

**Contrast** (WCAG 2.x, computed; text 4.5, marks 3.0).

| Pair | `qory` | `qory-dark` |
|---|---|---|
| `series-runs` on base-100 / base-200 (a mark) | 3.9 / 3.7 | 4.6 / 5.0 |
| `series-runs-today` on base-100 | 17.4 | 15.3 |
| `error` (a denial column) on base-100 / base-200 | 5.5 / 5.2 | 5.9 / 6.2 |
| faint (axis labels, 11 px; not the only carrier, the table exists) on base-100 | 4.8 | 4.6 |
| the rest | as `brief-runs.md` rh and `brief-policy.md` ph | |

**No colour-only meaning.** Every attention row has a mark with a shape, a word and an
`sr-only` name; every chart column has its number in the tooltip, the `aria-label` and the table;
today's column is also labelled "Today" on the axis; a denial column is in the plot titled
"Denied attempts per day", not only red.

**Targets.** 24 px row buttons get `min-h-10 min-w-10` under `@media (pointer: coarse)`; chart
slots are at least 24 px wide and the full plot height; on a phone the slot is the whole column
height of both plots.

**Reflow.** At 320 px and 200 % zoom nothing scrolls sideways at page level: the tables scroll in
their wrappers; the chart is an SVG with `viewBox` and `width: 100%` and its labels drop to every
third day below 400 px.

---

## oi. Phone layout (below 768 px)

16 px gutters, 20 px top padding. Needs attention rows: mark and subject on the first line with
the actions on the right; the sentence on the second line (the pd6 phone rule). The strip is two
columns by two. The Activity card: alive rows become two lines (state and task; repository and
the alive line); the chart keeps fourteen columns (16 px wide, 2 px gap) with labels every third
day; the last-runs rows reflow as rd8. The three glance cards stack under it. The access key rows
reflow (od8). The checklist drops its right column and the listening line sits under the card
(`brief.md` h1). Tooltips open on tap; the chart slot's tap opens the tooltip on the first tap
and follows the link on the second (`aria-expanded` on the slot), so a phone reader can read the
numbers without leaving.

---

## oj. Performance guidance for the builders

Budget: the first paint of `/workspace` is one query (`count_alive/1`) plus what the shell
already reads; every region is `assign_async` and lands within 200 ms on a workspace of
100,000 runs; at most **nine** queries in total, every one bounded by a `LIMIT` or an
index range, none over `events`.

1. **First paint is the shell.** Mount reads `Runs.count_alive/1`, `AccessKeys.list_access_keys/1`
   (already needed for the checklist and the sidebar count) and `Policy.mode_summary/1` (one
   query, already read for the sidebar), and renders the skeletons. Everything else is
   `assign_async` in four tasks: attention, activity, policy, keys-and-retention.
2. **Two subscriptions.** `Runs.subscribe/1` (`{:run_changed, run}`) and `Policy.subscribe/1`. A
   run change re-reads the alive rows, the last runs, the strip and today's column of the chart
   (one grouped query with `started_at >= today`), coalesced to one re-read per 250 ms; it never
   re-reads the 14-day history (only today can change) nor the attention list's denied
   destinations (those come from the policy topic and a 60 s timer). A policy change re-reads the
   Policy card and the `:enforce` / `:unmanaged` item. `:quiet` and `:behind` are recomputed on a
   5 s timer from the alive runs already in assigns, as the run page does; no query.
3. **The chart is one query.** `SELECT date_trunc('day', started_at), count(*), sum(denied_count)
   FROM runs WHERE workspace_id = $1 AND started_at >= $2 GROUP BY 1`, on the index
   `(workspace_id, started_at desc)` that `brief-runs.md` rj 8 asked for. Days are filled
   in Elixir. The strip's Runs and Denied cells are the same query's sums; Cost is
   `sum(cost_usd)` and `count(cost_usd)` on the same rows once ol 1 lands.
4. **Attention is bounded reads.** Denied destinations: `Runs.page_destinations/3` with
   `decision=denied`, `since=7d`, page 1 (50 rows, already capped), held to the effective policy
   in Elixir with `Policy.Effective` for the destinations' repositories (at most 5 destinations
   are shown, so at most 5 repositories are resolved). Lost: `runs WHERE state = 'lost' AND
   lost_at >= now() - 7d ORDER BY lost_at DESC LIMIT 6` (six, to know there are more). Behind:
   `Policy.digests/2` for the alive runs already read (at most 6). Idle keys: from the keys already
   read. `:enforce`'s count is `Policy.uncovered/2`, which shares the activity read's cap and
   answers `:unavailable` honestly.
5. **Access keys is three queries.** The keys (already read), the last run per key:
   `SELECT DISTINCT ON (access_key_id) … FROM runs WHERE workspace_id = $1 AND access_key_id = ANY($2)
   ORDER BY access_key_id, started_at DESC` for the at most six keys shown, and the hosts per
   key (`count(distinct host)` grouped by `access_key_id` over the last seven days); add the
   index `(workspace_id, access_key_id, started_at desc)`.
6. **Suggestions are counted, not listed.** The Policy card's "To review" reads
   `Policy.suggestions/3` for at most five repositories, those with a run in the last 14 days by
   most recent run; a count function that reads them in one query (`Policy.suggestion_counts/1`,
   ol 2) replaces the loop when it exists. The card renders "…" until it lands and is never
   blocking.
7. **Retention is one row.** `Retention.list_retention_runs(scope, 1)`.
8. **Stable ids.** Attention `att-*` as od1; alive rows `alive-#{run_id}`; last runs
   `run-#{run_id}` (the runs list's own, so a row can be updated by the same broadcast); chart
   slots `day-#{iso date}`; machines `key-#{id}`. Never an index. A `{:run_changed, run}` for a
   run on the page updates that row in place; a run not on the page bumps "1 new run" (rj 6).
9. **Clocks tick in the browser.** Every relative time and alive line is a `<time>` under the
   `Ticker` hook (rd3); the server sends instants. The 5 s quiet timer is the only server timer
   besides the 60 s attention refresh, and both pause while the socket is disconnected.

---

## ok. Done checklist

The page
- [ ] `/workspace` at `width="full"`; `<title>` is the workspace name; the description
  says "The workspace of the Acme organisation." with no term hover
- [ ] Needs attention renders only actionable items, in the order of od1, at most five, "and n more" linking to the right page; absent when empty
- [ ] Denied rows are the suggestion rows of pd6 with pd8's popover; the locked case reads the padlock sentence; one-click allow leaves the row struck until the next navigation
- [ ] Quiet and lost from the record's timestamps; Close uses the existing confirm; behind only while alive and after two intervals; enforce and unmanaged from `mode_summary/1`; idle keys at 30 days
- [ ] The strip: alive, runs, denied attempts, cost (absent until the fold exists; "n/a" when no run reported one)
- [ ] Alive rows with `<.run_state>`, repository, host and `<.alive>`; "No run alive now." when none
- [ ] The chart: two small multiples, fourteen columns each, today in ink, denials in error, stubs for zero, one tooltip for both plots, slots as links, the table twin, the `aria-label` with totals and peak
- [ ] Last runs: five rows of `<.runs_table>` with the Repository column, at full width; "All runs"
- [ ] Runs are counted in the three families (alive, ended well, ended badly) in the strip, the chart's tooltip and table; the state is "succeeded", never "exited"
- [ ] Policy card: mode with its source and the repositories that differ, the version
  pill, the repository counts, "to review"; the new-workspace wording
- [ ] Access keys: five active keys at full width, last seen, runner with the contract version, the hosts of the last 7 days, last run; "Create another access key" once a run has landed
- [ ] Retention: the setting and the last prune in the settings page's words

The empty workspace
- [ ] Step 1 ticks on a key, step 2 on `last_used_at`, step 3 on the first run; the card leaves on the next navigation after the first run, and the Access keys card takes the link
- [ ] No chart, policy or retention card while the checklist shows

Live and quiet
- [ ] Two subscriptions, reads coalesced at 250 ms; rows update in place by id; new rows append; nothing above the reader moves; "1 new run" when a run is not on the page
- [ ] Ticking text under `Ticker`; the polite region says at most one sentence per 10 s

Quality
- [ ] Both themes, at 1440, 1024, 768, 375; no page-level horizontal scroll at 320; skeletons in every region on a slow connection
- [ ] Keyboard-only pass: allow a host, close a run, read the chart by slots, toggle the table, revoke a key
- [ ] VoiceOver pass: the attention list reads as a list of acts; the chart reads its totals and peak; the tables reflow with their roles
- [ ] `prefers-reduced-motion`: no ripple; the chart and rows change without motion
- [ ] Synthetic sample data only; no customer, engagement or person named; no AI attribution; British spelling

---

## ol. Open questions for the coordinator

1. **Cost on the run row.** The strip's "Cost reported" needs `runs.cost_usd` folded by the
   projector from `session.result` (`cost_usd`, already parsed in `Runs.Record`'s slim read).
   Until the fold exists the cell is absent. Whether to sum only `success` results or every
   `session.result` that carries a cost is BACKEND's; the design says "reported", so every one.
2. **A count of suggestions across repositories.** `Policy.suggestions/3` is per repository. The
   card wants `%{repositories: n, hosts: n}` over the workspace in one bounded read
   (`Policy.suggestion_counts/1`); the loop over five repositories is the fallback.
3. **`/workspace/policy?confirm=enforce`.** The `:enforce` item's button should land on
   the policy page with the enforce confirm open (one click, as asked). That is a new
   query parameter on M5's page, owned by another builder; without it the button goes to
   `/workspace/policy` and the reader clicks Enforce there (two clicks).
4. **Thresholds.** Idle key at 30 days, lost within 7 days, behind after two heartbeat intervals,
   denied over 7 days, the chart over 14. All four are the design's choices, not the record's;
   confirm or change them in one place (`Overview.thresholds/0`).
5. **The denied rows and the effective policy.** A destination denied yesterday may be allowed
   since; the row should not offer to allow what is already allowed. The design filters the denied
   destinations through `Policy.Effective` of each destination's repositories in Elixir (at most
   five resolutions per page). If BACKEND would rather have a `Runs.page_destinations/3` option
   `uncovered: true`, the page uses it.
6. **"Last seen" of a key** is `last_used_at`, which `AccessKeys.touch/2` sets on every verified
   request. Confirm that a heartbeat touches it as well as a batch; if only batches do, step 2 of
   the checklist must read `last_heartbeat_at` too (`Runs.last_heartbeats_by_key/1` exists for
   that).
7. **A day boundary.** The chart counts UTC days and says so in its foot. If the
   workspace's people would rather read local days, the boundary is the browser's and the
   count must be made in the browser from per-hour buckets (24 × 14 rows), which is still
   one query; the design does not do this in M8.
