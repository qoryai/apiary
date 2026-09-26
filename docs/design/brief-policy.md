# Qory console: design brief for the security policy (M5)

Implementation spec for milestone M5: the workspace's policy page, a repository's
effective policy, versions, history and export, allow and deny from a connection row, and
the policy version and drift mark of the run header. It extends `brief.md` and
`brief-runs.md`; everything there (tokens, shell, components, tone, accessibility) still
holds and is not repeated. The rendered reference is `policy-mock.html` beside this file;
where the two disagree, this brief wins. Section letters continue the pattern with a `p`
prefix.

## Amendment 4: a rule's action changes from its row

The owner, 21 Sep 2026, on `/:org/:workspace/policy`: "I can't edit the rule for yahoo
here to deny access. It constantly switches to stockanalysis rule. I would expect a popup
for edition, with clear deny/allow buttons." Two things were wrong. The row's `⋯` menu
offered no way to turn an allow into a deny: that lived only in the composer, as "Replace
with deny", which nothing on the row points at. And a closed row menu was hit-testable:
the app's `.menu` rule set `display` in a layer above daisyUI's closed-dropdown rule, so
every closed menu hung, transparent, over the row below, and a click on the next row's `⋯`
landed on the menu above it (its first item, "Edit paths", which filled the composer with
the wrong host). Marked **[A4]** where it lands.

| Where | What changed |
|---|---|
| pd4 | the `⋯` menu gains **Change to deny** on an allow rule and **Change to allow** on a deny rule, after Edit paths; it writes at once through the domain, which replaces the rule for the host, and the toast is the composer's |
| pf2 | the toast row: "`finance.example` is denied for the workspace. Version 11." from the row as from the composer |
| ph (app.css) | a closed dropdown is `display: none` in the app's own layer, mirroring daisyUI's condition, for every dropdown; a hook-driven menu opens by the hook alone |

The edit popup the owner pictured is not built: a menu item that does the one thing is
shorter than a dialog with the same two buttons, and Edit paths already opens the composer
for the rest. Should more per-rule fields arrive (a note, an expiry), that is when a rule
dialog earns its place.

## Amendment 3: deny holds in either mode

An owner's decision of 21 Sep 2026: "if we have default observe and we added a rule to deny some
host, then all connections which do not match the deny rule should be allowed but the one which
is in rules should be denied even when the policy is in observe." The runner contract gains
`egress.deny`, a list in `allow`'s grammar that the runner decides **first and in either mode**;
Qory Apiary writes every deny rule that wins on its host to it. So a deny is no longer the
control plane's private notion that only shapes the allow list: it is in the document, it
holds under observe, and the record names it as the rule. Marked **[A3]** where it lands.

| Where | What changed |
|---|---|
| intro, pa 1 | the model sentence: the document says what is denied and what is allowed |
| pd2a | the note under an observing repository with a locked deny: the lock holds, and under observe it is the only thing denied |
| pd3, pf4 | the exact-host deny under an allowed `*.` suffix is **accepted** and rendered; the "cannot be said" refusal goes |
| pd8, pf7 | the popover's next sentence for a deny is the same in either mode; the observe-deny sentence of Amendment 2 goes |
| pe1, pe3, pf1 | the Observe card, both observe confirms and the locked-deny note say "only what a deny rule names" |
| pe6, pd9 | the timeline's policy items read `deny`: "denies 2 hosts", deny chips on a reload |
| pf2 | a deny always changes the document, so the "No new version: the document did not list it" toast no longer arises for one |
| pk, pl | checklist lines; question 7 is superseded |

**What the builders must know.** (1) A `*.` deny still takes the allow entries it covers out of
`allow`, so the list says what is reachable; the runner would deny them by the deny anyway. (2)
The one shape the wire cannot say is a `*.` deny with a repository's own allow below it that
outranks it: the allow wins and is rendered, the deny is not written to `deny` (it would deny the
winning host too) and still takes out what it outranks; `Apiary.Policy.Resolution` says so. (3)
The versions in force before this amendment carry no `deny`; `mix apiary.policy.rerender`
renders them again once after the upgrade.

## Amendment 2: deny from a row no rule decides

An owner's decision of 21 Sep 2026. A connection let through under observe with no rule, or
denied by default under enforce, offered only **Allow**; while a workspace observes, the
policy is written from the record, and a decision against a host is as common as one for
it. Such a row now holds a **Deny** before the **Allow** (pd8), bordered like it, Deny in
the danger tone and Allow in the success tone, the tones of the decision marks, since a
ghost beside a bordered button read as text. ~~A deny under observe says what it does:
nothing yet, until the mode is enforce.~~ [A3]: a deny holds in either mode, and its
sentence is the same under observe. Marked **[A2]** where it stands.

## Amendment 1: mode per repository

An owner's decision after the first issue of this brief. **The workspace's mode is a
default. Each repository either follows it or sets a mode of its own (observe or enforce).
Setting a mode, the workspace's or a repository's, is an owner's act; members read it.**
Two earlier rulings are folded in: **no Dismiss on suggestions and no Undo in toasts** in
M5, and **a new workspace is served no policy by Qory until its first change**: until then
machines run under their own. Every change below is marked **[A1]** where it stands.
Nothing else moved.

| Section | What changed |
|---|---|
| intro | the model sentence; per-repository mode leaves the out-of-scope list |
| pb Sidebar, query parameters | `?mode=own` on Repositories; the tag is the workspace's default, and says when repositories set their own |
| pd2 | `<.mode_switch>` sets the **default**; badge "Workspace default"; `can_edit` is owner-only; fact line counts the repositories that follow |
| pd2a (new) | `<.repository_mode>`: Follow the workspace · Observe · Enforce, with what is in effect and where it comes from |
| pd6 | no Dismiss; no in-row Undo |
| pd7 | a mode change re-renders the repositories that follow; a repository's mode change is a change of that repository |
| pd8 | the popover's "what happens next" reads the run's own mode; no Undo in the toast |
| pd9 | the mode in the Policy cell is the run's own, from `policy_applied`; never the workspace's |
| pe1 | the sentence under the cards; both confirms reworded and scoped to the repositories that follow; members cannot set the mode |
| pe2 | a **Mode** column; the summary counts repositories with their own mode |
| pe3 | the mode control above the suggestions; the repository's own confirms; the footer is the read-only summary; a locked deny under observe |
| pe5 | the version strip gains **Mode** with its source |
| pe7 | new workspace: "Qory serves no policy yet"; history's first-version sentence |
| pf1, pf2, pf5, pf6, pf7, pf8, pf9 | strings, all marked |
| pg, ph, pi, pj, pk | one line each for the new control; checklist lines |
| pl | questions 5 and 8 are closed by the rulings; 7 is answered; 10 to 12 are new |

**What the builders must know.** (1) A repository that sets a mode now has run configurations of
its own even with no rules of its own: "served the baseline" means *neither rules nor a mode*.
(2) A change of the default re-renders only the repositories that follow it. (3) Setting a
repository to the mode it already has in effect (own enforce while the default is enforce) changes
no bytes: a change row, no version, no confirm. (4) No mode word on a run, a connection or a
timeline item may come from the workspace: it is the `mode` of that run's `policy_applied`
event, or of the egress event. (5) A new workspace has no configuration at all until its
first change; the endpoint's answer for it is BACKEND's to choose within the contract, and
the page only says "machines use their own policy until then".

---

Naming. The brand is **Qory**. Sample data is synthetic only: Acme, Platform, `acme/shop`,
`acme/tax-service`, `acme/docs`, `github.example`, `gitlab.example`, `api.example`,
`registry.example`, `files.cdn.example`, `mcp.acme.example`, `*.paste.example`,
`beekeeper@example.com` (owner), `dana@example.com` (member), `build-01`.

The model is fixed by the build brief and is not re-argued here: **the policy document says what
is denied, in either mode, and what is allowed under enforce [A3]**; the **mode is the
workspace's default, which a repository follows or replaces with its own [A1]**; **deny**
is written to the document's deny list and **lock** is the control plane's notion that
decides what the document lists [A3]; every write renders versions that are kept for ever.
The UI calls `Apiary.Policy` and nothing else.

Out of scope, not designed here: defining a credential's value (a machine's business), editing the
machine's runner file, scheduled or expiring rules, approval flows, policy
templates.

---

## pa. Principles for editing a policy

The principles of `brief.md` and `brief-runs.md` apply; these six are added.

1. **The page says only what the document can say.** Every control maps to a field of
   `policy.schema.json` (`egress.mode`, `egress.allow`, `egress.deny` [A3], `egress.paths`,
   `credentials`) or to the one notion the control plane owns (lock). Nothing else is offered: no
   ports, no schemes, no methods. When a rule cannot be said, the page refuses it in a sentence
   that names the reason and the two ways out (pf4).
2. **A rule is read back before it is saved.** The composer validates in the contract's grammar as
   you type and answers with the rule in plain words: "allow every host below `internal.example`,
   on every path. It does not allow `internal.example` itself." The button is off until the
   sentence is there. People misread `*.`; the sentence is where they find out.
3. **One list, and every entry says where it came from.** A repository's policy is never two
   tables to be merged in the head. It is the effective list, one row per host in force, with a
   source chip (Workspace, This repository, Workspace, locked). A rule that lost is not
   hidden and not a row of its own: it hangs under the rule that beat it, struck through,
   with who and why.
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

One item is added to the "Workspace" section, after Connections, because the policy is
what the connections are judged by:

```
Workspace
[#] Overview
[>] Runs            (o) 2
[⇄] Connections
[✓] Policy          enforce    <- the mode in force, mono 11.5 faint
Manage
…
```

Icon `hero-shield-check-micro`. **[A1]** The trailing word stays, and it is the
workspace's **default** mode (`Policy.get_mode/1`), updated over PubSub
`policy:<workspace>`. While every repository follows it, it reads `enforce` with the
`title` "The workspace's default mode is enforce. Every repository follows it." When any
repository sets its own, it reads `enforce · 1 own` (the count in the same faint mono at
75 %), with the `title` "The workspace's default mode is enforce. 1 repository sets its
own and observes." (or "2 repositories set their own."). The tag never claims what every
run is under; it names the default and says how many differ. A new workspace that serves
nothing yet shows no tag. It is a word, not a colour: observe is not a fault.
`Layouts.app` gains `nav={:policy}`; every page below sets it, including the repository
pages. `counts` gains `:mode` and `:own_modes` [A1].

### Routes

All inside `live_session :workspace`, all `width="full"` (1200).

| Page | Path | LiveView, action |
|---|---|---|
| Workspace policy, rules (default tab) | `/:org/:workspace/policy` | `PolicyLive.Show, :rules` |
| Repositories | `/:org/:workspace/policy/targets` | `PolicyLive.Show, :targets` |
| Workspace history | `/:org/:workspace/policy/history` | `PolicyLive.Show, :history` |
| Workspace version (Document tab opens the current one) | `/:org/:workspace/policy/versions/:n` | `PolicyLive.Show, :version` |
| Workspace export (modal over the version) | `/:org/:workspace/policy/versions/:n/export` | `PolicyLive.Show, :export` |
| Repository, effective policy | `/:org/:workspace/policy/targets/:target_id` | `PolicyLive.Target, :rules` |
| Repository history | `/:org/:workspace/policy/targets/:target_id/history` | `…, :history` |
| Repository version | `/:org/:workspace/policy/targets/:target_id/versions/:n` | `…, :version` |
| Repository export | `/:org/:workspace/policy/targets/:target_id/versions/:n/export` | `…, :export` |

`/:org/:workspace/policy/document` and `/:org/:workspace/policy/targets/:id/document`
redirect to the current version, so "Document" is a stable link and a version URL is a
permanent one. `:target_id` is the repository row's id (a forge and path contain slashes).
A repository of another workspace renders the not-found state, never another workspace's
rules.

**Why not `/:org/:workspace/repositories/:id/policy`.** There is no repositories page in
the console: a repository is a label on runs, and `/:org/:workspace/repositories` would be
a parent that does not exist. The policy is one object with two scopes, the baseline and a
repository's view of it, so both live under `/:org/:workspace/policy`, keep
`nav={:policy}` lit, and share the breadcrumb `Policy › Repositories ›
github.example/acme/shop`. If a repositories section appears later, it links here.

Query parameters, all written with `push_patch`:

| Page | Param | Values |
|---|---|---|
| Rules, effective policy | `show` | `allow`, `deny`, `locked` (workspace); `workspace`, `repository`, `overrides` (repository). Default all |
| Repositories [A1] | `mode` | `own`: only the repositories that set their own mode (the link under the workspace's mode cards) |
| Rules, effective policy | `rule` | a host: scrolls to and highlights that rule (the target of "Show it", "Rule", "Open") |
| History | `change` | a change id: opens that change's diff. `who`, `kind`, `host`, `page` filter and page |
| Version | `compare` | a version number; default the one before. `view` = `changes`, `document`, `served` |

### How one gets to a repository's policy

1. **From a run**: the breadcrumb's repository item keeps linking to the filtered runs list; the
   header's **Policy** cell links to the exact version the run reported (pe6), whose breadcrumb
   leads up to the repository's policy.
2. **From connections**: the "Rule" button left in a row's slot after an allow or deny
   (pd8), and on `/:org/:workspace/connections?target=…` the description's second sentence
   gains a link: "Showing `github.example/acme/shop` only. Its policy".
3. **From the runs list**: the repository group header's facts gain a last item, the link
   "Policy", `text-xs text-muted`, shown on hover and focus of the header and always on touch.
4. **From the policy page**: the Repositories tab lists every repository that has posted a run.
5. **Back again**: the repository policy's tab row ends with two plain links, "Runs 5" and
   "Connections", to `/:org/:workspace/runs?target=…` and
   `/:org/:workspace/connections?target=…`.

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
attr :mode, :string, required: true, values: ~w(observe enforce)   # the workspace's default [A1]
attr :can_edit, :boolean, default: false     # owners only [A1]
attr :served, :boolean, default: true        # false on a new workspace: nothing is served yet [A1]
attr :following, :integer, default: 0        # repositories that follow the default [A1]
attr :fact, :map, default: nil               # %{denied: 12, destinations: 3, days: 7} or %{uncovered: …}
```

A `role="radiogroup"` of two cards side by side (stacked on phones). Card: `rounded-box border
p-[14px_16px] grid grid-cols-[16px_1fr] gap-x-2.5`; unselected `bg-base-200 border-line
text-muted`, hover `border-line-field`; selected `bg-base-100 border-line-field shadow-xs` with the
radio dot in honey (the checked state is one of honey's three uses) and a neutral badge
**Workspace default** [A1] (not "In force": a repository may differ).
Head: 16 px icon in faint (`hero-eye-micro`, `hero-shield-exclamation-micro`) and the name in 14
semibold. One sentence under it (pf1). The selected card ends with a fact line above a hairline,
from recorded connections (pf1). Choosing the other card never switches at once: it opens the
confirm (pe1). Arrow keys move between the cards, Space or Enter asks. **[A1]** For a member the
group is `aria-disabled="true"`: the cards keep their look and their words, lose hover and the
pointer, do nothing, and the line under them ends "Only an owner sets a mode." The fact line counts
only the repositories that follow the default.

### pd2a. Repository mode (`<.repository_mode>`) [A1]

```elixir
attr :id, :string, required: true
attr :setting, :string, required: true, values: ~w(follow observe enforce)
attr :effective, :string, required: true, values: ~w(observe enforce)
attr :workspace_default, :string, required: true, values: ~w(observe enforce)
attr :can_edit, :boolean, default: false     # owners only
attr :locked_denies, :list, default: []      # locked workspace denies in the list, for the observe note
```

One compact card, the first thing under the repository's tabs: `grid grid-cols-[auto_auto_1fr]
gap-x-4 items-center px-4 py-2.5`. Parts: the heading **Mode** (15 semibold); a segmented
**radio group** (`role="radiogroup"` labelled by the heading; three `role="radio"` buttons, 26 px,
in the `bg-base-300` track of the other segmented controls): **Follow the workspace ·
Observe · Enforce**; then one sentence of what is in effect and where it comes from (pf1).
It is compact on purpose: the workspace page explains the two modes once, in cards; here
the choice is whose mode, and the sentence carries the rest.

- Choosing a setting that **changes what is in effect** opens this repository's confirm (pe3).
  Choosing one that does not (Enforce while following an enforce default, or back to Follow when
  the default equals the own mode) is immediate, with a toast that says nothing changes today.
- While the repository **observes** and the effective list holds a locked workspace deny,
  an info `<.notice>` spans the card under the row (pf1): the lock holds, and under
  observe it is the only thing denied [A3]. Say so where the mode is set, not in a
  tooltip.
- A member sees the same card: the checked radio as it is, the other two at 45 % and
  `aria-disabled`, and the sentence ends "Only an owner sets a mode."
- Below 768 px the three parts stack and the radios become three equal 36 px cells.

### pd3. Rule composer (`<.rule_composer>`)

```elixir
attr :id, :string, required: true
attr :form, :any, required: true             # action, host, paths
attr :scope, :atom, required: true, values: [:workspace, :repository]
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
attr :rows, :list, required: true            # effective entries or workspace rules
attr :scope, :atom, required: true, values: [:workspace, :repository]
attr :can_lock, :boolean, default: false     # owners
# <.rule_row>
attr :id, :string, required: true            # "rule-#{id}"
attr :rule, :map, required: true             # action, host, paths, locked, source, created_by, inserted_at,
                                             # origin (:page | :connection | :suggestion), seen, beaten (the rule it holds against)
attr :scope, :atom, required: true
attr :can_lock, :boolean, default: false
attr :fresh, :boolean, default: false        # new in the version in force
```

Built on `<.table>`'s classes, 40 px rows. Columns on the workspace page: **Rule · Paths ·
Last 7 days · Added · (lock and actions)**. On a repository page: **Rule · Paths · Comes
from · Last 7 days · (actions)**.

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
- **Lock** (workspace page). Owners: a 24 px toggle button, `aria-pressed`; unlocked it is
  a faint open padlock with the tooltip "Lock: hold this rule against every repository";
  locked it is a bordered chip, closed padlock and the word **Locked**, tooltip "Locked:
  no repository can override it. Select to unlock." Members: a static closed padlock and
  the word "Locked", focusable, tooltip "Locked by beekeeper@example.com on 2 Sep 2026.
  Only an owner can change or unlock it."; an unlocked rule shows nothing in this place.
- **Actions**. Workspace page: a `⋯` menu (Edit paths, Change to deny / Change to allow
  [A4], Lock / Unlock for owners, a divider, Remove in error tone). A member sees no menu
  on a locked rule. Repository page: one ghost `btn-xs` whose word is the act: a workspace
  rule reads **Disable here** (allow) or **Allow here** (deny); the repository's own rule
  reads **Remove**, or **Restore** when it exists only to disable a workspace rule; a
  locked workspace rule reads the link **Open** (to `/:org/:workspace/policy?rule=…`).
- **Order**: locked rules first, then deny, then allow; inside each, by the host's labels read
  from the right, so `*.github.example` sits beside `github.example`. The card's footer says so.
- **Fresh**: `bg-added` on every cell and an info-toned chip "New in v10" after the host.
- **Beaten rule** (repository page only): a second `<tr>` under the winner with no top border,
  holding one line indented to the host, with a 2 px `line-strong` rule on its left: the lead in
  `base-content` 500, the beaten rule struck through in mono, then who and when, then the one act.
  - Override: "**Overrides the workspace's rule** ~~allow gitlab.example~~ Disabled here
    by dana · 9 Sep. Other repositories keep it."
  - Lock: a padlock, "**Holds against this repository's rule** ~~allow bin.paste.example~~
    dana · 28 Aug. It is not in force. `Remove it`"
  The struck rule is announced as "not in force: allow bin.paste.example" (`<s>` alone is
  silent to a screen reader; add an `sr-only` prefix).

### pd5. Source chip (`<.source_chip>`)

```elixir
attr :source, :atom, required: true, values: [:workspace, :repository, :workspace_locked]
```

`h-5 px-[7px] rounded-selector border text-[11.5px] font-medium`, a 12 px glyph and words:
**Workspace** (`bg-base-200 border-line text-muted`, a hexagon), **This repository**
(`bg-base-100 border-line-field text-base-content`, `hero-book-open-micro`), **Workspace,
locked** (as Workspace with `text-base-content` and `hero-lock-closed-micro`). Three
shapes, three wordings, no status hue: where a rule comes from is not good or bad.

### pd6. Suggestions (`<.suggestions>`)

```elixir
attr :id, :string, required: true
attr :suggestions, :list, required: true     # [%{host, runtime, runs, denied, last_denied_at, blocked_by}]
attr :covered, :list, default: []            # [%{host, by: :workspace | :repository}]
attr :runs, :integer, required: true         # how many runs the declaration was read from
```

A section card above the effective policy, shown only when there is something to review. Header
**Declared by the harness**, the count "2 to review", on the right a default `btn-xs` **Allow both
here** ("Allow all 4 here"; absent for one), and one sentence (pf5). One 44 px row per host: a
**dashed** red mark (not allowed yet: outline, not solid, because nothing was decided), the host,
a sentence of what the record says, and the actions: a split `btn-xs` **Allow here** with a caret
menu (Allow for the workspace, Allow with paths…). **[A1]** There is no Dismiss and no
Undo in M5. One click allows: the mark turns to the soft green check in place, the actions
become "✓ Allowed here", and the row leaves at the next navigation; a mistake is undone by
removing the rule in the list below. A host a locked deny covers has no button and reads
"A locked workspace rule denies `*.paste.example`. Only an owner can change it." The
footer lists what is already covered. In a repository that observes, the sentence reads
"Let through 9 times with no rule" and the mark stays dashed: the host is still not
allowed [A1].

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
third carrier, not the first. On a repository's history, a change made on the workspace
that re-rendered this repository appears with a small neutral chip **workspace** after the
time. **[A1]** A change of the workspace's default mode appears there only for a
repository that follows it, and its diff bar says how many followed: "re-rendered 1
repository that follows the default; 1 sets its own mode and did not change". A
repository's own mode change is a change of that repository (pf6), with the same two
panels: rules "− Mode enforce, the workspace's default / + Mode observe, its own",
document the `mode` line.

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
| denied, or let through by observe with no rule | `btn-xs` **Deny** in the danger tone (`q-rowbtn-deny`: bordered, `text-error`, soft error fill on hover), then `btn-xs` **Allow** in the success tone (`q-rowbtn-allow`) [A2]: no rule decides the host, so either is a decision, and under observe the record is read while the policy is written |
| denied by a rule (not locked) | `btn-xs` **Allow** in the success tone [A2] |
| allowed by a rule | `btn-xs` **Deny** in the danger tone [A2] |
| a locked workspace rule decides it | ghost icon button, closed padlock, tooltip "A locked workspace rule denies `*.paste.example`" (or "allows") |
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
   narrowest scope is the default) and "The whole workspace: every repository of
   Platform". On the workspace connections page with several repositories: "One
   repository" with a select of the repositories whose runs reached the destination, each
   with its count, and "The whole workspace"; nothing is checked, and the primary is
   disabled until one is: the page does not guess a scope. With the `target` filter set,
   that repository is checked. A deny adds the consequence under each radio: "Disables the
   workspace's allow rule here. Other repositories keep it." / "Replaces the workspace's
   allow rule. 6 runs of 2 repositories reached this host in the last 7 days."
4. **What happens next**, a reload icon and one sentence (pf7). **[A1]** The sentence reads the mode
   of the run's own policy (the `mode` of its last `policy_applied`), on the workspace
   connections page the effective mode of the repository chosen under "For": under observe
   the icon is the eye and the sentence says the connection is already let through.
   **[A3]** A deny reads the same in either mode: "Open connections to the host are closed
   at the reload." (the observe-deny sentence of [A2] is gone: a deny holds under
   observe).
5. Footer: Cancel, then the act named in full: **Allow for this repository**, **Allow for the
   workspace**, **Deny for this repository** (danger), **Deny for the workspace**
   (danger).

**Refusal.** When a locked rule decides the host the popover has no form: title
"`bin.paste.example` stays denied", a warning notice with the sentence of pf4, and the footer
**Close** and **Show the locked rule**. It is the same for owner and member, except the last
sentence; an owner changes a lock on the policy page, never from a row.

**After.** The popover closes, focus returns to the slot's button (now **Rule**), and a toast names
the change and the version. **[A1]** No Undo in M5: the **Rule** button is the way back. The row keeps its mark, its
counts, its reason and its tint. The reason cell gains an **after line** (12.5 px, muted) with a
badge that moves through three states as the record allows:

| Badge | Sentence |
|---|---|
| info **Rule added** | Allowed for this repository in `v10` by you, 2 minutes ago. The run has not reloaded yet. |
| success **In force in this run** | Allowed for this repository in `v10`. The run reloaded at `#0046`. |
| neutral **Rule added** | Allowed for this repository in `v10`. This run has ended; the next run of the repository has it. |

"In force in this run" is claimed only when the run has reported the new digest (F2), never after a
timer. On the workspace connections page the line reads "Allowed for the workspace in
`v15` by you, just now." with no run state. In the timeline's inline variant there is no
after line: the second "Policy applied" item (pe6) and the later allowed connection tell
it.

### pd9. Policy cell and drift mark (`<.policy_value>`, extended, and `<.drift>`)

```elixir
# <.policy_value> gains
attr :version, :map, default: nil            # %{n, scope: :workspace | :repository, path} from configuration_for_digest/3
attr :in_force, :map, default: nil           # %{n, digest, since} when it differs and the run is alive
# <.drift>
attr :reported, :map, required: true
attr :in_force, :map, required: true
attr :last_seq, :integer, required: true
attr :interval, :integer, default: 30
```

**[A1]** The mode in this cell is the run's own: the `mode` of its last `policy_applied` event,
never the workspace's default and never the repository's setting read now. The version
page it links to says where that mode came from (pe5). A reload that changed only the mode
shows as drift and then as "Policy applied again" like any other.

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
| digest matches a workspace baseline version | `enforce v14` and the sub value "workspace baseline" |
| digest matches no version here | `observe 4b227777d4dd · not rendered here`, tooltip "The run reported a digest that matches no version rendered here: a policy file on the machine, or a run started with --local." No link |
| `source: none` | `observe` and "no policy", as today |

The same version link replaces the bare digest in the run connections tab's summary ("policy
**enforce** `v9` Behind v10") and on the Details tab's "Policy in force" card, which gains the rows
**Version** (the link) and **In force now** (the version link, or "the same").

---

## pe. Page compositions

Copy is final. `{…}` is data. ~word~ carries the term hover; organisation and
workspace never do.

### pe1. Workspace policy, rules (`/:org/:workspace/policy`)

```
Policy                                              [v14 | sha256 e3b0c44298fc | ⧉]  [↥ Export]
What the runs of this workspace may reach through the runner's proxy. The policy can only
allow: what no rule names is denied under enforce, and let through and recorded under observe.

[ Rules 9 ]  Repositories 4   History 16   Document
+------------------------------------------+ +------------------------------------------+
| ( ) Observe                              | | (•) Enforce  [Workspace default]              |
|     Records every connection and denies  | |     Denies a connection no rule allows,  |
|     none. …                              | |     …                                    |
|                                          | |     ------------------------------------ |
|                                          | |     In the last 7 days it denied 12 …,   |
|                                          | |     in the 3 repositories that follow it |
+------------------------------------------+ +------------------------------------------+
This is the workspace's default. A repository follows it unless an owner sets a mode of its own:
1 of 4 repositories does, and observes. …                                              [A1]

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

**Going to enforce** opens a `lg` modal, "Set the workspace's default to enforce" [A1]:
the consequence sentence (pf1), which names how many repositories follow and which do not
change, then a bordered list headed "Let through in the last 7 days with no rule matching,
in those repositories" and the count on the right. The list is counted over the
repositories that follow the default only. One 38 px row per destination (at most 8, then
"and 4 more on the connections page"): a dashed red mark, host and port, "8 attempts · 3
runs", and a default `btn-xs` **Allow for the workspace**, which adds the rule there and
then (the mark turns green, the button becomes "✓ Allowed", the count drops). A closing
line says how the list was counted. Footer: Cancel (initial focus), **Set the default to
enforce** (primary). When nothing would be denied the list is replaced by "Every
destination your runs reached in the last 7 days is covered by a rule." The list is built
from recorded connections that today's rules still do not cover; when that cannot be
computed the modal shows the consequence sentence alone, never an estimate.

**Going to observe** opens a `sm` modal with the danger button **Set the default to observe**: it
loosens every repository that follows, so it asks too; the sentence says that only what a deny
rule names stays denied [A3]. **Locking** a rule is immediate, with a toast, unless it would put
repository rules out of force; then a `sm` modal lists them (pf2).

**[A1]** Members see everything and edit rules and credentials; what concerns a **mode** or a
**lock** is an owner's. The page does not grey itself out for them: the mode cards and locks keep
their look and say who can change them.

### pe2. Repositories (`/:org/:workspace/policy/targets`)

Summary line ("4 repositories have posted runs · 2 with rules of their own · 1 sets its own mode
· 1 with suggestions" [A1]), then one table: **Repository** (forge faint, path 500, mono; the row
link) · **Mode** [A1] (the effective mode as a word in 500, then a source chip:
**Workspace default**, neutral, or **Its own**, the bordered `base-100` chip of "This
repository"; two wordings and two chip styles, no status hue) · **Policy**
(`<.source_chip>`-style chip: "Own rules" or "Workspace baseline") · Own rules · Overrides
· Suggestions (an info chip "2 to review", or 0 in faint) · Version (mono, `v10` and the
short digest) · Last change. Sorted: suggestions first, then the most recent change.
Phones: rows reflow to the name, the mode with its source, the chip and the suggestion
chip. Footnote in pf.

### pe3. Repository policy (`/:org/:workspace/policy/targets/:target_id`)

```
Policy › Repositories › github.example/acme/shop
github.example/acme/shop                                  [v10 | sha256 c41d7e02b9a6 | ⧉] [↥ Export]
What runs of this repository may reach: the workspace's rules, then this repository's own. Where the
two meet on a host, the repository wins, unless the workspace's rule is locked.

[ Effective policy 10 ]  History 10   Document   Runs 5   Connections
+ Mode  [Follow the workspace | Observe | Enforce]  In effect: enforce, the workspace's default. …  [A1] +
+ Declared by the harness  2 to review ------------------------------------ [Allow both here] +
| Hosts the runtime says it needs, from the policy applied event of this repository's last 5  |
| runs. A declaration allows nothing by itself.                                               |
| [⦸] flags.example           Declared by claude in 5 runs. Denied 9 times, …  [Allow here|v] |
| [⦸] downloads.runtime.example  Declared by claude in 5 runs. No run has tried…  [Allow here|v] |
| 2 more declared hosts are already allowed: api.example by the workspace, mcp.acme.example by …   |
+---------------------------------------------------------------------------------------------+
+ Effective policy  10 rules · 7 hosts allowed --- [All | From the workspace 6 | This repository 4 | Overrides 2] +
| [Allow|Deny] [ mcp.acme.example ] [ Every path, or /v1/* /health ] [Add for this repository] |
| Rule                    Paths            Comes from          Last 7 days                     |
| [⊘] *.paste.example  every path       [🔒 Workspace, locked]   3 denied               Open     |
|     | 🔒 Holds against this repository's rule  ~allow bin.paste.example~  dana · 28 Aug. …|
| [✓] github.example      every path       [🔒 Workspace, locked]   41 allowed             Open     |
| [⊘] gitlab.example      every path       [This repository]   not seen               Restore  |
|     | Overrides the workspace's rule  ~allow gitlab.example~  Disabled here by dana · 9 Sep. …    |
| [⊘] telemetry.example   every path       [Workspace]              not seen               Allow here|
| [✓] mcp.acme.example    [/mcp/*][/health][This repository]   46 allowed             Remove   |
| [✓] files.cdn.example (New in v10)       [This repository]   3 denied before it     Remove   |
| [✓] registry.example    every path       [Workspace]              65 allowed             Disable here|
| Mode enforce, the workspace's default. Credentials: model-key from the workspace, forge-token …  [A1] |
+---------------------------------------------------------------------------------------------+
```

`<h1>` is the repository in mono, forge faint. The header's count is what is in force: "10 rules ·
7 hosts allowed" (the second number is the length of the rendered `allow`). "Overrides" filters to
the rows that have a beaten rule under them. A repository without rules of its own shows the same
page: every row comes from the workspace, the pill reads the baseline's version with the
sub value "workspace baseline", and an info notice sits above the list: "This repository
has no rules of its own. It is served the workspace baseline, version 14. The first rule
added here, or a mode of its own, gives it versions of its own." [A1] **[A1] Mode.**
`<.repository_mode>` (pd2a) sits first, above the suggestions. Its two confirms are this
repository's own:

- **To enforce** (from observe, its own or followed): a `lg` modal "Enforce
  `github.example/acme/tax-service`", the consequence sentence (pf1), then the same bordered list
  as the workspace's confirm, counted from **this repository's** recorded connections that
  today's effective rules still do not cover, each row with **Allow here** (a repository
  rule). ~~A destination a locked workspace deny covers has no button: it reads a padlock
  and "Locked deny", with the lock's tooltip.~~ [A3] A destination a deny covers is denied
  in either mode already, so enforcing would not start denying it: it is not in the list.
  Footer: Cancel (initial focus), **Enforce this repository** (primary).
- **To observe**: a `sm` modal "Observe `github.example/acme/shop`" with the danger button
  **Observe this repository**; its second paragraph names the locked denies that stay denied
  [A3].
- **To follow the workspace**: the confirm of whichever of the two it amounts to, with the
  sentence "The mode follows the workspace's default from now on, and changes when it
  does." in place of "becomes this repository's own". No confirm when what is in effect
  stays the same.

**A locked workspace deny in a repository that observes [A3].** The row stays in the list
exactly as it is (deny mark, "Workspace, locked", its beaten rule under it): the rule is
in the document's deny list, the hosts it covers are not in the allow list, and under
observe it is the only thing denied: runs are denied those hosts and the record says "Rule
`*.paste.example`", as under enforce. The mode card's notice says this in full (pf1), and
the row's "Last 7 days" reads "2 denied" as any deny row does. A run recorded before the
deny existed was let through, and its row says so; the count is what the record says.

The card's **footer** keeps the mode as a read-only summary of the control, "Mode **enforce**, the
workspace's default." or "Mode **observe**, this repository's own.", so the list can be
read without scrolling back up.

Credentials live in the footer sentence with the link "Edit credentials", which opens the
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
| Rendered        | Changed by       | Change                    | Mode [A1]            | ~Digest~  | Runs under it |
| Today, 14:02:54 | dana@example.com | Allowed files.cdn.example | enforce              | sha256=…  | 1 run · …     |
|                 |                  |                           | the workspace's default   |           |               |
+-----------------+------------------+---------------------------+----------------------+--------------------------+
[Changes from v9 | Document | As served]              Compare with [v9 · 9f86d081884c ⌄]    + Versions 10 ---+
+ run-configuration.json · v9 → v10 · 1 line added ---------------- [Copy document] +        | v10 Allowed files… |
|    "allow": [                                                                     |        | v9  Workspace switched… |
| +    "files.cdn.example",                                                         |        | v8  Allowed mcp.…  |
|  …                                                                                |        | 6 earlier versions |
+-----------------------------------------------------------------------------------+        +--------------------+
```

**[A1]** The strip's **Mode** cell reads the document's `egress.mode` and, as the sub value, where
it came from when this version was rendered: "the workspace's default" or "this
repository's own" (a workspace baseline version reads "the workspace's default" always).
It is the version's fact, not today's setting.

The state badge is success **In force**, or neutral **Superseded** with the sub line "by v11 after
2 d 4 h". The three views are a segmented control in the URL: the diff against the compared version
(default), the document indented, and **As served**: the exact bytes, unwrapped, in one scrolling
line, with the caption "388 bytes · sha256 over exactly these". "Copy document" copies the served
bytes in every view. The side list holds the last few versions with their change and author, the
current one on `primary-soft`; a version re-rendered by a workspace change carries the
chip **workspace**.

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
three and "and 2 more", the version link, the offset. **[A3]** The head reads "· denies 2 hosts"
after the allowed count when the deny list holds anything, and the delta gains a chip per host
that came into the deny list (`+ ⊘ tracker.example`, error-soft, the deny mark) or left it
(`− ⊘ tracker.example`, neutral, struck through), at most three a side and counted with the rest. Its body is one muted sentence: "The runner
fetched a new run configuration after the server's answer named a new digest. Compared with the
policy applied at `#0003`: 1 host added, none removed. Connections before this item were decided by
v9." The delta is computed from the `allow` and `deny` lists [A3] of the two events, which are in
the record; it is not read from the policy tables; the sentence ends "; denies 1 host more and none
fewer." when the deny list changed. A reload that changed only the mode reads "reloaded · **observe**
(was enforce) · 7 hosts allowed". Announcement: "The run reloaded its policy: version 10."

### pe7. Empty, loading, error and refusal states

| Where | State | What renders |
|---|---|---|
| Workspace rules | new workspace [A1] | the mode switch with Observe checked, badge "Workspace default", fact "Not served yet: it applies from the first change here."; pill "No version yet"; no sidebar tag; `<.empty_state icon="hero-shield-check">` **Qory serves no policy yet** "Until the first change here, every machine of this workspace runs under its own policy, the one in its runner file. The first rule you add, or a mode you set, renders version 1, and machines take their policy from Qory from then on. You can also let a run reach out first and allow its hosts from the Connections page, one row at a time." `[Add a host rule]` primary (reveals and focuses the composer) `[Go to connections]` default; footnote on the first version (pf2). A member reads "The first rule you add, or a mode an owner sets, …" |
| Workspace rules | filter matches nothing | inside the card, a one-line row in faint: "No locked rules." / "No deny rules." |
| Credentials | none | one faint row: "No credentials. A run that needs none runs without." |
| Repositories | none has posted | neutral empty state **No repositories yet** "A repository appears here once a run names it with its forge and repository labels." |
| Repository | not in this workspace | neutral empty state, `heading="h1"` **This repository is not in this workspace** `[Back to policy]` |
| Repository | no own rules | the info notice of pe3 |
| Suggestions | harness declared nothing, or all covered | the card is absent |
| History | no change yet [A1] | "No changes yet. Qory serves no policy for this workspace until the first one." |
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
| Page title, description [A3] | **Policy** / What the runs of this workspace may reach through the runner's proxy. What no rule names is denied under enforce, and let through and recorded under observe; a deny rule holds in either mode. |
| Repository description | What runs of this repository may reach: the workspace's rules, then this repository's own. Where the two meet on a host, the repository wins, unless the workspace's rule is locked. |
| Observe [A3] | Records every connection and denies only what a deny rule names. A host no rule names is let through, and the record says so. |
| Enforce | Denies a connection no rule allows, and records the denial. With no allow rule, a run reaches nothing. |
| Badge on the checked card [A1] | Workspace default |
| Fact, enforce is the default [A1] | In the last 7 days it denied **12** attempts to **3** destinations, in the 3 repositories that follow it. `See them` (to `/:org/:workspace/connections?decision=denied`). With every repository following: "… destinations." and no tail |
| Fact, observe is the default [A1] | In the last 7 days **14** attempts to **2** destinations had no rule, in the 3 repositories that follow it. Enforce would deny them. `See them` |
| Fact, new workspace [A1] | Not served yet: it applies from the first change here. |
| Fact, nothing recorded | No run has reached out in the last 7 days. |
| Under the cards [A1] | This is the workspace's default. A repository follows it unless an owner sets a mode of its own: `1 of 4 repositories does`, and observes. A wall's own refusals (the machine's address, a path that reads two ways) hold in either mode. The link goes to `/:org/:workspace/policy/targets?mode=own`. None: "… of its own. None does." Several with different modes: "`2 of 4 repositories do`: 1 observes, 1 enforces." A member's line adds "Only an owner sets a mode." |
| Confirm, default to enforce [A1] | **Set the workspace's default to enforce** / From the next heartbeat, about 30 s, **a connection no rule allows is denied** in the 3 repositories that follow the workspace's default, and in their 2 runs alive now. `github.example/acme/tax-service` sets its own mode and does not change. You can switch back at any time. / list head "Let through in the last 7 days with no rule matching, in those repositories" · "3 destinations" / "Counted from recorded connections that today's rules still do not cover. Enforce will deny these. A destination no run has reached yet is not in this list." / `[Cancel]` `[Set the default to enforce]` |
| Confirm, default to observe [A1] [A3] | **Set the workspace's default to observe** / From the next heartbeat, about 30 s, **only what a deny rule names is denied** in the 3 repositories that follow the workspace's default, and in their 2 runs alive now: every other connection is let through and recorded. A repository that sets its own mode does not change. The rules stay as they are, locked ones too: a deny holds in either mode. / `[Cancel]` `[Set the default to observe]` |
| Toasts [A1] | The workspace's default is enforce. 3 repositories follow it. Version 15. / The workspace's default is observe. 3 repositories follow it. Version 15. |
| Repository mode, the radios [A1] | Follow the workspace · Observe · Enforce |
| In effect, following [A1] | In effect: **enforce**, the workspace's default. It changes when the workspace's does. |
| In effect, own [A1] | In effect: **observe**, this repository's own. The workspace's default is enforce. |
| In effect, member [A1] | … Only an owner sets a mode. |
| Note, observing with a locked deny [A1] [A3] | **This repository observes: the locked deny still holds.** The locked deny `*.paste.example` is denied in either mode, and under observe it is the only thing denied here: every other host is let through and recorded. It holds whatever mode this repository is in. |
| Confirm, repository to enforce [A1] | **Enforce `github.example/acme/tax-service`** / From the next heartbeat, about 30 s, **a connection no rule allows is denied** in this repository's runs, 1 of them alive now. The mode becomes this repository's own: it stays enforce whatever the workspace's default becomes. Other repositories do not change. / list head "Let through in this repository's runs, last 7 days, with no rule matching" · "2 destinations" · row button `Allow here` · locked row "Locked deny" / "Counted from this repository's recorded connections that today's rules still do not cover. Enforce will deny these. A destination no run has reached yet is not in this list." / `[Cancel]` `[Enforce this repository]` |
| Confirm, repository to observe [A1] [A3] | **Observe `github.example/acme/shop`** / From the next heartbeat, about 30 s, **only what a deny rule names is denied in this repository's runs**, 1 of them alive now: every other connection is let through and recorded. The mode becomes this repository's own; the workspace's default stays enforce and other repositories do not change. / The rules stay as they are, locked ones too. A deny holds in either mode: `*.paste.example` stays denied in this repository. / `[Cancel]` `[Observe this repository]` danger |
| Confirm, back to the workspace [A1] | the same two, with "The mode follows the workspace's default from now on, and changes when it does." in place of the "becomes this repository's own" sentence, and the buttons `[Follow the workspace]` |
| Toasts, repository [A1] | github.example/acme/shop observes on its own. Version 11. / github.example/acme/shop enforces on its own. Nothing changes today: the workspace's default is enforce too. / github.example/acme/shop follows the workspace: enforce. Version 12. |

"and in their 2 runs alive now" / "1 of them alive now" is left out at zero.

### pf2. Rules, locks, credentials

| Where | Text |
|---|---|
| Composer hint | A host name in lower case, or `*.` and a suffix for every host below it. No scheme, no port. Paths go in their own field, separated by spaces. |
| Reads as, host | Reads as: **allow `api.example`**, on every path. |
| Reads as, suffix | Reads as: **allow every host below `internal.example`**, on every path. It does not allow `internal.example` itself. |
| Reads as, paths | Reads as: **allow `api.example` on 2 paths**: everything below `/v1/`, and `/health` exactly. Behind a wall the proxy reads requests to this host to check the path. |
| Reads as, deny | Reads as: **deny `telemetry.example`**. It takes the host out of what the workspace allows; a repository can still allow it unless you lock this rule. |
| Reads as, deny suffix | Reads as: **deny every host below `paste.example`**, and every allow rule it covers. |
| Note, covered | Already allowed by `*.internal.example`. Adding it changes nothing today and keeps the host allowed if the suffix rule is removed. |
| Card footer [A3] | Locked rules come first, then deny, then allow, each by host read from the right, so a suffix sits beside the hosts below it. A deny is written to the document's deny list, which a runner decides first and in either mode, and takes the allowed hosts it covers out of its allow list. |
| Wildcard tooltip | Every host below github.example, and not github.example itself. |
| Lock tooltips | Lock: hold this rule against every repository / Locked: no repository can override it. Select to unlock. / Locked by beekeeper@example.com on 2 Sep 2026. Only an owner can change or unlock it. |
| Lock confirm | **Lock the deny rule `telemetry.example`** / A locked rule holds against every repository. **1 repository rule stops being in force**: … / The repository's rule is kept and shown as held. Only an owner can unlock. / `[Cancel]` `[Lock the rule]` |
| Remove confirm (only when a workspace rule that repositories override or that is locked) | **Remove the allow rule `gitlab.example`** / 1 repository disables this rule; its own rule then has nothing to override and is kept. This takes effect within a heartbeat. / `[Cancel]` `[Remove the rule]` danger |
| Toasts (no Undo in M5 [A1]; a dismiss X; the row's Change to deny / allow [A4] gives the same toast as the composer) | `files.cdn.example` is allowed for the workspace. Version 15. / `gitlab.example` is denied for github.example/acme/shop. Version 11. / `api.example` is locked. No repository can override it. / ~~`telemetry.example` is denied for the workspace. No new version: the document did not list it.~~ [A3] a deny always changes the document / The rule `errors.example` is removed. Version 14. |
| Credentials description | Credentials a run may use, by name. The policy names one; it never holds one. Each machine defines its credentials in its runner file, and a name a machine does not define is no run. |
| Credential fields | Name, such as forge-token / Argument (optional), such as acme/shop / `[Add credential]` |
| Repositories footnote [A1] | A repository appears here once a run names it. A repository with neither rules nor a mode of its own is served the workspace baseline, and so is a run that names no repository. |
| First version footnote [A1] | Version 1 is rendered by the first change, never by a machine asking. Until it exists, a machine that asks is told there is no policy here and keeps its own. |

### pf3. Validation, in the contract's grammar

| Input | Sentence |
|---|---|
| a URL, a port, a path, or capitals | A rule names a host and nothing else: lower case, no scheme, no port, no path. `Use api.example with the path /v1/messages` |
| `*` anywhere but the lead, or `*` alone | `*.` may only lead a host: `*.example` matches every host below `example`. |
| an empty or over-long label, a leading or trailing dash, an underscore | Each part of a host is 1 to 63 letters, digits or dashes, and does not start or end with a dash. |
| an IP address with a port, brackets, or `/` | An address is written like a host, digits and dots only: `10.0.0.12`. The wall refuses the machine's own address whatever the policy says. |
| a bad path | A path starts with / and may end in one *; no other wildcard and no query, such as `/v1/*`. |
| the same rule again | `registry.example` is already allowed for the workspace, by beekeeper on 2 Sep. `Show it` |
| the opposite rule exists in this scope | `gitlab.example` is allowed for the workspace. Adding this deny replaces that rule. (kind: note; the button reads "Replace with deny") |
| a bad credential name | A name is 1 to 64 lower-case letters, digits, dots, dashes or underscores, and starts with a letter or digit. |
| an argument over 256 characters | An argument is at most 256 characters. |

### pf4. Refusals

| Case | Sentence |
|---|---|
| ~~an exact-host deny under an allowed `*.` suffix~~ [A3] | No refusal: the deny is accepted and written to the deny list. The reading line says "Reads as: **deny `files.cdn.example`**. It takes the host out of what the workspace allows; a repository can still allow it unless you lock this rule. It is denied in either mode, observe too. `*.cdn.example` still allows the other hosts below it." |
| the same, on a repository page, where the workspace's suffix is **locked** [A3] | the locked-allow refusal below: A locked workspace rule allows `*.cdn.example`. It holds against every repository, so a deny added here would change nothing. … |
| a locked deny, member | A locked workspace rule denies `*.paste.example`. It holds against every repository, so no rule added here would change what happens. Locked by beekeeper@example.com on 2 Sep 2026. Only an owner can change or unlock it. |
| a locked deny, owner | … on 2 Sep 2026. You can change or unlock it on the workspace's policy page. |
| a locked allow, on Deny | A locked workspace rule allows `github.example`. It holds against every repository, so a deny added here would change nothing. … |
| a member on a lock | Only an owner can lock, unlock or change a locked rule. |
| the render fails the schema | **The rule was not saved.** With it the rendered document would not pass the runner's policy schema, so nothing was changed and version 14 stays in force. The server log has the reason. |
| a concurrent write | **Someone changed the policy while you were editing.** beekeeper@example.com removed `registry.example` 4 s ago. The list below is current; add your rule again if it still applies. |

### pf5. Provenance and suggestions

| Where | Text |
|---|---|
| Override line | **Overrides the workspace's rule** ~~allow gitlab.example~~ Disabled here by dana · 9 Sep. Other repositories keep it. |
| Override line, repository allows what the workspace denies | **Overrides the workspace's rule** ~~deny telemetry.example~~ Allowed here by dana · 9 Sep. |
| Lock line | **Holds against this repository's rule** ~~allow bin.paste.example~~ dana · 28 Aug. It is not in force. `Remove it` |
| Row actions | Disable here / Allow here / Remove / Restore / Open |
| Card footer [A1] | Mode **enforce**, the workspace's default. (or "Mode **observe**, this repository's own.") Credentials: `model-key` from the workspace, `forge-token` argument `acme/shop` from this repository. `Edit credentials` |
| Suggestions description | Hosts the runtime says it needs, from the policy applied event of this repository's last 5 runs. A declaration allows nothing by itself. |
| Suggestion, denied | Declared by **claude** in 5 runs. **Denied 9 times**, last 2 minutes ago. |
| Suggestion, let through (observe) | Declared by **claude** in 5 runs. Let through 9 times with no rule. |
| Suggestion, never reached | Declared by **claude** in 5 runs. No run has tried to reach it. |
| Suggestion, locked | A locked workspace rule denies `*.paste.example`. Only an owner can change it. |
| Suggestion footer | 2 more declared hosts are already allowed: `api.example` by the workspace, `mcp.acme.example` by this repository. |
| After one click [A1] | ✓ Allowed here |

### pf6. History sentences

Subject is the author's email in 500; rules are mono chips. Built from `policy_changes.action`.

| Action | Sentence |
|---|---|
| rule added | **dana@example.com** allowed `files.cdn.example` / denied `telemetry.example` |
| rule removed | … removed the allow rule `errors.example` |
| paths changed | … changed the paths of `api.example` from every path to `/v1/*` |
| replaced | … replaced allow `gitlab.example` with deny |
| locked, unlocked | … locked `github.example` / unlocked `github.example` |
| default mode [A1] | … switched the workspace's default mode from observe to **enforce** |
| repository mode, own [A1] | … set this repository's mode to **observe** · second line "Its own from now on. It followed the workspace's default, enforce." |
| repository mode, no effect [A1] | … set this repository's mode to **enforce** · "Its own from now on. The workspace's default is enforce too, so the document did not change." · "no new version" |
| repository mode, follow [A1] | … set this repository to **follow the workspace** · "It observed on its own. The workspace's default is enforce." |
| on the workspace's Repositories-wide reading [A1] | where a repository's change is quoted outside its own history (a diff bar, a toast), "this repository" becomes its name: "set the mode of `github.example/acme/tax-service` to observe" |
| credential | … added the credential `model-key` / removed the credential `forge-token` `acme/shop` |
| origin line | From a connection row of run `0191d2aa` / From a suggestion / From the enforce confirm |
| no version line | The lock holds against repositories. The document did not change. |
| version cell | the pill, or "no new version" |
| diff bar | 1 line changed · re-rendered 2 repositories with rules of their own |
| diff bar, default mode [A1] | 1 line changed · re-rendered 1 repository that follows the default; 1 sets its own mode and did not change |
| footer | Showing 6 of 16. A change to the default mode re-renders every repository that follows it. A change that leaves the document's bytes the same is kept here and makes no new version. Changes to a repository's own rules are in that repository's history. |

### pf7. Connection row

| Where | Text |
|---|---|
| Next, run alive | Takes effect in running sessions within a heartbeat, about 30 s. This run is alive: its next attempt can succeed. |
| Next, run ended or workspace page | Takes effect in running sessions within a heartbeat, about 30 s. |
| Next, deny | Takes effect in running sessions within a heartbeat, about 30 s. Open connections to the host are closed at the reload. |
| Next, allow, the run's policy observes [A1] | This run's policy observes, so the connection is already let through. The rule changes what the record says from the next heartbeat, about 30 s, and what happens once the repository enforces. |
| Next, deny, the run's policy observes [A1] [A3] | the same as "Next, deny": a deny holds in either mode. Takes effect in running sessions within a heartbeat, about 30 s. Open connections to the host are closed at the reload. |
| Next, workspace page, "The whole workspace" chosen [A1] [A3] | Takes effect in running sessions within a heartbeat, about 30 s. |
| After line under observe [A1] | the same three badges; the sentence ends "… The run's policy observes: it was let through before, and is allowed by a rule from the reload." |
| Footnote, run connections (replaces the last sentence of M4's) | … A rule added here changes what happens next; what the record already says stays as it was. |
| Toast [A1] | `files.cdn.example` is allowed for github.example/acme/shop. / Version 10. Running sessions have it within a heartbeat. (no Undo) |

**[A1] One rule for every mode word near a run.** The reason sentences of `brief-runs.md`
rf ("Enforce mode denies it.", "Observe mode lets it through.") are built from the `mode`
field of the egress event; the run header, the connections summary ("policy **enforce**
`v9`") and the timeline's policy items from the `mode` of `policy_applied`. None may read
the workspace's default or the repository's setting. On `/:org/:workspace/connections` a
destination's reason is the last attempt's, so two repositories in different modes can
give "Observe mode lets it through. · last attempt" on a row that also has denials; the
sub-row's runs each carry their own counts, which is where the difference is read.

"about 30 s" is the run's `heartbeat_interval_seconds` on a run page and the contract's default on
the workspace pages.

### pf8. Version and export

| Where | Text |
|---|---|
| Caption | Shown indented for reading. "As served" is the exact bytes, 388 of them, that the digest is taken over. Deny rules and locks are not in the document: they decide what it lists. |
| Mode cell [A1] | enforce · "the workspace's default" / observe · "this repository's own" |
| Runs under it | `1 run` · 1 alive is behind, on v9 / No run has reported this version. |
| Export lead | The effective policy of **github.example/acme/shop** as of **version 10**, as the file a runner takes with `--policy`. It is a copy: it does not follow later changes. |
| Export caveats | Keep the file outside the checkout. A policy file only narrows what the machine's runner file allows, and it names credentials the machine must define. Deny rules and locks are already applied: the file lists what remains allowed. |

### pf9. Term hovers added

| Term | Tooltip |
|---|---|
| digest | The sha256 of the exact bytes a runner is served. Two runs with the same digest had the same policy. |
| workspace baseline | The workspace's rules with no repository's own: what a repository without rules, or a run that names none, is served. |
| locked | A workspace rule no repository can override. Only an owner can lock or unlock. |
| workspace default [A1] | The mode a repository runs under unless an owner sets one for it. |
| its own [A1] | An owner set this repository's mode. It no longer changes with the workspace's default. |
| harness | The runtime's own needs: hosts it declares in the policy applied event. Declared hosts are reported, never allowed by that. |

Announcements (one polite region per page): "Rule added. Version 15." "Rule removed. Version 15."
"The workspace's default is enforce." "This repository observes on its own." "This
repository follows the workspace: enforce." [A1] "files.cdn.example is allowed for this
repository." "The run reloaded its policy: version 10." "This run is behind the policy in
force."

---

## pg. Motion

| What | Behaviour | Reduced motion |
|---|---|---|
| Mode cards, source chips, rows, tabs | 120 ms colour, as `brief.md` | 0 |
| Repository mode radios [A1] | 120 ms colour on the pressed cell; the "In effect" sentence swaps at once; the observe note appears and leaves with no height animation (it sits at the card's end, nothing below jumps more than the note's height once) | same |
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

**[A1] The mode controls.** Both are radio groups with names. Workspace:
`role="radiogroup" aria-label="Default mode"`; each card `role="radio"`, named by its
heading, described by its sentence and the fact line. Repository: `role="radiogroup"`
labelled by the heading "Mode"; radios named "Follow the workspace", "Observe", "Enforce";
the group is `aria-describedby` the "In effect" sentence, so a screen reader hears "Mode,
radio group, Follow the workspace, selected, 1 of 3. In effect: enforce, the workspace's
default." One tab stop each, roving `tabindex`, arrows move the focus **without**
selecting (selection asks a confirm, so it is never a side effect of an arrow key); Space
or Enter chooses. After a confirm, focus lands on the radio now checked; after Cancel, on
the radio that was checked. For a member the group is `aria-disabled="true"`, stays
focusable so the sentence can be read, and "Only an owner sets a mode." is part of the
description. The source is a word in every place ("Workspace default", "Its own"); the
chip's border is the second carrier, never the only one. The observe note is
`role="note"`, not an alert: it is a standing fact.

**Keyboard path, repository.** … tabs → **mode radiogroup** → suggestions → filter segments →
composer → table.

**Keyboard path, workspace rules.** Skip link → sidebar → version pill → Export → tabs →
mode radiogroup (one tab stop; arrows move, Space or Enter asks) → filter segments →
composer (action segments, host, paths, Add rule) → table region → per row: lock toggle,
`⋯` menu → credentials. A rule's host is not a tab stop unless it carries the wildcard
tooltip. Shortcuts, inactive while a field has focus: `a` focuses the composer's host
field, `/` the History filter, `?` lists them.

**Focus after actions.** Add rule: the host field, cleared; the new row is announced by the polite
region, not focused. Remove: the next row's actions, or the composer when the table empties. Lock
toggle: stays on the toggle. One-click allow in suggestions: the next suggestion's **Allow here**, or the composer's host field after the last one [A1]. Popover
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
rule row reads "Deny, star dot paste.example, every path, Workspace, locked, 3 denied in
the last 7 days". The popover is a `dialog` labelled by its title; radios are grouped in
`fieldset`s with legends "What" and "For". The locked slot button's name is the sentence
of its tooltip. Tables keep explicit roles where the phone layout changes their display.

**Targets.** 24 px row buttons get `min-h-10 min-w-10` hit areas under `@media (pointer: coarse)`;
on phones every button in a composer, popover sheet and modal is 40 px.

**Reflow.** At 320 px and 200 % zoom nothing scrolls sideways at page level: code and diff wells,
the As served line and the tabs scroll inside themselves.

---

## pi. Phone layout (below 768 px)

Header: title and description, then the version pill full width, then Export full width (40 px).
Tabs scroll sideways. Mode cards stack. **[A1]** The repository's mode card stacks too: heading,
then the three radios as equal 36 px cells across the full width, then the sentence, then the note.
The repositories list keeps the mode and its source on the row's second line. The composer stacks: action segments, host, paths, button,
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
2. **One subscription.** Every policy page subscribes to `policy:<workspace>` and re-reads
   `effective/2` (or `list_rules/2`) once per message, coalesced to one read per 250 ms. The
   sidebar's mode word rides the same topic.
3. **The list is small, the counts are not.** Rules are bounded (a workspace has tens, not
   thousands): render them all, no pagination, no stream windowing. "Last 7 days" is one
   grouped query over `connections` by `rule` for the scope, in `assign_async`, cached for
   60 s per workspace and repository. The column renders "…" skeleton cells until it lands
   and is dropped on failure.
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
7a. **[A1] Modes cost one read.** The repositories list reads each repository's setting with the
   list's own query (no query per row); the sidebar's `:own_modes` is one count, cached with the
   mode and refreshed on `policy:<workspace>`. A repository's enforce confirm runs its
   bounded query when the modal opens, scoped to that repository. A change of the default
   re-renders only the repositories that follow it; the toast's "3 repositories follow it"
   is the number re-rendered.
8. **Drift is a comparison, not a poll.** The run page holds `policy_digest_reported` and reads
   `policy_digest_in_force` at mount and on each `policy:<workspace>` message; the mark is
   the inequality while the run is alive. No timer decides it.
9. **Bound everything from a runner.** Hosts from `harness_hosts` are validated by the host
   pattern before display, truncated in the middle past 48 characters, at most 50 suggestions.

---

## pk. Done checklist

Navigation and URLs
- [ ] [A1] Sidebar tag is the workspace's default, with "· n own" when repositories set
  their own; absent on a new workspace
- [ ] Sidebar item Policy with the mode word; `nav={:policy}` on every page below
  `/:org/:workspace/policy`
- [ ] Tabs, filters, the opened change, the compared version and the export modal are in the URL; a copied URL reproduces the view
- [ ] Repository policy under `/:org/:workspace/policy/targets/:id`; reachable from the
  run header, a row's Rule button, the connections page with `target`, the runs list group
  header, the Repositories tab

Rules
- [ ] [A1] Workspace mode cards set the **default**: badge "Workspace default", the line
  under them counts and links the repositories with their own mode, confirms scoped to the
  repositories that follow
- [ ] [A1] Repository mode: Follow the workspace · Observe · Enforce, the "In effect"
  sentence with its source, this repository's two confirms, no confirm when nothing
  changes in effect, the footer summary
- [ ] [A1] [A3] A locked workspace deny in an observing repository: the row stays, the
  note says the lock holds and is the only thing denied, the counts read as any deny row's
- [ ] [A1] Modes are an owner's: members see both controls read-only with "Only an owner sets a mode."
- [ ] [A1] Repositories list has the Mode column (effective mode and "Workspace default" /
  "Its own")
- [ ] [A1] Version strip shows Mode and where it came from; history reads a repository's mode change as a sentence
- [ ] [A1] Every mode word near a run comes from that run's events, never from the
  workspace
- [ ] [A1] New workspace: "Qory serves no policy yet", no version, no sidebar tag; no
  Dismiss on suggestions; no Undo in any toast
- [ ] Mode switch asks before either change; the enforce confirm lists what would be denied, from the record, with one-click allow; no estimate when it cannot be counted
- [ ] Composer validates in the contract's grammar as you type, reads the rule back, repairs a pasted URL, and accepts the exact-host deny under an allowed suffix, saying the suffix still allows the rest [A3]
- [ ] Workspace list: mark, wildcard, paths, last 7 days, added, lock; owners toggle
  locks, members read them
- [ ] Repository list: one list, source chip per row, beaten rules struck under their winner, Disable here / Allow here / Remove / Restore / Open
- [ ] Suggestions from `harness_hosts` with one-click allow and the locked case (no dismiss, no undo [A1])
- [ ] Credentials by name with an optional argument; never a value

Versions
- [ ] Version pill on both policy pages; "No version yet" on a new workspace
- [ ] History: every change with who, when, origin and the version it made or "no new version"; the diff in rules and in document lines
- [ ] Version page: changes, document, as served; compare with any version; copy copies the served bytes
- [ ] Export as YAML for `--policy`, copy and download, with the caveats

Connections and runs
- [ ] Slot buttons always visible: Allow, Deny, the padlock, nothing for the wall, Rule after
- [ ] Popover: path choice only when the host has path rules; repository is the default scope on a run page; no default among several repositories; the heartbeat sentence; bottom sheet on phones
- [ ] The row after: unchanged record plus the after line; "In force in this run" only when the run reported the new digest
- [ ] Run header: version link to the exact version; "Behind v10" only while alive and unequal; the notice; never on an ended run
- [ ] Timeline: "Policy applied again" with the delta from the two events, deny chips included [A3]
- [ ] [A3] Every sentence about observe says "denies only what a deny rule names"; none says observe denies nothing
- [ ] [A3] `mix apiary.policy.rerender` renders the versions in force again once after the upgrade; unchanged bytes write nothing

Quality
- [ ] Both themes, at 1440, 1024, 768, 375; no page-level horizontal scroll at 320
- [ ] Keyboard-only pass: add, lock, disable, allow from a row, switch mode, open a diff, export
- [ ] VoiceOver pass: the reading line speaks once per pause, a refusal is an alert, a struck rule is "not in force"
- [ ] A member never sees a control that would be refused, except the composer, whose refusal is the explanation
- [ ] Synthetic sample data only; no customer, engagement or person named; no AI attribution; British spelling

---

## pl. Open questions for the coordinator

1. **A repository path added from a row.** A repository rule on a host beats the
   workspace's unlocked rule on the same host, so "allow this path for this repository"
   must be written as the paths in force plus the new one, or it would silently drop
   `/v1/*`. The design assumes `rule_from_connection/4` merges. Confirm, or the popover
   must say "replaces the workspace's paths".
2. ~~**A narrower suffix under a broader allowed suffix** cannot be said either.~~ **Closed
   [A3]:** both are said by `egress.deny`; neither is refused.
3. **What "would have been denied" is counted from.** The enforce confirm and the observe fact line
   want recorded connections that *today's* rules do not cover (a function such as
   `Policy.uncovered(scope, since)`), which is not in the domain API yet. The fallback is the
   record's own field (allowed with an empty `rule`), which still lists hosts allowed since; the
   design hides the list rather than show that.
4. **"Last 7 days" per rule** needs `connections` grouped by `rule` per scope. If it is too costly
   for M5, the column is dropped, not faked; the page works without it.
5. ~~Dismissed suggestions.~~ **Closed [A1]:** no Dismiss in M5.
6. **Export form.** The design exports a YAML policy file for `qory run --policy` (S7 says "the
   runner file's inline document"). If an `egress:` block for `runner.yaml` is wanted as well, it
   is a second segment in the same modal ("Policy file | Runner file section"); the credentials
   cannot go in that one, since there they are definitions, not names.
7. ~~Observe and locks.~~ ~~**Answered [A1]:** a locked deny is applied to the document and denies
   nothing under observe.~~ **Superseded [A3]:** a deny, locked or not, is in the document's deny
   list and holds under observe; the mode card's note and both observe confirms say so.
8. ~~Undo.~~ **Closed [A1]:** no Undo in M5; the row's **Rule** button and the list's Remove are the
   way back.
9. **The runs list group header** gains a "Policy" link and the workspace connections
   description a link; both touch M4 components owned by another builder.
10. **[A1] The domain API for modes.** The design assumes `get_mode/1` (the default),
    `set_mode/2` (owners), and for a repository something like `repository_mode(scope, repository)`
    returning `%{setting: :follow | :observe | :enforce, effective: …}` and
    `set_repository_mode/3` (owners), plus a count of repositories with their own mode and, per
    configuration version, where its mode came from at render time (for the version strip). Names
    are BACKEND's.
11. **[A1] A new workspace and the wire.** "Served no policy until the first change" has
    to be an answer the runner treats as "use your own policy" and not as "no run"; the
    contract says anything but 200 is no run. The page only promises the sentence; the
    mechanism is BACKEND's and the runner's to settle.
12. **[A1] "Let through" per rule.** Under observe the "Last 7 days" of a locked deny should read
    "2 let through", which needs the same grouped query as question 4 to tell let-through from
    denied for hosts a deny covers. If it cannot, show the count as "2 attempts".
