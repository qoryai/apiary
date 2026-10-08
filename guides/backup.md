# Backup and restore

Postgres is the only state of Qory Apiary. The container holds nothing that a restart does
not rebuild, and nothing is written to a disk outside the database. A backup is therefore
four things:

1. a dump of the database;
2. `APIARY_ENCRYPTION_SECRET`;
3. `APIARY_SIGNING_SECRET`;
4. `SECRET_KEY_BASE`.

Keep the three values beside the dumps and not inside them, in a password manager or a
secret store: a dump restored without its `APIARY_ENCRYPTION_SECRET` trusts none of its
access keys, and a dump stored with the three values protects nothing they guard.

## Back up

### The compose installation

The `docker-compose.yml` of the repository runs Postgres as the service `postgres`, with the
role `apiary` and the database `apiary`. From the directory that holds it:

```sh
docker compose exec -T postgres pg_dump -U apiary -Fc apiary > qory.dump
```

`-Fc` is the custom format, compressed, which `pg_restore` reads. The server keeps serving
while the dump is taken, and the dump is of one moment.

### An external Postgres

Use a `pg_dump` at least as new as the database server. `DATABASE_URL` begins with
`ecto://`, which the Postgres tools do not know; write `postgres://` in its place:

```sh
pg_dump --format=custom --no-owner --file=qory.dump "postgres://USER:PASS@HOST/DATABASE"
```

A managed Postgres with its own snapshots and point-in-time recovery does the same job. Test
its restore the same way.

### How often

[Retention](retention.md) deletes old rows for good: what it pruned comes back from a backup
taken before the pruning and from nowhere else. Keep dumps for at least as long as you
may want to read a run that the server no longer keeps.

Take a dump before every upgrade ([Upgrading](upgrading.md)).

A deletion does not reach the dumps taken before it: a deleted account's address is in
them until they expire. How long you keep dumps is how long a deletion takes to be
complete, which is what to tell someone who asks for their data to be erased
([Install and configure](install.md), Deletion).

## Restore

Restore into an empty database, before the release starts. The release then finds the
schema at the version the dump was taken at and runs the migrations that came after it, so
a dump restores under the release it was taken under or under a later one.

### The compose installation

On a new machine, with the repository checked out and `.env` holding the same
`APIARY_ENCRYPTION_SECRET`, `APIARY_SIGNING_SECRET` and `SECRET_KEY_BASE`:

```sh
docker compose up -d postgres
docker compose exec -T postgres pg_restore -U apiary -d apiary --no-owner < qory.dump
docker compose up -d
```

The first command starts Postgres alone, which creates the empty database `apiary`. The
last starts the server, which migrates and serves.

Over an installation that already has data, stop the server and empty the database first:

```sh
docker compose stop apiary
docker compose exec -T postgres dropdb -U apiary apiary
docker compose exec -T postgres createdb -U apiary apiary
docker compose exec -T postgres pg_restore -U apiary -d apiary --no-owner < qory.dump
docker compose up -d
```

### An external Postgres

Create an empty database that the role of `DATABASE_URL` may create tables in, then:

```sh
pg_restore --no-owner --dbname="postgres://USER:PASS@HOST/DATABASE" qory.dump
```

Start the release afterwards.

### Check it

```sh
curl http://localhost:4100/health
```

answers `200` with `"database":"ok"`. Sign in, open **Runs**, and start a run on a machine
connected to one of the workspace's nodes: if it appears, the keys' integrity codes
verified, which means `APIARY_ENCRYPTION_SECRET` is the right one, and the machine took
the server's signed answers, which means `APIARY_SIGNING_SECRET` is.

## What each key is for

### `APIARY_ENCRYPTION_SECRET`

It keys the integrity codes some rows carry, access keys and enrolment codes among them: a
row changed outside the application no longer matches its code.
<!-- feature: secrets -->

It also encrypts the values of the workspaces' stored secrets, the table `secret_values`,
each under its workspace's data key, which is kept in `workspace_data_keys` encrypted under
a key derived from it.
<!-- /feature -->

<!-- feature: secrets -->
**Losing `APIARY_ENCRYPTION_SECRET` loses every stored secret value.** There is no other
copy and no way to recover them: each value has to be entered again, in the workspace's
secrets, from wherever it came from.
<!-- /feature -->

Without the `APIARY_ENCRYPTION_SECRET` the dump was taken under, no access key's integrity
code verifies either, so the instance trusts none of them: every signed request of a runner
is answered `401`, no machine starts a run against this server and no events arrive. For each
request the log has `access key row does not match its integrity code key_id=ak_…`. Put the
right `APIARY_ENCRYPTION_SECRET` back and every key verifies again.

Everything else survives: accounts, organisations, workspaces and memberships, runs,
events, logs, connections, and the access keys' own rows with their labels and key ids.
<!-- feature: security -->
So does the security policy, with its versions and history.
<!-- /feature -->

For the same reason `APIARY_ENCRYPTION_SECRET` must never change on a running installation
once an access key exists.
<!-- feature: secrets -->
The same holds once a stored secret exists.
<!-- /feature -->

### `APIARY_SIGNING_SECRET`

It is the seed of the key the instance signs its answers to runners with, and every machine
pins that key's public half. It encrypts nothing and keys nothing in the database, and it is
not derived from `APIARY_ENCRYPTION_SECRET`: each is lost, or kept, on its own.

**Losing or changing `APIARY_SIGNING_SECRET` means pinning every machine again.** The
instance then signs under another key, and each machine refuses its answers until it pins
the new public key. Nothing in the database is lost.

### `SECRET_KEY_BASE`

It signs the session cookie and the "Keep me signed in" cookie. With another value every
browser's cookies stop verifying, and everybody signs in again. That is all.

Nothing in the database depends on it. Log-in links, invitation links and email-change links
are stored as hashes of their secret and are checked against the database, so the links
already sent keep working for as long as they would have. Access keys do not depend on it.

## A restore drill

A backup that has never been restored is a hope. Once, and after any change to how backups
are taken, restore the newest dump on another machine:

1. Check the repository out at the tag the installation runs.
2. Write a `.env` with the installation's `APIARY_ENCRYPTION_SECRET`, `APIARY_SIGNING_SECRET`
   and `SECRET_KEY_BASE`, a
   new database password in `POSTGRES_PASSWORD` and `DATABASE_URL`, `PUBLIC_URL=http://localhost:4100`
   and `MAIL_TO_LOG=true`. The drill sends no mail, and nobody else signs in to it.
3. Restore as under "The compose installation" above.
4. `curl http://localhost:4100/health` answers `200`.
5. Ask for a log-in link at `http://localhost:4100/users/log-in` with your own address, take
   it from `docker compose logs apiary`, and sign in. The runs are there.
   <!-- feature: security -->
   So are the policy and its history.
   <!-- /feature -->
6. Prove the access keys verify. On the same machine, with the `qory` command and the
   secret of an access key that existed when the dump was taken, point a runner file's
   `server` section at `http://localhost:4100`, keeping the key's `access_key_id` and the
   pin, and start a run. A run that starts and appears under **Runs** proves the dump,
   `APIARY_ENCRYPTION_SECRET` and `APIARY_SIGNING_SECRET` belong together. A run that
   does not start because the server refuses its requests (`401`), or because its answers
   do not verify under the pin (`answer_unsigned`), means they do not.
7. Delete the drill: `docker compose down --volumes`, then the `.env` and the dump's copy.

Write down how long the restore took. It is how long an outage with a lost database lasts.
