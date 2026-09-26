# Conventions

The conventions for migrations, tests and doc comments, and the vocabulary. How the
application is laid out is in [architecture.md](architecture.md).

## Migrations

One migration per change, generated with `mix ecto.gen.migration`, named for what it does.
The rules are in [guides/upgrading.md](../guides/upgrading.md), because they exist for the person
who restarts a self-hosted installation; the short form:

- **Expand, then contract, in separate releases.** A release adds; the release after it
  removes what nothing reads any more. The previous release keeps running against the
  schema the next one migrated, so a rollback of the application needs no rollback of the
  database.
- **Every migration reverses.** `change` when Ecto can invert it, an explicit `down`
  otherwise. `Apiary.Release.rollback/2` runs it in production.
- **No data rewrite inside a schema migration**, and indexes on large tables are created
  concurrently.
- **The tenant keys come first** ([architecture.md](architecture.md), Tenancy).

The release's section in `CHANGELOG.md` names the tables the migration touches under
Migrations and anything the operator has to do under Upgrading.

## Tests

A test is hermetic: the SQL sandbox for the database, the Swoosh test adapter for email,
nothing that reaches the network. Fixtures hold synthetic data only: no real email
address, no real host name of anyone's infrastructure, no real secret, no key or run
recorded from anyone's machine. Name a test for the behaviour it pins, not for the function
it calls; a LiveView test finds elements by the ids the template sets, not by the words on
the page.

The tests tagged `:contract` (`test/contract/`) replay the fixtures of the server contract
from a checkout of qoryai/runner: `RUNNER_CONTRACT_DIR`, or `../../runner/main/contracts/runner/v1`
when that is there. Without one they are excluded and a line says so; CI checks the runner
out at the ref in `.runner-contract-ref` and sets `CONTRACT_FIXTURES_REQUIRED=1`, which makes
their absence a failure.

## Doc comments

Every context, schema and plug carries a `@moduledoc`, and every public context function a
`@doc`. The conventions:

- The first sentence starts with the name and is a complete sentence: `Organisations
  holds ...`, `create_access_key/2 creates ...`.
- A moduledoc says what the module owns, the words it defines, how a caller uses it, and
  the invariants a caller must not break, such as which scope a function expects.
- Say what the function does, including what it refuses (`{:error, :forbidden}`,
  `{:error, :last_owner}`) and what it returns exactly once, such as a secret.
- A comment inside a function says why the code exists or what is subtle in it, never what
  the next line does.
- Wrap at 90 columns.

One vocabulary, no synonyms: **organisation** is the tenant, the thing that signs up;
**workspace** is the unit of use inside it; **membership** is a user's place in an
organisation and its workspace, at the level owner or member; **access key** is a
workspace's credential for the server contract; **key id** is its public part, `ak_` and
sixteen characters; **secret** is the part that signs, shown once; **run** is one
execution of one session on a machine of the workspace; **event** is one thing a run
reports, delivered to the events URL; **receiver** is what answers the events URL; **run
configuration** is what the runner fetches before a run; **security policy** is
`SECURITY.md`. An organisation is never a team, a tenant in prose or an account; a
workspace is never a team, a project or a hive; an access key is never an API key or a
token; a secret is never a password. The product surface is the one place with other
words: a page, an email or a flash says a domain's words through Gettext, and the software
domain calls a target a **repository** ([lingo.md](lingo.md)). So do the guides,
which are written in the software domain's words. Organisation and workspace are the same
words in every domain; apiary and hive are words of the apiary skin, which is not built
yet. Code, schemas, migrations and these documents say organisation and workspace.
