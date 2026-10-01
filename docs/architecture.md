# Architecture

How the application is laid out, how each organisation's data is kept apart, and where
an edition adds to the core. How to contribute is in [CONTRIBUTING.md](../CONTRIBUTING.md);
the conventions for code, tests and migrations are in [conventions.md](conventions.md).

## Layout

The application is under `lib/apiary/`, one context per concern, each with its schemas
beside it:

- `Apiary.Accounts`: users, their tokens, the notifier, and `Apiary.Accounts.Scope`, the
  caller: the user, the organisation, the membership, how they reach it (`reach`), the
  workspace, what the edition says of their place there (`edition`), the features and
  the origin.
- `Apiary.Access`: who may do what, the one question every context function and page
  asks ([access.md](access.md)).
- `Apiary.Audit`: the audit trail, one entry for every change, written by the context
  function that makes it (The audit trail, below).
- `Apiary.Organisations`: organisations, workspaces, memberships and invitations;
  sign-up, the members of an organisation and the workspaces each reaches, suspending
  and activating a member, renaming, and the instance's own organisation and its owners,
  the instance admins. A membership is the organisation's and carries the level (owner,
  admin or member); in the core every level reaches every workspace (Memberships, below).
- `Apiary.Instance`: the instance's setting for how many invitations an organisation
  sends a day (`INVITATIONS_PER_DAY`), read and checked at boot. Who may sign up after
  the first sign-up is the edition's to say (`c:Apiary.Edition.sign_up_open?/0`).
- `Apiary.Features`: the instance's features, switched at launch (`QORY_FEATURES`), and
  what an organisation and a workspace have of them (Features, below).
- `Apiary.Deletion`: deleting a workspace or an organisation, which marks it, and the
  purge after the grace period (Deletion, below). `Apiary.Deletion.Tables` lists every
  table that holds an organisation's rows, in the order a purge deletes them: the
  edition's, then the core's.
- `Apiary.AccessKeys`: a workspace's access keys, their secrets encrypted at rest through
  `Apiary.Vault`, rotation and revocation, and the lookup a signed request verifies against.
- `Apiary.Targets`: the workspace's targets as the pages read them, the index in one query
  bounded by fourteen days and a target's page, and the targets a person pinned
  (`target_pins`), their own reading preference, which leaves no audit entry.
- `Apiary.Contract`: the signature of a signed GET, pure functions with no database.
- `Apiary.Edition`: the edition this build is, asked at the few places where an edition
  may add to the core or narrow it (An edition's part, below). `Apiary.Edition.Core` is
  the core's own, and the default.
- `Apiary.Release` and `Apiary.Release.Migrator`: what the release runs at boot, and the
  commands for whoever runs the instance (`bin/apiary eval "Apiary.Release.…"`).

The web side is under `lib/apiary_web/`:

- `contract/`: the server contract. `ApiaryWeb.Contract.SignedRequest` is the plug that
  verifies a signed request and assigns the access key; the controllers behind it answer
  the contract's endpoints: `ConfigurationController` for the discovery document,
  `EventsController` for the events, whose body `RawBody` keeps as it was sent,
  `RunConfigurationController` for the run configuration. Each of them refuses a
  contract revision it does not serve through `ContractVersion`.
- `live/`: the pages behind sign-in, one directory per area (`workspace_live`,
  `run_live`, `target_live`, `connection_live`, `policy_live`, `member_live`,
  `access_key_live`, `invitation_live`, and `user_live`, a person's own pages, their
  account and their organisations), `settings_live.ex`, the organisation's settings,
  `activity_live.ex`, the organisation's audit trail, whose words for each action are
  `ApiaryWeb.Activity.Describer`'s, the edition's first, then the core's, and
  `organisation_live.ex`, the organisation's own path, which sends on to a workspace or
  says the person reaches none yet.
- `controllers/`: health, the home page, the guides, a run's log, an invitation's link,
  and the session controllers.
- `components/`: `core_components.ex` and the layouts. A page composes these; it does not
  write its own button. `extension.ex` is the named places of the core's pages where an
  edition renders what it adds, and `settings_components.ex` the tabs of the
  organisation's settings, the core's and the edition's.
- `people.ex`: how a page names a person it holds by id, "Former member" for a deleted
  account (Deletion, below).
- `lingo.ex`: the domain's words. Every visible string goes through Gettext in engine
  words, and `priv/gettext/en@software/` says them in the software domain's; see
  [lingo.md](lingo.md).
- `routes.ex`, `router.ex` and `user_auth.ex`: the pipelines, the `live_session` blocks,
  and what a mount loads into the scope. The core's routes are macros
  (`ApiaryWeb.Routes`), which `ApiaryWeb.Router` calls and an edition's router calls too,
  with its own routes in the core's `live_session`s; the endpoint dispatches to the
  edition's router (`ApiaryWeb.Edition.router/0`). A workspace's pages are under
  `/:org/:workspace/…` and an organisation's under `/:org/…`, by their slugs; the
  organisation and the workspace come from the path, never from the session, and a slug
  of an organisation the user does not reach, through a membership or as the edition lets
  them in, or of a workspace they do not reach, answers not found. An organisation's page
  carries the workspace the user opened last while they reach it, else the first they
  reach, or none. The names a slug can never be are in `reserved_slugs.ex`, with the
  edition's, and a new top-level path or organisation page is added there in the same
  change.

Migrations are under `priv/repo/migrations/`, one per change; an edition's are in a
folder of its own, run with the core's as one sequence by version
(`c:Apiary.Edition.migrations_paths/0`). Tests mirror the tree: `test/apiary/` for the
contexts, `test/apiary_web/` for the plugs, controllers and pages. Fixtures are under
`test/support/fixtures/`, one module per context; they create data the way the product
does, through `Apiary.Organisations.sign_up_user/3` and the context functions, never by
inserting rows directly. A second organisation is a later sign-up, which
`sign_up_fixture/1` (`Apiary.OrganisationsFixtures`) makes whether or not the edition
opens one (`open: true`), so the core's tests make as many organisations as they need,
though the core's edition creates one. The exceptions are the published key of the
contract's fixtures, and a second workspace of an organisation (`workspace_fixture/2`),
inserted whatever the edition's limit says: `Apiary.Organisations.create_workspace/2`
creates one the product's way, and the core's edition allows one in use.

## Organisation keys

Each organisation's data is kept apart by the schema, not by the pages:

- Every table except the account tables (`users`, `users_tokens`) and the instance's own
  (`purged_organisations`, `instance_settings`, Oban's) carries `organisation_id`, and
  every table that belongs to a workspace carries `workspace_id` beside it with the
  composite foreign key `(organisation_id, workspace_id)` against `workspaces`, so no row
  can name a workspace of another organisation. Both come in the table's first migration;
  no migration retrofits them. A new table with `organisation_id` goes into
  `Apiary.Deletion.Tables`'s list (an edition's, into the edition's `deletion_tables/0`),
  in delete order, in the same change: `Apiary.Deletion.TablesCase`, which
  `test/apiary/deletion/tables_test.exs` uses, compares the list with the schema and
  fails until it is there.
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
  through a scope of this one: two `sign_up_fixture/1` calls, a row in the first, a read
  through the second that returns nothing or raises. `test/apiary/access_keys_test.exs`
  has the shape.

A page never touches `Apiary.Repo`; it calls a context with `@current_scope`.

## Memberships

A membership is the organisation's: one row per person and organisation in `memberships`,
with the level, and no workspace. `(organisation_id, user_id)` is a key an edition's table
may reference, and a membership goes with its organisation and with its account.

- In the core every level reaches every workspace of the organisation.
  `Apiary.Access.reaches_every_workspace?/1` says which levels do, from the edition
  (`c:Apiary.Edition.every_workspace_levels/0`), and nothing else compares a level for
  it. An edition that narrows it keeps which workspaces another level reaches in tables
  of its own, and says so through `c:Apiary.Edition.reaches_workspace?/3` and
  `c:Apiary.Edition.reached_workspaces/2`; the scope carries what it says in its
  `edition` map, and a membership the members page lists in its own.
- An invitation is an email address and the workspace it was sent from, and nothing
  else: no level and no message. Accepting it makes a membership at member, unless the
  edition gives another level (`c:Apiary.Edition.accepting/3`); an owner changes the
  level afterwards. The invitations a person sent stay when their level changes and when
  they leave or are removed, as the organisation's.
- A change of a level, and the end of a suspension, are told to the edition inside their
  transaction, once the entry is written (`c:Apiary.Edition.membership_changed/5`).
- The scope carries the workspace the path names. `Apiary.Access` checks the reach from
  that scope in `can?/3`, and reads the membership again in `authorize/3`; a workspace
  the person does not reach is not found.

## The instance's organisation

Every organisation is one row of `organisations`, with its memberships, levels,
workspaces, slugs, invitations, audit trail and deletion. The core's edition creates one
organisation, with one workspace; the schema holds any number, and the core's tests make
several (Layout, above) and hold each one's rows apart (Organisation keys, above). What
an edition knows of an organisation beyond the core's fields it keeps in tables of its
own, keyed by `organisation_id`, written in the transaction that creates the organisation
(`c:Apiary.Edition.organisation_created/2`) and gone with it, and carries on the
organisation's `edition` map (`Apiary.Organisations.Organisation`), which is not stored.

- **The first sign-up** (`Apiary.Organisations.sign_up_user/3`) creates the instance's
  own organisation (`c:Apiary.Edition.instance_organisation_id/0`; in the core's edition,
  the oldest organisation in use), named by the sign-up form's organisation name, with
  its workspace **Main** and the person as its owner, the instance's first admin, and
  nothing else; the edition is told so (`:first_sign_up`). Whether a sign-up is the first
  is read inside its transaction: when the instance has no organisation of its own, it
  takes a transaction-level advisory lock and reads again, so of two first sign-ups one
  creates it and the other finds it and is a later sign-up. The instance's organisation
  stays, so a sign-up that sees it without the lock needs none.
- **A later sign-up** without an invitation creates an organisation only where the
  edition opens one (`c:Apiary.Edition.sign_up_open?/0`); the core's edition opens none,
  so after the first sign-up people join by invitation. It hands the edition what the
  form sent beyond the core's fields (`{:sign_up, extra}`), which the edition may refuse
  on one of its fields. `Apiary.Organisations.sign_up_offer/1` (`:first`, `:open` or
  `:closed`) is what the page offers, and the sign-up asks again before it creates
  anything. A sign-up with an invitation creates no organisation. Every new organisation
  starts with one workspace, **Main**.
- **One way to create an organisation.** `Apiary.Organisations.build_organisation/2` is
  the one way, for a sign-up and for each of an edition's ways: the slug, the workspace
  Main, the owner membership, the edition's steps and the entry that begins its trail.
- **The instance admins** are the owners of the instance's organisation
  (`Apiary.Access.instance_admin?/1`, [access.md](access.md), The instance's admins). It
  is never deleted nor purged (`:instance_organisation`), so an instance never loses it:
  without one, the next sign-up would create it.
- **Invitations, bounded.** An invitation is an address, and its email names the
  organisation only inside a sentence Qory writes, never in the subject, a heading or the
  text of a link, and names nobody else: not the inviter, whose address's local part is
  theirs to choose. An organisation's name carries no web address (`://`, `www.`), no
  double quotation mark or lookalike, and no Unicode format character but the join
  controls, and the email takes such characters out of it all the same
  (`Apiary.Organisations.Organisation`); a mail client may still link a bare domain. The
  inviter's account is confirmed, and an organisation sends at most
  `Apiary.Instance.invitations_per_day/0` in a rolling 24 hours, counted from the audit
  entries of its invitations, which outlive the invitations the sweep and an acceptance
  delete, leaving out one withdrawn as undelivered, under the organisation's row lock
  (`FOR NO KEY UPDATE`, which a row that only references it does not wait for), so two
  at once cannot both be the last. Every invitation tried in those 24 hours, delivered or
  not, counts against a ceiling of three times as many. Each organisation has its own
  allowance; an invitation an edition writes from another organisation counts against
  the organisation it names (`Apiary.Organisations.insert_invitation/3`, `allowance:`),
  whose row is the one locked while it is counted. Each entry names the allowance it was
  counted against, `details.allowance_id`, and the day's count reads every entry that
  names an allowance, whatever its action.
- **Release commands.** `Apiary.Release.grant_instance_admin/2` makes an account an owner
  of the instance's organisation and `revoke_instance_admin/1` makes one a member of it,
  refusing the last owner; both act as the instance, `instance_admin.grant` and
  `instance_admin.revoke` in its trail, which no role takes. On an instance nobody has
  signed up to, `grant_instance_admin/2` with an organisation's name is the first
  sign-up, `first_only: true` to `sign_up_user/3`, under the same lock: of it and a
  sign-up on the web, one creates the instance's organisation, and the command then
  grants as it would on any instance.

## Suspending a member

A membership is suspended and activated again by the organisation's owners and admins
(`Apiary.Organisations.suspend_member/2`, [access.md](access.md), Suspending a member).

- **Where it is kept.** `suspended_at` and `suspended_by_id` on `memberships`; a check
  keeps the suspender with the suspension. Activating empties them and nothing else
  changes: no membership, access key or history is removed. The history is the trail's.
- **Enforced in `Apiary.Access`.** `reload/2` reads the suspension with the level, and a
  suspended membership is no membership. `Apiary.Organisations.resolve_scope/4`, the
  switcher and the organisations page read the same suspension, so a page never opens
  what `Apiary.Access` would refuse.
- **What an edition holds out of use.** An edition may hold an account or an
  organisation out of use beyond a membership (`c:Apiary.Edition.active_accounts/2`,
  `c:Apiary.Edition.active_organisations/2`, `c:Apiary.Edition.account_refusal/1`): the
  core's queries leave out what it holds so, a membership whose account it holds so
  counts as none, an invitation into an organisation it holds so accepts no one, and
  signing in asks it why an account may not, once the password or a log-in link has shown
  the account is the person's. It writes what it keeps under the row's lock, and
  `Apiary.Access` reads it in a statement after its locks, so one written while it waited
  is seen.
- **No owner who may act.** The last-owner rule counts the owners whose membership is
  not suspended and whose account is in use (`Apiary.Organisations.other_active_owner?/1`).

## An edition's part

The core compiles and runs without an edition: `Apiary.Edition.Core` and
`ApiaryWeb.Edition.Core` are its own, and the defaults. An edition is named once in the
configuration (`config :apiary, :edition`), with its web module, its router and the
application whose static files are served first; the configuration is read at compile
time and every call is made at runtime on the module it names, so the core never names
one of its modules. A module that `use`s `Apiary.Edition` or `ApiaryWeb.Edition` gets the
core's answer to every callback and overrides the ones it changes. What an edition
registers is read once at boot by the registry that owns it, which refuses to boot on a
mistake. An edition adds tables beside the core's and alters none of them: a foreign key
only ever points from an edition's table to a core table.

What an edition may do, by where it is asked (`Apiary.Edition`, `ApiaryWeb.Edition`):

- **Access** ([access.md](access.md), An edition's part): add actions and roles
  (`actions/0`, `roles/0`); answer first, refuse or narrow (`check/3`); let a person into
  an organisation without a membership, with a role there, and read what it gave again
  (`reach/1`, `role/1`, `reload/2`, which `Apiary.Access.reader/1` names); narrow the
  levels that reach every workspace and say what another level reaches
  (`every_workspace_levels/0`, `reaches_workspace?/3`, `reached_workspaces/2`); hold more
  organisation rows with a write that must stay allowed, after the organisation's own
  (`places_to_lock/1`).
- **In use**: refine the core's queries so an account or an organisation it holds out of
  use is left out (`active_accounts/2`, `active_organisations/2`), and say why an account
  may not sign in (`account_refusal/1`).
- **Sign-up and organisations**: open a later sign-up (`sign_up_open?/0`); add steps to
  the transaction that creates an organisation (`organisation_created/2`); be told, in
  the transaction that creates a workspace, of the workspace (`workspace_created/3`);
  name the instance's own organisation (`instance_organisation_id/0`); say how many
  organisations and workspaces may be in use (`limits/0`, one of each in the core's: the
  workspaces per organisation, which `Apiary.Organisations.create_workspace/2` counts),
  the most days the trail may be kept (`audit_retention_max_days/0`), and whether the
  pages and emails carry "Powered by Qory Apiary" (`attribution?/0`).
- **Places**: the organisations a person reaches, for the switcher and their
  organisations page (`places/1`).
- **Policy**: keep a level above a workspace's security policy
  (`above_workspace/1`, an `Apiary.Policy.Above`: host rules, a required mode, whether
  the workspace may allow hosts of its own). The core reads it once per operation of
  `Apiary.Policy`, resolves it with the workspace's and a target's rules
  (`Apiary.Policy.Resolution`: its deny above everything, its allow narrowed by a lower
  deny and never widened), renders it into every document, counts it in the record, and
  draws its rows and lines on the policy pages and Network access, saying the level's
  `name` and nothing of its own about it. A change of the level renders every workspace
  again through `Apiary.Policy.rerender_in/3`, inside the edition's transaction, each
  holder whose bytes change getting an `above_changed` change. The web side names where
  the level is read and changed (`above_policy_link/1`).
- **Invitations and members**: give the level an invitation's person joins at, or refuse
  the acceptance (`accepting/3`); add to it once the membership is made (`accepted/4`);
  hear of a change of a level or the end of a suspension (`membership_changed/5`).
- **Deletion**: refuse a deletion or a purge (`deletion_refusal/2`), hear of each
  marking, cancelling and purge (`deletion_changed/4`), and add tables to the purge's
  walk, purged before the core's (`deletion_tables/0`).
- **Registries**: add features, and say what an organisation or a workspace has of the
  instance's (`features/0`, `features_of/3`); add schemas an audit entry may be about
  (`subject_kinds/0`).
- **Runtime**: check its settings at boot (`boot!/0`), start processes after the core's
  (`children/0`), schedule jobs (`crontab/0`), add folders of migrations
  (`migrations_paths/0`) and run a step after them (`after_migrate/0`).
- **Pages** (`ApiaryWeb.Edition`): its router, which calls the core's route macros
  (`ApiaryWeb.Routes`) with its own routes in the core's `live_session`s, may serve a page
  of its own at a core path (`except:`), and is the one the endpoint dispatches to
  (`ApiaryWeb.Edition.router/0`); navigation entries, their groups and their counts
  (`nav_entries/1`, `nav_sections/0`, `nav_counts/1`); the switcher's entries, the scope
  a place of its own gives and the heading it lists such a place under
  (`switcher_entries/1`, `place_scope/2`, `place_group/1`); what a page says to a person it lets in without
  a membership, and of a refusal of its own (`reader_sentence/2`, `refusal_sentence/1`);
  settings sections (`settings_tabs/1`, `ApiaryWeb.SettingsComponents`); what it renders in
  the named places of the core's pages (`slot/2`, `ApiaryWeb.Extension`); the words for
  its actions on the Activity page (`activity_describer/0`); and the names its own paths
  take (`reserved_slugs/0`).

A core page never names a module of an edition: it links to the edition's pages only
through the places the core gives it, slots, settings tabs and navigation entries, and a
page whose behaviour differs is the edition's own at the same path. The core's tests ask
what the edition changes of what they assert through its test kit (`Apiary.EditionKit`),
and never name one of its modules ([conventions.md](conventions.md), Tests).

## Features

The instance has its features (`QORY_FEATURES`, `Apiary.Features`), switched when it is
launched and fixed while it runs. What an organisation, or a workspace of it, has is
`Apiary.Features.of/2`, and nothing else answers it: in the core, the instance's
features, in every organisation and workspace alike. An edition may narrow them below
the instance (`c:Apiary.Edition.features_of/3`), and never adds to them: `of/2` keeps only
what the instance has, and a feature only with the features it needs. An edition's own
features are listed after the core's (`c:Apiary.Edition.features/0`), and
`Apiary.Features.built/0` says which features are built so far.

- **Absent, as off on the instance.** Every surface asks `Apiary.Features.on?/2` with its
  scope, which carries the answer (`Apiary.Accounts.Scope`, `features`): the feature
  gates of the pages and the controllers, the navigation, `Apiary.Access` and the server
  contract, whose access key is asked through its organisation and workspace, so the
  discovery document and the run configuration leave out what the workspace lacks. What
  belongs to the instance follows its switch only: the guides at `/docs`, the sign-in and
  landing pages, and the routes' first answer (`ApiaryWeb.Features.Routes`).
- **Read again under the locks.** `Apiary.Access.reload/2` reads the features after its
  locks, so what an edition changes of them under the organisation's or the workspace's
  lock is waited for by a change that asked, or seen by it.

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
- **What is audited.** Creating an organisation (`organisation.create`, at sign-up with
  `details.sign_up`, or by one of an edition's ways); renaming the organisation or a
  workspace; inviting, changing the level of and removing a member; revoking and
  accepting an invitation; suspending and activating a member (`member.suspend`,
  `member.activate`); granting and revoking an instance admin, by a release command;
  creating, rotating (and retiring the previous secret of) and revoking an access key;
  closing a run; the retention settings; every write of the security policy, whose
  history is the trail's entries of the policy's actions; and the trail's own retention.
  What the application removes of its own accord is recorded as the action that removes
  it: an expired invitation deleted when a new one goes to its address, one whose email
  could not be delivered, and one expired for 30 days, which the daily sweep deletes as
  the instance, are each an `invitation.revoke`, with the reason. Deleting and restoring
  a workspace or the organisation, and the purge of a workspace, are audited too
  (Deletion, below); a person's account is no organisation's, so deleting it leaves an
  entry only where it ends a membership. An edition's actions are audited the same way,
  each in the trail of the organisation it changes. Every action of `Apiary.Access` is
  audited unless `Audit.not_audited/0` says why not (reads, and the server contract's
  calls); `Audit.audited?/1` is the one answer, which the Activity page's filter asks
  too. `Apiary.AuditCase` makes each audited change and finds exactly one entry, and
  finds none when it is refused: the core's in `test/apiary/audit_test.exs`, and an
  edition's, with the core's, in its own.
- **The actor is an id.** A person's user id, an access key's row id, or none for the
  instance (`Apiary.Accounts.Scope.for_instance/2`), which acts in a job no person
  enqueued. From where is the scope's `origin`: the request's address and client, which
  `ApiaryWeb.UserAuth` puts on the scope it loads (`ApiaryWeb.Origin`, which believes
  `X-Forwarded-For` only from the proxies `TRUSTED_PROXIES` names), or the job's worker.
- **No personal data, no secret.** A person's name and email address live in their
  account and nowhere else: `before`, `after` and `details` never hold them, nor a secret.
  A page looks a person up by id when it shows them (`Audit.names/2`), and says "Former
  member" once the account is deleted. A membership's entries name its person by user id.
- **Append-only.** Nothing in the application changes an entry, and nothing deletes one
  but the purge of a deleted workspace or organisation, whose entries go with it
  (Deletion, below), and the trail's retention: `Audit.PruneJob`, one per organisation a
  day, deletes what is older than `AUDIT_RETENTION_DAYS` and records that it did, as the
  instance. The address and the client are personal data kept for less,
  `AUDIT_ADDRESS_RETENTION_DAYS` (90 days unless set, never longer than the trail): the
  same job clears them from older entries and leaves the rest. Clearing writes no entry
  of its own, since it comes every day to an organisation used every day; a deletion's
  entry counts what it cleared beside.
- **Organisation-keyed** like every table: `organisation_id` always, `workspace_id` for a
  workspace's changes, with the composite key, empty for the organisation's own, a
  membership's among them. The owners and the admins read it on the organisation's
  Activity page (`audit.read`), and so does whoever an edition lets in with a role that
  holds it.

## Deletion

Nothing an organisation holds names a person but by id, and nothing is deleted at once
but a person's account, which leaves a tombstone.

- **A person's account becomes a tombstone** (`Apiary.Accounts.delete_user/2`). The
  person deletes it on their account page after a recent sign-in, or whoever runs the
  instance does with `Apiary.Release.delete_account/1`. The row keeps its id and gets
  `deleted_at`; its email address is NULL (the column is nullable, a check allows it
  only for a deleted account, and the unique index counts NULLs as distinct, so the
  address is free for a new sign-up at once, which makes a new account), and its password
  and preferences are erased. Its memberships, its sessions and its tokens are deleted;
  each membership's end is a `member.remove` in its organisation's trail,
  `details.reason` `account_deleted`. Every open session of it is disconnected, the
  page's own by the log-out it is sent to. Everything else the person made, an access
  key, a rule, an invitation they sent, stays and names the tombstone: the foreign keys
  to `users` from an organisation's rows are plain references, which nothing clears,
  since an account row is never deleted. Signing in, a log-in link, a session and an
  invitation's acceptance never find a tombstone: the acceptance holds the account
  `FOR SHARE`, the deletion `FOR UPDATE`. While the person is the only owner of an
  organisation in use (`Apiary.Organisations.sole_owned_organisations/2`), the deletion
  is refused, and the account page names those organisations; a tombstone never counts
  as an owner. A page that names a person by id says "Former member" for a tombstone
  (`ApiaryWeb.People`, `Audit.names/2`).
- **An invitation** holds the address of someone who agreed to nothing, and is deleted
  when it is accepted (in the transaction that makes the membership), revoked,
  withdrawn, replaced after it expired, or expired for 30 days
  (`Apiary.Organisations.InvitationSweep`, daily, one `OldInvitationsJob` per
  organisation, as the instance). An acceptance and a revocation lock the same row, so of
  the two exactly one happens.
- **A workspace or an organisation is marked first** (`Apiary.Deletion`): an owner or an
  admin deletes a workspace, an owner the organisation, typing its slug, and
  `deletion_marked_at`, `deletion_marked_by_id`, `purge_trigger` and `purge_after` are
  set, `DELETION_GRACE_DAYS` (30 unless set, 1 to 90) from now. From then it is gone from
  every scope the product loads (`Apiary.Organisations.resolve_scope/4`,
  `list_memberships/1`, `list_workspaces/1`) and every sweep over the organisations and
  workspaces in use, its URLs answer not found, `Apiary.Access` answers not found to
  anything asked of it but cancelling and the purge, a page opened before the marking
  included, its access keys answer the contract as a revoked key does, its invitations
  accept no one, and retention leaves it alone; nothing is removed. The organisation's
  last workspace in use is not deleted on its own, `{:error, :last_workspace}`: the
  organisation is. A workspace's members stay in the organisation; only their access to
  it goes, with the workspace. An owner or an admin cancels a workspace's deletion on the
  organisation's settings, an owner an organisation's on `/users/organisations`, the one
  page that still shows it, until its `purge_after` or until a purge claims it. The
  marking, the cancelling and a workspace's purge are entries of the organisation's
  trail, with no workspace, so they outlive the workspace.
- **The purge.** A daily sweep (`Apiary.Deletion.PurgeSweep`) enqueues one job per marked
  organisation and per marked workspace (of an organisation not marked itself) whose
  `purge_after` has passed, unique while it waits or runs, as the instance. The job first
  claims its row, `purge_started_at`, in one statement that finds it still marked and past
  `purge_after` by the database's clock; a cancelling finds it unclaimed and in its grace
  period under the same row's lock, so exactly one of the two happens. Then it deletes
  every row with the organisation key, table by table in the order of
  `Apiary.Deletion.Tables`, a batch at a time, each batch its own short transaction, and
  then, in one transaction, the workspace's row with its `workspace.purge` entry, or the
  organisation's row with the one line the instance keeps of it, `purged_organisations`:
  its id, when it was marked and by whom, when it was purged and why, and no name or
  slug. The organisation's trail goes with it. A purge that stops half way is retried
  and goes on; one whose workspace or organisation is gone completes with nothing to do
  (`c:Apiary.Job.scope_gone/1`).
- **A purge at once.** `Apiary.Deletion.purge_now/3` purges an organisation at once, for
  an erasure request the instance received: marked under its row's lock, its grace period
  ended now, so no owner can cancel it, and purged as the sweep would. It records on the
  organisation's row who asked and why, which the instance's line keeps whichever run
  finishes the purge. An edition's release command or page is its caller, over the same
  steps (`Apiary.Deletion.lock_for_erasure/1`, `mark_for_erasure/2`, `purge_marked/2`).
- **One walk over the organisation keys.** `Apiary.Deletion.Tables.tables/0` lists every
  table with `organisation_id` in delete order, a table before every table it has a
  foreign key to: the edition's tables (`c:Apiary.Edition.deletion_tables/0`), in the
  edition's order, then the core's, in theirs. The edition's go first because a key only
  ever points from an edition's table to a core table, never back, so that order is
  always valid. The purge walks it, and an export will; retention deletes a run's log
  chunks, events and deliveries in the same order. Its test
  (`Apiary.Deletion.TablesCase`) compares it with the schema.
- **The edition's part.** The edition refuses what it will not let go
  (`c:Apiary.Edition.deletion_refusal/2`), asked on the locked row after the core's own
  refusals: the core's edition refuses the instance's organisation
  (`:instance_organisation`), and a page says an edition's refusal in its own words
  (`c:ApiaryWeb.Edition.refusal_sentence/1`). The edition is told of each marking,
  cancelling and purge inside the transaction that makes it
  (`c:Apiary.Edition.deletion_changed/4`), and may name people beyond the organisation's
  members to tell once it commits.
- **What stays outside**: backups taken before a purge hold its rows until they expire,
  which the instance's backup period bounds; the log holds ids only.
