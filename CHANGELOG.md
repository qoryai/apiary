# Changelog

Every release of the apiary, newest first, in the shape of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0 a minor
release may change what an existing installation does, and says so under Upgrading. Every
section names the database migrations the release runs on boot, so a self-hoster knows what
a restart does before doing it (the Upgrading guide, `guides/upgrading.md`).

## [Unreleased]

### Added

- The application: Phoenix 1.8 and LiveView on Postgres, one release, one container image,
  configuration by environment, migrations on boot, `GET /health`, structured JSON logs in
  production.
- Accounts: sign-up with email, magic-link and password sign-in, confirmation, password
  reset, account settings.
- Organisations (an *apiary* on the surface) and hives (a *team*): sign-up creates one of
  each and makes the user their owner. Members are invited by email, accept through a link,
  and are owners or members; the last owner cannot be removed. Organisation and hive can be
  renamed.
- Access keys of the hive: a key id with the `ak_` prefix, a label, a secret shown once,
  rotation with two secrets that both verify until the previous one is retired, revocation,
  last used, last runner and contract version. Secrets are encrypted at rest with an
  application-held key.
- The discovery endpoint of the server contract, `GET /.well-known/qory-configuration`: a
  signed request answered with the configuration document, version 1 revision 1, section
  `events` and the document's digest in `X-Qory-Configuration`; the `run` section arrives
  with the run configuration. The rules of the wire as the apiary implements them are in
  `docs/contract-assumptions.md`.
- The events endpoint of the server contract, `POST /v1/events`: a batch signed over its raw
  body, verified before it is parsed, deduplicated on each event's id and stored as received,
  in any order; the run is created on the first event of an unknown subject, in the key's
  hive. It answers `202` before anything is projected, `410` for a run the hive has closed,
  and carries the configuration digest on both. A body over 2 MiB is `413`, an unsupported
  `X-Qory-Contract-Version` is `400`, and a key is limited to 50 batches a second, 100 at
  once (`429` with `Retry-After`). A batch holds at most 1000 events, and one that cannot be
  stored is `503`, never `500`. The ping is answered like any batch, and the key records the
  runner's versions and when its last heartbeat was received.
- The fixtures of the server contract are replayed in the tests and in CI, from the
  runner's repository at the ref in `.runner-contract-ref`: every signed request, the
  batches, and the recorded run in any order, batching and repetition.
- The projector: a run's events are folded into the run, its connections, its log and the
  hive's repositories, after the receiver has answered. Idempotent and tolerant of any order
  of arrival; `Apiary.Runs.Projector.rebuild/1` rebuilds a run's projections from its events
  alone. Changes are announced on `Apiary.PubSub` (`runs:<hive>`, `run:<hive>:<run>`).
  Values no column can hold are read as absent, and an event that still makes a projection
  fail is skipped and named in the log, so one event never blocks a run. Event data stays out
  of the query log at every level.
- Lost runs: a run that has been silent for more than three of the heartbeat intervals it
  announced (90 seconds when it announced none) is marked `lost`, whether it was running or
  still pending; a later heartbeat or its exit corrects that. Checked every 15 seconds
  (`config :apiary, Apiary.Runs.Liveness, interval: …, enabled: …`), safely on several nodes.
  Silence is measured on the server's clock alone (when a heartbeat was received, not when
  the runner says it was sent), so a runner whose clock is wrong is neither lost for it nor
  held alive by it. Before each check, and once at boot, the runs whose events were left
  unprojected for more than ten seconds are projected, at most 100 a check.
- Runs in the console's API (`Apiary.Runs`): how many runs of the hive are alive, a run by
  id, the newest runs, and closing a run, after which the receiver answers `410` for it.
- The hive overview shows "Runs alive now", live; the access keys page shows each key's last
  heartbeat beside its last use.
- The hive overview, `/hive`, is the landing page of `docs/design/brief-overview.md`: what
  needs you first (**Needs attention**: denied destinations today's rules still do not
  allow, with a one-click allow; quiet and lost runs, with a close in place; a run behind
  the policy in force; observe with rules ready to enforce, or no policy served yet; idle
  keys), then what the agents did (the activity strip in the three families, the alive
  rows, a fourteen-day chart of runs and denied attempts per UTC day with a table twin, the
  last runs), then the policy, the access keys (each with the hosts its runs came from: a key is
  not a machine, a pool of ephemeral instances shares one) and retention at a glance. Every number is a count
  the hive keeps; every list is bounded and ends in a link. The page follows the hive live
  (rows patched in place, new rows appended, "1 new run" in words) and the empty hive's
  checklist reads its three steps from the record, ticking the third on the first run.
  `/hive/policy?confirm=enforce` lands on the policy page with the enforce confirm open.
- Runs are counted in three families on every surface: alive (pending, running), ended well
  (succeeded) and ended badly (failed, timed out, lost, closed). The runs list's State
  filter is grouped by them, one click per family, and its summary line counts them; the
  URL still carries the states alone.
- The projection keeps, per run, the cost its sessions reported (`runs.cost_usd`, the sum of
  `cost_usd` over the run's `session.result` events; null until a result carried one). The
  overview's strip sums it over fourteen days and says how many runs reported one.
- The size of the pseudo-terminal an interactive run ran on, as the runner at
  `.runner-contract-ref` now records it: `terminal` of `ai.qory.run.started` and each
  `ai.qory.run.resized`, a valid event of the contract, folded into `runs.terminal_cols`
  and `runs.terminal_rows` as the size the record last said. The Details tab shows it
  ("Terminal 120×40"); the timeline does not list resizes, the terminal is where they
  matter. The terminal tab replays the log at the recorded size, resize by resize: the log
  endpoint answers one size at a time (`x-qory-log-size`) and stops short of the next
  resize, and the screen keeps the recorded columns and rows, scaling its font to the box
  (or scrolling sideways on a phone) instead of refitting the columns, so a full-screen
  program replays as the screen it drew and not as stacked frames. A run on pipes, and one
  recorded before the runner reported a size, is fitted to the box as before, with the
  wrap toggle. The runner cuts a terminal chunk at 4096 bytes or a 50 ms quiet gap now,
  one redraw a chunk, instead of at every line: the apiary reads the bytes the same.
- The projection keeps, per run, the count of its denied connections, and per connection the
  mode, path rule, credential name and request method of its last attempt, ranked by
  sequence like the rest and reproduced by a rebuild. `mix apiary.rebuild`
  (`Apiary.Release.rebuild/1` in a release) projects runs again from their events, in
  batches, for the rows a release's new columns are empty on.
- The runs list, `/hive/runs`: every run of the hive with its state, what it worked on, its
  runtime, host, start, duration and denials; grouped by repository (two forges with one
  path are two groups, runs without a repository are Unassigned), by task across
  repositories, or not at all; filtered by state, repository, task, runtime, host, time
  range and "has denials", with the options counted from the data. Every filter, the
  grouping and the page are in the URL, which is validated and shareable. A running run
  whose heartbeat is overdue turns amber and its clock stops at "at least"; the server
  decides that, and only the projector and the lost-run check change a state. Live: a run
  on the page changes in place, a new one is counted ("1 new run") until the reader asks.
- The hive's connections, `/hive/connections`: one row per host, port and path across the
  runs in range, with attempts, allowed and denied, the reason and the outcome of the last
  attempt in a sentence, and the runs that reached each destination; filtered by decision,
  repository, host and time range. With a repository chosen it is the per-repository view,
  which the runs list links to.
- The run page, `/hive/runs/:run_id` (the id the runner prints): a header with everything
  `run.started`, `run.exited` and the policy applied say, the labels and whether the run is
  still heard from, and four tabs that are URLs. **Timeline**: the session read in sequence
  order, a tool call's events paired into one item with its input and its response, one
  lane per agent bracketed by the subagent's start and finish, a connection inside a call
  only when exactly one call was open ("while", never "because"), the background tasks the
  runtime last listed, and a sentence wherever the record has no session to show; it
  follows a live run, inserting at the live end and counting elsewhere, holds a window of
  at most 600 items however long the run, and has a keyboard path. **Terminal**: the raw
  bytes in xterm.js, dark in both themes, tailing, with search, wrap, download and a stream
  switch on pipes. **Connections**: one row per destination with the reason and the outcome
  of the last attempt. **Details**: the command, the policy in force, the record, and
  closing a run that went quiet, behind a confirmation.
- What the run page reads is bounded by rows, never by what a runner put in them: every
  field of an event is cut by the database before it crosses the wire (8 KB a payload,
  512 KB for "Show all", which reads one item), one item loads at most a hundred
  connections and counts the rest, a live page reads the range a projection announced and
  what the open tab shows of it rather than the run again, the static render reads the run
  row alone, the lane key shows a dozen lanes and counts the rest, and a run's connections
  come fifty to a page. A tool call whose end the record lacks stops being open when its
  turn ends, its subagent finishes, the session ends or starts again, or the run exits, and
  reads "No end recorded"; connections after that are items at their own sequence.
- A member closes only a run that has not ended (`pending`, `running`, `lost`):
  `Apiary.Runs.close_run/2` answers `{:error, :not_closable}` for a run that succeeded, failed
  or timed out, and its end stays as its events gave it.
- `GET /hive/runs/:run_id/log?after=<sequence>&limit=<chunks>&stream=<name>`: the decoded
  bytes of a run's log as `application/octet-stream`, chunked, with the last sequence sent
  in `x-qory-log-through`; `download=1` sends the whole log as an attachment. Signed-in
  members of the run's hive only; a run of another hive is not found. No log byte crosses
  the LiveView socket.
- xterm.js 6.0.0 with its fit and search add-ons is vendored under `assets/vendor/xterm`
  (MIT; versions and checksums in `assets/vendor/README.md`) and built as its own bundle,
  which only the terminal tab loads.
- The sidebar has two sections, Hive (Overview, Runs, Connections) and Manage; Runs shows
  how many runs are alive now on every page of the hive. The overview links to the runs.
- For development, `mix apiary.demo` replays the synthetic recorded runs under `priv/demo/` into a hive through the receiver's own ingest, as new runs that end now (dev and test only), and prints each run's page. The records cover a session with two subagents, a failed run, a running one, one stopped at its time limit, one that only pinged and one without labels under an observing policy.

- The security policy (`Apiary.Policy`): the hive has a mode, `observe` or `enforce`, and a
  baseline of rules; a repository has rules of its own on top, and follows the hive's mode
  unless an owner sets its own (so one repository is enforced while the hive still watches,
  or the reverse). A locked rule of the hive holds in a repository whatever its mode. A rule allows or denies a host
  (a name or a `*.` suffix, on every path or held to a list of paths) or a credential of the
  machine's by name, and never holds a credential. A deny is written to the document's
  `egress.deny`, which a runner decides first and in either mode, and takes the allow
  entries it covers out of `egress.allow`, which is how a repository disables a host of the
  hive. So under `observe` a run is denied exactly what a deny rule names, a locked deny
  included, and everything else is let through and recorded; under `enforce` a host no rule
  allows is denied as well. A deny of a host below an allowed `*.` suffix stands beside the
  allow (`*.example` allowed, `tracker.example` denied). On a conflict the repository wins,
  unless the hive's rule is locked: a locked rule holds against every repository. Members
  edit; only an owner changes the mode, and only an owner locks, unlocks, changes or removes
  a locked rule. A rule's row turns it from allow to deny and back from its menu. A list holds at most 500 rules, a rule 100 paths, and a change whose run
  configuration would be over 1 MiB, more than a runner reads, is refused. What the document
  cannot say is refused when it is written, with a sentence that says what to do instead: a
  `*.` suffix held to paths above another allowed entry.
- Run configurations: every change renders the baseline and every repository with rules of
  its own, in the same transaction, as canonical JSON validated against the contract's
  schemas (vendored under `priv/contract/`; `jsv` is a runtime dependency now). Each version
  is kept as the exact bytes served, under `sha256=` of those bytes, with who changed what
  and when; a change that renders the same bytes makes no new version. The history of the
  hive and of each repository is kept with the rules before and after, and is diffable.
  Changes are announced on `Apiary.PubSub` (`policy:<hive>`).
- Suggestions: the hosts a repository's harness declared, from its runs' policy applied
  events, that its policy neither covers nor denies. Each is shown against the record, the
  attempts to it that the repository's runs were allowed and denied in the last seven days,
  and beside the declared hosts a rule already covers, with the rule that does. Allow and deny from a connection's row:
  the host, or the path when the host is held to paths, in the repository or in the hive.
  Export of the effective policy for a node without a server: the `egress` section of
  `runner.yaml`, `deny` included, and a `--policy` file when there are paths or credentials.
- `mix apiary.policy.rerender` (in a release `bin/apiary eval
  "Apiary.Release.policy_rerender()"`): renders every managed hive's run configurations
  again through today's resolution, in the hive's lock; a target whose bytes change gets a
  new version and a `rerendered` row in its history (no change of the rules), and unchanged
  bytes write nothing, so it can be run again at any time.
- The run's timeline and Details read the `deny` list of `run.policy_applied` beside
  `allow`: "denies 2 hosts" on the policy items, "Denied hosts" in the Details, and on a
  reload a chip with the deny mark for each host that came into or left the deny list,
  bounded as the allow chips are.
- The run configuration endpoint of the server contract, `GET /v1/run-configuration`: a
  signed request answered with the stored bytes for the key's hive and the labelled
  repository, the baseline for any other, the digest in `X-Qory-Run-Configuration` and as the
  `ETag`, never a `304`, rate limited per key with the events endpoint's bucket. Nothing
  is rendered or stored by a read, on the wire or on a page: version 1 is written by the
  first change and by nothing else. A hive serves it only once somebody has made its policy (the first rule or the first change of
  mode; `Apiary.Policy.managed?/1`): from then on discovery names the `run` section for that
  hive. Until then there is no `run` section, the endpoint answers `404`, and the hive's
  machines keep the policy of their own `runner.yaml`. The discovery document and its digest
  are therefore one of two, by hive.
- Live reload: every `202` and `410` of `POST /v1/events` to a hive with a policy carries
  `X-Qory-Run-Configuration`, the digest in force for the run's repository, read after the
  commit and never rendered while answering; a run whose policy changed fetches it again
  within a heartbeat. The digest a batch reported is kept on the delivery and on the run,
  and `Apiary.Policy.digests/2` says whether a run is behind.
- What the record says about the rules (`Apiary.Policy.uncovered/2`, `denied_summary/2`,
  `rule_activity/3`): the destinations that were let through and that today's rules do not
  cover, which is what enforce would start denying; the attempts denied and their
  destinations; and per rule the attempts allowed and denied, each connection counted on the
  rule the runner would report. Read through the existing index `connections (hive_id,
  last_seen_at)`, at most 20,000 connections an answer; a hive with more in the range is
  told the count is unavailable rather than given a count of a part. No new migration.
- `mix apiary.demo` gives a hive without rules a policy to look at: a baseline, a host held
  to paths, a locked deny, a repository's overrides, several versions and a history.
- The policy pages, under **Policy** in the sidebar, which names the mode in force once the
  hive has a policy. `/hive/policy`: the mode as two cards, each change confirmed (going to
  enforce lists the destinations it would start denying, from the record, with Allow for
  the hive beside each; only an owner changes the mode); the host rules with a composer that
  checks a rule in the contract's grammar as it is typed and reads it back in words before
  it can be saved, repairs a pasted URL, takes a pasted list a line at a time, and refuses
  what the document cannot say with the ways out; per rule its paths, what the last seven
  days' connections say of it, who added it, and its lock, which owners toggle and members
  read; the credentials, by name. `/hive/policy/repositories` and
  `/hive/policy/repositories/:id`: a repository's effective policy as one list, every rule
  with where it came from (Hive; This repository; Hive, locked), a rule that lost struck
  through under the rule that beat it, Disable here, Allow here, Remove, Restore, and the
  hosts the harness declared with one-click allow. History with every change, the version
  it made or that it made none, and its diff in rules and in document lines; a page per
  version (changes from any earlier version, the document, the bytes as served, copy); the
  export as a modal at its own URL, with download. Tabs, filters, the opened change, the
  compared version and the export are in the URL. A hive nobody has changed yet says that
  its runs use each machine's own policy until the first change. The hive's mode is a
  default: a repository's page sets Follow the hive, Observe or Enforce (owners only), with
  its own confirms (enforcing lists what that repository's runs would be denied, with Allow
  here; observing names the locked denies that stop denying); the repositories list has a
  Mode column and `?mode=own`; the sidebar's tag names the default and how many
  repositories set their own.
- Allow and Deny from a connection's row, on a run's Connections tab and on
  `/hive/connections`: Allow where the last attempt was denied or let through with no rule,
  Deny where a rule allowed it, a padlock where a locked hive rule decides the host (it
  opens the reason, and for an owner where to change it), nothing where the wall refused.
  The popover asks for whom: on a run the repository first, on the hive's page a repository
  whose runs reached the destination or the whole hive, none chosen in advance; on a host
  held to paths the request's path is added to, or taken out of, the paths in force. The
  record is not rewritten: the row keeps its decision and gains a line naming the rule, its
  version and who added it, which reads "In force in this run" only once the run has
  reported the digest in force. A run that holds no configuration fetched from this server
  is told it uses its machine's policy. No new migration.
- The run header names the policy version the run last reported, as a link to that exact
  version ("hive baseline" for a baseline's, "not rendered here" for a digest this hive
  never rendered), and while an alive run's reported digest is not the one in force it
  shows "Behind vN" with a notice and the link to what changed; an ended run is never
  behind. The timeline shows a second `run.policy_applied` as "Policy applied again" with
  the hosts the reload added and removed, from the two events. The runs list links a
  repository group to its policy, and `/hive/connections?repo=…` to the repository's.
- Retention (`Apiary.Retention`): a hive keeps a run's events and a run's log output for a
  number of days each, 1 to 3650, or for ever, which is the default; owners set it on the
  settings page, and the log is never kept longer than the events that carry it. A nightly
  job (`Apiary.Retention.Scheduler`, three o'clock UTC plus up to an hour, one node at a
  time under an advisory lock) prunes whole runs that are not alive, counted from the last
  event the server received: past the log's days the run loses its log chunks and log
  events, past the events' days all its events, log chunks and deliveries. Every delete is
  one statement over at most 2,000 rows of one run, read through an index, in its own
  transaction. The run stays, with its state, times, labels, counts and connections; its
  page says on which date the events, or the log output, were pruned where they would have
  been. The job says what it pruned: a `retention_runs` row per hive per night, the last
  five on the settings page, and a `retention pruned hive=…` line in the log. `mix
  apiary.prune` (`Apiary.Release.prune/1` in a release) runs it by hand, `--dry-run`
  counts without deleting. A rebuild leaves a run alone whose events are pruned, or due to
  be: its projection is all that is left of it. A run whose events are pruned takes no more
  events: the receiver answers `410`, as for a closed run, because a batch delivered again
  could no longer be told from a new one; a run whose log is pruned takes no more log
  events.
- Live reload, proven end to end: `e2e/run.sh`, and the workflow `End to end` in CI, start
  a test instance on a database of its own, run `qory run` behind a Docker wall on a Linux
  node against it under an `enforce` policy, let the session be refused a host, allow the
  host the way the connection's row does, and assert the second policy applied event with
  the new digest, the allowed connection after it, and the time between the allow and that
  connection, under thirty-five seconds. `e2e/README.md` says what runs where and what the
  number means.
- The documentation ships with the application: the guides under `guides/` (quickstart,
  install and configure, upgrading, backup and restore, retention, the hosting checklist,
  the security policy, the runner file's `server` section, the server contract) and the
  module reference are built by ExDoc into `priv/static/docs`, in the release image too,
  and every instance serves them at `/docs`, without signing in; the user menu links
  there. A checkout that has not run `mix docs` says so at `/docs`. `mix docs
  --warnings-as-errors` is part of `mix precommit` and of CI. `docs/upgrading.md` moved
  to `guides/upgrading.md`.
- `PUBLIC_URL` is a scheme, a host and, when it has one, a port: a path, a query or a user
  is refused at boot with a message that says so, because a runner refuses a server URL
  that has one. The hints name what works, `https://qory.example`, or `http://localhost:4100`
  for a trial on one machine. Every message an operator reads, `.env.example` and the compose
  file say Qory, and the default sender of mail is `qory@<public host>`.
- A key whose secrets the instance cannot decrypt, because `CLOAK_KEY` is not the key they
  were encrypted with, answers every signed request `503` `{"error":"unavailable"}` with a
  log line naming the key id, where it raised and answered `500` before; the access keys
  page still lists it, **Rotate** issues a new secret in place of the unreadable ones and
  **Revoke** revokes. The backup guide says so.
- `/docs` is served by the endpoint's static plug in every environment; in development it
  answered `400` for a built page.
- An empty `SMTP_USERNAME`, which is how `.env.example` leaves it, means no
  authentication at the relay; before, it meant authenticating with an empty name.

### Migrations

- `users`, `users_tokens` (the account tables), `organisations`, `hives`, `memberships`,
  `invitations`, `access_keys`. All new; nothing to migrate from.
- `20260920020000`: `CHECK` constraints on `memberships.level` and `invitations.level`
  (`owner` or `member`), and indexes on `invitations.invited_by_id` and
  `access_keys.created_by_id`. Short; reversible.
- `20260921000100` to `20260921000600`: the tables of the record, `repositories`, `runs`,
  `events`, `log_chunks`, `connections`, `deliveries`. All new and empty; each reverses by
  dropping its table.
- `20260921000700`: `access_keys.last_heartbeat_at`, a nullable column. Instant; reversible.
- `20260922000100`: `runs.denied_count` (the run's denied connections, default 0) and
  `connections.last_mode`, `last_path_rule`, `last_credential`, `last_request_method`
  (nullable). Expand only; reversible. It backfills the count in one statement, the sum of
  each run's `connections`; on a large `connections` table that statement is the slow part.
  The four columns are not backfilled here: see Upgrading.
- `20260922000200`: the index the runs list reads by, on `runs (hive_id,
  COALESCE(started_at, inserted_at) DESC, id DESC)`, and `connections (hive_id,
  last_seen_at)`. Both built `CONCURRENTLY`, outside a transaction and without the migration
  lock, so the receiver keeps writing while they build; reversible. Two instances must not
  boot this migration at the same moment.
- `20260923000100`: `hives.egress_mode`, `observe` or `enforce` by a `CHECK`, default
  `observe` for every hive that exists: nothing is denied until somebody says so. Instant;
  reversible.
- `20260923000200` to `20260923000400`: the tables of the security policy, `policy_rules`,
  `policy_changes`, `run_configurations`, with the hive's composite key and a composite key
  to the repository. All new and empty; each reverses by dropping its table.
- `20260923000500`: `deliveries.run_configuration_digest`, a nullable column: what a batch
  said the run holds. Instant; reversible. Deliveries recorded before it keep null.
- `20260925000300`: a one-off repair of data, idempotent. Before this release a page's
  read of a hive nobody had changed rendered and stored a baseline run configuration
  (version 1, no change and no author behind it), so the hive's first real change became
  version 2. Nothing is persisted by a read any more, and this migration deletes such rows
  where the hive has no change yet or a later version supersedes them, moving the versions
  after them and the changes' `version_after` down by one, so the first change is version
  1 again. A row that is the only version of a managed baseline stays: it is what is
  served. Short; `down` does nothing.
- `20260923000600`: `repositories.egress_mode`, nullable, `observe` or `enforce` by a
  `CHECK`; null, which every repository that exists gets, follows the hive's mode. Instant;
  reversible.
- `20260924000100`: `hives.events_retention_days` and `hives.log_retention_days`, nullable,
  1 to 3650 by a `CHECK`; null, which every hive that exists gets, keeps everything.
  Instant; reversible.
- `20260924000200`: `runs.events_pruned_at` and `runs.log_pruned_at`, nullable. Instant;
  reversible.
- `20260924000300`: the table `retention_runs`, with the hive's composite key. New and
  empty; reverses by dropping it.
- `20260924000400`: two partial indexes on `runs (hive_id, COALESCE(last_event_at,
  inserted_at), id)`, for the runs whose events, and whose log, are not pruned yet. Built
  `CONCURRENTLY`, outside a transaction and without the migration lock, like
  `20260922000200`; reversible. Two instances must not boot this migration at the same
  moment.
- `20260925000100`: `runs.cost_usd`, a nullable `numeric`: the cost the run reported.
- `20260926000100`: `runs.terminal_cols` and `runs.terminal_rows`, nullable integers: the
  pseudo-terminal's size as the record last said it. Expand only, instant; reversible. Runs
  projected before it keep null until `mix apiary.rebuild` (see Upgrading).
  Instant; reversible. Runs projected before it keep null until `mix apiary.rebuild`, which
  now selects a run with a session result and no cost (see Upgrading).
- `20260925000200`: the index `runs (hive_id, access_key_id, COALESCE(started_at,
  inserted_at) DESC, id DESC)`, which the overview reads the last run of each key by. Built
  `CONCURRENTLY`, outside a transaction and without the migration lock, like
  `20260922000200`; reversible. Two instances must not boot this migration at the same
  moment.
- `20260924000500`: the run state `exited` becomes `succeeded`, in the rows and in the
  `CHECK` on `runs.state`. Outside a transaction, under the migration lock, every step
  idempotent: the `CHECK` is swapped for one that takes both words (`NOT VALID`, instant),
  the rows are renamed in batches of 5000 by primary key, one commit a batch, until a pass
  finds none, and the `CHECK` is narrowed to the new word and validated under a lock that
  lets reads and writes through. Its length is the number of `exited` runs; the receiver
  keeps writing throughout. Reversible: `down` renames the rows back the same way.

### Upgrading

- A deny holds in either mode from this release on: the run configurations carry
  `egress.deny`, and a runner of 0.4.0 or later denies what it names under `observe` too.
  The versions in force were rendered before the document had a deny list, so a hive with
  deny rules keeps serving documents without one until its next change. Run
  `mix apiary.policy.rerender` once after the upgrade (in a release `bin/apiary eval
  "Apiary.Release.policy_rerender()"`): it renders every managed hive's documents again,
  writes a new version only where the bytes change, with a `rerendered` row in the history,
  and runs in flight take it within a heartbeat. A hive without deny rules renders the
  bytes it always did and gets nothing. Before that, read the hive's deny rules as what a
  run under `observe` will start being denied.
- The upgrade changes no machine's policy. A hive serves a run configuration only once
  somebody has made its policy in the console, by the first rule or the first change of
  mode; until then discovery names no `run` section and every machine keeps the `egress`
  section of its own `runner.yaml`, enforcement included. The first change anywhere, a
  repository's rule or a repository's mode included, is the moment the hive takes over,
  for every repository, every machine under its keys and the runs in flight, which reload
  within a heartbeat: from then on the hive's policy is the policy and the machine's
  own is not merged with it. So before the first change, say in the hive everything the
  machines' own lists say (the mode is `observe` until an owner sets it, which denies
  only what a deny rule names), or keep a machine on its own policy with `qory run --local`. It does not go back
  by removing the rules: a hive that was given a policy keeps serving it.
- First release; nothing to upgrade. Set the variables in `.env.example`; `CLOAK_KEY` must
  never change once a key has been created, or every stored secret becomes unreadable.
- Mail delivery is required: the release does not boot without `SMTP_RELAY`. A trial on one
  machine may set `MAIL_TO_LOG=true` instead, which writes every email, log-in links
  included, to the log.
- Connections projected before `20260922000100` have no mode, path rule, credential or
  request method of their last attempt: the console says "The policy denies it." where it
  would name the mode, until those runs are projected again. `mix apiary.rebuild`, or in a
  release `bin/apiary eval "Apiary.Release.rebuild()"`, does that: only the runs that need
  it, a hundred at a time, safely beside the running server, and it can be stopped and run
  again. `--all` (`all: true`) rebuilds every run.
- The cost a run reported is folded from its events from this release on; a run projected
  before it shows no cost, and the overview's "Cost reported" counts it as a run that did
  not report one. `mix apiary.rebuild` (or `bin/apiary eval "Apiary.Release.rebuild()"`)
  fills the column for the runs that have a session result and no cost yet, beside the
  running server, and can be run again at any time.
- The terminal's size is folded from this release on. A run projected before it, whose
  `run.started` reports a size, is fitted to the box until `mix apiary.rebuild` fills
  `terminal_cols` and `terminal_rows`; the same task selects those runs. Runs recorded by a
  runner before 0.4.0 report no size and are fitted to the box, as before. The runner on
  each machine has to be 0.4.0 or later (`qory` built against it) for the size to be
  recorded and for the terminal stream to be cut at a redraw instead of a line.
- Retention is off until an owner sets it: an upgrade prunes nothing. What the job deletes
  comes back only from a backup of Postgres.
- A run that ended well is `succeeded`, no longer `exited`: on the badge, in the header
  ("Succeeded 19 s after it started"), in the state filter and in `runs.state`, which
  `20260924000500` renames on boot. A saved link with `state=exited` still opens the same
  list and is rewritten to `state=succeeded`. The previous release does not read
  `succeeded`, so going back to it means rolling that migration back first.
