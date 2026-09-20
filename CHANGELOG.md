# Changelog

Every release of the apiary, newest first, in the shape of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
The version numbers follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0 a minor
release may change what an existing installation does, and says so under Upgrading. Every
section names the database migrations the release runs on boot, so a self-hoster knows what
a restart does before doing it (`docs/upgrading.md`).

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
  `Apiary.Runs.close_run/2` answers `{:error, :not_closable}` for a run that exited, failed
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
  baseline of rules; a repository has rules of its own on top. A rule allows or denies a host
  (a name or a `*.` suffix, on every path or held to a list of paths) or a credential of the
  machine's by name, and never holds a credential. The contract's policy document can only
  allow, so a deny is the apiary's own: it takes entries out of what is rendered, which is
  how a repository disables a host of the hive. On a conflict the repository wins, unless the
  hive's rule is locked: a locked rule holds against every repository. Members edit; only an
  owner locks, unlocks, changes or removes a locked rule. What the document cannot say is
  refused when it is written, with a sentence that says what to do instead: a deny of a host
  below an allowed `*.` suffix, and a `*.` suffix held to paths above another allowed entry.
- Run configurations: every change renders the baseline and every repository with rules of
  its own, in the same transaction, as canonical JSON validated against the contract's
  schemas (vendored under `priv/contract/`; `jsv` is a runtime dependency now). Each version
  is kept as the exact bytes served, under `sha256=` of those bytes, with who changed what
  and when; a change that renders the same bytes makes no new version. The history of the
  hive and of each repository is kept with the rules before and after, and is diffable.
  Changes are announced on `Apiary.PubSub` (`policy:<hive>`).
- Suggestions: the hosts a repository's harness declared, from its runs' policy applied
  events, that its policy neither covers nor denies. Allow and deny from a connection's row:
  the host, or the path when the host is held to paths, in the repository or in the hive.
  Export of the effective policy for a node without a server: the `egress` section of
  `runner.yaml`, and a `--policy` file when there are paths or credentials.
- The run configuration endpoint of the server contract, `GET /v1/run-configuration`: a
  signed request answered with the stored bytes for the key's hive and the labelled
  repository, the baseline for any other, the digest in `X-Qory-Run-Configuration` and as the
  `ETag`, never a `304`. A hive without a policy gets a baseline made on first need:
  `observe`, nothing allowed, nothing denied. Discovery names the `run` section.
- Live reload: every `202` and `410` of `POST /v1/events` carries
  `X-Qory-Run-Configuration`, the digest in force for the run's repository, read from an
  index and never rendered while answering; a run whose policy changed fetches it again
  within a heartbeat. The digest a batch reported is kept on the delivery and on the run,
  and `Apiary.Policy.digests/2` says whether a run is behind.
- `mix apiary.demo` gives a hive without rules a policy to look at: a baseline, a host held
  to paths, a locked deny, a repository's overrides, several versions and a history.

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

### Upgrading

- Discovery names a `run` section from this release on, so every run under a server key
  takes its policy from the hive and no longer from the machine's `runner.yaml`. A hive
  nobody has given a policy serves `observe` with nothing allowed, which records everything
  and denies nothing: a machine that enforced its own list stops enforcing it until the hive
  has the list and the mode. Give the hive its policy before upgrading a fleet that relies
  on enforcement, or run such a machine with `--local`. The digest of the discovery document
  changes, so a run in flight fetches it again.
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
