# Upgrading

An upgrade is a restart: stop the old release, start the new one, and the new one migrates
the database before it serves. This page says what that rests on and what to do when it
goes wrong.

## What a restart does

1. The release boots, connects to Postgres and runs every migration not yet recorded in
   `schema_migrations`, in order, each in its own transaction. The endpoint does not start
   until they are done; a migration that fails stops the boot and the process exits
   non-zero, the migrations before it applied and the failed one rolled back.
2. Two instances starting at once do not race: Ecto's migrator takes a lock on
   `schema_migrations`, so the second waits and then finds nothing to do. A migration that
   builds an index concurrently runs without that lock; the changelog says so where it
   applies, and two instances must not boot such a migration at the same moment.
3. Once the migrations have run, and before it serves, the release checks that its
   `APIARY_ENCRYPTION_SECRET` and `APIARY_SIGNING_SECRET` are the ones the instance first
   started with, and stops when one is not
   ([Install and configure](install.md), The keys generated at first start).
4. The version the release reports, at `GET /health` and with `bin/apiary version`, is the
   version in `mix.exs`, which is the tag of the release. `GET /health` also reports
   `revision`, the commit the image was built from.

`MIGRATE_ON_BOOT=false` turns step 1 off for whoever runs `bin/migrate` by hand before
the restart, for example to watch a long migration.

## Before an upgrade

- Read the release's section in `CHANGELOG.md`, the file at the root of the repository.
  Every section has **Migrations**, the tables it touches and whether a migration is long,
  and **Upgrading**, anything whoever runs the instance has to do or know.
- Back up Postgres. It is the only state; a `pg_dump` of the database is a complete backup.
  `APIARY_ENCRYPTION_SECRET`, `APIARY_SIGNING_SECRET` and `SECRET_KEY_BASE`, which
  `compose.yaml` keeps in the volume `keys`, are the other three things to keep: without
  `APIARY_ENCRYPTION_SECRET` no access key is trusted, and without `APIARY_SIGNING_SECRET`
  every machine has to be pinned again. [Backup and restore](backup.md) has the commands.

## How migrations are written

The rules a migration in this repository follows, so an upgrade is safe and a rollback is
possible:

- **Expand, then contract.** A migration adds tables, columns, indexes and constraints the previous release's code
  satisfies, and a table or a column that release still reads is dropped or renamed only
  by a release after the one that stopped reading it. So the previous release runs on the
  new schema, and going back one release is starting it again
  ([Rolling back](#rolling-back)). For that reason a release does not refuse a schema newer
  than its own.
- **No data rewrite inside a schema migration**, but the backfill of a column or a table
  that replaces another, which fills the new one in the migration that adds it.
  Any other backfill that touches many rows runs in batches, either as its own migration
  that commits per batch or as a task the changelog names, never in the same transaction
  as a `CREATE INDEX` on a large table.
- **Indexes on large tables are created concurrently** (`create index ... concurrently`,
  which Ecto runs outside a transaction), so a busy instance keeps serving.
- **Every migration has a `down`.** `bin/apiary eval "Apiary.Release.rollback(Apiary.Repo, <version>)"`
  reverts to the migration version the changelog names for the previous release.
- **The keys of the organisation and the workspace come first.** Every table carries
  `organisation_id`, and every table that belongs to a workspace carries `workspace_id`
  beside it with the composite foreign key, from its first migration; no migration
  retrofits them.

## Rolling back

The previous release runs on the new release's schema (expand, then contract, above), so
going back one release changes nothing in the database:

1. Set `APIARY_VERSION` in `.env` back to the previous release.
2. `docker compose up -d`. The previous release starts on the newer schema, and runs no
   migration, since none is pending for it.

Further back than one release, restore the dump taken before the upgrade
([Backup and restore](backup.md)), then set the version back and start it.

Every migration has a `down` all the same. To take the schema back too, run the rollback
command above from the newer release's image, in a one-off container, while `.env` still
names it, with the migration version the changelog names for the previous release, and
then set the version back:

```sh
docker compose stop apiary
docker compose run --rm apiary bin/apiary eval "Apiary.Release.rollback(Apiary.Repo, <version>)"
```

A rollback does not bring back rows that [retention](retention.md) pruned in the meantime,
and nothing but a backup does.

## When an upgrade fails

A migration that fails stops the boot. `docker compose up -d` reports the container
`Started`, `docker compose ps` then shows it `Restarting`, and `/health` gets no answer.
`docker compose logs apiary` shows, for each attempt,
`Running pending database migrations`, the error, and
`Database migration failed; refusing to boot`. Each attempt runs the failed migration
again, and it is rolled back each time; the migrations before it stay applied.

The way back is the previous release: set `APIARY_VERSION` in `.env` back to it and
`docker compose up -d` ([Rolling back](#rolling-back)). Further back than one release,
restore the dump taken before the upgrade, then set the version back.

A boot the key check stops says which key in the same log
([Install and configure](install.md), The keys generated at first start): put that key's
value back, and it starts.

A migration the changelog says is long can be run on its own: set `MIGRATE_ON_BOOT=false`
in `.env`, run it in a one-off container, `docker compose run --rm apiary bin/migrate`, and
start the release once it is done.

## Container images

A release is a tag `vX.Y.Z` on the repository, and its image is `ghcr.io/qoryai/apiary`,
built from the `Dockerfile` at that tag and tagged `X.Y.Z`, without the `v`, `X.Y` and
`latest`. The image's command is `bin/server`, which migrates and serves. Version numbers
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html): before 1.0 a minor
release may change what an existing installation does, and says so under **Upgrading** in
its section of the changelog, so upgrade one minor version at a time.

`compose.yaml` runs the image `.env` names in `APIARY_VERSION`, so the upgrade is a new
value there and a new start: back up, set `APIARY_VERSION` to the new version, then

```sh
docker compose pull && docker compose up -d
curl http://localhost:4100/health
```

`/health` answers with the new release's `version` and `revision` once it has migrated.
When a release changes `compose.yaml`, its section of the changelog says so under
**Upgrading**.

## Projections after an upgrade

The runs, their connections and their logs are projections of the recorded events. When
the changelog of a release says so, `mix apiary.rebuild`, or in a release
`bin/apiary eval "Apiary.Release.rebuild()"`, projects every run again from its events: a
hundred at a time, safely beside the running server, and it can be stopped and run again.
