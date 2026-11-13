# Upgrading

An upgrade is a restart: stop the old release, start the new one, and the new one migrates
the database before it serves. This page says what that rests on and what to do when it
goes wrong.

## What a restart does

1. The release boots, connects to Postgres and runs every migration not yet recorded in
   `schema_migrations`, in order, each in a separate transaction. The endpoint does not start
   until they are done; a migration that fails stops the boot and the process exits
   non-zero, the migrations before it applied and the failed one rolled back.
2. Two instances starting at once do not race: Ecto's migrator takes a lock on
   `schema_migrations`, so the second waits and then finds nothing to do. A migration that
   builds an index concurrently runs without that lock; the changelog says so where it
   applies, and two instances must not boot such a migration at the same moment.
3. Once the migrations have run, the release adopts the organisations of an instance
   upgraded from a release without operators, in one transaction that is safe to run
   again ([Instance admins](admin.md#an-instance-upgraded-from-a-release-without-operators)).
   An adoption that fails stops the boot, as a migration that fails does.
4. Once the adoption has run, and before it serves, the release checks that its
   `APIARY_ENCRYPTION_SECRET` and `APIARY_SIGNING_SECRET` are the ones the instance first
   started with, and stops when one is not
   ([Install and configure](install.md), The keys generated at first start).
5. The version the release reports, at `GET /health` and with `bin/apiary version`, is the
   version in `mix.exs`, which is the tag of the release. `GET /health` also reports
   `revision`, the commit the image was built from.

`MIGRATE_ON_BOOT=false` turns step 1 off for whoever runs `bin/migrate` by hand before
the restart, for example to watch a long migration.

## How the old release stops

On a stop, Qory Apiary closes the ports it listens on and finishes the open requests for
up to 20 seconds in total. Then it finishes the running jobs for up to 15 seconds. A
request still open after the 20 seconds, or a job still running after the 15, is cut.

Give the container or the service a stop grace period of at least 40 seconds:

- Docker Compose: `stop_grace_period: 40s` on the `apiary` service, as `compose.yaml`
  sets it.
- Kubernetes: `terminationGracePeriodSeconds: 40` in the pod's spec.
- systemd: `TimeoutStopSec=40` in the unit.

With a shorter grace period, Docker can kill Qory Apiary before the open requests and
jobs end. Docker waits 10 seconds by default.

## Before an upgrade

- Read the release's section in `CHANGELOG.md`, the file at the root of the repository.
  When there is anything to do, the section has **Migrations**, the tables it touches
  and whether a migration is long, and **Upgrading**, anything whoever runs the instance
  has to do or know.
- Back up Postgres, then the artifact store: the volume `artifacts` of `compose.yaml`,
  mounted at `/var/lib/apiary/artifacts`, or the folder `QORY_ARTIFACTS_DIR` is set to.
  Together they are the instance's state; a `pg_dump` of the database and a copy of the
  store taken after it are a complete backup. Keep the store across the upgrade.
  `APIARY_ENCRYPTION_SECRET`, `APIARY_SIGNING_SECRET` and `SECRET_KEY_BASE`, which
  `compose.yaml` keeps in the volume `keys`, are the other three things to keep: without
  `APIARY_ENCRYPTION_SECRET` no access key is trusted, and without `APIARY_SIGNING_SECRET`
  every machine has to be pinned again. [Backup and restore](backup.md) has the commands.
<!-- feature: factory, secrets -->
- Upgrade every Qory Gateway first, to a gateway built with qoryai/forager#53 or later,
  then upgrade Qory Apiary to a release with several model keys per run. That release
  adds `pause_for_s` to each model key in a run configuration, a member that the run
  configuration schema of an earlier gateway does not define. A run registered before
  the upgrade keeps its one key and goes on across the deploy; its run configuration
  gains `pause_for_s`, the key's Pause for when the upgrade runs.
<!-- /feature -->

## Upgrade the gateway before Qory Apiary

Upgrade every Qory Gateway first, wait until the gateway accepts connections, then
upgrade Qory Apiary. A new release of Qory Apiary can send the gateway a value of the run
configuration that only the new gateway reads, and an older gateway then fails the run
with `run_configuration_invalid`. The script `aws/host/bin/update` of qoryai/deploy
upgrades in this order: the gateway, Qory Apiary, the GitHub adapter, the provisioner,
and Caddy.

## How migrations are written

The rules a migration in this repository follows, so an upgrade is safe and a rollback is
possible:

- **Expand, then contract.** A migration adds tables, columns, indexes and constraints the previous release's code
  satisfies, and a table or a column that release still reads is dropped or renamed only
  by a release after the one that stopped reading it. So the previous release runs on the
  new schema, and going back one release is starting it again
  ([Rolling back](#rolling-back)). For that reason a release does not refuse a schema newer
  than the one it ships.
- **No data rewrite inside a schema migration**, but the backfill of a column or a table
  that replaces another, which fills the new one in the migration that adds it.
  Any other backfill that touches many rows runs in batches, either as a separate migration
  that commits per batch or as a task the changelog names, never in the same transaction
  as a `CREATE INDEX` on a large table.
- **Indexes on large tables are created concurrently** (`create index ... concurrently`,
  which Ecto runs outside a transaction), so a busy instance keeps serving.
- **Every migration has a `down`.** `bin/apiary eval "Apiary.Release.rollback(Apiary.Repo, <version>)"`
  reverts every migration from `<version>` on, that version included: give the first
  migration the previous release does not have. The 19 migrations `20260927100100` to
  `20261025170000` are the exception: their versions are older than most other
  migrations, so a rollback to `20260927100100` reverts 262 of the 276 migrations. Go back
  from the release that adds them by image only, and leave their tables in place.
- **The keys of the organisation and the workspace come first.** Every table carries
  `organisation_id`, and every table that belongs to a workspace carries `workspace_id`
  beside it with the composite foreign key, from its first migration; no migration
  retrofits them.

## Rolling back

The previous release runs on the new release's schema (expand, then contract, above), so
going back one release changes nothing in the database. To go back one release:

1. Set `APIARY_VERSION` in `.env` back to the previous release.
2. `docker compose up -d`. The previous release starts on the newer schema, and runs no
   migration, since none is pending for it.

Across migrations `20261111090000` and `20261111100000`, these two steps are not enough,
and the steps below apply instead. The two migrations do not follow expand, then
contract: `20261111090000` drops `machine_types.image` and `20261111100000` drops
`runs.provider_value_id`. A release from before them, whose last migration is
`20261110090000`, reads both columns and does not run on the newer schema. To go back to
such a release, take the schema back to before `20261110153000`, the first migration
that release does not have. The rollback adds both columns again, with no image on any
machine type. It reverts every migration from `20261110153000` on, that version
included, and loses:

- the fallbacks of every model choice;
- every key's Resets, Pause for and state;
- the stored chunks of every session transcript; the `dev.qory.session.transcript`
  events stay in `events` until retention deletes them;
- a continuation's `resume`;
- the key copies, and when each key value was set;
- every key of a run but the first, and the provider of a run whose first key is gone;
- the model providers each queued run waits for;
- the paused state: each paused run becomes Cancelled, and no run continues it.

To go back to such a release:

1. Stop Qory Apiary, so that no write lands between the dump and the rollback:

   ```sh
   docker compose stop apiary
   ```

2. Take a database dump ([Backup and restore](backup.md)).
3. While `APIARY_VERSION` in `.env` is still the newer release, run the rollback from the
   newer release's image, in a one-off container:

   ```sh
   docker compose run --rm apiary bin/apiary eval "Apiary.Release.rollback(Apiary.Repo, 20261110153000)"
   ```

4. Set `APIARY_VERSION` in `.env` back to the previous release.
5. `docker compose up -d`.

Further back than one release, restore the dump taken before the upgrade
([Backup and restore](backup.md)), then set the version back and start it.

Every migration has a `down` all the same. To take the schema back too, run the rollback
command above from the newer release's image, in a one-off container, while
`APIARY_VERSION` in `.env` is still the newer release, with the first migration version
the previous release does not have, and then set the version back:

```sh
docker compose stop apiary
docker compose run --rm apiary bin/apiary eval "Apiary.Release.rollback(Apiary.Repo, <version>)"
```

Go back from the release that adds the 19 migrations `20260927100100` to
`20261025170000` by image only, with their tables left in place: a rollback to
`20260927100100` reverts 262 of the 276 migrations.

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

A migration the changelog says is long can be run separately: set `MIGRATE_ON_BOOT=false`
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
