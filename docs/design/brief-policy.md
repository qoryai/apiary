# Qory console: design brief for the security policy (M5)

Implementation spec for milestone M5: the hive's policy page, a repository's effective policy,
versions, history and export, allow and deny from a connection row, and the policy version and
drift mark of the run header. It extends `brief.md` and `brief-runs.md`; everything there (tokens,
shell, components, tone, accessibility) still holds and is not repeated. The rendered reference is
`policy-mock.html` beside this file; where the two disagree, this brief wins. Section letters
continue the pattern with a `p` prefix.

Naming. The brand is **Qory**. Sample data is synthetic only: Acme, Platform, `acme/shop`,
`acme/tax-service`, `acme/docs`, `github.example`, `gitlab.example`, `api.example`,
`registry.example`, `files.cdn.example`, `mcp.acme.example`, `*.paste.example`,
`beekeeper@example.com` (owner), `dana@example.com` (member), `build-01`.

The model is fixed by the build brief and is not re-argued here: **the policy document can only
allow**; the **mode is the hive's**; **deny** and **lock** are the control plane's notions that
decide what the document lists; every write renders versions that are kept for ever. The UI calls
`Apiary.Policy` and nothing else.

Out of scope, not designed here: defining a credential's value (a machine's business), editing the
machine's runner file, per-repository mode, scheduled or expiring rules, approval flows, policy
templates.

---

## pa. Principles for editing a policy

The principles of `brief.md` and `brief-runs.md` apply; these six are added.

1. **The page says only what the document can say.** Every control maps to a field of
   `policy.schema.json` (`egress.mode`, `egress.allow`, `egress.paths`, `credentials`) or to one of
   the two notions the control plane owns (deny, lock). Nothing else is offered: no ports, no
   schemes, no methods, no "block list". When a rule cannot be said, the page refuses it in a
   sentence that names the reason and the two ways out (pf4).
2. **A rule is read back before it is saved.** The composer validates in the contract's grammar as
   you type and answers with the rule in plain words: "allow every host below `internal.example`,
   on every path. It does not allow `internal.example` itself." The button is off until the
   sentence is there. People misread `*.`; the sentence is where they find out.
3. **One list, and every entry says where it came from.** A repository's policy is never two
   tables to be merged in the head. It is the effective list, one row per host in force, with a
   source chip (Hive, This repository, Hive, locked). A rule that lost is not hidden and not a row
   of its own: it hangs under the rule that beat it, struck through, with who and why.
4. **Allow and deny look the same everywhere.** A rule row uses the decision mark of
   `brief-runs.md` rd12: soft green check for allow, solid red barred circle for deny. The policy
   page, the connection row, the confirm and the suggestion list share one vocabulary, so a denial
   in a run and the rule that would lift it are recognisably the same kind of thing.
5. **The record does not change; what happens next does.** Allowing a host from a denied row never
   recolours the row: it was denied, and it stays denied. The row gains a second line that says a
   rule was added, in which version, and whether this run has it yet.
6. **Every consequence has a clock on it.** A change reaches running sessions "within a heartbeat,
   about 30 s" (the interval from the record, never a guess). A confirm states that, a toast states
   the new version, and the run header says when a run is still behind.

---

## pb. Information architecture and URLs

### Sidebar

One item is added to the "Hive" section, after Connections, because the policy is what the
connections are judged by:

```
Hive
[#] Overview
[>] Runs            (o) 2
[⇄] Connections
[✓] Policy          enforce    <- the mode in force, mono 11.5 faint
Manage
…
```

Icon `hero-shield-check-micro`. The trailing word is the hive's mode (`Policy.get_mode/1`), updated
over PubSub `policy:<hive>`; its `title` is "The hive is in enforce mode". It is a word, not a
colour: observe is not a fault. `Layouts.app` gains `nav={:policy}`; every page below sets it,
including the repository pages. `counts` gains `:mode`.

### Routes

All inside `live_session :hive`, all `width="full"` (1200).

| Page | Path | LiveView, action |
|---|---|---|
| Hive policy, rules (default tab) | `/hive/policy` | `PolicyLive.Show, :rules` |
| Repositories | `/hive/policy/repositories` | `PolicyLive.Show, :repositories` |
| Hive history | `/hive/policy/history` | `PolicyLive.Show, :history` |
| Hive version (Document tab opens the current one) | `/hive/policy/versions/:n` | `PolicyLive.Show, :version` |
| Hive export (modal over the version) | `/hive/policy/versions/:n/export` | `PolicyLive.Show, :export` |
| Repository, effective policy | `/hive/policy/repositories/:repository_id` | `PolicyLive.Repository, :rules` |
| Repository history | `/hive/policy/repositories/:repository_id/history` | `…, :history` |
| Repository version | `/hive/policy/repositories/:repository_id/versions/:n` | `…, :version` |
| Repository export | `/hive/policy/repositories/:repository_id/versions/:n/export` | `…, :export` |

`/hive/policy/document` and `/hive/policy/repositories/:id/document` redirect to the current
version, so "Document" is a stable link and a version URL is a permanent one. `:repository_id` is
the repository row's id (a forge and path contain slashes). A repository of another hive renders
the not-found state, never another hive's rules.

**Why not `/hive/repositories/:id/policy`.** There is no repositories page in the console: a
repository is a label on runs, and `/hive/repositories` would be a parent that does not exist. The
policy is one object with two scopes, the baseline and a repository's view of it, so both live
under `/hive/policy`, keep `nav={:policy}` lit, and share the breadcrumb `Policy › Repositories ›
github.example/acme/shop`. If a repositories section appears later, it links here.

Query parameters, all written with `push_patch`:

| Page | Param | Values |
|---|---|---|
| Rules, effective policy | `show` | `allow`, `deny`, `locked` (hive); `hive`, `repository`, `overrides` (repository). Default all |
| Rules, effective policy | `rule` | a host: scrolls to and highlights that rule (the target of "Show it", "Rule", "Open") |
| History | `change` | a change id: opens that change's diff. `who`, `kind`, `host`, `page` filter and page |
| Version | `compare` | a version number; default the one before. `view` = `changes`, `document`, `served` |

### How one gets to a repository's policy

1. **From a run**: the breadcrumb's repository item keeps linking to the filtered runs list; the
   header's **Policy** cell links to the exact version the run reported (pe6), whose breadcrumb
   leads up to the repository's policy.
2. **From connections**: the "Rule" button left in a row's slot after an allow or deny (pd8), and
   on `/hive/connections?repo=…` the description's second sentence gains a link: "Showing
   `github.example/acme/shop` only. Its policy".
3. **From the runs list**: the repository group header's facts gain a last item, the link
   "Policy", `text-xs text-muted`, shown on hover and focus of the header and always on touch.
4. **From the policy page**: the Repositories tab lists every repository that has posted a run.
5. **Back again**: the repository policy's tab row ends with two plain links, "Runs 5" and
   "Connections", to `/hive/runs?repo=…` and `/hive/connections?repo=…`.

---

## pc. Tokens added

One token, declared beside `--q-denied-tint` in `app.css` for both themes and the no-script dark
block, and exposed through `@theme inline` as `--color-added: var(--q-added-tint)`.

| Token | Use | Both themes |
|---|---|---|
| `--q-added-tint` | an added diff line; the row of a rule new in the version in force | `color-mix(in oklab, var(--q-success-soft) 55%, var(--color-base-100))` |

Removed diff lines take the existing `--q-denied-tint`. Nothing else is new: the mode cards, source
chips and version pill are built from the existing surfaces and borders; the drift mark is the
warning badge pair (`primary-soft` / `primary-soft-content`), as amber is everywhere.

---

## pd. Components

In `lib/apiary_web/components/policy_components.ex` unless a file is named. Every component that
renders inside a stream takes its `id` from the caller.

### pd1. Version pill (`<.version_pill>`)

The version and digest, wherever a policy is named: page heads, history rows, the diff bar.

```elixir
attr :version, :integer, default: nil        # nil renders "No version yet"
attr :digest, :string, default: nil          # "sha256=…"; shows the first 12 hex characters
attr :navigate, :string, default: nil        # the version page
attr :copy, :boolean, default: false         # adds the icon-only copy button (copies the full digest)
attr :size, :string, default: "md", values: ~w(sm md)
```

`inline-flex h-7 rounded-field border border-line-strong bg-base-100 shadow-xs font-mono text-xs
overflow-hidden`, cells divided by hairlines: `v14` in 600 (a link when `navigate`), `sha256` in
faint then the 12 characters in muted, then a 28 px copy button with the tooltip "Copy the digest".
`sm`: `h-[22px] text-[11.5px]`, no shadow, no copy. The full digest is the `title`. Inside running
text (timeline head, summary line, run header) a version is not a pill but a **version link**: mono
600, underlined in `line-field`, `v9`.

### pd2. Mode switch (`<.mode_switch>`)

```elixir
attr :mode, :string, required: true, values: ~w(observe enforce)
attr :can_edit, :boolean, default: true
attr :fact, :map, default: nil               # %{denied: 12, destinations: 3, days: 7} or %{uncovered: …}
```

A `role="radiogroup"` of two cards side by side (stacked on phones). Card: `rounded-box border
p-[14px_16px] grid grid-cols-[16px_1fr] gap-x-2.5`; unselected `bg-base-200 border-line
text-muted`, hover `border-line-field`; selected `bg-base-100 border-line-field shadow-xs` with the
radio dot in honey (the checked state is one of honey's three uses) and a neutral badge "In force".
Head: 16 px icon in faint (`hero-eye-micro`, `hero-shield-exclamation-micro`) and the name in 14
semibold. One sentence under it (pf1). The selected card ends with a fact line above a hairline,
from recorded connections (pf1). Choosing the other card never switches at once: it opens the
confirm (pe1). Arrow keys move between the cards, Space or Enter asks.

### pd3. Rule composer (`<.rule_composer>`)

```elixir
attr :id, :string, required: true
attr :form, :any, required: true             # action, host, paths
attr :scope, :atom, required: true, values: [:hive, :repository]
attr :reading, :map, default: nil            # %{kind: :hint | :ok | :error | :note | :refusal, text: …, fix: …}
```

A row on `bg-base-200` between the card's header and its table, never a modal: `grid
grid-cols-[auto_1.2fr_1fr_auto] gap-2 px-4 py-2.5`. Parts: a two-item segmented control **Allow |
Deny** (the pressed Deny takes `text-error-soft-content`); a mono **host** input (placeholder
`api.example or *.internal.example`); a mono **paths** input (placeholder "Every path, or /v1/*
/health", space-separated, disabled for deny: a deny is of the whole host); the primary button
**Add rule** ("Add for this repository" on a repository page). `autocapitalize="off"
spellcheck="false" autocomplete="off"`. Pasting a list of hosts, one per line, fills the composer
with the first and queues the rest ("3 more to add"), so a list is added line by line with each
read back.

Under the fields, spanning the row, the **reading line** (`role="status"`, 12.5 / 18, a 14 px icon):

| Kind | Icon, colour | When |
|---|---|---|
| hint | info, faint | empty fields |
| ok | check, `success`; the sentence in muted with the rule in `base-content` 500 | the rule is in the grammar and can be said |
| note | info, faint | it can be saved and changes nothing today (already covered by a suffix) |
| error | warning triangle, `error` | not in the grammar, or already there. The field takes `aria-invalid` |
| refusal | an error `<.notice>` in place of the line | the document cannot say it, or a locked rule forbids it |

Validation runs on every change with `phx-debounce="150"` (not on blur: the reading line is the
point), by the same patterns as the contract: host
`^(\*\.)?([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$`, path
`^/[^*?#\s]*\*?$`, credential name `^[a-z0-9][a-z0-9_.-]{0,63}$`, argument 1 to 256 characters.
The errors are specific (pf3), and when the input is a URL the line offers the repair as a link:
"Use api.example with the path /v1/messages". The button is disabled unless the kind is ok or note.
Enter submits. After a save the fields clear, focus returns to the host field, the new row is
highlighted with `bg-added` until the next navigation, and the toast names the version.

The credential composer is the same row with two fields, **Name** and **Argument (optional)**, and
a default (not primary) button "Add credential"; a page has one primary.

### pd4. Rule row (`<.rule_row>`) and rules table (`<.rules_table>`)

```elixir
# <.rules_table>
attr :id, :string, required: true
attr :rows, :list, required: true            # effective entries or hive rules
attr :scope, :atom, required: true, values: [:hive, :repository]
attr :can_lock, :boolean, default: false     # owners
# <.rule_row>
attr :id, :string, required: true            # "rule-#{id}"
attr :rule, :map, required: true             # action, host, paths, locked, source, created_by, inserted_at,
                                             # origin (:page | :connection | :suggestion), seen, beaten (the rule it holds against)
attr :scope, :atom, required: true
attr :can_lock, :boolean, default: false
attr :fresh, :boolean, default: false        # new in the version in force
```

Built on `<.table>`'s classes, 40 px rows. Columns on the hive page: **Rule · Paths · Last 7 days ·
Added · (lock and actions)**. On a repository page: **Rule · Paths · Comes from · Last 7 days ·
(actions)**.

- **Rule**: `<.decision_mark>` (allow: soft green check; deny: solid red barred circle; `sr-only`
  word "Allow" / "Deny") and the host in `font-mono text-[12.5px] font-medium`. A leading `*.` is
  drawn in `accent` 600 and the host carries the tooltip "Every host below github.example, and not
  github.example itself."
- **Paths**: "every path" in faint, or the paths as `<.mono>` chips that wrap; an empty list reads
  "no path" with the tooltip "The host is listed with no path: every request to it is denied under
  enforce."
- **Last 7 days** (right-aligned, 13 px, `tabular-nums`): what recorded connections say about the
  rule: "412 allowed", "3 denied" in error tone, "412 allowed · 1 denied", or "not seen" in faint.
  It is how a rule nobody needs is found. Load it async; if the query is not available the column
  is dropped, never filled with a placeholder.
- **Added**: the local part of the author's email and the date in faint, "dana · 16 Sep", plus
  ", from a connection" or ", from a suggestion" when that is the rule's origin.
- **Comes from** (repository page), a `<.source_chip>` (pd5).
- **Lock** (hive page). Owners: a 24 px toggle button, `aria-pressed`; unlocked it is a faint open
  padlock with the tooltip "Lock: hold this rule against every repository"; locked it is a bordered
  chip, closed padlock and the word **Locked**, tooltip "Locked: no repository can override it.
  Select to unlock." Members: a static closed padlock and the word "Locked", focusable, tooltip
  "Locked by beekeeper@example.com on 2 Sep 2026. Only an owner can change or unlock it."; an
  unlocked rule shows nothing in this place.
- **Actions**. Hive page: a `⋯` menu (Edit paths, Lock / Unlock for owners, a divider, Remove in
  error tone). A member sees no menu on a locked rule. Repository page: one ghost `btn-xs` whose
  word is the act: a hive rule reads **Disable here** (allow) or **Allow here** (deny); the
  repository's own rule reads **Remove**, or **Restore** when it exists only to disable a hive rule;
  a locked hive rule reads the link **Open** (to `/hive/policy?rule=…`).
- **Order**: locked rules first, then deny, then allow; inside each, by the host's labels read
  from the right, so `*.github.example` sits beside `github.example`. The card's footer says so.
- **Fresh**: `bg-added` on every cell and an info-toned chip "New in v10" after the host.
- **Beaten rule** (repository page only): a second `<tr>` under the winner with no top border,
  holding one line indented to the host, with a 2 px `line-strong` rule on its left: the lead in
  `base-content` 500, the beaten rule struck through in mono, then who and when, then the one act.
  - Override: "**Overrides the hive's rule** ~~allow gitlab.example~~ Disabled here by dana · 9 Sep.
    Other repositories keep it."
  - Lock: a padlock, "**Holds against this repository's rule** ~~allow bin.paste.example~~
    dana · 28 Aug. It is not in force. `Remove it`"
  The struck rule is announced as "not in force: allow bin.paste.example" (`<s>` alone is
  silent to a screen reader; add an `sr-only` prefix).

### pd5. Source chip (`<.source_chip>`)

```elixir
attr :source, :atom, required: true, values: [:hive, :repository, :hive_locked]
```

`h-5 px-[7px] rounded-selector border text-[11.5px] font-medium`, a 12 px glyph and words: **Hive**
(`bg-base-200 border-line text-muted`, a hexagon), **This repository** (`bg-base-100
border-line-field text-base-content`, `hero-book-open-micro`), **Hive, locked** (as Hive with
`text-base-content` and `hero-lock-closed-micro`). Three shapes, three wordings, no status hue: where
a rule comes from is not good or bad.

### pd6. Suggestions (`<.suggestions>`)

```elixir
attr :id, :string, required: true
attr :suggestions, :list, required: true     # [%{host, runtime, runs, denied, last_denied_at, blocked_by}]
attr :covered, :list, default: []            # [%{host, by: :hive | :repository}]
attr :runs, :integer, required: true         # how many runs the declaration was read from
```

A section card above the effective policy, shown only when there is something to review. Header
**Declared by the harness**, the count "2 to review", on the right a default `btn-xs` **Allow both
here** ("Allow all 4 here"; absent for one), and one sentence (pf5). One 44 px row per host: a
**dashed** red mark (not allowed yet: outline, not solid, because nothing was decided), the host,
a sentence of what the record says, and the actions: a split `btn-xs` **Allow here** with a caret
menu (Allow for the hive, Allow with paths…) and a ghost **Dismiss**. One click allows: the mark
turns to the soft green check in place, the actions become "✓ Allowed here" and an **Undo** link,
and the row leaves at the next navigation. A host a locked deny covers has no button and reads "A
locked hive rule denies `*.paste.example`. Only an owner can change it." The footer lists what
is already covered. Dismissed hosts are kept per repository and return if the harness's list
changes.

### pd7. History (`<.change_list>`, `<.change_row>`, `<.policy_diff>`)

```elixir
# <.change_row>
attr :id, :string, required: true            # "chg-#{id}"
attr :change, :map, required: true           # action, who, at, origin, version, digest, scope
attr :open, :boolean, default: false
attr :patch, :string, required: true         # the URL with ?change=
# <.policy_diff>
attr :diff, :map, required: true             # %{rules: [...], document: [...], from: v, to: v, rerendered: n}
```

One card, grouped by day (a `bg-base-200` day bar: Today, Yesterday, then "16 Sep 2026"), newest
first, 20 per page. A row is a native `<details>` whose `<summary>` is a 44 px grid: chevron, the
author's avatar, the sentence (pf6) with an optional faint second line for the origin ("From a
connection row of run `0191d2aa`"), the time, and the `<.version_pill size="sm">` the change
made, or the words "no new version" in faint when the bytes did not change. Open, it shows the
diff: a bar (`v12 → v13`, "1 line changed · re-rendered 2 repositories with rules of their own",
and the link "Open v13"), then two panels side by side (stacked on phones):

- **rules**: the change in the page's own words, one line each, `+` on `bg-added`, `−` on
  `bg-denied`, and one muted context line for what did not change.
- **document**: a line diff of the rendered JSON, indented for reading, keys in `accent`, the same
  gutters. Unchanged arrays fold to their first two items and "… 5 more".

Every `+` and `−` is a character in a gutter with an `sr-only` "Added:" / "Removed:"; colour is the
third carrier, not the first. On a repository's history, a change made on the hive that re-rendered
this repository appears with a small neutral chip **hive** after the time.

### pd8. Connection row actions (`<.rule_action>` and `<.rule_popover>`, in `run_components.ex`)

Fills the trailing slot that `brief-runs.md` rd12 reserved. The slot's width becomes `auto` (a
`btn-xs` with a word); the rest of the row is unchanged.

```elixir
# <.rule_action>  (inside <.connection_row>'s :trailing slot)
attr :id, :string, required: true
attr :connection, :map, required: true
attr :standing, :atom, required: true
  # :can_allow | :can_deny | :locked_deny | :locked_allow | :wall | :rule_added
attr :rule_path, :string, default: nil       # the link of "Rule"
# <.rule_popover>
attr :id, :string, required: true
attr :connection, :map, required: true
attr :action, :atom, required: true, values: [:allow, :deny]
attr :repositories, :list, required: true    # the run's one, or those whose runs reached the destination
attr :host_paths, :list, default: nil        # the path rules in force for the host, when it has any
attr :refusal, :map, default: nil            # %{rule, locked_by, locked_at, owner?}
attr :alive, :boolean, default: false        # a run that can still benefit
attr :interval, :integer, default: 30
```

What the slot holds:

| The row | Slot |
|---|---|
| denied, or let through by observe with no rule | default `btn-xs` **Allow** |
| allowed by a rule | ghost `btn-xs` **Deny** |
| a locked hive rule decides it | ghost icon button, closed padlock, tooltip "A locked hive rule denies `*.paste.example`" (or "allows") |
| the wall refused it (`wall:own-address`, `wall:ambiguous-path`) | nothing, with `sr-only` "No rule changes this" |
| a rule was added from this row | ghost `btn-xs` link **Rule** to the rule on its policy page |

The buttons are always visible: an action that appears on hover is an action a keyboard and a
phone never find. The button opens a **popover** anchored under it, right-aligned (348 px,
`shadow-pop`, top layer: a `<dialog>` opened with `show()` or the `popover` attribute, so the
table's scroll container cannot clip it); below 768 px it is a bottom sheet with 40 px buttons.
Contents, top to bottom:

1. Title: the mark and "Allow `files.cdn.example`" / "Deny `registry.example`"; with path rules,
   "Allow on `api.example`".
2. **What**, only when the host has path rules: a legend that shows them, then two radios. "This
   path" (checked), with a mono input holding the request's path exactly, and the hint "Added to
   the paths in force for the host. End it with * to allow everything below." "Every path of the
   host": "Drops the path rules of this host, for the scope chosen below." The input validates as
   pd3 does.
3. **For**: two radios. On a run page: "This repository `github.example/acme/shop`" (checked: the
   narrowest scope is the default) and "The whole hive: every repository of Platform". On the hive
   connections page with several repositories: "One repository" with a select of the repositories
   whose runs reached the destination, each with its count, and "The whole hive"; nothing is
   checked, and the primary is disabled until one is: the page does not guess a scope. With the
   `repo` filter set, that repository is checked. A deny adds the consequence under each radio:
   "Disables the hive's allow rule here. Other repositories keep it." / "Replaces the hive's allow
   rule. 6 runs of 2 repositories reached this host in the last 7 days."
4. **What happens next**, a reload icon and one sentence (pf7).
5. Footer: Cancel, then the act named in full: **Allow for this repository**, **Allow for the
   hive**, **Deny for this repository** (danger), **Deny for the hive** (danger).

**Refusal.** When a locked rule decides the host the popover has no form: title
"`bin.paste.example` stays denied", a warning notice with the sentence of pf4, and the footer
**Close** and **Show the locked rule**. It is the same for owner and member, except the last
sentence; an owner changes a lock on the policy page, never from a row.

**After.** The popover closes, focus returns to the slot's button (now **Rule**), a toast names the
change and the version with **Undo** (5 s; undo is `remove_rule/2`). The row keeps its mark, its
counts, its reason and its tint. The reason cell gains an **after line** (12.5 px, muted) with a
badge that moves through three states as the record allows:

| Badge | Sentence |
|---|---|
| info **Rule added** | Allowed for this repository in `v10` by you, 2 minutes ago. The run has not reloaded yet. |
| success **In force in this run** | Allowed for this repository in `v10`. The run reloaded at `#0046`. |
| neutral **Rule added** | Allowed for this repository in `v10`. This run has ended; the next run of the repository has it. |

"In force in this run" is claimed only when the run has reported the new digest (F2), never after a
timer. On the hive connections page the line reads "Allowed for the hive in `v15` by you, just now."
with no run state. In the timeline's inline variant there is no after line: the second "Policy
applied" item (pe6) and the later allowed connection tell it.

### pd9. Policy cell and drift mark (`<.policy_value>`, extended, and `<.drift>`)

```elixir
# <.policy_value> gains
attr :version, :map, default: nil            # %{n, scope: :hive | :repository, path} from configuration_for_digest/3
attr :in_force, :map, default: nil           # %{n, digest, since} when it differs and the run is alive
# <.drift>
attr :reported, :map, required: true
attr :in_force, :map, required: true
attr :last_seq, :integer, required: true
attr :interval, :integer, default: 30
```

The cell reads the mode, then the **version link** `v9` (to that exact version), then the first
twelve characters of the digest in mono faint. When the run is alive and its last reported digest
is not the one in force for its repository, the digest gives way to the **drift mark**: a warning
badge, `hero-exclamation-triangle-micro` 11 px and "Behind v10", with the tooltip "The run last
reported v9 at #0041. v10 has been in force for 47 s. A run reloads at its next heartbeat." Under
the strip a warning `<.notice>` says the same in full with the link "What changed between v9 and
v10" (the version page with `?compare=9`). The notice is a fact about the record: not a toast, not
dismissible, gone when the run reports the new digest. An **ended** run is never "behind": it ran
under what it ran under, and shows the version and digest only. Other values:

| Record | Cell |
|---|---|
| digest matches a version of the repository | `enforce v9 9f86d081884c` |
| digest matches a hive baseline version | `enforce v14` and the sub value "hive baseline" |
| digest matches no version here | `observe 4b227777d4dd · not rendered here`, tooltip "The run reported a digest that matches no version rendered here: a policy file on the machine, or a run started with --local." No link |
| `source: none` | `observe` and "no policy", as today |

The same version link replaces the bare digest in the run connections tab's summary ("policy
**enforce** `v9` Behind v10") and on the Details tab's "Policy in force" card, which gains the rows
**Version** (the link) and **In force now** (the version link, or "the same").

---

## pe. Page compositions

Copy is final. `{…}` is data. ~word~ carries the term hover.

### pe1. Hive policy, rules (`/hive/policy`)

```
Policy                                              [v14 | sha256 e3b0c44298fc | ⧉]  [↥ Export]
What the runs of this ~hive~ may reach through the runner's proxy. The policy can only
allow: what no rule names is denied under enforce, and let through and recorded under observe.

[ Rules 9 ]  Repositories 4   History 16   Document
+------------------------------------------+ +------------------------------------------+
| ( ) Observe                              | | (•) Enforce  [In force]                  |
|     Records every connection and denies  | |     Denies a connection no rule allows,  |
|     none. …                              | |     …                                    |
|                                          | |     ------------------------------------ |
|                                          | |     In the last 7 days it denied 12      |
|                                          | |     attempts to 3 destinations. See them |
+------------------------------------------+ +------------------------------------------+
The mode is the hive's: every repository runs under it. …

+ Host rules 8 ------------------------------------------ [All | Allow 6 | Deny 2 | Locked 2] +
| [Allow|Deny] [ api.example or *.internal.example ] [ Every path, or /v1/* /health ] [Add rule]|
| (i) A host name in lower case, or *. and a suffix …                                         |
|----------------------------------------------------------------------------------------------|
| Rule                     Paths        Last 7 days          Added                             |
| [⊘] *.paste.example   every path   3 denied             beekeeper · 2 Sep    [🔒 Locked] ⋯|
| [✓] github.example       every path   58 allowed           beekeeper · 2 Sep    [🔒 Locked] ⋯|
| [⊘] telemetry.example    every path   not seen             dana · 16 Sep, from a connection ⋯|
| [✓] api.example          [/v1/*]      412 allowed·1 denied beekeeper · 2 Sep              🔓 ⋯|
| …                                                                                            |
| Locked rules come first, then deny, then allow, …                                            |
+----------------------------------------------------------------------------------------------+
+ Credentials 1 ------------------------------------------------------------------------------+
| Credentials a run may use, by name. The policy names one; it never holds one. …             |
| [ Name, such as forge-token ] [ Argument (optional), such as acme/shop ] [Add credential]   |
| Name        Argument      Last 7 days     Added                                             |
| model-key   no argument   412 requests    beekeeper · 2 Sep                               ⋯ |
+----------------------------------------------------------------------------------------------+
```

`<title>`: "Policy · Qory". Header actions: the version pill (links to History; copy button) and a
default button **Export**. There is no primary in the header: the page's primary is the composer's
**Add rule**. The tabs are `<.tabs>` of `brief-runs.md` rd9 with counts: Rules (host rules plus
credentials), Repositories, History (changes), Document.

**Going to enforce** opens a `lg` modal, "Switch the hive to enforce": the consequence sentence
(pf1), then a bordered list headed "Let through in the last 7 days with no rule matching" and the
count on the right. One 38 px row per destination (at most 8, then "and 4 more on the connections
page"): a dashed red mark, host and port, "8 attempts · 3 runs", and a default `btn-xs` **Allow for
the hive**, which adds the rule there and then (the mark turns green, the button becomes "✓
Allowed", the count drops). A closing line says how the list was counted. Footer: Cancel (initial
focus), **Switch to enforce** (primary). When nothing would be denied the list is replaced by
"Every destination your runs reached in the last 7 days is covered by a rule." The list is built
from recorded connections that today's rules still do not cover; when that cannot be computed the
modal shows the consequence sentence alone, never an estimate.

**Going to observe** opens a `sm` modal with the danger button **Switch to observe**: it loosens
the hive, so it asks too. **Locking** a rule is immediate, with a toast, unless it would put
repository rules out of force; then a `sm` modal lists them (pf2).

Members see everything and can do everything except what concerns a lock; the page does not grey
itself out for them.

### pe2. Repositories (`/hive/policy/repositories`)

Summary line, then one table: **Repository** (forge faint, path 500, mono; the row link) · **Policy**
(`<.source_chip>`-style chip: "Own rules" or "Hive baseline") · Own rules · Overrides · Suggestions
(an info chip "2 to review", or 0 in faint) · Version (mono, `v10` and the short digest) · Last
change. Sorted: suggestions first, then the most recent change. Phones: rows reflow to the name,
the chip and the suggestion chip. Footnote in pf.

### pe3. Repository policy (`/hive/policy/repositories/:repository_id`)

```
Policy › Repositories › github.example/acme/shop
github.example/acme/shop                                  [v10 | sha256 c41d7e02b9a6 | ⧉] [↥ Export]
What runs of this repository may reach: the hive's rules, then this repository's own. Where the
two meet on a host, the repository wins, unless the hive's rule is locked.

[ Effective policy 10 ]  History 10   Document   Runs 5   Connections
+ Declared by the harness  2 to review ------------------------------------ [Allow both here] +
| Hosts the runtime says it needs, from the policy applied event of this repository's last 5  |
| runs. A declaration allows nothing by itself.                                               |
| [⦸] flags.example           Declared by claude in 5 runs. Denied 9 times, …  [Allow here|v] Dismiss |
| [⦸] downloads.runtime.example  Declared by claude in 5 runs. No run has tried…  [Allow here|v] Dismiss |
| 2 more declared hosts are already allowed: api.example by the hive, mcp.acme.example by …   |
+---------------------------------------------------------------------------------------------+
+ Effective policy  10 rules · 7 hosts allowed --- [All | From the hive 6 | This repository 4 | Overrides 2] +
| [Allow|Deny] [ mcp.acme.example ] [ Every path, or /v1/* /health ] [Add for this repository] |
| Rule                    Paths            Comes from          Last 7 days                     |
| [⊘] *.paste.example  every path       [🔒 Hive, locked]   3 denied               Open     |
|     | 🔒 Holds against this repository's rule  ~allow bin.paste.example~  dana · 28 Aug. …|
| [✓] github.example      every path       [🔒 Hive, locked]   41 allowed             Open     |
| [⊘] gitlab.example      every path       [This repository]   not seen               Restore  |
|     | Overrides the hive's rule  ~allow gitlab.example~  Disabled here by dana · 9 Sep. …    |
| [⊘] telemetry.example   every path       [Hive]              not seen               Allow here|
| [✓] mcp.acme.example    [/mcp/*][/health][This repository]   46 allowed             Remove   |
| [✓] files.cdn.example (New in v10)       [This repository]   3 denied before it     Remove   |
| [✓] registry.example    every path       [Hive]              65 allowed             Disable here|
| Mode enforce, from the hive. Credentials: model-key from the hive, forge-token …            |
+---------------------------------------------------------------------------------------------+
```

`<h1>` is the repository in mono, forge faint. The header's count is what is in force: "10 rules ·
7 hosts allowed" (the second number is the length of the rendered `allow`). "Overrides" filters to
the rows that have a beaten rule under them. A repository without rules of its own shows the same
page: every row comes from the hive, the pill reads the baseline's version with the sub value
"hive baseline", and an info notice sits above the list: "This repository has no rules of its own.
It is served the hive baseline, version 14. The first rule added here gives it versions of its
own." Credentials live in the footer sentence with the link "Edit credentials", which opens the
credential composer and rows in place of the footer; they are few and rarely touched.

### pe4. History (`…/history`)

Filters (`<.filter>` chips: Who, Kind, Host), the summary "16 changes · 14 versions · since 2 Sep
2026", the change list (pd7), a footer line and Newer / Older. `?change=` opens one change and
scrolls to it. The repository's history is the same page under the repository's breadcrumb and
tabs.

### pe5. Version and export (`…/versions/:n`)

```
Policy › github.example/acme/shop › Version 10
Version 10  [✓ In force]                                                          [↥ Export]
+-----------------+------------------+---------------------------+----------------------+--------------------------+
| Rendered        | Changed by       | Change                    | ~Digest~             | Runs under it            |
| Today, 14:02:54 | dana@example.com | Allowed files.cdn.example | sha256=c41d7e02b9a6… | 1 run · 1 alive is behind|
+-----------------+------------------+---------------------------+----------------------+--------------------------+
[Changes from v9 | Document | As served]              Compare with [v9 · 9f86d081884c ⌄]    + Versions 10 ---+
+ run-configuration.json · v9 → v10 · 1 line added ---------------- [Copy document] +        | v10 Allowed files… |
|    "allow": [                                                                     |        | v9  Hive switched… |
| +    "files.cdn.example",                                                         |        | v8  Allowed mcp.…  |
|  …                                                                                |        | 6 earlier versions |
+-----------------------------------------------------------------------------------+        +--------------------+
```

The state badge is success **In force**, or neutral **Superseded** with the sub line "by v11 after
2 d 4 h". The three views are a segmented control in the URL: the diff against the compared version
(default), the document indented, and **As served**: the exact bytes, unwrapped, in one scrolling
line, with the caption "388 bytes · sha256 over exactly these". "Copy document" copies the served
bytes in every view. The side list holds the last few versions with their change and author, the
current one on `primary-soft`; a version re-rendered by a hive change carries the chip **hive**.

**Export** (S7) is a `lg` modal at its own URL: one sentence that names the scope and the version,
a code block `acme-shop-policy.yaml` with **Download** and **Copy**, a second one-line block with
the command, and the caveats (pf8). The text is YAML in the runner's policy file format, with two
comment lines carrying the scope, version and digest. Deny rules and locks do not appear in it:
they are already applied. Footer: **Done**.

### pe6. Run header and timeline (F2, S4)

The header is `brief-runs.md` re2 with the Policy cell of pd9 and, while the run is behind, the
notice under the strip. In the timeline the first `run.policy_applied` stays **Policy applied** and
gains the version link before its offset. Every later one is **Policy applied again**, square node
with `hero-arrow-path-micro`: "reloaded · enforce · 7 hosts allowed", then one delta chip per host
added (`+ files.cdn.example`, success-soft) or removed (`− gitlab.example`, error-soft), at most
three and "and 2 more", the version link, the offset. Its body is one muted sentence: "The runner
fetched a new run configuration after the server's answer named a new digest. Compared with the
policy applied at `#0003`: 1 host added, none removed. Connections before this item were decided by
v9." The delta is computed from the `allow` lists of the two events, which are in the record; it is
not read from the policy tables. A reload that changed only the mode reads "reloaded · **observe**
(was enforce) · 7 hosts allowed". Announcement: "The run reloaded its policy: version 10."

### pe7. Empty, loading, error and refusal states

| Where | State | What renders |
|---|---|---|
| Hive rules | new hive | the mode switch with Observe in force and the fact "A new hive starts here. No run has reached out yet."; pill "No version yet"; `<.empty_state icon="hero-shield-check">` **No rules yet** "In observe mode with no rules, runs reach everything and every connection is recorded. Add the hosts your runs need here, or let a run reach out first and allow its hosts from the Connections page, one row at a time." `[Add a host rule]` primary (reveals and focuses the composer) `[Go to connections]` default; footnote on the first version (pf) |
| Hive rules | filter matches nothing | inside the card, a one-line row in faint: "No locked rules." / "No deny rules." |
| Credentials | none | one faint row: "No credentials. A run that needs none runs without." |
| Repositories | none has posted | neutral empty state **No repositories yet** "A repository appears here once a run names it with its forge and repository labels." |
| Repository | not in this hive | neutral empty state, `heading="h1"` **This repository is not in this hive** `[Back to policy]` |
| Repository | no own rules | the info notice of pe3 |
| Suggestions | harness declared nothing, or all covered | the card is absent |
| History | one version, no changes | "No changes yet. Version 1 was rendered on 2 Sep 2026 when a machine first asked." |
| Version | `:n` does not exist | neutral empty state **There is no version 31** "The latest is version 14." `[Open version 14]` |
| Any list | loading | skeleton rows in the shape of the columns; never a spinner |
| Any list | query failed | info `<.notice>` "The policy could not be loaded. Reload the page; if it keeps happening, the server log has the reason." |
| Any write | the render fails the schema | error `<.notice>` above the composer (pf4) |
| Any write | someone else wrote first | error `<.notice>` above the composer (pf4); the list is re-read |
| Any write | refused by grammar, document or lock | in the composer or the popover (pd3, pd8) |

---

## pf. Microcopy

### pf1. Headings, mode, and the confirms

| Where | Text |
|---|---|
| Page title, description | **Policy** / What the runs of this ~hive~ may reach through the runner's proxy. The policy can only allow: what no rule names is denied under enforce, and let through and recorded under observe. |
| Repository description | What runs of this repository may reach: the hive's rules, then this repository's own. Where the two meet on a host, the repository wins, unless the hive's rule is locked. |
| Observe | Records every connection and denies none. A host no rule names is let through, and the record says so. |
| Enforce | Denies a connection no rule allows, and records the denial. With no allow rule, a run reaches nothing. |
| Fact, enforce in force | In the last 7 days it denied **12** attempts to **3** destinations. `See them` (to `/hive/connections?decision=denied`) |
| Fact, observe in force | In the last 7 days **14** attempts to **2** destinations had no rule. Enforce would deny them. `See them` |
| Fact, nothing recorded | No run has reached out in the last 7 days. |
| Under the cards | The mode is the hive's: every repository runs under it. A wall's own refusals (the machine's address, a path that reads two ways) hold in either mode. |
| Confirm, to enforce | **Switch the hive to enforce** / From the next heartbeat, about 30 s, **a connection no rule allows is denied**, in every repository and in the 2 runs alive now. You can switch back at any time. / list head "Let through in the last 7 days with no rule matching" · "3 destinations" / "Counted from recorded connections that today's rules still do not cover. Enforce will deny these. A destination no run has reached yet is not in this list." / `[Cancel]` `[Switch to enforce]` |
| Confirm, to observe | **Switch the hive to observe** / From the next heartbeat, about 30 s, **nothing is denied**: every connection is let through and recorded, in every repository and in the 2 runs alive now. The rules stay as they are. Locked rules do not hold in observe mode either. / `[Cancel]` `[Switch to observe]` |
| Toasts | The hive is in enforce mode. Version 15. / The hive is in observe mode. Version 15. |

"in the 2 runs alive now" is left out at zero.

### pf2. Rules, locks, credentials

| Where | Text |
|---|---|
| Composer hint | A host name in lower case, or `*.` and a suffix for every host below it. No scheme, no port. Paths go in their own field, separated by spaces. |
| Reads as, host | Reads as: **allow `api.example`**, on every path. |
| Reads as, suffix | Reads as: **allow every host below `internal.example`**, on every path. It does not allow `internal.example` itself. |
| Reads as, paths | Reads as: **allow `api.example` on 2 paths**: everything below `/v1/`, and `/health` exactly. Behind a wall the proxy reads requests to this host to check the path. |
| Reads as, deny | Reads as: **deny `telemetry.example`**. It takes the host out of what the hive allows; a repository can still allow it unless you lock this rule. |
| Reads as, deny suffix | Reads as: **deny every host below `paste.example`**, and every allow rule it covers. |
| Note, covered | Already allowed by `*.internal.example`. Adding it changes nothing today and keeps the host allowed if the suffix rule is removed. |
| Card footer | Locked rules come first, then deny, then allow, each by host read from the right, so a suffix sits beside the hosts below it. A deny takes allowed hosts out of the document; the document itself can only allow. |
| Wildcard tooltip | Every host below github.example, and not github.example itself. |
| Lock tooltips | Lock: hold this rule against every repository / Locked: no repository can override it. Select to unlock. / Locked by beekeeper@example.com on 2 Sep 2026. Only an owner can change or unlock it. |
| Lock confirm | **Lock the deny rule `telemetry.example`** / A locked rule holds against every repository. **1 repository rule stops being in force**: … / The repository's rule is kept and shown as held. Only an owner can unlock. / `[Cancel]` `[Lock the rule]` |
| Remove confirm (only when a hive rule that repositories override or that is locked) | **Remove the allow rule `gitlab.example`** / 1 repository disables this rule; its own rule then has nothing to override and is kept. This takes effect within a heartbeat. / `[Cancel]` `[Remove the rule]` danger |
| Toasts | `files.cdn.example` is allowed for the hive. Version 15. / `gitlab.example` is denied for github.example/acme/shop. Version 11. / `api.example` is locked. No repository can override it. / `telemetry.example` is denied for the hive. No new version: the document did not list it. / The rule `errors.example` is removed. Version 14. |
| Credentials description | Credentials a run may use, by name. The policy names one; it never holds one. Each machine defines its credentials in its runner file, and a name a machine does not define is no run. |
| Credential fields | Name, such as forge-token / Argument (optional), such as acme/shop / `[Add credential]` |
| Repositories footnote | A repository appears here once a run names it. A repository without rules of its own is served the hive baseline, and so is a run that names no repository. |
| First version footnote | The first version is rendered when a rule is added, or when a machine first asks for its run configuration: observe, with an empty allow list. |

### pf3. Validation, in the contract's grammar

| Input | Sentence |
|---|---|
| a URL, a port, a path, or capitals | A rule names a host and nothing else: lower case, no scheme, no port, no path. `Use api.example with the path /v1/messages` |
| `*` anywhere but the lead, or `*` alone | `*.` may only lead a host: `*.example` matches every host below `example`. |
| an empty or over-long label, a leading or trailing dash, an underscore | Each part of a host is 1 to 63 letters, digits or dashes, and does not start or end with a dash. |
| an IP address with a port, brackets, or `/` | An address is written like a host, digits and dots only: `10.0.0.12`. The wall refuses the machine's own address whatever the policy says. |
| a bad path | A path starts with / and may end in one *; no other wildcard and no query, such as `/v1/*`. |
| the same rule again | `registry.example` is already allowed for the hive, by beekeeper on 2 Sep. `Show it` |
| the opposite rule exists in this scope | `gitlab.example` is allowed for the hive. Adding this deny replaces that rule. (kind: note; the button reads "Replace with deny") |
| a bad credential name | A name is 1 to 64 lower-case letters, digits, dots, dashes or underscores, and starts with a letter or digit. |
| an argument over 256 characters | An argument is at most 256 characters. |

### pf4. Refusals

| Case | Sentence |
|---|---|
| an exact-host deny under an allowed `*.` suffix (or a narrower suffix under a broader one) | **This rule cannot be said.** `*.cdn.example` is allowed, and the policy document can only list what is allowed: it has no way to take one host out from under a `*.` entry. Remove `*.cdn.example` and allow the hosts you want by name, or deny `*.cdn.example` whole. `Show *.cdn.example` `Deny *.cdn.example instead` |
| the same, on a repository page, where the suffix is the hive's | … `*.cdn.example` is allowed by the hive, and … Disable `*.cdn.example` for this repository and allow the hosts you want by name. `Disable *.cdn.example here` |
| a locked deny, member | A locked hive rule denies `*.paste.example`. It holds against every repository, so no rule added here would change what happens. Locked by beekeeper@example.com on 2 Sep 2026. Only an owner can change or unlock it. |
| a locked deny, owner | … on 2 Sep 2026. You can change or unlock it on the hive's policy page. |
| a locked allow, on Deny | A locked hive rule allows `github.example`. It holds against every repository, so a deny added here would change nothing. … |
| a member on a lock | Only an owner can lock, unlock or change a locked rule. |
| the render fails the schema | **The rule was not saved.** With it the rendered document would not pass the runner's policy schema, so nothing was changed and version 14 stays in force. The server log has the reason. |
| a concurrent write | **Someone changed the policy while you were editing.** beekeeper@example.com removed `registry.example` 4 s ago. The list below is current; add your rule again if it still applies. |

### pf5. Provenance and suggestions

| Where | Text |
|---|---|
| Override line | **Overrides the hive's rule** ~~allow gitlab.example~~ Disabled here by dana · 9 Sep. Other repositories keep it. |
| Override line, repository allows what the hive denies | **Overrides the hive's rule** ~~deny telemetry.example~~ Allowed here by dana · 9 Sep. |
| Lock line | **Holds against this repository's rule** ~~allow bin.paste.example~~ dana · 28 Aug. It is not in force. `Remove it` |
| Row actions | Disable here / Allow here / Remove / Restore / Open |
| Card footer | Mode **enforce**, from the hive. Credentials: `model-key` from the hive, `forge-token` argument `acme/shop` from this repository. `Edit credentials` |
| Suggestions description | Hosts the runtime says it needs, from the policy applied event of this repository's last 5 runs. A declaration allows nothing by itself. |
| Suggestion, denied | Declared by **claude** in 5 runs. **Denied 9 times**, last 2 minutes ago. |
| Suggestion, let through (observe) | Declared by **claude** in 5 runs. Let through 9 times with no rule. |
| Suggestion, never reached | Declared by **claude** in 5 runs. No run has tried to reach it. |
| Suggestion, locked | A locked hive rule denies `*.paste.example`. Only an owner can change it. |
| Suggestion footer | 2 more declared hosts are already allowed: `api.example` by the hive, `mcp.acme.example` by this repository. |
| After one click | ✓ Allowed here · `Undo` |

### pf6. History sentences

Subject is the author's email in 500; rules are mono chips. Built from `policy_changes.action`.

| Action | Sentence |
|---|---|
| rule added | **dana@example.com** allowed `files.cdn.example` / denied `telemetry.example` |
| rule removed | … removed the allow rule `errors.example` |
| paths changed | … changed the paths of `api.example` from every path to `/v1/*` |
| replaced | … replaced allow `gitlab.example` with deny |
| locked, unlocked | … locked `github.example` / unlocked `github.example` |
| mode | … switched the hive from observe to **enforce** |
| credential | … added the credential `model-key` / removed the credential `forge-token` `acme/shop` |
| origin line | From a connection row of run `0191d2aa` / From a suggestion / From the enforce confirm |
| no version line | The lock holds against repositories. The document did not change. |
| version cell | the pill, or "no new version" |
| diff bar | 1 line changed · re-rendered 2 repositories with rules of their own |
| footer | Showing 6 of 16. A change that leaves the document's bytes the same is kept here and makes no new version. Changes to a repository's own rules are in that repository's history. |

### pf7. Connection row

| Where | Text |
|---|---|
| Next, run alive | Takes effect in running sessions within a heartbeat, about 30 s. This run is alive: its next attempt can succeed. |
| Next, run ended or hive page | Takes effect in running sessions within a heartbeat, about 30 s. |
| Next, deny | Takes effect in running sessions within a heartbeat, about 30 s. Open connections to the host are closed at the reload. |
| Footnote, run connections (replaces the last sentence of M4's) | … A rule added here changes what happens next; what the record already says stays as it was. |
| Toast | `files.cdn.example` is allowed for github.example/acme/shop. / Version 10. Running sessions have it within a heartbeat. `Undo` |

"about 30 s" is the run's `heartbeat_interval_seconds` on a run page and the contract's default on
the hive pages.

### pf8. Version and export

| Where | Text |
|---|---|
| Caption | Shown indented for reading. "As served" is the exact bytes, 388 of them, that the digest is taken over. Deny rules and locks are not in the document: they decide what it lists. |
| Runs under it | `1 run` · 1 alive is behind, on v9 / No run has reported this version. |
| Export lead | The effective policy of **github.example/acme/shop** as of **version 10**, as the file a runner takes with `--policy`. It is a copy: it does not follow later changes. |
| Export caveats | Keep the file outside the checkout. A policy file only narrows what the machine's runner file allows, and it names credentials the machine must define. Deny rules and locks are already applied: the file lists what remains allowed. |

### pf9. Term hovers added

| Term | Tooltip |
|---|---|
| digest | The sha256 of the exact bytes a runner is served. Two runs with the same digest had the same policy. |
| hive baseline | The hive's rules with no repository's own: what a repository without rules, or a run that names none, is served. |
| locked | A hive rule no repository can override. Only an owner can lock or unlock. |
| harness | The runtime's own needs: hosts it declares in the policy applied event. Declared hosts are reported, never allowed by that. |

Announcements (one polite region per page): "Rule added. Version 15." "Rule removed. Version 15."
"The hive is in enforce mode." "files.cdn.example is allowed for this repository." "The run
reloaded its policy: version 10." "This run is behind the policy in force."

---

## pg. Motion

| What | Behaviour | Reduced motion |
|---|---|---|
| Mode cards, source chips, rows, tabs | 120 ms colour, as `brief.md` | 0 |
| Reading line | text swap, no fade, no height animation: the line always reserves one row (two on phones) | same |
| New rule row, one-click allow | the row appears in place with `bg-added`; the mark swaps from dashed red to green at once; nothing slides | same |
| Popover | 180 ms, opacity and 4 px towards the button, scale 0.98, as the dropdown; sheet on phones 240 ms from the bottom edge | appears |
| Modals | as `brief.md` | appears |
| After-line badge | swaps Rule added → In force in this run with no animation; it is a fact arriving | same |
| Drift mark and notice | appear and leave at once; amber never pulses | same |
| Diff | the `<details>` opens at once; chevron 120 ms | instant |
| Copy buttons | "Copied" for 1600 ms, as `brief.md` | same |

No looping animation is added. Layout never animates: the composer's row height is fixed, a rule
saved by someone else updates in place by DOM id, and a new rule from another session is inserted
at its sorted position only when nothing in the table has focus; otherwise the card's header gains
the accent link "1 new rule", which re-reads the list.

---

## ph. Accessibility

**Contrast** (WCAG 2.x, computed from the oklch values; text needs 4.5, marks 3.0).

| Pair | `qory` | `qory-dark` |
|---|---|---|
| base-content / muted on `added-tint` (fresh row, added diff line) | 16.5 / 6.35 | 14.1 / 6.50 |
| `success` (the `+` gutter, the allow mark's glyph) on `added-tint` | 4.61 | 7.68 |
| `success-soft-content` on `added-tint` | 8.16 | 10.0 |
| `info-soft-content` ("New in v10" chip) on `added-tint` | 7.80 | 9.66 |
| `accent` (the `*.` of a suffix, JSON keys) on base-100 / base-200 | 6.05 / 5.76 | 10.4 / 10.9 |
| `error` (dashed mark, `−` gutter) on base-100 | 5.50 | 5.85 |
| `primary-soft-content` on `primary-soft` (drift mark, drift notice) | 7.60 | 9.47 |
| `info-soft-content` on `info-soft` (Rule added, 2 to review) | 7.37 | 8.94 |
| faint (placeholders, "not seen", "every path") on base-100 | 4.77 | 4.63 |
| removed diff line: see `denied-tint` in `brief-runs.md` rh | | |

**No colour-only meaning.** Allow and deny differ in fill, glyph and an `sr-only` word; a
suggestion's mark is dashed because nothing is decided. Sources differ in glyph and wording. Diff
lines carry `+` / `−` and an `sr-only` "Added:" / "Removed:". A beaten rule is struck through and
also prefixed `sr-only` "not in force:". The drift mark is a triangle and the words "Behind v10".
Locked is a padlock and the word.

**Keyboard path, hive rules.** Skip link → sidebar → version pill → Export → tabs → mode
radiogroup (one tab stop; arrows move, Space or Enter asks) → filter segments → composer (action
segments, host, paths, Add rule) → table region → per row: lock toggle, `⋯` menu → credentials. A
rule's host is not a tab stop unless it carries the wildcard tooltip. Shortcuts, inactive while a
field has focus: `a` focuses the composer's host field, `/` the History filter, `?` lists them.

**Focus after actions.** Add rule: the host field, cleared; the new row is announced by the polite
region, not focused. Remove: the next row's actions, or the composer when the table empties. Lock
toggle: stays on the toggle. One-click allow in suggestions: the row's **Undo** link. Popover
opens: the first radio (the refusal: **Close**); closes: the slot's button, which now reads
**Rule**. Confirm modals: Cancel first, as `brief.md`; after confirming, the radio card now in
force. Export: the **Copy** button; after copying, focus stays and "Copied" is announced. Opening a
change: focus stays on its summary. Failed write: the notice is `role="alert"` and the field keeps
focus with `aria-invalid` and `aria-describedby` on the reading line.

**Names and roles.** The mode switch is a `radiogroup` labelled "Mode"; each card's name is its
heading and its sentence its description. The composer is a `form` labelled "Add a host rule"; its
inputs have `sr-only` labels "Host" and "Paths, optional" and are described by the reading line
(`role="status"`, or `role="alert"` for an error or refusal). Row buttons name their rule: "Lock
telemetry.example", "Actions for api.example", "Disable github.example for this repository". A
rule row reads "Deny, star dot paste.example, every path, Hive, locked, 3 denied in the last 7
days". The popover is a `dialog` labelled by its title; radios are grouped in `fieldset`s with
legends "What" and "For". The locked slot button's name is the sentence of its tooltip. Tables keep
explicit roles where the phone layout changes their display.

**Targets.** 24 px row buttons get `min-h-10 min-w-10` hit areas under `@media (pointer: coarse)`;
on phones every button in a composer, popover sheet and modal is 40 px.

**Reflow.** At 320 px and 200 % zoom nothing scrolls sideways at page level: code and diff wells,
the As served line and the tabs scroll inside themselves.

---

## pi. Phone layout (below 768 px)

Header: title and description, then the version pill full width, then Export full width (40 px).
Tabs scroll sideways. Mode cards stack. The composer stacks: action segments, host, paths, button,
reading line, all 40 px with 16 px text in the fields so the phone does not zoom. Rule rows reflow
inside the same table into blocks (keep `role="row"` / `role="cell"`): line one the mark and host
with the action on the right; then paths (only when there are any), the source chip, the last 7
days; "Added" is dropped (it is in History). A beaten rule's line wraps under its winner with the
same left rule. Suggestion rows put the sentence under the host and buttons. History rows drop to
chevron, avatar, sentence, with time and version under the sentence; the diff panels stack, rules
first. Version page: strip in two columns, the versions list under the document. The row popover
is a bottom sheet with the primary above Cancel; modals are sheets as `brief.md`. Tooltips open on
tap.

---

## pj. Performance guidance for the builders

1. **Stable ids.** Rules `"rule-#{id}"`, beaten rules `"rule-#{winner_id}-over"`, suggestions
   `"sg-#{:erlang.phash2(host)}"`, changes `"chg-#{id}"`, versions `"ver-#{n}"`. Never an index.
2. **One subscription.** Every policy page subscribes to `policy:<hive>` and re-reads
   `effective/2` (or `list_rules/2`) once per message, coalesced to one read per 250 ms. The
   sidebar's mode word rides the same topic.
3. **The list is small, the counts are not.** Rules are bounded (a hive has tens, not thousands):
   render them all, no pagination, no stream windowing. "Last 7 days" is one grouped query over
   `connections` by `rule` for the scope, in `assign_async`, cached for 60 s per hive and
   repository. The column renders "…" skeleton cells until it lands and is dropped on failure.
4. **Validation is cheap and local to the server.** The reading line is computed by
   `Apiary.Policy` pure functions from the form and the rules already in assigns: no query per
   keystroke. Debounce 150 ms. The refusal check (suffix cover, locks) runs on the same data.
5. **Diffs are computed on open.** The history page loads rows only (`list_changes/3`, 20 per
   page); `diff/1` runs when a change opens. Documents are small; the line diff is server-side, and
   a version page loads exactly two documents.
6. **The enforce confirm** reads at most 8 destinations and a count, from one bounded query, when
   the modal opens, not on page load. The mode card's fact line is one count in `assign_async`.
7. **Row actions cost nothing until used.** The slot's standing (`:can_allow`, `:locked_deny`, …)
   is derived once per page from the effective policy held in assigns, not per row by query. The
   popover's repository list is loaded when it opens.
8. **Drift is a comparison, not a poll.** The run page holds `policy_digest_reported` and reads
   `policy_digest_in_force` at mount and on each `policy:<hive>` message; the mark is the
   inequality while the run is alive. No timer decides it.
9. **Bound everything from a runner.** Hosts from `harness_hosts` are validated by the host
   pattern before display, truncated in the middle past 48 characters, at most 50 suggestions.

---

## pk. Done checklist

Navigation and URLs
- [ ] Sidebar item Policy with the mode word; `nav={:policy}` on every page below `/hive/policy`
- [ ] Tabs, filters, the opened change, the compared version and the export modal are in the URL; a copied URL reproduces the view
- [ ] Repository policy under `/hive/policy/repositories/:id`; reachable from the run header, a row's Rule button, the connections page with `repo`, the runs list group header, the Repositories tab

Rules
- [ ] Mode switch asks before either change; the enforce confirm lists what would be denied, from the record, with one-click allow; no estimate when it cannot be counted
- [ ] Composer validates in the contract's grammar as you type, reads the rule back, repairs a pasted URL, and refuses the exact-host deny under an allowed suffix with the sentence of pf4
- [ ] Hive list: mark, wildcard, paths, last 7 days, added, lock; owners toggle locks, members read them
- [ ] Repository list: one list, source chip per row, beaten rules struck under their winner, Disable here / Allow here / Remove / Restore / Open
- [ ] Suggestions from `harness_hosts` with one-click allow, undo, dismiss, and the locked case
- [ ] Credentials by name with an optional argument; never a value

Versions
- [ ] Version pill on both policy pages; "No version yet" on a new hive
- [ ] History: every change with who, when, origin and the version it made or "no new version"; the diff in rules and in document lines
- [ ] Version page: changes, document, as served; compare with any version; copy copies the served bytes
- [ ] Export as YAML for `--policy`, copy and download, with the caveats

Connections and runs
- [ ] Slot buttons always visible: Allow, Deny, the padlock, nothing for the wall, Rule after
- [ ] Popover: path choice only when the host has path rules; repository is the default scope on a run page; no default among several repositories; the heartbeat sentence; bottom sheet on phones
- [ ] The row after: unchanged record plus the after line; "In force in this run" only when the run reported the new digest
- [ ] Run header: version link to the exact version; "Behind v10" only while alive and unequal; the notice; never on an ended run
- [ ] Timeline: "Policy applied again" with the delta from the two events

Quality
- [ ] Both themes, at 1440, 1024, 768, 375; no page-level horizontal scroll at 320
- [ ] Keyboard-only pass: add, lock, disable, allow from a row, switch mode, open a diff, export
- [ ] VoiceOver pass: the reading line speaks once per pause, a refusal is an alert, a struck rule is "not in force"
- [ ] A member never sees a control that would be refused, except the composer, whose refusal is the explanation
- [ ] Synthetic sample data only; no customer, engagement or person named; no AI attribution; British spelling

---

## pl. Open questions for the coordinator

1. **A repository path added from a row.** A repository rule on a host beats the hive's unlocked
   rule on the same host, so "allow this path for this repository" must be written as the paths in
   force plus the new one, or it would silently drop `/v1/*`. The design assumes
   `rule_from_connection/4` merges. Confirm, or the popover must say "replaces the hive's paths".
2. **A narrower suffix under a broader allowed suffix** (`deny *.eu.cdn.example` under `allow
   *.cdn.example`) cannot be said either, by the same reasoning as the exact host. The brief treats
   both as the pf4 refusal; the build brief names only the exact host.
3. **What "would have been denied" is counted from.** The enforce confirm and the observe fact line
   want recorded connections that *today's* rules do not cover (a function such as
   `Policy.uncovered(scope, since)`), which is not in the domain API yet. The fallback is the
   record's own field (allowed with an empty `rule`), which still lists hosts allowed since; the
   design hides the list rather than show that.
4. **"Last 7 days" per rule** needs `connections` grouped by `rule` per scope. If it is too costly
   for M5, the column is dropped, not faked; the page works without it.
5. **Dismissed suggestions** need somewhere to live (a small table or a column per repository).
   Without it, drop Dismiss; the list then shrinks only by allowing.
6. **Export form.** The design exports a YAML policy file for `qory run --policy` (S7 says "the
   runner file's inline document"). If an `egress:` block for `runner.yaml` is wanted as well, it
   is a second segment in the same modal ("Policy file | Runner file section"); the credentials
   cannot go in that one, since there they are definitions, not names.
7. **Observe and locks.** The observe confirm says locked rules do not hold in observe mode, which
   follows from "observe denies none". Confirm that no one expects a locked deny to deny under
   observe.
8. **Undo** is `remove_rule/2` (or restoring the replaced rule) and makes a version of its own. If
   a replaced rule cannot be restored in one call, the toast drops Undo for replacements.
9. **The runs list group header** gains a "Policy" link and the hive connections description a
   link; both touch M4 components owned by another builder.
