# Conventions

The conventions for migrations, tests and doc comments, and the vocabulary. How the
application is laid out is in [architecture.md](architecture.md).

## Migrations

One migration per change, generated with `mix ecto.gen.migration`, named for what it does.
The rules are in [guides/upgrading.md](../guides/upgrading.md), because they exist for the person
who restarts a self-hosted installation; the short form:

- **A replacement backfills and drops in one migration.** Until Qory Apiary has
  installations, a change that replaces a column or a table backfills the new one and
  drops the old one in the same migration: no expand-then-contract across releases, no
  dual-writes, no notes on rolling back to the old shape, since nothing is installed yet
  and nobody runs an older release against a newer schema.
- **Every migration reverses.** `change` when Ecto can invert it, an explicit `down`
  otherwise. `Apiary.Release.rollback/2` runs it in production.
- **No data rewrite inside a schema migration** but a replacement's backfill, and indexes
  on large tables are created concurrently.
- **The organisation keys come first** ([architecture.md](architecture.md), Organisation
  keys).

The release's section in `CHANGELOG.md` names the tables the migration touches under
Migrations and anything the operator has to do under Upgrading.

The core's migrations are in `priv/repo/migrations`. An edition's are in a folder of its
own, which sorts after the core's baseline, and the two run as one sequence by version
(`c:Apiary.Edition.migrations_paths/0`, which the release runs). An edition's migration
creates, changes and drops the edition's tables only, and may add a foreign key from one
of them to a key of the core's; a core migration never changes a key an edition may
reference without a note under Migrations. After the migrations the release runs the
edition's step (`c:Apiary.Edition.after_migrate/0`).

## Tests

A test is hermetic: the SQL sandbox for the database, the Swoosh test adapter for email,
nothing that reaches the network. Fixtures hold synthetic data only: no real email
address, no real host name of anyone's infrastructure, no real secret, no key or run
recorded from anyone's machine. Name a test for the behaviour it pins, not for the function
it calls; a LiveView test finds elements by the ids the template sets, not by the words on
the page.

One row is outside the sandbox on purpose: the instance's own organisation
(`c:Apiary.Edition.instance_organisation_id/0`). `test/test_helper.exs` commits it before
the sandbox takes over, with its confirmed admin, through the instance's first sign-up
(`Apiary.OrganisationsFixtures.ensure_instance_organisation!/0`), and every run finds it
again. Without it the first sign-up of each test would be the instance's first, which
creates the instance's organisation whatever the test asked for. A test of the first
sign-up hides it inside its own sandbox; a test outside the sandbox that does puts it
back before it ends. A sweep over every organisation or workspace visits it too.
A test module whose tests write through it, inviting into it, changing or suspending its
people, or anything else that locks its row or its owners' memberships, is not async: two sandboxes would each lock that one committed row, with rows
of their own, and deadlock each other.

A test of two changes racing each other runs outside the sandbox, on connections of its
own that commit (`Apiary.Races` in `test/support/races.ex`): it is `async: false`,
deletes what it made in `on_exit` and what a stopped run left behind in `setup_all`, gives
its people and organisations names that say they are a race's, and forces the order of
the two sides by waiting, in the database, until one is blocked by the other
(`pg_blocking_pids`), never by sleeping. A test that counts rows counts from what is there
before it acts, since a stopped race may have left some.

The core's tests ask what an edition changes of what they assert through its test kit
(`Apiary.EditionKit`: the kit `config/test.exs` names, or the core's own,
`Apiary.EditionKit.Core`, when it names none): its rows of the access test, and how the
instance's own organisation is hidden for a test of the first sign-up.
A test that enumerates what the product has is a case template in `test/support`, given
data per edition: the access rows (`Apiary.AccessCase`), the audited changes
(`Apiary.AuditCase`), the refusals of the pages (`ApiaryWeb.RefusalsCase`), a router's
pages and their features (`ApiaryWeb.RoutesFeaturesCase`), the reserved names
(`ApiaryWeb.ReservedSlugsCase`) and the tables a purge walks
(`Apiary.Deletion.TablesCase`). The core's tests cover the core's actions
(`covers: :core`). An edition's tests use the same templates with the core's data and
their own and cover every action, so the core's answers are asked again under the
edition, and the check that every action has a row, a change or a page covers the
edition's too. No file of the core names an edition's module
(`test/apiary/edition_boundary_test.exs`).

The tests tagged `:contract` (`test/contract/`) replay the fixtures of the server contract
at the commit in `.runner-contract-ref`: `RUNNER_CONTRACT_DIR`, or else that commit's
`contracts/runner/v1`, taken once with `git archive` from the checkout `../../runner/main`
into `_build/` (that checkout is only read, whatever it has checked out). Without either
they are excluded and a line says so; CI checks the runner out at that commit and sets
`CONTRACT_FIXTURES_REQUIRED=1`, which makes their absence a failure. The commit is one on
the runner's `next` branch, pinned by its id since no tag of the runner has these files
yet; the next tag comes with the joint release. The end to end job builds qory against
the runner at `.runner-e2e-ref`, pinned apart.

## Doc comments

Every context, schema and plug carries a `@moduledoc`, and every public context function a
`@doc`. The conventions:

- The first sentence starts with the name and is a complete sentence: `Organisations
  holds ...`, `add_access_key/3 adds ...`.
- A moduledoc says what the module owns, the words it defines, how a caller uses it, and
  the invariants a caller must not break, such as which scope a function expects.
- Say what the function does, including what it refuses (`{:error, :forbidden}`,
  `{:error, :last_owner}`) and what it returns exactly once, such as a secret.
- A comment inside a function says why the code exists or what is subtle in it, never what
  the next line does.
- Wrap at 90 columns.

One vocabulary, no synonyms: **organisation** is the thing that signs up and holds
everything else; **workspace** is the unit of use inside it; **membership** is a user's
place in an organisation, at the level owner, admin or member; **access key** is a
node's credential for the server contract, an Ed25519 key; **key id** is its id, `ak_`
and sixteen characters; **secret** is the part that signs, which stays on the machine;
**run** is one execution of one session on a machine of the workspace; **event** is one
thing a run reports, delivered to the events URL; **receiver** is what answers the events
URL; **run configuration** is what the runner fetches before a run; **security policy** is
`SECURITY.md`. An organisation is never a team, a tenant or an account; a
workspace is never a team, a project or a hive; an access key is never an API key or a
token; a secret is never a password. The product surface is the one place with other
words: a page, an email or a flash says a domain's words through Gettext, and the software
domain calls a target a **repository** ([lingo.md](lingo.md)). So do the guides,
which are written in the software domain's words. Organisation and workspace are the same
words in every domain; apiary and hive are words of the apiary skin, which is not built
yet. Code, schemas, migrations and these documents say organisation and workspace.

The product surface's sentences are in Gettext catalogues ([lingo.md](lingo.md)): the
core's in `priv/gettext`, which `mix gettext.extract --merge` updates. An edition
translates its own sentences with a backend of its own, into catalogues of its own
(`c:ApiaryWeb.Edition.gettext_backend/0`).
