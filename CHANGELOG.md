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
  sequence like the rest and reproduced by a rebuild.
- For development, `mix apiary.demo` replays the synthetic recorded runs under `priv/demo/` into a hive through the receiver's own ingest, as new runs that end now (dev and test only).

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
- `20260922000100`: `runs.denied_count` (the run's denied connections, default 0),
  `connections.last_mode`, `last_path_rule`, `last_credential` and `last_request_method`
  (nullable), and indexes on `runs (hive_id, started_at)`, `runs (hive_id, repository_id,
  started_at)` and `connections (hive_id, last_seen_at)`. Expand only; reversible. The
  migration backfills both in place with two statements: the count from the run's
  `connections`, the four columns from the one event each connection names as its last, so
  no run needs a rebuild. On a large `connections` table the second statement is the slow
  one (one index lookup in `events` per row).

### Upgrading

- First release; nothing to upgrade. Set the variables in `.env.example`; `CLOAK_KEY` must
  never change once a key has been created, or every stored secret becomes unreadable.
- Mail delivery is required: the release does not boot without `SMTP_RELAY`. A trial on one
  machine may set `MAIL_TO_LOG=true` instead, which writes every email, log-in links
  included, to the log.
