# Contributing

Thank you for considering a contribution.

A question or a bug is an issue on this repository. A vulnerability is not: report it the
way [SECURITY.md](SECURITY.md) says.

## Where contributions go

Everywhere. Four kinds are the most useful:

- **A page or a context feature of the console.** A LiveView under `lib/apiary_web/live/`
  or a function in one of the contexts under `lib/apiary/`, with its test. The console is
  what an organisation sees: its workspace, the members, the access keys, the settings.
- **The receiver of the server contract.** Discovery, the events endpoint and the run
  configuration exist, each behind the same signed request; the discovery document names
  the run configuration for a workspace whose policy somebody has made. What the endpoints
  assume beyond the contract is written down in
  [docs/contract-assumptions.md](docs/contract-assumptions.md). The contract
  itself lives in [qoryai/forager](https://github.com/qoryai/forager), under
  `contracts/forager/v1/`; a change to the contract goes there, and this repository follows it.
- **The security policy.** [SECURITY.md](SECURITY.md) says what counts as a vulnerability
  here. A tighter definition, or a case it misses, is a contribution.
- **Docs.** [README.md](README.md) for running the released image, the guides under
  [guides/](guides/), which every instance serves at `/docs`
  ([guides/upgrading.md](guides/upgrading.md) for a self-hoster's restart),
  [CHANGELOG.md](CHANGELOG.md) for what a release did, and this file for running it from a
  checkout.

## Contributor Licence Agreement

You keep the copyright in your contribution. Every contribution is made under the
Contributor Licence Agreement in [CLA.md](CLA.md), under which **8wonders GmbH, and its
successors and assigns**, hold a licence to it: perpetual, worldwide and irrevocable,
including the right to license and relicense it, and a patent grant on the same terms as
the Apache License, Version 2.0. That licence is what lets 8wonders GmbH license the
project, including in its other editions ([EDITIONS.md](EDITIONS.md)). The Apache grant to
everyone stands beside it: what you contribute is also licensed to every user under the
Apache License, Version 2.0 (Licence, below).

Opening a pull request against this repository is your acceptance of the agreement, for that
contribution and every later one. The pull request is the record of your acceptance. Read
[CLA.md](CLA.md) before your first pull request.

The agreement names 8wonders GmbH with successors-and-assigns wording, so that if the
project moves into a dedicated entity, existing grants travel with it and nobody signs again.

## Licence

By contributing, you agree that your contribution is licensed under the Apache License,
Version 2.0 (see [LICENSE](LICENSE)) in addition to the CLA grant above.

## Run it from a checkout

You need Docker with `docker compose`, and `git`. This builds the image from the checkout
and runs it with the repository's `compose.yaml`: Postgres, the keys generated at first
start, and the server on port 4100 of `127.0.0.1`.

```sh
git clone https://github.com/qoryai/apiary.git && cd apiary
docker build -t apiary:dev .
cp .env.example .env
APIARY_IMAGE=apiary APIARY_VERSION=dev docker compose up -d
curl http://localhost:4100/health
```

The build takes a few minutes. The image is `apiary:dev`, never the name of the image a
release publishes. `APIARY_IMAGE` and `APIARY_VERSION` name it in place of
`ghcr.io/qoryai/apiary`, which a release publishes; the shell's values win over `.env`'s.
Every later `docker compose` command reads them too, `docker compose logs` included, so set
them in the shell for those first:

```sh
export APIARY_IMAGE=apiary APIARY_VERSION=dev
```

`/health` answers once the migrations have run, a few seconds after the start:

```text
{"status":"ok","database":"ok","version":"0.1.0","revision":null}
```

`revision` is the commit the image was built from: `null` here, since a `docker build` of
your own names none. From the set-up link on, go on as the
[quickstart](guides/quickstart.md) does from its step 4, with the `export` set.

## Development

The toolchain is pinned in `mise.toml`; `mise install` provides it. Erlang 29, Elixir 1.20
and Node 24, which runs the browser scripts' tests (no npm). Postgres must be reachable on
`localhost:5432` as user `postgres` without a password; that is the one thing mise does not provide. The development database is
`apiary_dev`; to use another, set `DATABASE_URL` (`ecto://postgres@localhost/my_database`)
in `mise.local.toml`, which is not tracked, or in the shell.

```sh
mix setup                          # dependencies, database, assets
mix test                           # creates and migrates the test database, then runs everything
mix format                         # CI runs mix format --check-formatted
mix compile --warnings-as-errors
mix docs --warnings-as-errors      # the guides and the module reference, into priv/static/docs
mix gettext.extract --merge        # after changing a visible string; see docs/lingo.md
mix precommit                      # the above plus deps.unlock --unused and the Gettext check; run it before a pull request
node --test 'assets/js/test/*.test.mjs'  # the browser scripts' tests, under Node's WebCrypto
mix phx.server                     # http://localhost:4100
```

The tests tagged `:contract` replay Forager's contract fixtures at the commit in
`.forager-contract-ref`. They take them from `FORAGER_CONTRACT_DIR`, set to
`contracts/forager/v1` of a qoryai/forager checkout at that commit. Without it they are
left out, and a line says so.

CI (`.github/workflows/ci.yml`) runs five jobs side by side. **Checks**, the checks that
do not depend on the features, runs once: the formatting check, the compile with warnings
as errors, the Gettext check, the browser scripts' tests, the documentation build,
`MIX_ENV=prod mix assets.deploy` to prove the assets still build, and the AWS template's
checks. **The tests** run under each of three sets of features: every feature, the
default features, and the record alone. **The image** is built on each platform,
`linux/amd64` and `linux/arm64`. **Database over TLS** runs the tests tagged
`database_tls` against a Postgres 18 that serves TLS. **Compose install and upgrade**
runs `compose.yaml` as a person does: the install, a restart, the path from a checkout,
the upgrade from the base commit's image and from the latest release, and an external
Postgres over TLS.

Links the application generates, magic links and invitations, are built for
`PHX_HOST`, default `localhost`; when a local reverse proxy serves the dev server under
another name, set `PHX_HOST` (or a full `PUBLIC_URL`) in `mise.local.toml`, which is not
tracked, or in the shell. Emails in development go to `http://localhost:4100/dev/mailbox`.

## Architecture, access and conventions

How the application is built and the rules its code follows are under [docs/](docs/):
[architecture.md](docs/architecture.md) for the layout, the organisation keys and the
edition seams,
[conventions.md](docs/conventions.md) for migrations, tests, doc comments and the vocabulary,
[access.md](docs/access.md) for who may do what,
[lingo.md](docs/lingo.md) for the words on the page,
[ui.md](docs/ui.md) for the rules the pages follow, and
[contract-assumptions.md](docs/contract-assumptions.md) for the server contract. A change to
what they describe changes them in the same pull request.

## Releases

How a release is made is in [docs/releases.md](docs/releases.md). A tag `vX.Y.Z` runs
`.github/workflows/release.yml`, which publishes the image `ghcr.io/qoryai/apiary` as
`X.Y.Z`, `X.Y` and `latest`, and the GitHub release with `compose.yaml`, `env.example` and
`apiary.yaml` attached; the README's Run it downloads the first two. Pre-release images go
to `ghcr.io/qoryai/apiary-prerelease`, a private package and not a place to install from:
only releases are installed.

## Pull requests

Run `mix precommit` before opening one. Commit messages say what changed and why it was
needed, in the imperative.
