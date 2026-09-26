# Contributing

Thank you for considering a contribution.

## Where contributions go

Everywhere. Four kinds are the most useful:

- **A page or a context feature of the console.** A LiveView under `lib/apiary_web/live/`
  or a function in one of the contexts under `lib/apiary/`, with its test. The console is
  what an organisation sees: its workplace, the members, the access keys, the settings.
- **The receiver of the server contract.** Discovery and the events endpoint exist; the run
  configuration, which the discovery document does not name yet, is the next endpoint to
  build, behind the same signed request. What the endpoints assume beyond the contract is
  written down in [docs/contract-assumptions.md](docs/contract-assumptions.md). The contract
  itself lives in [qoryai/runner](https://github.com/qoryai/runner), under
  `contracts/runner/v1/`; a change to the contract goes there, and this repository follows it.
- **The security policy.** [SECURITY.md](SECURITY.md) says what counts as a vulnerability
  here. A tighter definition, or a case it misses, is a contribution.
- **Docs.** [README.md](README.md) for running it, the guides under [guides/](guides/), which
  every instance serves at `/docs` ([guides/upgrading.md](guides/upgrading.md) for a
  self-hoster's restart), [CHANGELOG.md](CHANGELOG.md) for what a release did.

## Contributor Licence Agreement

Copyright in this project is held by a single owner: **8wonders GmbH, and its successors and
assigns**. To keep that true, every contribution is made under the Contributor Licence
Agreement in [CLA.md](CLA.md): a perpetual, worldwide, irrevocable licence to the
contribution, including the right to relicense it, and a patent grant on the same terms as
the Apache License, Version 2.0. You keep your copyright.

Opening a pull request against this repository is your acceptance of the agreement, for that
contribution and every later one. The pull request is the record of your acceptance. Read
[CLA.md](CLA.md) before your first pull request. A signing step on the pull request may be
added later; it will not change the terms.

The agreement names the owner with successors-and-assigns wording, so that if the
project moves into a dedicated entity, existing grants travel with it and nobody signs again.

Why a CLA at all: the licensing decisions of the project are only executable with a sole
copyright holder. Declaring it before a community exists is what makes it a kept promise
rather than a takeback.

## Licence

By contributing, you agree that your contribution is licensed under the Apache License,
Version 2.0 (see [LICENSE](LICENSE)) in addition to the CLA grant above.

## Development

The toolchain is pinned in `mise.toml`; `mise install` provides it. Erlang 29 and Elixir
1.20. Postgres must be reachable on `localhost:5432` as user `postgres` without a
password; that is the one thing mise does not provide.

```sh
mix setup                          # dependencies, database, assets
mix test                           # creates and migrates the test database, then runs everything
mix format                         # CI runs mix format --check-formatted
mix compile --warnings-as-errors
mix docs --warnings-as-errors      # the guides and the module reference, into priv/static/docs
mix gettext.extract --merge        # after changing a visible string; see docs/lingo.md
mix precommit                      # the above plus deps.unlock --unused and the Gettext check; run it before a pull request
mix phx.server                     # http://localhost:4100
```

CI (`.github/workflows/ci.yml`) runs the formatting check, the compile with warnings as
errors and the tests, then `MIX_ENV=prod mix assets.deploy` to prove the assets still build. Links the application generates, magic links and invitations, are built for
`PHX_HOST`, default `localhost`; when a local reverse proxy serves the dev server under
another name, set `PHX_HOST` (or a full `PUBLIC_URL`) in `mise.local.toml`, which is not
tracked, or in the shell. Emails in development go to `http://localhost:4100/dev/mailbox`.

## Layout

The application is under `lib/apiary/`, one context per concern, each with its schemas
beside it:

- `Apiary.Accounts`: users, their tokens, the notifier, and `Apiary.Accounts.Scope`, the
  caller: the user, the organisation, the hive and the membership.
- `Apiary.Organisations`: organisations, hives, memberships and invitations; sign-up, the
  members of a hive, renaming.
- `Apiary.AccessKeys`: a hive's access keys, their secrets encrypted at rest through
  `Apiary.Vault`, rotation and revocation, and the lookup a signed request verifies against.
- `Apiary.Contract`: the signature of a signed GET, pure functions with no database.
- `Apiary.Release` and `Apiary.Release.Migrator`: what the release runs at boot.

The web side is under `lib/apiary_web/`:

- `contract/`: the server contract. `ApiaryWeb.Contract.SignedRequest` is the plug that
  verifies a signed request and assigns the access key; the controllers behind it answer
  the contract's endpoints: `ConfigurationController` for the discovery document,
  `EventsController` for the events, whose body `RawBody` keeps as it was sent,
  `RunConfigurationController` for the run configuration. Each of them refuses a
  contract revision it does not serve through `ContractVersion`.
- `live/`: the pages behind sign-in, one directory per area (`hive_live`, `member_live`,
  `access_key_live`, `settings_live`, `invitation_live`, `user_live`).
- `controllers/`: health, the home page, and the session controllers.
- `components/`: `core_components.ex` and the layouts. A page composes these; it does not
  write its own button.
- `lingo.ex`: the body's words. Every visible string goes through Gettext in engine words,
  and `priv/gettext/en@software/` says them in the software body's; see
  [docs/lingo.md](docs/lingo.md).
- `router.ex` and `user_auth.ex`: the pipelines, the `live_session` blocks, and what a
  mount loads into the scope.

Migrations are under `priv/repo/migrations/`, one per change. Tests mirror the tree:
`test/apiary/` for the contexts, `test/apiary_web/` for the plugs, controllers and pages.
Fixtures are under `test/support/fixtures/`, one module per context; they create data the
way the product does, through `Apiary.Organisations.sign_up_user/2` and the context
functions, never by inserting rows directly. The one exception is the published key of the
contract's fixtures, which no product function would create.

The tests tagged `:contract` (`test/contract/`) replay the fixtures of the server contract
from a checkout of qoryai/runner: `RUNNER_CONTRACT_DIR`, or `../../runner/main/contracts/runner/v1`
when that is there. Without one they are excluded and a line says so; CI checks the runner
out at the ref in `.runner-contract-ref` and sets `CONTRACT_FIXTURES_REQUIRED=1`, which makes
their absence a failure.

## Tenancy

The organisation is the tenant, and the schema enforces it, not the pages:

- Every table except the account tables (`users`, `users_tokens`) carries
  `organisation_id`, and every table that belongs to a hive carries `hive_id` beside it
  with the composite foreign key `(organisation_id, hive_id)` against `hives`, so no row
  can name a hive of another organisation. Both come in the table's first migration; no
  migration retrofits them.
- A unique constraint is scoped by the organisation: `(organisation_id, name)` on hives,
  `(organisation_id, user_id)` on memberships, `(organisation_id, email)` on pending
  invitations, `(organisation_id, hive_id, label)` on active access keys. A name is
  unique inside an organisation, never across them.
- Every context function that reads or writes an organisation's data takes an
  `Apiary.Accounts.Scope` as its first argument and filters by its organisation and hive,
  and by nothing else the caller passes. The exceptions are the entry points that have no
  caller yet: sign-up, an invitation token, and the key id of a signed request.
- A test for a new table asserts that a row of another organisation is not reachable
  through a scope of this one: two `sign_up_fixture()` calls, a row in the first, a read
  through the second that returns nothing or raises. `test/apiary/access_keys_test.exs`
  has the shape.

A page never touches `Apiary.Repo`; it calls a context with `@current_scope`.

## Migrations

One migration per change, generated with `mix ecto.gen.migration`, named for what it does.
The rules are in [guides/upgrading.md](guides/upgrading.md), because they exist for the person
who restarts a self-hosted installation; the short form:

- **Expand, then contract, in separate releases.** A release adds; the release after it
  removes what nothing reads any more. The previous release keeps running against the
  schema the next one migrated, so a rollback of the application needs no rollback of the
  database.
- **Every migration reverses.** `change` when Ecto can invert it, an explicit `down`
  otherwise. `Apiary.Release.rollback/2` runs it in production.
- **No data rewrite inside a schema migration**, and indexes on large tables are created
  concurrently.
- **The tenant keys come first**, as above.

The release's section in `CHANGELOG.md` names the tables the migration touches under
Migrations and anything the operator has to do under Upgrading.

## Tests

A test is hermetic: the SQL sandbox for the database, the Swoosh test adapter for email,
nothing that reaches the network. Fixtures hold synthetic data only: no real email
address, no real host name of anyone's infrastructure, no real secret, no key or run
recorded from anyone's machine. Name a test for the behaviour it pins, not for the function
it calls; a LiveView test finds elements by the ids the template sets, not by the words on
the page.

## Doc comments

Every context, schema and plug carries a `@moduledoc`, and every public context function a
`@doc`. The conventions:

- The first sentence starts with the name and is a complete sentence: `Organisations
  holds ...`, `create_access_key/2 creates ...`.
- A moduledoc says what the module owns, the words it defines, how a caller uses it, and
  the invariants a caller must not break, such as which scope a function expects.
- Say what the function does, including what it refuses (`{:error, :unauthorized}`,
  `{:error, :last_owner}`) and what it returns exactly once, such as a secret.
- A comment inside a function says why the code exists or what is subtle in it, never what
  the next line does.
- Wrap at 90 columns.

One vocabulary, no synonyms: **organisation** is the tenant, the thing that signs up;
**hive** is the team inside it, the unit of use; **membership** is a user's place in an
organisation and its hive, at the level owner or member; **access key** is a hive's
credential for the server contract; **key id** is its public part, `ak_` and sixteen
characters; **secret** is the part that signs, shown once; **run** is one execution of one
session on a machine of the hive; **event** is one thing a run reports, delivered to the events URL; **receiver** is
what answers the events URL; **run configuration** is what the runner fetches before a run;
**security policy** is `SECURITY.md`. An organisation is never a team, a tenant in prose, a
workspace or an account; a hive is never a team or a project; an access key is never an
API key or a token; a secret is never a password. The product surface is the one place
with other words: a page, an email or a flash says a body's words through Gettext, and the
software body calls a hive a **workplace** ([docs/lingo.md](docs/lingo.md)). So do the
guides, which are written in the software body's words. Code, schemas, migrations and this
file say organisation and hive.

## Releases

A release is a tag on a branch named after it, `v0.1.0`, opened as one pull request. That
branch adds the release's section to `CHANGELOG.md`, `[X.Y.Z] - YYYY-MM-DD` with the day
the tag lands, with Added, Changed and Fixed as they apply and always **Migrations**, the
tables the release's migrations touch and whether one is long, and **Upgrading**, anything
the operator has to do or know; a fix that goes to `main` outside a release branch goes
under `[Unreleased]` until the next one. The same branch sets `version` in `mix.exs` to the
tag without the `v`: that is what `GET /health` and `bin/apiary version` report, and the
release workflow refuses a tag whose version `mix.exs` does not carry.

Pushing `vX.Y.Z` to the GitHub mirror runs `.github/workflows/release.yml`, which takes
the release body from the changelog, builds the image from the `Dockerfile` and publishes
it to `ghcr.io` under the version and `latest`. `scripts/changelog-section.sh 0.1.0` prints
the section the workflow would take, and fails when there is none, which is what stops a
tag from publishing without one. Check both before tagging:

```sh
scripts/changelog-section.sh X.Y.Z
grep 'version: "X.Y.Z"' mix.exs
```

Commit messages say what changed and why it was needed, in the imperative.
