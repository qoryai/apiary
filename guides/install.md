# Install and configure

Qory Apiary is one container image. Postgres is its only dependency and holds all of its state.
Configuration is by environment variables, read once at boot. Pending database migrations
run at boot, before the server accepts a request, so an upgrade is a restart
([Upgrading](upgrading.md)).

[From nothing to a first run](quickstart.md) is the shortest way to a running trial. This
page is the reference for an installation that stays.

## The pieces

- **The image** is built from the `Dockerfile` of the repository. It holds the release and
  nothing else, runs as the user `nobody`, and its command is `bin/server`, which migrates
  and serves. `bin/migrate` runs the same migrations by hand, and `bin/apiary version`
  prints the release's version.
- **Postgres.** The `docker-compose.yml` of the repository starts Postgres 18 with the role
  `apiary`, the database `apiary` and the volume `postgres-data`, and starts the `apiary`
  service once the database is healthy, publishing port 4100. An external Postgres is one
  `DATABASE_URL` away; the role needs the right to create and alter tables in its
  database, since the release migrates it.
- **A reverse proxy** that terminates TLS, in front of the port.
- **An SMTP relay.** People sign in with a link sent by email and are invited by email, so
  the release does not boot without a way to deliver mail.

```sh
cp .env.example .env    # fill in the values
docker compose up --build -d
```

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

Links in emails, the `server` block the console shows for a new access key and the URLs in
the discovery document are all built from `PUBLIC_URL`, never from the request's `Host`
header. A `PUBLIC_URL` that is not the address runners and people use gives them links that
do not work.

## Health

`GET /health` needs no authentication and no session, and is never cached
(`Cache-Control: no-store`). It asks the database `SELECT 1`, with five seconds to answer.

| Status | Body | When |
|---|---|---|
| `200` | `{"status":"ok","database":"ok","version":"0.2.0"}` | the database answered; `version` is the release's |
| `503` | `{"status":"degraded","database":"error"}` | the database did not answer |

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
page under `/:org/…` and its reads, a runner's request, the projection of a run's events,
a background job, and the line that says a job failed, was cancelled or was discarded. A
line written for a signed-in person carries their id as `metadata.user_id`: every page
they open, and a job their action enqueued. A person's own pages, their account settings
and their organisations, carry `user_id` and no organisation or workspace. A runner's
request is an access key's and carries no `user_id`.

The ids are never a name, a slug or an email address, so a search by any of them finds
everything that happened for it without the log holding a customer's or a person's names.
`user_id` is a pseudonymous id: the log alone does not say who it is. A job's line names
the job, its attempt and the kind of error, never its arguments or the error's message.

A request line's duration is `metadata.duration_us`, in microseconds. No header and no
body is ever logged, and neither is anything a runner signed or sent. Four routes carry a
secret in their path, an invitation, its continuation, a log-in link and an email change;
their secret segment is logged as `:token`, so a reader of the log cannot sign in or join
an organisation with what it finds there.

The exception is `MAIL_TO_LOG=true`, which writes whole emails to the log, links included.
It is for a trial on one machine only.

## Environment variables

Every variable the release reads in production. "Required" means the release does not boot
without it and exits with the message shown.

### Database

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `DATABASE_URL` | required | The connection URL, `ecto://USER:PASS@HOST/DATABASE`. With the compose file the host is `postgres` and the role and database are `apiary`. A password with characters that mean something in a URL has to be percent-encoded. |
| `POOL_SIZE` | `10` | Connections in the pool. An integer. |
| `ECTO_IPV6` | off | `true` or `1` connects to the database over IPv6. Anything else is off. |
| `MIGRATE_ON_BOOT` | `true` | `false`, `0` or `no` leaves pending migrations to `bin/migrate`. Anything else runs them at boot. |

```text
environment variable DATABASE_URL is missing.
For example: ecto://USER:PASS@HOST/DATABASE
```

### Secrets

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `SECRET_KEY_BASE` | required | Signs the session cookie and the "Keep me signed in" cookie. At least 64 bytes. Generate one with `openssl rand -base64 48`, or with `mix phx.gen.secret` where there is Mix. |
| `CLOAK_KEY` | required | Encrypts access key secrets at rest. Exactly 32 bytes in base64, 44 characters: `openssl rand -base64 32`. It must never change once an access key exists, or every stored secret becomes unreadable. Keep it with the database backups, not in them ([Backup and restore](backup.md)). |

```text
environment variable SECRET_KEY_BASE is missing.
You can generate one by calling: mix phx.gen.secret
```

```text
environment variable CLOAK_KEY is missing.
It is 32 random bytes in base64. Generate one with: openssl rand -base64 32
```

```text
environment variable CLOAK_KEY is not 32 bytes in base64 (44 characters).
Generate one with: openssl rand -base64 32
```

### Public address and port

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `PUBLIC_URL` | required | The address people and runners use to reach this instance, `https://qory.example`, or `http://localhost:4100` for a trial on one machine. `http` or `https`, a host and optionally a port, and nothing after: a path, a query or a user is refused at boot, because a runner refuses a server URL that has one. It decides the links in emails, the discovery document and whether plain HTTP is redirected. A runner accepts plain `http` only to an address of its own machine, so for runners on other machines the public URL is `https`. |
| `PHX_HOST` | none | Read only when `PUBLIC_URL` is not set: the public address is then `https://` and this host. `.env.example` does not list it; set `PUBLIC_URL`. |
| `PORT` | `4100` | The port the release listens on inside the container. An integer. The compose file publishes 4100, so change both or neither. |
| `PHX_SERVER` | set by `bin/server` | Any value makes the release serve HTTP. `bin/server` sets it; an operator who starts `bin/apiary start` directly sets it too. |

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
and nothing after: no path, no query. Runners refuse a server URL that has more.
For example: https://qory.example
```

### Mail

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `SMTP_RELAY` | required, unless `MAIL_TO_LOG=true` | The host of the SMTP relay. Empty counts as not set. |
| `MAIL_TO_LOG` | off | Read only when `SMTP_RELAY` is not set. Exactly `true` writes every email to the log in full, at level `info`, instead of sending it. For a trial on one machine only: log-in links and invitation links are credentials, and with this setting they reach everyone and everything that reads the log. |
| `SMTP_PORT` | `587` | The relay's port. An integer. `465` means implicit TLS on connect; any other port uses STARTTLS as `SMTP_TLS` says. |
| `SMTP_USERNAME` | none | The relay's user. Not set, or left empty as `.env.example` has it, means no authentication; set means the release always authenticates. |
| `SMTP_PASSWORD` | none | The relay's password. |
| `SMTP_TLS` | `always` | The STARTTLS policy: `always`, `if_available` or `never`. Not read on port 465. |
| `MAIL_FROM` | `qory@` and the host of `PUBLIC_URL` | The sender address of every email. |

```text
no mail delivery is configured.
Set SMTP_RELAY to the host of an SMTP relay, or, for a trial on one machine only,
set MAIL_TO_LOG=true to write every email (log-in links included) to the log.
```

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
- `security`: the security policy, and the run configuration served to runners. Needs
  `observability`.
<!-- /feature -->

A feature that is off is absent, not disabled: its pages answer not found, the console and
the discovery document leave it out, and the documentation at `/docs` does not describe
it. An instance with the record alone:

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

The value is read once, at boot. A name that is not a feature, or a feature without one it
needs, stops the boot:

```text
environment variable QORY_FEATURES is not valid: unknown feature obsevability; the Install guide at /docs lists the features.
Leave it unset or set it to all for every feature, or name them, for example:
QORY_FEATURES=observability
```

To switch a feature on later, add it to the value and restart. Every instance has the
whole database schema whatever its features, so nothing is migrated.

### Compose only

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `POSTGRES_PASSWORD` | required by `docker compose` | The password of the role `apiary` in the bundled Postgres. The release never reads it: it is for the `postgres` service, and the password inside `DATABASE_URL` has to match it. Compose refuses to start without it and says `set POSTGRES_PASSWORD in .env`. Postgres applies it when the volume is first created; changing the variable later does not change the role's password. |

`POOL_SIZE`, `PORT` and `SMTP_PORT` have to be integers. A value that is not one stops the
boot with an error that does not name the variable.

## Backups

Postgres is the only state, so a `pg_dump` of the database is a complete backup, and the
two values to keep beside it are `CLOAK_KEY` and `SECRET_KEY_BASE`.
[Backup and restore](backup.md) has the commands for the compose installation and for an
external Postgres, what is lost without each key, and a restore drill. What the server
deletes with age, and how to keep less or more, is in [Retention](retention.md).

## Before other people sign in

Go through the [hosting checklist](hosting-checklist.md).
