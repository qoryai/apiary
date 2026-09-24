# Backup and restore

Postgres is the only state of Qory Apiary. The container holds nothing that a restart does
not rebuild, and nothing is written to a disk outside the database. A backup is therefore
three things:

1. a dump of the database;
2. `CLOAK_KEY`;
3. `SECRET_KEY_BASE`.

Keep the two values beside the dumps and not inside them, in a password manager or a secret
store: a dump without `CLOAK_KEY` restores everything except the access key secrets, and a
dump stored with `CLOAK_KEY` protects nothing of them.

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

## Restore

Restore into an empty database, before the release starts. The release then finds the
schema at the version the dump was taken at and runs the migrations that came after it, so
a dump restores under the release it was taken under or under a later one.

### The compose installation

On a new machine, with the repository checked out and `.env` holding the same `CLOAK_KEY`
and `SECRET_KEY_BASE`:

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
that has one of the workplace's access keys: if it appears, the access key secrets were
restored readable, which means `CLOAK_KEY` is the right one.

## What each key is for

### `CLOAK_KEY`

It encrypts the secrets of access keys at rest: the columns `secret_primary` and
`secret_secondary` of the table `access_keys`. Nothing else in the database is encrypted
with it.

Without the `CLOAK_KEY` the dump was taken under, those secrets cannot be read. What that
looks like, so it is recognised:

- Every signed request of a runner holding such a key, the configuration document, the
  run configuration and every batch of events, is answered `503` with
  `{"error":"unavailable"}`, never `401`: the instance is at fault, not the machine. The
  runner fails closed, so no machine starts a run against this server and no events
  arrive. For each request the log has `access key secret cannot be decrypted
  key_id=ak_…: CLOAK_KEY is not the key the secret was encrypted with`.
- The console still shows every key on **Access keys** with its label, key id and last
  use, since the page never reads a secret. It cannot show a secret again, by design.
- **Rotate** on such a key issues a new secret, shown once, in place of the ones nobody can
  read, which are dropped; **Revoke** revokes as ever.

The way out is therefore a new secret for every machine: rotate each key under the new
`CLOAK_KEY`, or create a new key, and paste the `server` block into each machine's runner
file ([The runner file's `server` section](runner-file.md)). When the right `CLOAK_KEY`
turns up, put it back before rotating and every existing secret reads again.

Everything else survives: accounts, organisations, workplaces and memberships, runs,
events, logs, connections, the security policy with its versions and history, and the
access keys' own rows with their labels and key ids.

For the same reason `CLOAK_KEY` must never change on a running installation once an access
key exists.

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
2. Write a `.env` with the installation's `CLOAK_KEY` and `SECRET_KEY_BASE`, a new database
   password in `POSTGRES_PASSWORD` and `DATABASE_URL`, `PUBLIC_URL=http://localhost:4100`
   and `MAIL_TO_LOG=true`. The drill sends no mail, and nobody else signs in to it.
3. Restore as under "The compose installation" above.
4. `curl http://localhost:4100/health` answers `200`.
5. Ask for a log-in link at `http://localhost:4100/users/log-in` with your own address, take
   it from `docker compose logs apiary`, and sign in. The runs, the policy and its history
   are there.
6. Prove the access key secrets are readable. On the same machine, with the `qory` command,
   point a runner file's `server` section at `http://localhost:4100` with the access key and
   secret of a key that existed when the dump was taken, and start a run. A run that starts
   and appears under **Runs** proves the dump and `CLOAK_KEY` belong together. A run that
   does not start because the server refuses its requests means they do not.
7. Delete the drill: `docker compose down --volumes`, then the `.env` and the dump's copy.

Write down how long the restore took. It is how long an outage with a lost database lasts.
