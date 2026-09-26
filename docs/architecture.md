# Architecture

How the application is laid out and how the tenant is enforced. How to contribute is in
[CONTRIBUTING.md](../CONTRIBUTING.md); the conventions for code, tests and migrations are in
[conventions.md](conventions.md).

## Layout

The application is under `lib/apiary/`, one context per concern, each with its schemas
beside it:

- `Apiary.Accounts`: users, their tokens, the notifier, and `Apiary.Accounts.Scope`, the
  caller: the user, the organisation, the workspace and the membership.
- `Apiary.Organisations`: organisations, workspaces, memberships and invitations; sign-up,
  the members of a workspace, renaming.
- `Apiary.AccessKeys`: a workspace's access keys, their secrets encrypted at rest through
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
- `live/`: the pages behind sign-in, one directory per area (`workspace_live`,
  `member_live`, `access_key_live`, `settings_live`, `invitation_live`, `user_live`).
- `controllers/`: health, the home page, and the session controllers.
- `components/`: `core_components.ex` and the layouts. A page composes these; it does not
  write its own button.
- `lingo.ex`: the domain's words. Every visible string goes through Gettext in engine
  words, and `priv/gettext/en@software/` says them in the software domain's; see
  [lingo.md](lingo.md).
- `router.ex` and `user_auth.ex`: the pipelines, the `live_session` blocks, and what a
  mount loads into the scope. A workspace's pages are under `/:org/:workspace/…` and an
  organisation's under `/:org/…`, by their slugs (decision 0073); the organisation and
  the workspace come from the path, never from the session, and a slug the user is not a
  member of answers not found. The names a slug can never be are in `reserved_slugs.ex`,
  and a new top-level path or organisation page is added there in the same change.

Migrations are under `priv/repo/migrations/`, one per change. Tests mirror the tree:
`test/apiary/` for the contexts, `test/apiary_web/` for the plugs, controllers and pages.
Fixtures are under `test/support/fixtures/`, one module per context; they create data the
way the product does, through `Apiary.Organisations.sign_up_user/2` and the context
functions, never by inserting rows directly. The one exception is the published key of the
contract's fixtures, which no product function would create.

## Tenancy

The organisation is the tenant, and the schema enforces it, not the pages:

- Every table except the account tables (`users`, `users_tokens`) carries
  `organisation_id`, and every table that belongs to a workspace carries `workspace_id`
  beside it with the composite foreign key `(organisation_id, workspace_id)` against
  `workspaces`, so no row can name a workspace of another organisation. Both come in the
  table's first migration; no migration retrofits them.
- A unique constraint is scoped by the organisation: `(organisation_id, name)` on
  workspaces, `(organisation_id, user_id)` on memberships, `(organisation_id, email)` on
  pending invitations, `(organisation_id, workspace_id, label)` on active access keys. A
  name is unique inside an organisation, never across them.
- Every context function that reads or writes an organisation's data takes an
  `Apiary.Accounts.Scope` as its first argument and filters by its organisation and
  workspace, and by nothing else the caller passes. The exceptions are the entry points
  that have no caller yet: sign-up, an invitation token, and the key id of a signed
  request.
- A test for a new table asserts that a row of another organisation is not reachable
  through a scope of this one: two `sign_up_fixture()` calls, a row in the first, a read
  through the second that returns nothing or raises. `test/apiary/access_keys_test.exs`
  has the shape.

A page never touches `Apiary.Repo`; it calls a context with `@current_scope`.
