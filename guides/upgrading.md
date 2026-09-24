# Upgrading

An upgrade is a restart: stop the old release, start the new one, and the new one migrates
the database before it serves. This page says what that rests on and what to do when it
goes wrong.

## What a restart does

1. The release boots, connects to Postgres and runs every migration not yet recorded in
   `schema_migrations`, in order, each in its own transaction. The endpoint does not start
   until they are done; a migration that fails stops the boot, the process exits non-zero,
   and the previous release can be started again.
2. Two instances starting at once do not race: Ecto's migrator takes a lock on
   `schema_migrations`, so the second waits and then finds nothing to do. A migration that
   builds an index concurrently runs without that lock; the changelog says so where it
   applies, and two instances must not boot such a migration at the same moment.
3. The version the release reports, at `GET /health` and with `bin/apiary version`, is the
   version in `mix.exs`, which is the tag of the release.

`MIGRATE_ON_BOOT=false` turns step 1 off for an operator who runs `bin/migrate` by hand
before the restart, for example to watch a long migration.

## Before an upgrade

- Read the release's section in `CHANGELOG.md`, the file at the root of the repository.
  Every section has **Migrations**, the tables it touches and whether a migration is long,
  and **Upgrading**, anything the operator has to do or know.
- Back up Postgres. It is the only state; a `pg_dump` of the database is a complete backup.
  `CLOAK_KEY` and `SECRET_KEY_BASE` are the other two things to keep: without `CLOAK_KEY`
  every stored secret is unreadable. [Backup and restore](backup.md) has the commands.
- Upgrade one minor version at a time before 1.0. A minor release may drop a column a
  release before it still read; two steps at once may skip the release that carried the data
  across.

## How migrations are written

The rules a migration in this repository follows, so an upgrade is safe and a rollback is
possible:

- **Expand, then contract, in separate releases.** A release adds columns, tables and
  indexes and keeps writing the old shape; the release after it removes what nothing reads
  any more. The previous release keeps running against a schema the next one migrated, so a
  rollback of the application needs no rollback of the database.
- **No data rewrite inside a schema migration.** A backfill that touches many rows runs in
  batches, either as its own migration that commits per batch or as a task the changelog
  names, never in the same transaction as a `CREATE INDEX` on a large table.
- **Indexes on large tables are created concurrently** (`create index ... concurrently`,
  which Ecto runs outside a transaction), so a busy instance keeps serving.
- **Every migration has a `down`.** `bin/apiary eval "Apiary.Release.rollback(Apiary.Repo, <version>)"`
  reverts to the migration version the changelog names for the previous release.
- **The keys of the organisation and the workplace come first.** Every table carries
  `organisation_id`, and every table that belongs to a workplace carries `hive_id` beside
  it with the composite foreign key, from its first migration; no migration retrofits
  them.

## Rolling back

1. Stop the new release.
2. If the changelog's Upgrading section says the release's migrations are not backward
   compatible, run the rollback command above with the migration version it names, from
   the new release's image (`docker run --rm --env-file .env <new image> bin/apiary eval ...`).
3. Start the previous release. It runs no migrations if the schema is at its version.

A rollback does not bring back rows that [retention](retention.md) pruned in the meantime,
and nothing but a backup does.

## Container images

A release is a tag `vX.Y.Z` on the repository, and the image is built from the `Dockerfile`
at that tag. The image's command is `bin/server`, which migrates and serves.

The `docker-compose.yml` in the repository builds the image from the checkout, so for that
installation the upgrade is the new tag and a rebuild:

```sh
git fetch --tags
git checkout vX.Y.Z
docker compose up --build -d
```

An installation whose compose file names a built image instead (`image:` in place of
`build:`) upgrades with `docker compose pull` and `docker compose up -d`.

## Projections after an upgrade

A release that adds columns to what is projected from a run's events leaves them empty on
the runs projected before it. When the changelog says so, `mix apiary.rebuild`, or in a
release `bin/apiary eval "Apiary.Release.rebuild()"`, projects those runs again from their
events: only the runs that need it, a hundred at a time, safely beside the running server,
and it can be stopped and run again. `Apiary.Release.rebuild/1` with `all: true` rebuilds
every run.
