# Backup and restore

Postgres is the only state of Qory Apiary. The container holds nothing that a restart does
not rebuild, and nothing is written to a disk outside the database but the keys, which
`compose.yaml` keeps in the volume `keys`. A backup is therefore four things:

1. a dump of the database;
2. `APIARY_ENCRYPTION_SECRET`;
3. `APIARY_SIGNING_SECRET`;
4. `SECRET_KEY_BASE`.

Keep the three values beside the dumps and not inside them, in a password manager or a
secret store: a dump restored without its `APIARY_ENCRYPTION_SECRET` does not start, and a
dump stored with the three values protects nothing they guard.

## Back up

### The keys

With `compose.yaml` the three are in the file `/var/lib/apiary/keys/apiary.env` of the
volume `keys`, with the database password, `DATABASE_PASSWORD`, one `NAME=value` line each
([Install and configure](install.md), The keys generated at first start). Copy it out
once, after the first start, into a file only you can read, from the directory that holds
`compose.yaml`:

```sh
(umask 077 && docker compose exec -T apiary cat /var/lib/apiary/keys/apiary.env > qory-keys.env)
```

The instance runs with a key set in the environment rather than the file's: when `.env`
sets one of the four names, put `.env`'s line in `qory-keys.env` in place of the file's.
After a restore that put the keys in `.env` (below), `.env`'s four lines are the keys.

### The compose installation

`compose.yaml` runs the bundled Postgres as the service `postgres`, with the role `apiary`
and the database `apiary`. From the directory that holds it:

```sh
docker compose exec -T postgres pg_dump -U apiary -Fc apiary > qory.dump
```

`-Fc` is the custom format, compressed, which `pg_restore` reads. The server keeps serving
while the dump is taken, and the dump is of one moment.

### An external Postgres

Use a `pg_dump` at least as new as the database server. It takes `DATABASE_URL` as it is,
written as `postgres://`, its `sslmode` included; an `sslrootcert` path names a file on the
machine that runs `pg_dump`. When the password is in `DATABASE_PASSWORD` rather than in the
URL, give it to `pg_dump` as `PGPASSWORD`.

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

On a new machine, in a directory with the installation's `compose.yaml` and `.env`, put the
keys of the backup in `.env` first. This takes every line of the four names out of `.env`
and adds the backup's, so `.env` names each key once, as the backup has it:

```sh
(
  umask 077
  grep -Ev '^(SECRET_KEY_BASE|APIARY_ENCRYPTION_SECRET|APIARY_SIGNING_SECRET|DATABASE_PASSWORD)=' .env > .env.new
  cat qory-keys.env >> .env.new
) && mv .env.new .env
```

A value set in the environment wins over the volume's file, so the file is never edited by
hand. Then:

```sh
docker compose up -d postgres
docker compose exec -T postgres pg_restore -U apiary -d apiary --no-owner < qory.dump
docker compose up -d
```

The first command runs the service `keys` and starts Postgres alone, which creates the
empty database `apiary` with the backup's database password. The last starts the server,
which migrates and serves.

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

Start the release afterwards, with the keys of the backup: with `compose.yaml`, put them in
`.env` as above.

### Check it

```sh
curl http://localhost:4100/health
```

answers `200` with `"database":"ok"`: the instance started, so its `APIARY_ENCRYPTION_SECRET`
and `APIARY_SIGNING_SECRET` are the ones the dump recorded, since another stops the boot
and the log says which (What each key is for, below). Sign in, open **Runs**, and start a
run on a machine connected to one of the workspace's nodes: if it appears, the keys'
integrity codes verified, and the machine took the server's signed answers.

## What each key is for

### `APIARY_ENCRYPTION_SECRET`

It keys the integrity codes some rows carry, access keys and enrolment codes among them: a
row changed outside the application no longer matches its code.
<!-- feature: secrets -->

It also encrypts the values of the workspaces' stored secrets, the table `secret_values`,
each under its workspace's data key, which is kept in `workspace_data_keys` encrypted under
a key derived from it.
<!-- /feature -->

<!-- feature: instance_mail -->

It also encrypts the SMTP password saved in Instance settings › Mail, which a restore keeps
with the secret the dump recorded. Where that saved password cannot be read, mail from
those settings is off, and the page and the log say so, until an instance admin enters the
password again there. Mail set by `SMTP_RELAY` and the variables beside it does not depend
on it.
<!-- /feature -->

<!-- feature: secrets -->
**Losing `APIARY_ENCRYPTION_SECRET` loses every stored secret value.** There is no other
copy and no way to recover them: each value has to be entered again, in the workspace's
secrets, from wherever it came from.
<!-- /feature -->

Without the `APIARY_ENCRYPTION_SECRET` the dump was taken under, no access key's integrity
code would verify, so the instance does not start: at every start it checks the secret
against the check value it recorded at its first start, and the log says
`APIARY_ENCRYPTION_SECRET is not the one this instance first started with.` Put the right
`APIARY_ENCRYPTION_SECRET` back and it starts, and every key verifies again.

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

It is the seed of the key the instance signs its answers to gateways with, and every machine
pins that key's public half. It encrypts nothing and keys nothing in the database, and it is
not derived from `APIARY_ENCRYPTION_SECRET`: each is lost, or kept, on its own.

**Losing or changing `APIARY_SIGNING_SECRET` means pinning every machine again.** The
instance does not start with another key than the one it recorded at its first start or
accepted since: the log names the new key's fingerprint and the pinned one. To change it
on purpose, set `APIARY_ACCEPT_SIGNING_FINGERPRINT` to the new key's fingerprint in `.env`,
then `docker compose up -d`: the boot makes the new key the instance's
([Install and configure](install.md#the-keys-generated-at-first-start)); each machine then
refuses its answers until it pins the new public key. Nothing in the database is lost.

### `SECRET_KEY_BASE`

It signs the session cookie and the "Keep me signed in" cookie. With another value every
browser's cookies stop verifying, and everybody signs in again. That is all.

Nothing in the database depends on it. Log-in links, invitation links and email-change links
are stored as hashes of their secret and are checked against the database, so the links
already sent keep working for as long as they would have. Access keys do not depend on it.

## A restore drill

A backup that has never been restored is a hope. Once, and after any change to how backups
are taken, restore the newest dump on another machine:

1. Put a copy of the installation's `compose.yaml` in an empty directory, with the dump and
   `qory-keys.env`.
2. Write a `.env` there with the installation's `APIARY_VERSION`, and its `APIARY_IMAGE`
   when it sets one, `COMPOSE_PROFILES=postgres`, `PUBLIC_URL=http://localhost:4100` and
   its mail settings, `SMTP_RELAY` and the variables beside it. Nobody else signs in to
   it.
3. Restore as under "The compose installation" above, the keys first.
4. `curl http://localhost:4100/health` answers `200`.
5. Ask for a log-in link at `http://localhost:4100/users/log-in` with your own address,
   and sign in with the link the email brings. The runs are there.
   <!-- feature: security -->
   So are the policy and its history.
   <!-- /feature -->
6. Prove the access keys verify. On the same machine, with the `qory` command and the
   secret of an access key that existed when the dump was taken, point a Forager file's
   `gateway.server` section at `http://localhost:4100`, keeping the key's `access_key_id` and the
   pin, and start a run. A run that starts and appears under **Runs** proves the dump,
   `APIARY_ENCRYPTION_SECRET` and `APIARY_SIGNING_SECRET` belong together. Keys that do
   not belong to the dump stop the boot before this: step 4 gets no answer, and
   `docker compose logs apiary` says which key.
7. Delete the drill: `docker compose down --volumes`, then the `.env`, the dump's copy and
   `qory-keys.env`'s.

Write down how long the restore took. It is how long an outage with a lost database lasts.
