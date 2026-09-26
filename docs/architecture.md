# Architecture

How the application is laid out and how the tenant is enforced. How to contribute is in
[CONTRIBUTING.md](../CONTRIBUTING.md); the conventions for code, tests and migrations are in
[conventions.md](conventions.md).

## Layout

The application is under `lib/apiary/`, one context per concern, each with its schemas
beside it:

- `Apiary.Accounts`: users, their tokens, the notifier, and `Apiary.Accounts.Scope`, the
  caller: the user, the organisation, the workspace and the membership.
- `Apiary.Access`: who may do what, the one question every context function and page
  asks ([access.md](access.md)).
- `Apiary.Audit`: the audit trail, one entry for every change, written by the context
  function that makes it (The audit trail, below).
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
  `member_live`, `access_key_live`, `settings_live`, `invitation_live`, `user_live`), and
  `activity_live.ex`, the organisation's audit trail.
- `controllers/`: health, the home page, and the session controllers.
- `components/`: `core_components.ex` and the layouts. A page composes these; it does not
  write its own button.
- `lingo.ex`: the domain's words. Every visible string goes through Gettext in engine
  words, and `priv/gettext/en@software/` says them in the software domain's; see
  [lingo.md](lingo.md).
- `router.ex` and `user_auth.ex`: the pipelines, the `live_session` blocks, and what a
  mount loads into the scope. A workspace's pages are under `/:org/:workspace/…` and an
  organisation's under `/:org/…`, by their slugs; the organisation and the workspace come
  from the path, never from the session, and a slug the user is not a member of answers
  not found. The names a slug can never be are in `reserved_slugs.ex`,
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

## The audit trail

Every change a person, an access key or the instance makes to what an organisation holds
leaves one entry in `audit_entries` (`Apiary.Audit`): who, which action, on what, when,
from where, and the changed fields before and after. It is not the record: the record is
what runs did and comes from the runner; the trail is what was done to the apiary. The
events a runner posts are the record and leave no entry.

- **Written with the change.** The context function that asked `Access.authorize/3`
  writes the entry with `Audit.record/6`, a step of its `Ecto.Multi` or a write inside
  its `Repo.transact/1`, in the change's transaction: a change that commits has its entry,
  one that is refused or rolls back has none, and an edit that changed nothing has none.
  Nothing writes an entry afterwards, from an event or a job. The action is one of
  `Apiary.Access.actions/0`; a change with none gets one there first.
- **What is audited.** Signing up with a new organisation; renaming the organisation or a
  workspace; inviting, changing the level of and removing a member; revoking and accepting
  an invitation; creating, rotating (and retiring the previous secret of) and revoking an
  access key; closing a run; the retention settings; every write of the security policy,
  whose history is the trail's entries of the policy's actions; and the trail's own
  retention. What the application removes of its own accord is recorded as the action
  that removes it: an expired invitation deleted when a new one goes to its address, and
  one whose email could not be delivered, are each an `invitation.revoke`, with the
  reason.
  Every action of `Apiary.Access` is audited unless `Audit.not_audited/0` says why not
  (reads, and the server contract's calls); `Audit.audited?/1` is the one answer, which
  the Activity page's filter asks too. `test/apiary/audit_test.exs` makes each audited
  change and finds exactly one entry, and finds none when it is refused.
- **The actor is an id.** A person's user id, an access key's row id, or none for the
  instance (`Apiary.Accounts.Scope.for_instance/2`), which acts in a job no person
  enqueued. From where is the scope's `origin`: the request's address and client, which
  `ApiaryWeb.UserAuth` puts on the scope it loads (`ApiaryWeb.Origin`, which believes
  `X-Forwarded-For` only from the proxies `TRUSTED_PROXIES` names), or the job's worker.
- **No personal data, no secret.** A person's name and email address live in their
  account and nowhere else: `before`, `after` and `details` never hold them, nor a secret.
  A page looks a person up by id when it shows them (`Audit.names/2`), and says "Former
  member" once the account is gone. A membership's entries name its person by user id.
- **Append-only.** Nothing in the application changes an entry, and nothing deletes one,
  but the trail's retention: `Audit.PruneJob`, one per organisation a day, deletes what is
  older than `AUDIT_RETENTION_DAYS` and records that it did, as the instance. The address
  and the client are personal data kept for less, `AUDIT_ADDRESS_RETENTION_DAYS` (90 days
  unless set, never longer than the trail): the same job clears them from older entries
  and leaves the rest. Clearing writes no entry of its own, since it comes every day to an
  organisation used every day; a deletion's entry counts what it cleared beside.
- **Tenant-keyed** like every table: `organisation_id` always, `workspace_id` for a
  workspace's changes, with the composite key, empty for the organisation's own. The
  owners read it on the organisation's Activity page (`audit.read`).
