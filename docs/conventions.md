# Conventions

The conventions for migrations, tests and doc comments, and the vocabulary. How the
application is laid out is in [architecture.md](architecture.md).

## Migrations

One migration per change, generated with `mix ecto.gen.migration`, named for what it does.
The rules are in [guides/upgrading.md](../guides/upgrading.md), because they exist for the person
who restarts a self-hosted installation; the short form:

- **A replacement backfills and drops in one migration.** A change that replaces a
  column or a table backfills the new one and drops the old one in the same migration: no
  expand-then-contract across releases, no dual-writes, no notes on rolling back to the
  old shape.
- **Every migration reverses.** `change` when Ecto can invert it, an explicit `down`
  otherwise. `Apiary.Release.rollback/2` runs it in production.
- **No data rewrite inside a schema migration** but a replacement's backfill, and indexes
  on large tables are created concurrently.
- **The organisation keys come first** ([architecture.md](architecture.md), Organisation
  keys).

The release's section in `CHANGELOG.md` names the tables the migration touches under
Migrations and anything whoever runs the instance has to do under Upgrading, when there is
anything to do.

The core's migrations are in `priv/repo/migrations`. An edition's are in a separate
folder, which sorts after the core's baseline, and the two run as one sequence by version
(`c:Apiary.Edition.migrations_paths/0`, which the release runs). An edition's migration
creates, changes and drops the edition's tables only, and may add a foreign key from one
of them to a key of the core's; a core migration never changes a key an edition may
reference without a note under Migrations. After the migrations the release runs the
edition's step (`c:Apiary.Edition.after_migrate/0`).

A migration's version is the timestamp in its name, `YYYYMMDDHHMMSS`. From 2026-10-11 on,
the core's migrations use the hours 00–16 of it; the hours 17–23 are kept for editions
built on the core, so the two never share a version. `mix ecto.gen.migration` stamps the
current time, so a timestamp it gives at 17:00 or later is moved into 00–16 of the same
day, after the day's last core migration, before the migration is committed. The earlier
migrations keep their versions, some of which fall in 17–23: renaming a migration changes
its version, and a database that already has it runs it again.

## Tests

A test is hermetic: the SQL sandbox for the database, the Swoosh test adapter for email,
nothing that reaches the network. Fixtures hold synthetic data only: no real email
address, no real host name of anyone's infrastructure, no real secret, no key or run
recorded from anyone's machine. Name a test for the behaviour it pins, not for the function
it calls; a LiveView test finds elements by the ids the template sets, not by the words on
the page.

One row is outside the sandbox on purpose: the instance's organisation
(`c:Apiary.Edition.instance_organisation_id/0`). `Apiary.TestSetup.start!/1` commits it before
the sandbox takes over, with its confirmed admin, through the instance's set-up
(`Apiary.Setup.set_up/3`, in `Apiary.OrganisationsFixtures.ensure_instance_organisation!/0`),
and every run finds it again; the set-up's row of `instance_settings` is deleted after
it, so the suite's database holds none, as the key check's tests expect. Without it the first sign-up of each test would be the instance's first, which
creates the instance's organisation whatever the test asked for. A test of the first
sign-up hides it inside the test's sandbox; a test outside the sandbox that does puts it
back before it ends. A sweep over every organisation or workspace visits it too.
A test module whose tests write through it, inviting into it, changing or suspending its
people, or anything else that locks its row or its owners' memberships, is not async: two sandboxes would each lock that one committed row, with other
rows, and deadlock each other.

A suite starts with `Apiary.TestSetup.start!/1`: the core's from `test/test_helper.exs`,
an edition's from the edition's test helper, each giving the tags it leaves out beside
the ones `start!/1` leaves out itself.

A test that exercises a feature is tagged `@tag needs: :security` (or `@moduletag`), and a run
without that feature leaves it out. A test that exercises two features is tagged
`@tag needs: [:security, :secrets]`, and a run with either off leaves it out. A tag on a test
replaces the module's tag: a test in a module tagged `needs: :security` lists `:security` again
when it adds a feature. `Apiary.DataCase` and `ApiaryWeb.ConnCase` accept a list; a module with
`use ExUnit.Case` alone adds `@before_compile Apiary.TestSetup` after it. Without it, in a run
with a feature off, ExUnit logs an ArgumentError, leaves every test of the module out of the
result, and `mix test` exits 0. A row of `ApiaryWeb.RefusalsCase` takes
`needs:` in the same way. The core's suite checks `Apiary.TestSetup.unhooked/0` for such modules.

CI runs every test once, with every feature on, and runs only the tests tagged
`@tag :feature_sets` again, under `QORY_FEATURES=observability,security`,
`QORY_FEATURES=observability,security,managed_organisations` and
`QORY_FEATURES=observability` (`mix test --only feature_sets`). Tag a test `:feature_sets`
(or `@describetag`, `@moduletag`) when it reads the instance's features, in its body, a
`setup` or a helper: `Apiary.Features.on?/1`, `enabled/0`, `visible?/2` or `hidden_of/1`,
`ApiaryWeb.Features.on?/1`, `Apiary.TestSetup.off/0`, or `Application.get_env/2`,
`fetch_env/2` or `fetch_env!/2` of `:features`. A test tagged `with_features:` runs once,
in the run with every feature on, under the features it lists, and takes no tag. So does a
test whose `needs:` lists a feature of the guard's `@once`, which the three other runs
leave off. No CI run uses `all`: the suite's registry address (`config/test.exs`) makes `all`
every feature, the set of the first run. The guard does not count a `put_env` of the
features or `without_registry` as setting them, because `without_registry` keeps the set's
other features: a test that reads them after either takes the tag. The guard
`test/apiary/feature_sets_tag_test.exs` fails for a test that reads the features with
neither the tag, `with_features:` nor a feature of `@once` in its `needs:`; for a tagged
file that reads nothing; for a test with both `with_features:` and the tag; and for a
helper of `test/support` that reads the features and is not on its list
(`Apiary.FeatureSetsScan`). The guard follows calls within a file only: a reviewer checks a
test that reaches a listed helper or a module of `lib/`. Before you report a chunk done,
run the full suite locally under all 4 sets: `QORY_FEATURES` blank,
`observability,security`, `observability,security,managed_organisations` and
`observability`.

A template that makes many people and places for each of many tests may make them once
for its module (`cast: :module` of `ApiaryWeb.RefusalsCase`, on
`Apiary.DataCase.setup_module_sandbox/2`): one sandbox for the module, and each test
inside a savepoint of it, rolled back as it ends. What lives in a process, an edition's
stub among it, is set in each test's `setup`; a test under other features than the
module's, or one that commits outside the sandbox, stays on `cast: :test`.

A test of two changes racing each other runs outside the sandbox, on separate
connections that commit (`Apiary.Races` in `test/support/races.ex`): it is `async: false`,
deletes what it made in `on_exit` and what a stopped run left behind in `setup_all`, gives
its people and organisations names that say they are a race's, and forces the order of
the two sides by waiting, in the database, until one is blocked by the other
(`pg_blocking_pids`), never by sleeping. A test that counts rows counts from what is there
before it acts, since a stopped race may have left some.

The core's tests ask what an edition changes of what they assert through its test kit
(`Apiary.EditionKit`: the kit `config/test.exs` names, or the core's kit,
`Apiary.EditionKit.Core`, when it names none): its rows of the access test, and how the
instance's organisation is hidden for a test of the first sign-up.
A test that enumerates what the product has is a case template in `test/support`, given
data per edition: the access rows (`Apiary.AccessCase`), the audited changes
(`Apiary.AuditCase`), the refusals of the pages (`ApiaryWeb.RefusalsCase`), a router's
pages and their features (`ApiaryWeb.RoutesFeaturesCase`), the reserved names
(`ApiaryWeb.ReservedSlugsCase`) and the tables a purge walks
(`Apiary.Deletion.TablesCase`). The core's tests cover the core's actions
(`covers: :core`). An edition's tests use the same templates with the core's data and
the edition's and cover every action, so the core's answers are asked again under the
edition, and the check that every action has a row, a change or a page covers the
edition's too. No file of the core names an edition's module
(`test/apiary/edition_boundary_test.exs`).

The tests tagged `:contract` (`test/contract/`) replay the fixtures of the server contract
at the commit in `.forager-contract-ref`. They take it from `FORAGER_CONTRACT_DIR`, set to
`contracts/forager/v1` of a qoryai/forager checkout at that commit. Without it they are
excluded and a line says so; CI checks Forager out at that commit
and sets `CONTRACT_FIXTURES_REQUIRED=1`, which makes their absence a failure. The commit is
one of Forager after its release `v0.7.0`, pinned by its id. The end to end
job builds qory against Forager at `.forager-e2e-ref`, pinned apart.

The tests tagged `:load` measure the receiver for long and outside the sandbox, and the
suite leaves them out (`Apiary.TestSetup.start!/1`). The one of a gateway's backlog flushed
after an outage runs with `QORY_FEATURES` unset:
`mix test --only load test/apiary_web/contract/backlog_load_test.exs`.

## Public ids

Every insert into a table with a `public_id` column (a prefix, `_` and 16 Crockford base32
characters, `Apiary.PublicId`) goes through `Apiary.PublicId.Insert`. It runs the insert
again with a fresh id, 3 tries in all, when the unique index `<table>_public_id_index`
refuses it, in a savepoint when the caller is in a transaction, and for no other error. A
column default that makes the id (such as `source_item_public_id()`) makes another on the
next try.

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
URL; **run configuration** is what the server answers a run's registration with; **security policy** is
`SECURITY.md`. An organisation is never a team, a tenant or an account; a
workspace is never a team, a project or a hive; an access key is never an API key or a
token; a secret is never a password. The product surface is the one place with other
words: a page, an email or a flash says a domain's words through Gettext, and the software
domain calls a target a **repository** ([lingo.md](lingo.md)). So do the guides,
which are written in the software domain's words. Organisation and workspace are the same
words in every domain. Code, schemas, migrations and these documents say organisation and
workspace.

The product surface's sentences are in Gettext catalogues ([lingo.md](lingo.md)): the
core's in `priv/gettext`, which `mix gettext.extract --merge` updates. An edition
translates its sentences with a separate backend, into separate catalogues
(`c:ApiaryWeb.Edition.gettext_backend/0`).

## Conventions of the edition

The code under `lib/apiary_pro` and `lib/apiary_pro_web` is the edition that the
configuration names (`Apiary.Edition`, `ApiaryWeb.Edition`). In this section, the core
means the rest of the code. The edition follows the core's conventions for migrations,
tests, doc comments and the vocabulary, in the sections before this one; this section
adds what the edition changes or adds to them. How the edition is laid out is in
[architecture.md](architecture.md), and who may do what in [access.md](access.md).

### Vocabulary

The core's words, with the same rules: an organisation is never a team, a tenant or an
account; a workspace is never a team, a project or a hive; an access key is never an API
key or a token; a secret is never a password. The edition adds these:

- **Tenant** is a row of `tenants` (`ApiaryPro.Tenants.Tenant`): an organisation's place
  on the instance, its kind, its operator, whether it is the instance organisation, and
  its suspension. It is never a synonym for organisation. "The tenant's kind" is right; "a
  tenant signs up" is wrong: an organisation signs up and gets a tenant row, written in
  the transaction that creates it.
- **Kind** is what a tenant says an organisation is: an ordinary `organisation` or an
  `operator`.
- **Operator** is an organisation of the kind `operator`, which provides a harness its
  clients run. **Client** is an organisation whose tenant names an operator. In the
  edition's prose a client is always this; the program that sends a request is "the
  request's client" or the browser.
- **Instance organisation** is the organisation the instance's first sign-up, its set-up,
  creates, as the core names it too: of the kind `operator` where the instance has
  `managed_organisations`, `organisation` otherwise, and of either afterwards, as the
  instance admins change it. Its owners are the **instance admins**.
- **Workspace access** is a member's reach into one workspace of their organisation, a row
  of `workspace_access`. An owner and an admin need none.
- **Reader** is the role of a person who reads an organisation without a membership
  there: the operator's people in its clients, and the instance admins anywhere.

The organisation keys are the core's: every edition table with `organisation_id` carries
it first, with `workspace_id` beside it and the composite key against `workspaces` for a
workspace's data, and goes into `ApiaryPro.Deletion.Tables` in delete order.

### Migrations

The edition's 19 migrations are in `priv/repo/migrations`, with the core's, under the file
names they had before the move, so a database that recorded them runs none of them again.
Ecto runs them with the core's as one sequence by version.
`test/apiary_pro/migration_versions_test.exs` checks that no two migrations share a
version and that the edition's keep their names.

- **A migration of the edition creates, changes and drops the edition's tables only.** It
  never alters a core table. It may add a foreign key from a table of the edition to a key
  of the core's: the unique keys `workspaces (organisation_id, id)` and `memberships
  (organisation_id, user_id)`, and the ids of `organisations` and `users`, which are never
  reused.
- **The core's rules hold**: one migration per change, every migration reverses, and the
  organisation keys come first.
- **After the migrations**, the release runs the edition's step
  (`ApiaryPro.Adoption.run/0`, the edition's `after_migrate/0`), which adopts the
  organisations of an instance upgraded from Qory Apiary 0.1.0, and so does `ecto.migrate`
  in dev.

### Tests

The edition's tests are under `test/apiary_pro/` for the contexts and
`test/apiary_pro_web/` for the pages, and their support under `test/support/` and
`test/support/pro/`. One `mix test` runs them with the core's, against one database. The
edition's test kit (`ApiaryPro.EditionKit`, which `config/test.exs` names for the core's
`Apiary.EditionKit`) answers what the core's test support asks of the edition: the
edition's rows of the access test, how the instance organisation is hidden for a test of
the set-up, and what the edition keeps that names an account a race test deletes.

The suite's instance organisation is made once, by the set-up of the suite's database
(`Apiary.Setup.set_up/3`), of the kind the features the suite runs with give it: an
operator with `managed_organisations`, an organisation without. A test that needs it an
operator makes it one inside its sandbox
(`ApiaryPro.OperatorsFixtures.make_instance_organisation_an_operator/1`); a test of the
set-up hides it and sets the instance up under the features it names
(`@tag with_features:`), so both kinds are tested whatever the suite runs with.

The core's case templates are run again with the edition's data beside the core's: the
access rows (`ApiaryPro.AccessRows`), the audited changes (`ApiaryPro.AuditChanges`), the
refusals of the pages (`ApiaryProWeb.RefusalsRows`), the edition's router's pages and
their features, the reserved names and the tables a purge walks. The edition's rows cover
every action, the core's among them. The core's audited changes and refusals are made
again under the edition, so a change of the edition that changes a core answer by mistake
fails a test of the edition's. The access rows are checked for a row per action only;
[access.md](access.md), Its actions and rows, lists the files that test the edition's
rules of the answer.

A test of the edition's behaviour lives under the edition's folders. A race test of the
edition's (`ApiaryPro.Races`) follows the core's rules for races: outside the sandbox,
`async: false`, its order forced in the database.

**The feature sets.** A test reads the instance's features when it calls the core's reads
(`Apiary.Features.on?/1`, `enabled/0`, `visible?/2` and `hidden_of/1`,
`Apiary.TestSetup.off/0`) or the edition's (`ApiaryPro.Features.of/1`,
`of_organisation/1`, `of_all/1` and `hidden/1`, and `ApiaryPro.Grants.offered/1` and
`shown/1`). Such a test takes the tag `:feature_sets`, as the core's section Tests says.
`test/apiary/feature_sets_tag_test.exs` is the guard for both: it runs
`Apiary.FeatureSetsScan` over `test/`, with the edition's reads among the calls it looks
for.

### Configuration, assets and documentation

- **Configuration.** `config/config.exs` names the edition (`config :apiary, :edition`):
  `ApiaryPro.Edition`, `ApiaryProWeb.Edition` and `ApiaryProWeb.Router`.
  `config/runtime.exs` reads the sign-up settings, and `config/test.exs` sets the suite's
  sign-up values and the edition's test kit.
- **Assets.** The edition's style rules are the end of `assets/css/app.css`, from the
  comment that starts "The edition's rules". `test/apiary_pro_web/css_classes_test.exs`
  holds them to classes that the rules before them do not define.
- **Gettext.** The edition's sentences are translated with `ApiaryProWeb.Gettext`, in the
  catalogues of `priv/gettext_pro`, which `mix gettext.extract --merge` updates with the
  core's.
- **Documentation.** `mix docs` builds the edition's guides and modules with the core's.
- **Third-party notices.** `mix apiary_pro.notices` writes `THIRD_PARTY_NOTICES` from the
  lock and Qory Apiary's licence and notice.

Two tests keep the boundary: `test/apiary/edition_boundary_test.exs` and
`test/apiary/edition_words_test.exs`, which hold the core's files to naming no module of
the edition.
