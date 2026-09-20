# Apiary

Apiary is the console of Qory: an organisation (an apiary) signs up, gets a team (a hive),
and creates an access key for the runner file on its machines. From then on every run of
that hive reports back here. Postgres is the only dependency.

## Local development

Elixir and Erlang come from [mise](https://mise.jdx.dev) (`mise.toml` pins the versions;
run `mise install` once). Postgres must be reachable on `localhost:5432` as user
`postgres` without a password.

```sh
mix setup          # dependencies, database, assets
mix phx.server     # http://localhost:4100
```

Links (magic links, invitations) are generated for `PHX_HOST`, default `localhost`. When a
local reverse proxy serves the dev server under another name, set `PHX_HOST` (or a full
`PUBLIC_URL`) in `mise.local.toml` or the shell; that file is not tracked. Emails in
development go to the mailbox at `http://localhost:4100/dev/mailbox`.

`mix precommit` runs the compiler with warnings as errors, the formatter, the documentation
build with warnings as errors and the tests.

## Documentation

The guides live in [guides/](guides/) and are built with the module reference by `mix docs`
into `priv/static/docs`. Every instance serves them at `/docs`, the release image included,
so the documentation a person reads is that of the version they run. Start with
[guides/quickstart.md](guides/quickstart.md): from nothing to a first run.

## Self-hosting with docker compose

```sh
cp .env.example .env    # fill in the values
docker compose up --build
```

The image builds the release; the compose file adds Postgres 18 with a volume and starts
Qory on port 4100 once the database is healthy. Pending migrations run at boot, so an
upgrade is `docker compose pull` (or `--build`) and `docker compose up`; read
[guides/upgrading.md](guides/upgrading.md) and the release's section in `CHANGELOG.md` first.

`.env` has six groups of variables:

| Group | Variables |
|---|---|
| Database | `DATABASE_URL` (required), `POSTGRES_PASSWORD` (for the bundled Postgres), `POOL_SIZE`, `ECTO_IPV6`, `MIGRATE_ON_BOOT` |
| Secret key base | `SECRET_KEY_BASE` (required; `mix phx.gen.secret`) |
| Encryption key | `CLOAK_KEY` (required; `openssl rand -base64 32`; encrypts access key secrets at rest, keep it with the database backups) |
| Public URL | `PUBLIC_URL` (required: scheme and host, a port when it has one, no path, e.g. `https://qory.example`), `PORT` (default 4100) |
| Mail | `SMTP_RELAY`, `SMTP_PORT` (587), `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_TLS` (`always`, `if_available`, `never`), `MAIL_FROM` (default `qory@<public host>`), `MAIL_TO_LOG` (trial only, see below) |
| Clustering | `DNS_CLUSTER_QUERY` (optional) |

A missing or malformed required variable stops the boot with a message naming it.

TLS is terminated in front of the container. With an `https://` public URL, plain HTTP
requests are redirected and HSTS is sent, so the reverse proxy must pass
`X-Forwarded-Proto: https`. With an `http://` public URL (a LAN, a trial on one machine)
nothing is redirected.

Mail delivery is required: without `SMTP_RELAY` the release refuses to boot, with a
message naming `SMTP_RELAY` and `MAIL_TO_LOG`. For a trial on one machine, `MAIL_TO_LOG=true`
writes every email to the log in full at level `info` instead, so the magic link for the
first sign-in can be copied from `docker compose logs apiary`. Log-in and invitation links
are credentials; with `MAIL_TO_LOG=true` they are readable by anyone who can read the log,
so never use it on an installation other people sign in to.

## Health and logs

`GET /health` needs no authentication and is never cached. It answers
`200 {"status":"ok","database":"ok","version":"0.1.0"}` when the database answers, and
`503 {"status":"degraded","database":"error"}` otherwise.

In production the release writes one JSON object per line to stdout (`time`, `severity`,
`message`, `metadata` with `request_id`; request lines add `request` with method, path,
status, duration, client ip and user agent; never headers or bodies). The token in the path
of an invitation, log-in or email-change link is logged as `:token`. Any log shipper
that reads container stdout can take them as they are. Development keeps the
human-readable format.

## Building a release

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
_build/prod/rel/apiary/bin/server      # with the variables above in the environment
_build/prod/rel/apiary/bin/migrate     # migrations by hand, when MIGRATE_ON_BOOT=false
```

Or build the image directly: `docker build -t apiary .`
