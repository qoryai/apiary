# Install and configure

Qory Apiary is one container image. Postgres is its only dependency and holds all of its state.
Configuration is by environment variables, read once at boot. Pending database migrations
run at boot, before the server accepts a request, so an upgrade is a restart
([Upgrading](upgrading.md)).

[From nothing to a first run](quickstart.md) is the shortest way to a running trial. This
page is the reference for an installation that stays.

## The pieces

- **The image**, `ghcr.io/qoryai/apiary`, is built from the `Dockerfile` of the repository.
  CI builds it on every pull request and push and publishes nothing; only a release
  publishes it, tagged with its version without the `v` (`X.Y.Z`), `X.Y` and `latest`, for
  `linux/amd64` and `linux/arm64`. It holds the release and nothing else, runs as the user
  `nobody`, listens on port 4100, and its command is `bin/server`, which migrates and
  serves. `bin/migrate` runs the same migrations by hand, `bin/apiary version` prints the
  release's version, and `bin/keys` generates the keys
  ([The keys generated at first start](#the-keys-generated-at-first-start)). The commit it
  was built from is its label `org.opencontainers.image.revision` and `revision` at
  [`GET /health`](#health).
- **`compose.yaml`** of the repository runs it as three services. `keys` runs once at every
  start and exits: it generates the keys the volume `keys` does not hold yet. `postgres`,
  in the profile `postgres` that `.env` turns on with `COMPOSE_PROFILES=postgres`, is
  Postgres 18 with the role `apiary`, the database `apiary` and the volume `postgres-data`.
  `apiary` starts once `keys` has finished and the database is healthy, and publishes port
  4100 on `127.0.0.1` only. An external Postgres is one `DATABASE_URL` away, with the line
  `COMPOSE_PROFILES=postgres` taken out of `.env`
  ([Postgres over TLS](#postgres-over-tls)); the role needs the right to create and alter
  tables in its database, since the release migrates it.
- **A reverse proxy** that terminates TLS, in front of the port.
- **An SMTP relay.** People sign in with a link sent by email and are invited by email.
  Without `SMTP_RELAY` the release starts all the same, sends no email, and says so in
  its log; an invitation is then a link that whoever invites copies and sends themselves.

With `compose.yaml` and its `.env` in one directory, `docker compose up -d` starts the
three services, and `docker compose logs apiary` shows the boot.
[From nothing to a first run](quickstart.md) runs them from a checkout, with an image built
on the machine.

## TLS and the reverse proxy

The release listens on plain HTTP, on every interface, IPv4 and IPv6, on `PORT`. TLS is
terminated by a reverse proxy in front of it.

- With a `PUBLIC_URL` that starts with `https://`, a request that arrives over plain HTTP is
  redirected to HTTPS and answers carry HSTS. The proxy must send
  `X-Forwarded-Proto: https` with every request it passes on; without it every request is
  redirected, for ever.
- With a `PUBLIC_URL` that starts with `http://`, a LAN or a trial on one machine, nothing
  is redirected.
- `GET /health` is never redirected, so a load balancer can probe it over plain HTTP, and
  neither are requests to the hosts `localhost` and `127.0.0.1`.

The console's pages are live over a WebSocket: let the proxy pass WebSocket upgrades
through. Without them the pages fall back to long polling.

Links in emails, the Forager file lines and the command the console shows to connect a
machine, and the URLs in the discovery document are all built from `PUBLIC_URL`, never
from the request's `Host` header. A `PUBLIC_URL` that is not the address machines and
people use gives them links that do not work.

The audit trail records the address each change came from, and the limits on signing in
count attempts by it. Behind a proxy that is the proxy's, unless `TRUSTED_PROXIES` names
it: addresses or CIDR ranges of the proxies in front of the release, separated by commas.
For a request from one of them the release reads `X-Forwarded-For` from its right-most
hop leftwards, passes over the hops the trusted proxies added, and takes the first address
that is not one of them. What the client wrote to the left of that is never read, so a
client cannot choose the address recorded. Name only the proxies that set the header
themselves, and leave it unset when nothing is in front of the release: a proxy the
release trusts is believed about every address it passes on. A range of every address, `0.0.0.0/0` or `::/0`, stops the boot,
since it would believe any client about its own address. A hop's port is left out.
Behind a proxy the release does not trust, every client counts as the proxy, and they
share its limits on signing in.

```sh
TRUSTED_PROXIES=10.0.0.0/8,192.0.2.7
```

## Health

`GET /health` needs no authentication and no session, and is never cached
(`Cache-Control: no-store`). It asks the database `SELECT 1`, with five seconds to answer.

| Status | Body | When |
|---|---|---|
| `200` | `{"status":"ok","database":"ok","version":"0.1.0","revision":"4f2a9c1e0b…"}` | the database answered; `version` is the release's, `revision` the commit its image was built from, `null` in a build without one |
| `503` | `{"status":"degraded","database":"error","version":"0.1.0","revision":"4f2a9c1e0b…"}` | the database did not answer |

## Logs

In production the release writes one JSON object per line to standard output, at level
`info` and above. Any log shipper that reads a container's output can take the lines as
they are.

| Member | Holds |
|---|---|
| `time` | when, UTC, ISO 8601 |
| `severity` | the level: `info`, `warning`, `error` and so on |
| `message` | the line's text |
| `metadata` | of an explicit list and nothing else: `request_id`, `organisation_id`, `workspace_id`, `user_id`, `duration_us`, `application`, `domain`, `mfa`, `module`, `function`, `file`, `line`, `pid`, `crash_reason`, `initial_call`, `registered_name` |
| `request` | on the one line written per request: `connection` with `protocol`, `method`, `path` and `status`, and `client` with `user_agent` and `ip` |

A line written while the apiary works for an organisation carries its id as
`metadata.organisation_id`, and `metadata.workspace_id` when the work is in a workspace: a
page under `/:org/…` and its reads, a gateway's request, the projection of a run's events,
a background job, and the line that says a job failed, was cancelled or was discarded. A
line written for a signed-in person carries their id as `metadata.user_id`: every page
they open, and a job their action enqueued. A person's own pages, their account settings
and their organisations page, carry `user_id` and no organisation or workspace. A gateway's
request is an access key's and carries no `user_id`.

The ids are never a name, a slug or an email address, so a search by any of them finds
everything that happened for it without the log holding a customer's or a person's names.
`user_id` is a pseudonymous id: the log alone does not say who it is. A job's line names
the job, its attempt and the kind of error, never its arguments or the error's message.

A request line's duration is `metadata.duration_us`, in microseconds. No header and no
body is ever logged, and neither is anything a gateway signed or sent. Four routes carry a
secret in their path, an invitation, its continuation, a log-in link and an email change;
their secret segment is logged as `:token`, so a reader of the log cannot sign in or join
an organisation with what it finds there.

## Environment variables

Every variable the release reads in production. "Required" means the release does not boot
without it and exits with the message shown.

### Database

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `DATABASE_URL` | required; with `compose.yaml`, `postgres://apiary@postgres/apiary` | The connection URL, `postgres://USER:PASS@HOST/DATABASE` (`postgresql://` and `ecto://` work as well), with TLS as its `sslmode` says ([Postgres over TLS](#postgres-over-tls)). `compose.yaml` gives the bundled Postgres's URL unless `.env` sets another; a `DATABASE_URL` set in the shell that runs `docker compose` wins over `.env`'s. A password with characters that mean something in a URL has to be percent-encoded. |
| `DATABASE_PASSWORD` | none; with `compose.yaml`, generated at first start | The password when `DATABASE_URL` carries none; an empty one in the URL counts as none. Passed as it is, so it needs no percent-encoding. With `compose.yaml` the service `keys` generates it, and the bundled Postgres takes it as the password of the role `apiary` ([The keys generated at first start](#the-keys-generated-at-first-start)). |
| `POOL_SIZE` | `10` | Connections in the pool. An integer. |
| `ECTO_IPV6` | off | `true` or `1` connects to the database over IPv6. Anything else is off. |
| `MIGRATE_ON_BOOT` | `true` | `false`, `0` or `no` leaves pending migrations to `bin/migrate`. Anything else runs them at boot. |

```text
environment variable DATABASE_URL is missing.
For example: postgres://USER:PASS@HOST/DATABASE
```

### Postgres over TLS

`DATABASE_URL` takes libpq's `sslmode` and `sslrootcert`, as managed Postgres services
print them, so a pasted URL connects with TLS as it says:

```text
postgres://USER:PASS@HOST:5432/DATABASE?sslmode=verify-full
```

| `sslmode` | The connection |
|---|---|
| none | Not encrypted, unless Ecto's own `ssl=true` asks for TLS, checked against the system's CAs. |
| `disable` | Not encrypted. |
| `verify-full` | Encrypted; the server's certificate and host name are checked, against the system's CAs, or against the file `sslrootcert=/path/to/ca.pem` names. `sslrootcert=system` is the system's CAs. |
| `require` | Encrypted; the server's certificate is not checked, with or without `sslrootcert`. Said once at boot, as a warning. |

Two differences from libpq. An `sslrootcert` without an `sslmode` is not read here, and
the connection is as with no `sslmode` (the first row above), where libpq takes
`sslrootcert=system` alone as `verify-full`. And `require` with an `sslrootcert` checks
nothing here, where libpq checks the certificate against that file. Write
`sslmode=verify-full` for a checked connection.

A CA your provider does not publish to the system's store is a file you mount into the
container, with a `compose.override.yaml` beside `compose.yaml`, and name with
`sslrootcert`. Written as `postgres://`, the same URL serves `pg_dump` and `psql` too
([Backup and restore](backup.md)).

```text
The database connection is encrypted, and the server's certificate is not checked (sslmode=require).
```

Any other `sslmode`, `prefer`, `allow` and `verify-ca` among them, stops the boot, and so
does an `sslrootcert` file that cannot be read under `verify-full`:

```text
environment variable DATABASE_URL asks sslmode=prefer, which Qory does not take.
Use sslmode=verify-full, which checks the server's certificate, or sslmode=require, which encrypts without checking it.
```

```text
environment variable DATABASE_URL names sslrootcert=/certs/ca.pem, which cannot be read.
```

### Secrets

With `compose.yaml` the service `keys` generates the three at first start, with
`DATABASE_PASSWORD` ([The keys generated at first start](#the-keys-generated-at-first-start)).
Set one in `.env` only for a value of your own, such as one restored from a backup: a
value set in the environment always wins. A variable left blank counts as not set.

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `SECRET_KEY_BASE` | required; with `compose.yaml`, generated at first start | Signs the session cookie and the "Keep me signed in" cookie. At least 64 bytes. Generate one with `openssl rand -base64 48`, or with `mix phx.gen.secret` where there is Mix. |
| `APIARY_ENCRYPTION_SECRET` | required; with `compose.yaml`, generated at first start | Keys the integrity codes of stored rows, access keys among them. Exactly 32 bytes, in base64 (44 characters) or in hex (64 characters, either case): `openssl rand -base64 32`. It must never change once an access key exists, or no access key verifies. Keep it with the database backups, not in them ([Backup and restore](backup.md)). |
| `APIARY_SIGNING_SECRET` | required; with `compose.yaml`, generated at first start | The seed of the Ed25519 key the instance signs its answers to gateways with; every machine pins its public key. Exactly 32 bytes, in base64 (44 characters) or in hex (64 characters, either case): `openssl rand -base64 32`. A value of its own, never derived from `APIARY_ENCRYPTION_SECRET` and never the same. There is no fallback, and the boot refuses the same value as `APIARY_ENCRYPTION_SECRET`, the fixture seeds Forager's contract publishes and the development and test seeds this repository publishes. Changing it, or losing it, means pinning every machine again. Keep it with `APIARY_ENCRYPTION_SECRET` ([Backup and restore](backup.md)). |
| `APIARY_ACCEPT_SIGNING_FINGERPRINT` | none | Empty, except to change the signing key on purpose: the fingerprint the key check names as the new key's, which the next boot records as the instance's ([The keys generated at first start](#the-keys-generated-at-first-start)). Any other value changes nothing. A fingerprint is public, not a secret. |
<!-- feature: secrets -->

`APIARY_ENCRYPTION_SECRET` also encrypts the workspaces' stored secret values, under keys
derived from it: it must never change once one exists, and losing it loses every stored
value, for good.
<!-- /feature -->

```text
environment variable SECRET_KEY_BASE is missing.
You can generate one by calling: mix phx.gen.secret
With compose.yaml, the service keys generates it at first start, in /var/lib/apiary/keys/apiary.env.
```

```text
environment variable APIARY_ENCRYPTION_SECRET is missing.
It is 32 random bytes in base64. Generate one with: openssl rand -base64 32
With compose.yaml, the service keys generates it at first start, in /var/lib/apiary/keys/apiary.env.
```

```text
environment variable APIARY_ENCRYPTION_SECRET is not 32 bytes in base64 (44 characters) or in hex (64 characters).
Generate one with: openssl rand -base64 32
```

```text
environment variable APIARY_SIGNING_SECRET is missing.
It is 32 random bytes in base64, generated apart from APIARY_ENCRYPTION_SECRET.
Generate one with: openssl rand -base64 32
With compose.yaml, the service keys generates it at first start, in /var/lib/apiary/keys/apiary.env.
```

```text
environment variable APIARY_SIGNING_SECRET is not 32 bytes in base64 (44 characters) or in hex (64 characters).
Generate one with: openssl rand -base64 32
```

```text
environment variable APIARY_SIGNING_SECRET is the same value as APIARY_ENCRYPTION_SECRET.
It is a secret of its own, generated apart. Generate one with: openssl rand -base64 32
```

```text
environment variable APIARY_SIGNING_SECRET is the development or test seed this repository publishes.
Generate one with: openssl rand -base64 32
```

```text
APIARY_SIGNING_SECRET is a value the Forager contract publishes in its fixtures, so anyone could sign as this instance. Generate one with: openssl rand -base64 32
```

### The keys generated at first start

`bin/keys`, which the service `keys` of `compose.yaml` runs at every start before Postgres
and the server, keeps the instance's keys in the volume `keys`, in the file
`/var/lib/apiary/keys/apiary.env`: `SECRET_KEY_BASE`, `APIARY_ENCRYPTION_SECRET`,
`APIARY_SIGNING_SECRET` and `DATABASE_PASSWORD`, one `NAME=value` line each, mode 0600,
owned by `nobody`. For each name:

- set in the environment, that is in `.env`: it is not generated, and the file does not
  keep it;
- held by the file: it is kept, never changed;
- else: it is generated with `openssl`, `SECRET_KEY_BASE` from 48 random bytes, each of the
  two 32-byte keys from 32 bytes of its own, in base64, and the database password from 24
  bytes, in hex.

It also writes the database password to `/var/lib/apiary/keys/postgres-password`, mode
0644, which the bundled Postgres reads as `POSTGRES_PASSWORD_FILE`. Postgres sets it when
its volume is first created. Each file is written whole to a temporary file and renamed,
so a crash leaves no half file. `bin/keys` prints names and paths, never a value:

```text
Generated SECRET_KEY_BASE, APIARY_ENCRYPTION_SECRET, APIARY_SIGNING_SECRET and DATABASE_PASSWORD in /var/lib/apiary/keys/apiary.env.
Keep a copy apart from the database backups: without APIARY_ENCRYPTION_SECRET no access key is trusted. To print the file: docker compose exec apiary cat /var/lib/apiary/keys/apiary.env
```

```text
The keys in /var/lib/apiary/keys/apiary.env are kept; none was generated.
```

A name set in the environment, which the file does not hold, and one the file holds:

```text
APIARY_SIGNING_SECRET is set in the environment: not generated, not kept here.
```

```text
APIARY_SIGNING_SECRET is set in the environment, which wins; the file keeps its own.
```

When it cannot write, it exits non-zero, and nothing that depends on it starts:

```text
Cannot write /var/lib/apiary/keys: Permission denied. The volume keys has to be writable by the user nobody.
```

The release reads the file at boot, from the directory `APIARY_KEYS_DIR` names, which the
image sets to `/var/lib/apiary/keys`, for each of the four names the environment does not
set: the environment always wins. The two 32-byte keys may be in base64 (44 characters)
or in hex (64 characters, either case); both are decoded to the same bytes.

Keep a copy of the keys apart from the database backups ([Backup and restore](backup.md)).
`docker compose down --volumes` deletes the volume `keys` with the database's: with the
bundled Postgres the two go together. With an external Postgres, a start on a new volume
generates new keys against the old database, and the key check below stops it.

**The key check at boot.** At its first boot the instance records a check value of
`APIARY_ENCRYPTION_SECRET`, which tells nothing of the secret, and the fingerprint of its
signing key, in its own row of `instance_settings`. At every boot, once the migrations
have run and before it serves, it compares both with the keys it runs with; before it
records the check value on a database that already holds data, the oldest row made under
an `APIARY_ENCRYPTION_SECRET` must have been made under this one, so a wrong secret is
not recorded as the right one. A boot with another `APIARY_ENCRYPTION_SECRET` stops, and
the log says first:

```text
APIARY_ENCRYPTION_SECRET is not the one this instance first started with.
```

and then to put back the value kept with your backups. A boot with another
`APIARY_SIGNING_SECRET` stops with both fingerprints, which are public: they are what
every machine pins.

```text
APIARY_SIGNING_SECRET is not the one this instance's machines pinned: its key's fingerprint is <new>, the pinned one is <recorded>.
Put back the value kept with your backups. To change it on purpose, and pin every machine again, set APIARY_ACCEPT_SIGNING_FINGERPRINT=<new> and start Qory Apiary again.
```

To change the signing key on purpose, which means pinning every machine again, set
`APIARY_ACCEPT_SIGNING_FINGERPRINT` to the new key's fingerprint, the `<new>` the message
names. With `compose.yaml`, put it in `.env`, then:

```sh
docker compose up -d
```

The boot records the new key's fingerprint as the instance's, says so in the log, and
starts:

```text
The signing key with fingerprint <new> is now the instance's. Pin it on every machine again.
```

Any other value changes nothing, and the boot stops as before. The variable names one key,
so it needs no reset: left set, it matches the key it named, and should the key change
again, the boot stops again with the next fingerprint. Taking the line out of `.env` later
is tidy, not required. The boot reads it only once `APIARY_ENCRYPTION_SECRET` is the one
the instance first started with. `APIARY_ENCRYPTION_SECRET` has no such variable: it never
changes once an access key exists.

### Public address and port

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `PUBLIC_URL` | required | The address people and machines use to reach this instance, `https://qory.example`, or `http://localhost:4100` for a trial on one machine. `http` or `https`, a host and optionally a port, and nothing after: a path, a query or a user is refused at boot, because Forager refuses a server URL that has one. It decides the links in emails, the discovery document and whether plain HTTP is redirected. Forager accepts plain `http` only to an address of its own machine, so for other machines the public URL is `https`. |
| `PHX_HOST` | none | Read only when `PUBLIC_URL` is not set: the public address is then `https://` and this host. `.env.example` does not list it; set `PUBLIC_URL`. |
| `PORT` | `4100` | The port the release listens on inside the container. An integer. `compose.yaml` publishes 4100, on `127.0.0.1`, so change both or neither. |
| `PHX_SERVER` | set by `bin/server` | Any value makes the release serve HTTP. `bin/server` sets it; whoever starts `bin/apiary start` directly sets it too. |

```text
environment variable PUBLIC_URL is missing.
It is the address of this instance, for example: https://qory.example
```

```text
environment variable PUBLIC_URL must start with http:// or https://.
For example: https://qory.example
```

```text
environment variable PUBLIC_URL has no host.
For example: https://qory.example
```

```text
environment variable PUBLIC_URL must be a scheme and a host, with a port when it has one,
and nothing after: no path, no query. Forager refuses a server URL that has more.
For example: https://qory.example
```

### Mail

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `SMTP_RELAY` | none | The host of the SMTP relay. Empty counts as not set. Not set, the release sends no email, and says so in one line of its log at each start, at level `info`. |
| `SMTP_PORT` | `587` | The relay's port. An integer. `465` means implicit TLS on connect; any other port uses STARTTLS as `SMTP_TLS` says. |
| `SMTP_USERNAME` | none | The relay's user. Not set, or left empty as `.env.example` has it, means no authentication; set means the release always authenticates. |
| `SMTP_PASSWORD` | none | The relay's password. |
| `SMTP_TLS` | `always` | The STARTTLS policy: `always`, `if_available` or `never`. Not read on port 465. |
| `MAIL_FROM` | `qory@` and the host of `PUBLIC_URL` | The sender address of every email. |

```text
environment variable SMTP_TLS must be always, if_available or never
```

### Clustering

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `DNS_CLUSTER_QUERY` | none | A DNS name whose A and AAAA records list the other nodes to cluster with. Not set means one node. |

### Features

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `QORY_FEATURES` | `all` | The features this instance has: `all`; `all-` and the features left out, separated by commas; or the features on, separated by commas. Not set, or empty, is `all`. |

- `observability`: the record, the runs with their terminals and timelines, the
  connections, and retention. Every instance has it, and every other feature needs it.
<!-- feature: security -->
- `security`: the security policy, and the run configuration served to gateways. Needs
  `observability`.
<!-- /feature -->

A feature that is off is absent, not disabled: its pages answer not found, the console and
the discovery document leave it out, and the documentation at `/docs` does not describe
it.

The organisation and its workspace have the features the instance has. An instance with
the record alone:

```sh
QORY_FEATURES=observability
```
<!-- feature: security -->

The record and the security policy, and nothing else:

```sh
QORY_FEATURES=observability,security
```

Every feature but the security policy:

```sh
QORY_FEATURES=all-security
```
<!-- /feature -->

The two forms differ when an upgrade brings a feature. `all` and `all-…` switch it on with
the upgrade; a list leaves it off until you add it to the list.

An opt-in feature is on only when a list names it: `all`, `all-…`, and a value that is not
set or empty leave it off, with or without an upgrade.

The value is read once, at boot. A name that is not a feature, or a feature without one it
needs, stops the boot:

```text
environment variable QORY_FEATURES is not valid: unknown feature obsevability; the Install guide at /docs lists the features.
Leave it unset or set it to all for the default features, or name them, for example:
QORY_FEATURES=observability
```

To switch a feature on later, add it to the value and restart. Every instance has the
whole database schema whatever its features, so nothing is migrated.

### Audit trail

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `AUDIT_RETENTION_DAYS` | `90` | How many days the audit trail keeps an entry: a whole number from `30` to `90`. Not set, or empty, is `90`. |
| `AUDIT_ADDRESS_RETENTION_DAYS` | `90` | How many days an entry keeps the address and the client (the browser's user agent) it came from, after which they are cleared and the rest of the entry stays: a whole number from `1` to the value of `AUDIT_RETENTION_DAYS`. Not set, or empty, is `90`, or the value of `AUDIT_RETENTION_DAYS` when that is shorter. |
| `TRUSTED_PROXIES` | none | The reverse proxies whose `X-Forwarded-For` gives the address a change came from, and the address the limits on signing in count by: addresses or CIDR ranges, separated by commas ([TLS and the reverse proxy](#tls-and-the-reverse-proxy)). Not set, or empty, trusts none. An entry that is neither, or a range of every address (a prefix of `0`), stops the boot. |

Every change made to what an organisation holds leaves an entry in its audit trail, which
its owners and admins read on its Audit log page, `/:org/audit-log`, in the organisation's sidebar: who made it (a person, an access
key, or Qory Apiary itself for its own scheduled work), when, from which address and client, and
what it changed. An entry never holds a secret, nor a person's name or email address: it
names a person by their account, and the page looks the address up when it shows it.
<!-- feature: security -->
The security policy's history is part of the trail.
<!-- /feature -->

Once a day, at 02:40 UTC, a job deletes every organisation's entries older than
`AUDIT_RETENTION_DAYS`, and each deletion is itself an entry. The address and the client
are personal data, kept no longer than the entry and for less if you choose: the same job
clears them from the entries older than `AUDIT_ADDRESS_RETENTION_DAYS`, 90 days unless
set, and leaves the rest of each entry for the trail's period. The clearing writes no
entry of its own; a deletion's entry says how many it cleared beside. A value outside the
bounds stops the boot:

```text
environment variable AUDIT_RETENTION_DAYS is not valid: it is a number of days from 30 to 90, got: "365"; 90 days is the most this edition keeps.
Leave it unset for 90 days, or set it, for example:
AUDIT_RETENTION_DAYS=60
```

An `AUDIT_ADDRESS_RETENTION_DAYS` longer than `AUDIT_RETENTION_DAYS` stops the boot too,
since an address is not kept longer than its entry. The values are read at boot, so a
change takes a restart. A shorter period deletes or clears what it no longer keeps at the
next day's job; setting it longer again does not bring it back.

<!-- feature: secrets -->
### Integrations

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `INTEGRATION_URL_SOURCES` | `true` | Whether an integration may be added from an https address of its `description.json`: `true`, `1` or `yes`, or `false`, `0` or `no`. Not set, or empty, is `true`. Any other value stops the boot. |

When a workspace adds an integration from a release, Qory Apiary reads the release's
`description.json` and `checksums.txt` from the forge or the address it names. A release
is on `github.com`, `gitlab.com` or `codeberg.org`, found by the repository's path and
the version at the download address that forge gives it (on GitLab, the API's download
route, `/api/v4/projects/…/releases/…/downloads/…`, which redirects to where the
release's link points), or at an https address of its `description.json`. A repository
on any other host is refused: self-hosted forges are not supported.

Qory Apiary connects only to public addresses: it resolves the host, refuses the fetch when any
address is private, loopback, link-local or a cloud metadata address, and connects to the
address it checked, each redirect checked again, at most five, within 15 seconds and
1 MiB. This holds for every host, and no setting allows a private address. A fetch that
fails says only that it failed; the reason is in the log, with the address it was
fetching.

An address of a `description.json` may be on any host, so an instance open to people you
do not know, such as a cloud service, sets `INTEGRATION_URL_SOURCES=false`: integrations
are then added from forges' releases alone. A workspace that asks for one from an address
is told so, and a release already asked for from an address is not fetched, nor added.
Even so, Qory Apiary follows a forge release's download links where they lead, to any public
https host: on GitLab a release's links, and on Codeberg its attachments, may be addresses
the release's author chose.

Qory Apiary fetches every release without credentials, as anyone could: no request carries a
token, so private releases are not supported.

The value is read at boot, so a change takes a restart. A release asked for from an
address once `INTEGRATION_URL_SOURCES` is off is not fetched; it fails with
`integration_source_refused`, and a release found before is not added.
<!-- /feature -->

### Sign-up and invitations

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `INVITATIONS_PER_DAY` | `20` | How many invitations the organisation makes in 24 hours, emailed or copied: a whole number from `1`. Not set, or empty, is `20`. |
| `FIRST_ADMIN_EMAIL` | none | Optional. The first admin's address, used once, at the instance's first start, with `FIRST_ORGANISATION_NAME` ([The instance admins](#the-instance-admins)). Not set, or empty, with `FIRST_ORGANISATION_NAME` empty too, leaves the first sign-up to the web. |
| `FIRST_ORGANISATION_NAME` | none | Optional. The name of the instance's organisation, created with the first admin at the first start; the same rules as an organisation's name on the sign-up page. |

The first person who signs up on a new instance creates its organisation, with its
workspace **Main**, and is its owner. The instance has that one organisation and that one
workspace. The organisation is the instance's own, and its owners are the instance's
**instance admins** ([The instance admins](#the-instance-admins)); to everyone in it, it
is an organisation like any other. The first sign-up is always offered, until someone has
signed up; with `FIRST_ADMIN_EMAIL` and `FIRST_ORGANISATION_NAME` set, the first start
makes it before the instance serves a page ([The instance admins](#the-instance-admins)).

After the first, nobody signs up without an invitation: the sign-up page says sign-up is by
invitation, and the landing and log-in pages offer none. People join through an invitation
from an owner or an admin of the organisation, sent from its **Members** page. Someone with
an invitation signs up without being asked for an organisation's name, and joins the
organisation.

An invitation is an email address and nothing else: the invited person joins as a member,
and an owner makes them an admin or an owner afterwards. The email names the organisation
only inside a sentence the instance writes, never in its subject or as a heading, and does
not name the person who sent it; only someone whose account is confirmed can send one. The
organisation's name cannot hold a web address (`://` or `www.`), quotation marks other
than an apostrophe, straight or curly, control characters or invisible Unicode characters;
a name like `Acme.io` or `Dana’s` is fine, though a mail client may turn a bare domain into
a link. Once the organisation has made `INVITATIONS_PER_DAY` invitations in the last 24
hours, whoever makes the next is told so, and it makes no more until the oldest of them is
a day old; an invitation that was accepted, revoked or deleted since still counts, and one
whose email could not be delivered does not. Every invitation tried, delivered or not, counts against three times
`INVITATIONS_PER_DAY`, so the organisation cannot keep sending to addresses that bounce.

Without mail, nothing is sent: the invite page shows the invitation's link once, for
whoever invites to copy and send themselves, and their account need not be confirmed.
Only the link's hash is kept, so it cannot be shown again; **Make a new link** on the
pending invitation makes another, which works for seven days again, and the old one stops
working at once. A link copied, and each new link made, count against
`INVITATIONS_PER_DAY` as an emailed invitation does.

A value it does not accept stops the boot:

```text
environment variable INVITATIONS_PER_DAY is not valid: it is a whole number of invitations from 1, got: "0".
Leave it unset for 20 a day, or set it, for example:
INVITATIONS_PER_DAY=50
```

### Deletion

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `DELETION_GRACE_DAYS` | `30` | How many days a deleted workspace or organisation is kept, and can be restored, before it is purged: a whole number from `1` to `90`. Not set, or empty, is `30`. |

The instance's organisation is not deleted, since its owners run the instance, and neither
is its workspace Main, its only one: the organisation's settings say so. The value is
checked at boot all the same, and one outside the bounds stops the boot:

```text
environment variable DELETION_GRACE_DAYS is not valid: it is a number of days from 1 to 90, got: "0".
Leave it unset for 30 days, or set it, for example:
DELETION_GRACE_DAYS=14
```

A person deletes their own account on **Account settings**; it is deleted at once, and its
row stays without the address, the password or the preferences, so what the person did
keeps naming them, as "Former member". Invitations are deleted when they are accepted,
and 30 days after they expired. One command, for whoever runs the instance with a shell on
the release, answers a request made in writing:

```sh
bin/apiary eval 'Apiary.Release.delete_account("dana@example.com")'
```

It deletes an account by its address, as the person would, and refuses while the person is
the organisation's only owner: make another member an owner first.

### The instance admins

The instance admins are the owners of the instance's organisation, the one the instance's
first user signed up with. Inside the organisation they act at their level, as any owner
does. Two commands, for whoever has a shell on the release, make an account one and take
it away, for an install that is scripted and for recovery when no admin is left; for the
first admin of a new instance, `FIRST_ADMIN_EMAIL` and `FIRST_ORGANISATION_NAME`, below,
are simpler, as they need no shell:

```sh
bin/apiary eval 'Apiary.Release.grant_instance_admin("dana@example.com")'
bin/apiary eval 'Apiary.Release.revoke_instance_admin("dana@example.com")'
```

**Claim a fresh instance at its first start** with `FIRST_ADMIN_EMAIL` and
`FIRST_ORGANISATION_NAME`, both optional. With `compose.yaml`, set them in `.env` before
the first `docker compose up -d`:

```sh
FIRST_ADMIN_EMAIL=you@example.com
FIRST_ORGANISATION_NAME=Acme
```

On an instance nobody has signed up to, the first start claims it before it serves a
page, so no sign-up on the web can come first: it is the instance's first sign-up, as the
command below makes it, and emails you your log-in link. Should the email not go out, the
instance is claimed all the same, and the log says to ask for a link at `/users/log-in`
once the mail settings work. The boot's own lines never carry the address or the link.
On an instance that has its organisation, a restored one
included, the boot ignores the two: it checks neither, creates and grants nothing, sends no
email and writes no line, so changing them later changes nothing, and later admins are
invited in Qory. Of two starts at once, one claims and the other starts as on any
instance. Both empty, the first sign-up is the web's. On an instance nobody has signed up
to, one set and the other empty, or a value the sign-up page would refuse, stops the boot
with a message that names the variable and not the value:

```text
environment variable FIRST_ORGANISATION_NAME is empty, and FIRST_ADMIN_EMAIL is set. Set both to claim this instance at its first start, or neither.
```

```text
environment variable FIRST_ADMIN_EMAIL is not valid: must have the @ sign and no spaces.
```

**Claim a fresh instance before its address is public** with the first command too, given
the name of your organisation:

```sh
bin/apiary eval 'Apiary.Release.grant_instance_admin("dana@example.com", "Acme")'
```

On an instance nobody has signed up to, it is the instance's first sign-up: it creates the
organisation, its workspace Main and the account as its owner, and emails the account its
log-in link, as the sign-up page would. Without the name it is refused and says so. Should
the email not go out, the instance is claimed all the same, and the command says to ask
for a link at `/users/log-in` once the mail settings work; it never prints the address or
the link. Should someone sign up on the web a moment before,
theirs is the first sign-up, and the command does what it does on any instance.

Otherwise the first command makes the account an owner of the instance's organisation,
adding it to the organisation when it is not there yet; the account must exist, so the
person signs up with an invitation first. The second makes an instance admin a member of
the organisation: they stay in it, where an owner removes them if they should leave. It
refuses the last instance admin: grant another first. Each is an entry in the
organisation's activity, by Qory Apiary rather than by a person.

**Suspending** a member pauses and removes nothing, and **Activate** undoes it; each is an
entry in the activity. On the organisation's **Members** page an owner suspends an admin or
a member, and an admin a member, and nobody suspends themselves. A suspended person acts in
the organisation no more, and is told so when they open it, until they are activated; their
open pages follow. **The access keys they added keep working**: an access key belongs to
its node, not to a person, so an owner or an admin revokes it on the node's **Access key**
tab if it should stop.

The last owner of the organisation who may act is not suspended, made an admin or a member,
or removed. Should every instance admin be locked out, `grant_instance_admin` is the way
back.

### Compose only

`docker compose` reads these, and the release does not. Compose takes a variable from the
shell that runs it before `.env`: a value exported in the shell wins over the line in
`.env`.

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `APIARY_VERSION` | required by `docker compose` | The tag of the image to run: a release's version, without the `v`. `.env.example` leaves it empty, and compose refuses to start without it and says `set APIARY_VERSION in .env`. |
| `APIARY_IMAGE` | `ghcr.io/qoryai/apiary` | The image, without its tag. |
| `COMPOSE_PROFILES` | `postgres` in `.env.example` | `postgres` runs the bundled Postgres. Take the line out, or leave it empty, with an external Postgres in `DATABASE_URL`. |

`compose.yaml` publishes the release's port on `127.0.0.1:4100` only, for a reverse proxy
on the same machine. For a proxy elsewhere, a `compose.override.yaml` beside it publishes
the port on an address that proxy reaches, as well:

```yaml
services:
  apiary:
    ports:
      - "10.0.0.5:4100:4100"
```

`POOL_SIZE`, `PORT` and `SMTP_PORT` have to be integers. A value that is not one stops the
boot with an error that does not name the variable.

## Backups

Postgres is the only state, so a `pg_dump` of the database is a complete backup, and the
three values to keep beside it are `APIARY_ENCRYPTION_SECRET`, `APIARY_SIGNING_SECRET` and
`SECRET_KEY_BASE`, which `compose.yaml` keeps in the volume `keys`.
[Backup and restore](backup.md) has the commands for the compose installation, its keys
and an external Postgres, what is lost without each key, and a restore drill. A deleted account
does not reach the backups taken before it: those hold its address until they expire, so
how long you keep dumps bounds how long a deletion takes to be complete. What the server
deletes with age, and how to keep less or more, is in [Retention](retention.md).

## Before other people sign in

Go through the [hosting checklist](hosting-checklist.md).
