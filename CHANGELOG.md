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
  signed request answered with the configuration document, version 1, sections `events` and
  `run`. The signature rules Apiary assumes are in `docs/contract-assumptions.md`.

### Migrations

- `users`, `users_tokens` (the account tables), `organisations`, `hives`, `memberships`,
  `invitations`, `access_keys`. All new; nothing to migrate from.
- `20260920020000`: `CHECK` constraints on `memberships.level` and `invitations.level`
  (`owner` or `member`), and indexes on `invitations.invited_by_id` and
  `access_keys.created_by_id`. Short; reversible.

### Upgrading

- First release; nothing to upgrade. Set the variables in `.env.example`; `CLOAK_KEY` must
  never change once a key has been created, or every stored secret becomes unreadable.
- Mail delivery is required: the release does not boot without `SMTP_RELAY`. A trial on one
  machine may set `MAIL_TO_LOG=true` instead, which writes every email, log-in links
  included, to the log.
