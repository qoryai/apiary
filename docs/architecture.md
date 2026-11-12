# Architecture

How the application is laid out, how each organisation's data is kept apart, and where
an edition adds to the core. How to contribute is in [CONTRIBUTING.md](../CONTRIBUTING.md);
the conventions for code, tests and migrations are in [conventions.md](conventions.md).

## Layout

The application is under `lib/apiary/`, one context per concern, each with its schemas
beside it:

- `Apiary.Accounts`: users, their tokens, the notifier, and `Apiary.Accounts.Scope`, the
  caller: the user, the organisation, the membership, how they reach it (`reach`), the
  workspace, what the edition says of their place there (`edition`), what the person is
  not shown (`hidden`) and the origin.
- `Apiary.Access`: who may do what, the one way every context function and page checks
  it. [access.md](access.md) lists what stays outside it: authentication, data rules and
  the last-owner rule among them.
- `Apiary.Audit`: the audit trail, one entry for every change, written by the context
  function that makes it (The audit trail, below).
- `Apiary.Organisations`: organisations, workspaces, memberships and invitations;
  sign-up, the members of an organisation and the workspaces each reaches, suspending
  and activating a member, renaming, and the instance's organisation and its owners,
  the instance admins. A membership is the organisation's and carries the level (owner,
  admin or member); in the core every level reaches every workspace (Memberships, below).
- `Apiary.Instance`: how many invitations an organisation sends a day
  (`INVITATIONS_PER_DAY`, checked at boot, or the value saved in Instance settings ›
  Configuration). Who may sign up after the first sign-up is the edition's to say
  (`c:Apiary.Edition.sign_up_open?/0`).
- `Apiary.InstanceConfig`: the instance's settings an instance admin changes in Instance
  settings › Configuration, in the row of `instance_settings`: the audit trail's two
  periods, the grace period and the invitations a day. Each is the variable of the
  server's environment when set and not empty, else the value saved, else the default.
  Each node keeps a copy (`Apiary.InstanceConfig.Cache`), read again over `Apiary.PubSub`
  after each save; a node that misses the broadcast keeps the values it had until it
  starts again.
- `Apiary.Features`: the instance's features, switched at launch (`QORY_FEATURES`), and
  what a person is shown of them (Features, below).
- `Apiary.Deletion`: deleting a workspace or an organisation, which marks it, and the
  purge after the grace period (Deletion, below). `Apiary.Deletion.Tables` lists every
  table that holds an organisation's rows, in the order a purge deletes them: the
  edition's, then the core's.
- `Apiary.AccessKeys`: the access keys of a workspace's machines and pools, and the lookup a signed
  request verifies against. Each key has one Ed25519 public key, and Qory Apiary holds no
  secret of it; it belongs to one machine or pool: enrolment codes
  (`access_key_enrolment_codes`, kept as their SHA-256), the code being the approval of
  the key it brings while its maker is still an owner or an admin, a key made in a
  browser active at once, revocation, at most two keys at a time per machine or pool, and the ledger of public keys
  (`access_key_public_keys`), one public key for one access key, ever, whose tombstones
  outlive the purge. `Apiary.Contract.Ed25519`
  holds the checks every public key received passes, the fingerprint and cofactorless
  verification.
- `Apiary.Nodes`: a workspace's machines and pools (`nodes`), the places its runs run:
  a machine is one computer that stays registered, a pool is one or more machines that
  use the pool's access key, up to its machine limit or none; the kind is fixed when one is made, and a deleted one is gone
  from every read but keeps its row until its workspace is purged. Its instances
  (`node_instances`) are claims Forager makes under the machine's or pool's key, recorded by
  `Apiary.Nodes.seen/3` behind an ETS throttle (`Apiary.Nodes.Throttle`); running means a
  run alive by `Apiary.Runs.Liveness.alive/2`, and the instance limit is checked under
  the row lock of the machine or pool when a run registers (`check_instance_limit/3`, `admit/4`).
- `Apiary.KeyDerivation` and `Apiary.Integrity`: the keys derived from
  `APIARY_ENCRYPTION_SECRET`, one per purpose, and the integrity codes of stored rows.
- `Apiary.Targets`: the workspace's targets as the pages read them, the index in one query
  bounded by fourteen days and a target's page, and the targets a person pinned
  (`target_pins`), their reading preference, which leaves no audit entry.
- `Apiary.Contract`: the signature of a signed GET, pure functions with no database.
- `Apiary.Edition`: the edition this build is, asked at the few places where an edition
  may add to the core or narrow it (An edition's part, below). `Apiary.Edition.Core` is
  the core's edition, and the default.
- `Apiary.Release` and `Apiary.Release.Migrator`: what the release runs at boot, and the
  commands for whoever runs the instance (`bin/apiary eval "Apiary.Release.…"`).
- `Apiary.Setup`: the set-up link of a new instance, its code found or made and logged
  at a start before set-up, just before the endpoint starts, or, with
  `QORY_SETUP_CODE_SHA256` set, the hash of a code the install made, with no code made or
  logged; the set-up that uses the code; and the release command's claim of a new
  instance.

The web side is under `lib/apiary_web/`:

- `contract/`: the server contract. `ApiaryWeb.Contract.SignedRequest` is the plug that
  verifies a signed request and assigns the access key; the controllers behind it answer
  the contract's endpoints: `ConfigurationController` for the discovery document,
  `RegistrationController` for a run's registration and its reload, and
  `EventsController` for the events, whose bodies `RawBody` keeps as they were sent.
  Each of them refuses a contract revision it does not serve through `ContractVersion`.
  `EnrolmentController`
  answers enrolment, beside them and outside `SignedRequest`: a machine with no access
  key yet enrols one with a code (`Apiary.AccessKeys.enrol/2`), its body kept by `RawBody`
  too, and its answers signed with the instance's key.
- `live/`: the pages behind sign-in, one directory per area (`workspace_live`,
  `run_live`, `target_live`, `connection_live`, `policy_live`, `member_live`, `node_live`,
  `invitation_live`, and `user_live`, a person's pages, their
  account and their organisations), `settings_live.ex`, the organisation's settings,
  `activity_live.ex`, the organisation's audit trail, whose words for each action are
  `ApiaryWeb.Activity.Describer`'s, the edition's first, then the core's, and
  `organisation_live.ex`, the organisation's path, which sends on to a workspace or
  says the person reaches none yet.
- `controllers/`: health, the home page, the guides, a run's log, an invitation's link,
  and the session controllers.
- `components/`: `core_components.ex` and the layouts. A page composes these; it does not
  write a button itself. `extension.ex` is the named places of the core's pages where an
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
  with the edition's routes in the core's `live_session`s; the endpoint dispatches to the
  edition's router (`ApiaryWeb.Edition.router/0`). A workspace's pages are under
  `/:org/:workspace/…` and an organisation's under `/:org/…`, by their slugs; the
  organisation and the workspace come from the path, never from the session, and a slug
  of an organisation the user does not reach, through a membership or as the edition lets
  them in, or of a workspace they do not reach, answers not found. An organisation's page
  carries the workspace the user opened last while they reach it, else the first they
  reach, or none. The names a slug can never be are in `reserved_slugs.ex`, with the
  edition's, and a new top-level path or organisation page is added there in the same
  change. A slug follows the name: renaming an organisation or a workspace changes its
  slug, and the old addresses lead nowhere, with no redirect
  (`Apiary.Organisations.update_organisation/2`, `update_workspace/2`). Jobs and PubSub
  topics name an organisation or a workspace by its id, and so does the session, but for
  one address: the page a signed-out visitor asked for, kept as its path, slugs
  included, until they log in (`:user_return_to`, `ApiaryWeb.UserAuth`). After a rename
  that path leads to Not Found, as any old link does. An adapter's set-up pass contains
  the organisation's slug only to suggest a name at the other system
  (`Apiary.Adapters.SetupPass`).
- `content_security_policy.ex`: the `content-security-policy` the endpoint puts on every
  answer of the router and on `/docs`, with a fresh nonce per request (`@csp_nonce`):
  only the console's bundles and scripts that carry the nonce run, and no page writes
  an `on…=` attribute or a `javascript:` address. A reverse proxy must pass the header on,
  neither stripping nor replacing it. `ApiaryWeb.ContentSecurityPolicyTest` requests
  every GET route and checks each page's markup, its dead render and a LiveView's
  connected one, without a browser: the header, and nothing in the markup the policy
  would refuse.

Migrations are under `priv/repo/migrations/`, one per change; an edition's are in a
separate folder, run with the core's as one sequence by version
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

- Every table except the account tables (`users`, `users_tokens`) and the instance's tables
  (`purged_organisations`, `instance_settings`, the ledger of access keys' public keys
  `access_key_public_keys`, Oban's) carries `organisation_id`, and
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
  pending invitations, `(organisation_id, workspace_id, label)` on today's active access
  keys, `(node_id, label)` on the keys in use of a machine or pool. A name is unique inside an
  organisation, never across them; a public key is unique on the instance, by the ledger.
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
  it adds, and says so through `c:Apiary.Edition.reaches_workspace?/3` and
  `c:Apiary.Edition.reached_workspaces/2`; the scope carries what it says in its
  `edition` map, and so does a membership the members page lists.
- An invitation is an email address and the workspace it was sent from, and nothing
  else: no level and no message. Accepting it makes a membership at member, unless the
  edition gives another level (`c:Apiary.Edition.accepting/3`); an owner changes the
  level afterwards. Each is refused a level the edition refuses there
  (`Apiary.Access.level_refusal/4`), none in the core's edition. The invitations a person sent stay when their level changes and when
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
an edition knows of an organisation beyond the core's fields it keeps in tables it
adds, keyed by `organisation_id`, written in the transaction that creates the organisation
(`c:Apiary.Edition.organisation_created/2`) and gone with it, and carries on the
organisation's `edition` map (`Apiary.Organisations.Organisation`), which is not stored.

- **The first sign-up** (`Apiary.Organisations.sign_up_user/3`) creates the instance's
  organisation (`c:Apiary.Edition.instance_organisation_id/0`; in the core's edition,
  the oldest organisation in use), named by the sign-up form's organisation name, with
  the person as its owner, the instance's first admin, and nothing else; the edition is
  told so (`:first_sign_up`). By the set-up link and by the release command it has no
  workspace (`workspace: false`): on the organisation's overview, `/:org`, its owner
  chooses a kind on a card, which creates the workspace, named after the kind
  (`Apiary.Organisations.create_workspace_of_kind/3`). It is the set-up's or the
  release command's alone (`first_only: true`, `actor: :instance`; The set-up link,
  below); any other sign-up before it is `{:error, :not_set_up}`. Whether a sign-up is
  the first is read inside its transaction: when no organisation is the instance's yet,
  it takes a transaction-level advisory lock and reads again, so of two first
  sign-ups one creates it and the other finds it, `{:error, :instance_claimed}`. The
  instance's organisation stays, so a sign-up that sees it without the lock needs none.
- **A later sign-up** without an invitation creates an organisation only where the
  edition opens one (`c:Apiary.Edition.sign_up_open?/0`); the core's edition opens none,
  so after the first sign-up people join by invitation. It hands the edition what the
  form sent beyond the core's fields (`{:sign_up, extra}`), which the edition may refuse
  on one of its fields. `Apiary.Organisations.sign_up_offer/1` (`:not_set_up`, `:open` or
  `:closed`) is what the page offers, and the sign-up asks again before it creates
  anything. A sign-up with an invitation creates no organisation. An organisation the
  sign-up page creates has no workspace either (`workspace: false`): its owner lands on
  the organisation's overview and creates its first workspace there, as after the set-up
  link.
- **One way to create an organisation.** `Apiary.Organisations.build_organisation/2` is
  the one way, for a sign-up and for each of an edition's ways: the slug, made from the
  name (a sign-up refuses a name whose slug is taken, `taken: :refuse`), the workspace
  Main unless `workspace: false`, the owner membership, the edition's steps and the entry
  that begins its trail.
- **The instance admins** are the owners of the instance's organisation. They take the
  instance actions, an `Apiary.Access.Action` with `instance: true`, which pass only in that
  organisation ([access.md](access.md), The instance's admins). That organisation
  is never deleted nor purged (`:instance_organisation`), so an instance never loses it:
  without one, the next sign-up would create it.
- **Invitations, bounded.** An invitation is an address, and its email names the
  organisation only inside a sentence Qory Apiary writes, never in the subject, a heading or the
  text of a link, and names nobody else: not the inviter, whose address's local part is
  theirs to choose. An organisation's name carries no web address (`://`, `www.`), no
  double quotation mark or lookalike, and no Unicode format character but the join
  controls, and the email takes such characters out of it all the same
  (`Apiary.Organisations.Organisation`); a mail client may still link a bare domain. A mailed
  invitation needs a confirmed inviter, and an organisation makes at most
  `Apiary.Instance.invitations_per_day/0` in a rolling 24 hours, counted from the audit
  entries of its invitations, which outlive the invitations the sweep and an acceptance
  delete, leaving out one withdrawn as undelivered, under the organisation's row lock
  (`FOR NO KEY UPDATE`, which a row that only references it does not wait for), so two
  at once cannot both be the last. Every invitation tried in those 24 hours, delivered or
  not, counts against a ceiling of three times as many. Each organisation has a separate
  allowance; an invitation an edition writes from another organisation counts against
  the organisation it names (`Apiary.Organisations.insert_invitation/3`, `allowance:`),
  whose row is the one locked while it is counted. Each entry names the allowance it was
  counted against, `details.allowance_id`, and the day's count reads every entry that
  names an allowance, whatever its action.
- **Release commands.** `Apiary.Release.grant_instance_admin/2` makes an account an owner
  of the instance's organisation and `revoke_instance_admin/1` makes one a member of it,
  refusing the last owner; both act as the instance, `instance_admin.grant` and
  `instance_admin.revoke` in its trail, which no role takes. On an instance that is not
  set up, `grant_instance_admin/2` with an organisation's name is the first sign-up,
  `first_only: true` and `actor: :instance` to `sign_up_user/3`, under the same lock: of
  it and the set-up link, one creates the instance's organisation, and the command then
  grants as it would on any instance.
- **The set-up link.** `Apiary.Setup`, a child of the application's supervisor after
  the edition's processes and just before `ApiaryWeb.Endpoint`, logs "Set up Qory Apiary
  at <url>/setup/<code>." at every start while the instance has no organisation, unless
  `QORY_SETUP_CODE_SHA256` is set (the preset, below). The code
  is 32 random bytes in base64url, kept as it is in `instance_settings.setup_code`: found
  or made by `code!/0` under the row's lock (`FOR UPDATE`), so two starts at once agree on
  one. `set_up/3` is `sign_up_user/3` with `first_only: true` and `actor: :instance`,
  whose first sign-up takes the first-sign-up lock, then the row's, compares the code in
  constant time (`Plug.Crypto.secure_compare/2`), and sets `set_up_at` and makes the code
  NULL in the transaction that creates the organisation; the release command's first
  sign-up marks it used the same way. Before set-up, every other sign-up is
  `{:error, :not_set_up}`. The page is `ApiaryWeb.SetupLive`; its line on what is created
  is the edition's (`c:Apiary.Edition.first_sign_up_line/0`).
- **The preset.** With `QORY_SETUP_CODE_SHA256` set, the install makes the code and
  prints the link, and `Apiary.Setup.preset!/0` reads the hash at boot. An empty or blank
  value counts as unset. Any other value that is not 64 hexadecimal characters, with
  whitespace around them ignored, stops the boot. A start before set-up makes and logs no
  code: it sets a stored `setup_code` to NULL under the row's lock and logs a line without
  a link. The one code accepted has 43 base64url characters and a SHA-256 equal to the
  hash, compared in constant time. The set-up, by the link or by the release command,
  writes the hash to `instance_settings.used_setup_code_sha256`, and a code whose hash is
  that value is refused, so the hash sets an instance up once. The first sign-up's entry
  has `details.setup_code`: `link`, `preset` or `command`.

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
`ApiaryWeb.Edition.Core` are the core's, and the defaults. An edition is named once in the
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
  (`reach/1`, `role/1`, `reload/2`, which `Apiary.Access.reader/1` names); put what its
  checks read of an organisation on a membership's organisation, once for the scope
  (`put_organisation/1`); narrow the levels that reach every workspace and say what
  another level reaches (`every_workspace_levels/0`, `reaches_workspace?/3`,
  `reached_workspaces/2`); hold more organisation rows with a write that must stay
  allowed, after the organisation's row (`places_to_lock/1`).
- **In use**: refine the core's queries so an account or an organisation it holds out of
  use is left out (`active_accounts/2`, `active_organisations/2`), and say why an account
  may not sign in (`account_refusal/1`).
- **Sign-up and organisations**: open a later sign-up (`sign_up_open?/0`); add steps to
  the transaction that creates an organisation (`organisation_created/2`); be told, in
  the transaction that creates a workspace, of the workspace (`workspace_created/3`);
  name the instance's organisation (`instance_organisation_id/0`); say how many
  organisations and workspaces may be in use (`limits/0`, one of each in the core's: the
  workspaces per organisation, which `Apiary.Organisations.create_workspace/2` counts),
  the most days the trail may be kept (`audit_retention_max_days/0`), and whether the
  pages and emails carry "Powered by Qory Apiary" (`attribution?/0`).
- **Places**: the organisations a person reaches, for the switcher and their
  organisations page (`places/1`).
- **Policy**: keep a level above a workspace's security policy
  (`above_workspace/1`, an `Apiary.Policy.Above`: host rules, a required mode, and whether
  the workspace may allow more hosts). The core asks for it in the
  reads and writes of `Apiary.Policy` that need it, resolves it with the workspace's and
  a target's rules (`Apiary.Policy.Resolution`: its deny above every rule, below an
  integration's host only, its allow narrowed by a lower deny and never widened), renders
  it into every document, counts it
  in the record, and draws its rows and lines on the policy pages and Network access,
  saying the level's `name` and nothing else about it. A change of the level
  renders every workspace again through `Apiary.Policy.rerender_in/3`, inside the
  edition's transaction, each holder whose bytes change getting an `above_changed`
  change. The web side names where
  the level is read and changed, and its New rule page (`above_policy_link/1`).
- **Invitations and members**: give the level an invitation's person joins at, or refuse
  the acceptance (`accepting/3`); add to it once the membership is made (`accepted/4`);
  hear of a change of a level or the end of a suspension (`membership_changed/5`); refuse
  a level in an organisation, with a reason, which every way the core gives a level asks,
  the People page offering only the others (`level_refusal/4`), and say the refusal in
  the edition's words (`c:ApiaryWeb.Edition.level_refusal_sentence/2`).
- **Deletion**: refuse a deletion or a purge (`deletion_refusal/2`), hear of each
  marking, cancelling and purge (`deletion_changed/4`), and add tables to the purge's
  walk, purged before the core's (`deletion_tables/0`).
- **Registries**: add features (`features/0`); add schemas an audit entry may be about
  (`subject_kinds/0`).
- **What a person is shown**: hide features the instance has, or parts, from a
  person in an organisation (`hidden/1`).
- **Audit trail**: add keys to each entry's details as it is written, such as
  how the actor reached the organisation, cheaply and inside the change's transaction
  (`audit_details/3`); it changes none of the core's.
- **Runtime**: check its settings at boot (`boot!/0`), start processes after the core's
  (`children/0`), schedule jobs (`crontab/0`), add folders of migrations
  (`migrations_paths/0`) and run a step after them (`after_migrate/0`).
- **Pages** (`ApiaryWeb.Edition`): its router, which calls the core's route macros
  (`ApiaryWeb.Routes`) with the edition's routes in the core's `live_session`s, may serve a page
  of the edition at a core path (`except:`), and is the one the endpoint dispatches to
  (`ApiaryWeb.Edition.router/0`); navigation entries, their groups and their counts
  (`nav_entries/1`, `nav_sections/0`, `nav_counts/1`); the entries of the breadcrumb's
  organisation menu and workspace menu, and the heading the organisation menu lists a
  place the edition gives under (`switcher_entries/1`, `workspace_switcher_entries/1`,
  `place_group/1`; `place_scope/2`, which the core no longer asks); what a page says to
  a person it lets in without a membership, of a refusal the edition makes, and, where the pages
  `who_may_sentence/2` lists call it, of who may take an action, which changes only the words,
  since `Apiary.Access` decides (`reader_sentence/2`,
  `refusal_sentence/1`, `who_may_sentence/2`); settings sections (`settings_tabs/1`,
  `ApiaryWeb.SettingsComponents`); what it renders in the named places of the core's
  pages (`slot/2`, `ApiaryWeb.Extension`); the words for its actions in the audit log
  (`activity_describer/0`), and who made an entry, in its Who column
  (`activity_actor/2`); the names the edition's paths take (`reserved_slugs/0`); and the
  product's name where no instance admin set one (`product_name/0`), which the Qory Apiary
  menu's button and the form of Instance settings › General show, while page titles, the
  log-in pages and emails show Qory Apiary there (`Apiary.ProductName`).

A core page never names a module of an edition: it links to the edition's pages only
through the places the core gives it, slots, settings tabs and navigation entries, and a
page whose behaviour differs is the edition's page at the same path. The core's tests ask
what the edition changes of what they assert through its test kit (`Apiary.EditionKit`),
and never name one of its modules ([conventions.md](conventions.md), Tests).

## Features

The instance has its features (`QORY_FEATURES`, `Apiary.Features`), switched when it is
launched and fixed while it runs: the only on and off (`Apiary.Features.on?/1`). Below the
instance a feature is shown or hidden, never switched off. What a person is not shown in
an organisation is the edition's answer (`c:Apiary.Edition.hidden/1`), and nothing else
answers it: in the core, nothing is hidden. The answer does not depend on the workspace.
An edition's features are listed after the core's (`c:Apiary.Edition.features/0`), and
`Apiary.Features.built/0` names the ones a page of an edition may show or hide for an
organisation. An opt-in feature (`default: false`, `Apiary.Features.opt_in/0`) is on
where `QORY_FEATURES` lists it by name, and is never one of those. The core's opt-in
feature, `registry`, is also on with `all` where `QORY_REGISTRY` is set. A feature may have
**parts** (`Apiary.Features.parts/0`), which an edition may hide apart from the rest of the
feature, and which are never on or off apart from it: the core's one part of a feature is
the run's Terminal, `observability.terminal`, the run's log, which `run.read_log` belongs
to (an action's `part`). A part may belong to no feature, and is then on in every
instance: the core's one is `nodes`, the machines, the pools, their access keys and the
gateways, which the `node.*` and `access_key.*` actions belong to.

- **Absent, as off on the instance.** A feature that is off, or a feature or a part
  hidden from a person, is absent for them: the feature gates of the pages and the
  controllers, the navigation and `Apiary.Access` ask `Apiary.Features.visible?/2` with
  the person's scope, which carries what is hidden (`Apiary.Accounts.Scope`, `hidden`).
  What belongs to the instance follows its switch only (`Apiary.Features.on?/1`): the
  guides at `/docs`, the sign-in and landing pages, the routes' first answer
  (`ApiaryWeb.Features.Routes`), and the server contract, whose access key, and its
  scope, answer as the instance. A hidden feature still works in full for machines: a run's
  registration, events, attach, outcome and reload, and its run configuration, follow the
  instance's features alone, and so do rendering and the instance's jobs; the discovery
  document reads no feature.
- **Read again under the locks.** `Apiary.Access.reload/2` asks what is hidden after the
  edition's reload, under the edition's locks, so what an edition changes of it under the
  organisation's lock is waited for by a change that asked, or seen by it.

## Secrets at rest and integrity codes

`APIARY_ENCRYPTION_SECRET`, 32 random bytes, is the key the instance encrypts and codes
with, and nothing is encrypted or keyed under the secret's bytes: every key is derived from it
with HKDF-SHA256 (`Apiary.KeyDerivation`), salt `apiary/kdf/v1`, one info string per
purpose: `apiary integrity v1` for integrity
codes, `apiary check v1` for the check value the boot compares (`Apiary.KeyCheck`) and
`apiary mail v1` for the SMTP password saved in Instance settings › Mail
(`Apiary.Mail.Password`, AES-256-GCM with associated data binding it to its row, its
field, the relay, the port, TLS and the username). Each derived key
has a key id, a truncated SHA-256 of a label and the key, stored beside what it made, so a
rotation of the secret can keep the previous one to read with and tell the two apart.

The key that signs the instance's answers to gateways, which every machine pins as
`apiary_public_key`, is not derived from it: its Ed25519 seed is a separate secret,
`APIARY_SIGNING_SECRET`, 32 random bytes with no fallback in production, so that the pin
does not change with the encryption secret (`Apiary.SigningKey`). The instance refuses at
boot the fixture seeds Forager's contract publishes and, in production, a seed equal to the
encryption secret and the development and test seeds `config/` publishes, and holds the key
in a struct whose `inspect` shows its fingerprint alone.

**Integrity codes** (`Apiary.Integrity`) find a row changed outside the application by
someone who can write to the database but does not hold the secret: an HMAC-SHA256 under
the integrity key over a canonical encoding of a kind, a version and the fields the caller
chooses, each length-prefixed and typed, stored with the key id beside it, and verified in
constant time. A caller codes what grants access, the access key rows of a machine or pool (their machine or pool,
public key, arrival and revocation) and the enrolment codes, and checks the code where it
trusts the row: `Apiary.AccessKeys.fetch_for_verification/1` refuses the key of a machine or pool whose row
does not match, before any signature is checked;
the per-request columns stay outside it. Policy rules carry no code.

## The audit trail

Every change a person, an access key or the instance makes to what an organisation holds
leaves one entry in `audit_entries` (`Apiary.Audit`): who, which action, on what, when,
from where, and the changed fields before and after. It is not the record: the record is
what runs did and comes from Forager; the trail is what was done to Qory Apiary. The
events the gateway posts are the record and leave no entry.

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
  an access key's arrival on a machine or pool and its revocation, and making
  and cancelling an enrolment code;
  the retention settings; every write of the security policy, whose
  history is the trail's entries of the policy's actions; and the trail's retention.
  What the application removes by itself is recorded as the action that removes
  it: an expired invitation deleted when a new one goes to its address, one whose email
  could not be delivered, and one expired for 30 days, which the daily sweep deletes as
  the instance, are each an `invitation.revoke`, with the reason. Deleting and restoring
  a workspace or the organisation, and the purge of a workspace, are audited too
  (Deletion, below); a person's account is no organisation's, so deleting it leaves an
  entry only where it ends a membership. An edition's actions are audited the same way,
  each in the trail of the organisation it changes. Every action of `Apiary.Access` is
  audited unless `Audit.not_audited/0` says why not (reads, and the server contract's
  calls); `Audit.audited?/1` is the one answer, which the audit log's filter asks
  too. `Apiary.AuditCase` makes each audited change and finds exactly one entry, and
  finds none when it is refused: the core's in `test/apiary/audit_test.exs`, and an
  edition's, with the core's, in the edition's audit test.
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
  day, deletes what is older than the trail's period (`AUDIT_RETENTION_DAYS`, or Instance
  settings › Configuration) and records that it did, as the instance. The address and the
  client are personal data kept for less, the address period,
  `AUDIT_ADDRESS_RETENTION_DAYS` or Instance settings › Configuration (90 days unless set,
  never longer than the trail): the same job clears them from older entries and leaves the rest. Clearing writes no entry,
  since it comes every day to an organisation used every day; a deletion's
  entry counts what it cleared beside.
- **Organisation-keyed** like every table: `organisation_id` always, `workspace_id` for a
  workspace's changes, with the composite key, empty for the organisation's changes, a
  membership's among them. The owners and the admins read it on the organisation's
  audit log (`audit.read`), and so does whoever an edition lets in with a role that
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
  deleting page's session by the log-out it is sent to. Everything else the person made, an access
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
  set, the grace period from now (`DELETION_GRACE_DAYS`, or Instance settings ›
  Configuration; 30 days unless set, 1 to 90), which a later change of the period leaves
  as it is. From then it is gone from
  every scope the product loads (`Apiary.Organisations.resolve_scope/4`,
  `list_memberships/1`, `list_workspaces/1`) and every sweep over the organisations and
  workspaces in use, its URLs answer not found, `Apiary.Access` answers not found to
  anything asked of it but cancelling and the purge, a page opened before the marking
  included, its access keys answer the contract as a revoked key does, its invitations
  accept no one, and retention leaves it alone; nothing is removed. The keys of its machines and pools
  are hidden so, not revoked, and come back with a cancelled deletion; the purge makes their
  public keys tombstones in the ledger, `workspace_deleted` for an organisation's purge
  too, before it deletes them. The organisation's
  last workspace in use is not deleted alone, `{:error, :last_workspace}`: the
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
  `Apiary.Deletion.Tables`, a batch at a time, each batch a separate short transaction, and
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
  always valid. The purge walks it; retention deletes a run's log
  chunks, events and deliveries in the same order. Its test
  (`Apiary.Deletion.TablesCase`) compares it with the schema.
- **The edition's part.** The edition refuses what it will not let go
  (`c:Apiary.Edition.deletion_refusal/2`), asked on the locked row after the core's
  refusals: the core's edition refuses the instance's organisation
  (`:instance_organisation`), and a page says an edition's refusal in the edition's words
  (`c:ApiaryWeb.Edition.refusal_sentence/1`). The edition is told of each marking,
  cancelling and purge inside the transaction that makes it
  (`c:Apiary.Edition.deletion_changed/4`), and may name people beyond the organisation's
  members to tell once it commits.
- **What stays outside**: backups taken before a purge hold its rows until they expire,
  which the instance's backup period bounds; the log holds ids only.

## Tenants, operators and the organisation's level

The code under `lib/apiary_pro` and `lib/apiary_pro_web` is the edition that the
configuration names (`Apiary.Edition`, `ApiaryWeb.Edition`): it answers the core's
callbacks, adds tables beside the core's and alters none of them. In this section, the
core means the rest of the code.

This section covers the edition's layout, its tables and their keys, the tenants and the
instance organisation, the adoption of an instance whose organisations have no tenant,
operators and their clients, policy requests, the organisation's policy, its variables
and its secrets, the suspension of accounts and organisations, transfers, features below
the instance, and the edition's part of the audit trail and of deletion. Who may do what
is in [access.md](access.md), Who may do what: operators, clients and the instance; the
edition's conventions are in [conventions.md](conventions.md), Conventions of the
edition.

### Layout

The edition's application is under `lib/apiary_pro/`, one context per concern, each with its
schemas beside it:

- `ApiaryPro.Edition`: the edition (`Apiary.Edition`), each callback answered by the
  context of the edition that owns it.
- `ApiaryPro.Access`: the edition's actions, its instance actions among them, marked
  `instance: true`, its roles `reader` and `person`, and its part of the answer
  (`check/3`), which `Apiary.Access` calls ([access.md](access.md)).
- `ApiaryPro.Reach`: how a person reaches an organisation beyond their membership there,
  through its operator or as an instance admin, and which workspaces a member reaches:
  the edition's `reach/1`, `reload/2`, `places_to_lock/1`, `every_workspace_levels/0`,
  `reaches_workspace?/3` and `reached_workspaces/2`. `ApiaryPro.Places` is every
  organisation a person reaches from the switcher, their memberships and the clients of
  each operator they belong to, each an `ApiaryPro.ClientReach`.
- `ApiaryPro.WorkspaceAccess`: which workspaces a member reaches, one row per person and
  workspace, adding a member to a workspace and removing them from one (Workspace
  access, below).
- `ApiaryPro.Invitations`: what the edition adds to an invitation's acceptance: the
  workspace it was sent from, none for an invitation sent to the organisation alone, and
  an operator's invitation of its client's first owner, which makes that person the owner.
- `ApiaryPro.Tenants`: what the edition says of an organisation beyond the core's, its
  kind, its operator and its suspension, one row of `tenants` each (Tenants and the
  instance organisation, below).
- `ApiaryPro.Organisations`: a person's new organisation, from the organisation switcher,
  and the instance organisation.
- `ApiaryPro.SignUp`: who may sign up, saved on Instance settings › Configuration
  (`ApiaryProWeb.InstanceLive.SignUpPart`) and applied at once on every node through each
  node's copy (`ApiaryPro.SignUp.Cache`), overridden by `SIGNUP_ORGANISATIONS` and
  `SIGNUP_OPERATORS`, which the edition's `boot!/0` checks; and the kinds a sign-up
  offers.
- `ApiaryPro.Operators`: operators and their clients, and the instance actions of the
  instance organisation's owners: creating a client and inviting its first owner, listing
  an operator's clients, listing the organisations of the instance, creating an
  organisation or an operator there, and changing a kind (Operators and clients, below).
- `ApiaryPro.PolicyRequests`: an operator's requests for changes to its clients' policy,
  and the clients' answers (Policy requests, below).
- `ApiaryPro.OrganisationPolicy`: the organisation's policy, the level above its
  workspaces' security policy: its host rules, the mode floor and the switch, and the
  render of every workspace a change makes (The organisation's policy, below).
- `ApiaryPro.OrganisationVariables`: the organisation's variables, the level above its
  workspaces' variables: its names and values, the names it locks, and the checks a
  change makes across every workspace (The organisation's variables, below).
- `ApiaryPro.OrganisationSecrets`: who reads, changes and links the organisation's
  secrets, which the core keeps beside its workspaces' secrets, and whether they are
  sealed (The organisation's secrets, below).
- `ApiaryPro.Suspensions`: suspending and activating a person's account, and an
  organisation or an operator, instance actions of the instance admins, and the accounts
  Instance settings › Accounts lists (Suspension of accounts and organisations, below).
- `ApiaryPro.Transfers`: a client's drop by its operator, and an organisation's ownership
  when its owners cannot act: the arbiter's offers pending in `transfers`, their lapse
  and their acceptance (Transfers, below).
- `ApiaryPro.Features` and `ApiaryPro.Grants`: the edition's feature,
  `managed_organisations`, what an organisation or a workspace has of the instance's, and
  the grants that say so (Features below the instance, below).
- `ApiaryPro.Deletion` and `ApiaryPro.Deletion.Tables`: the edition's part in deleting and
  purging (Deletion, below).
- `ApiaryPro.Adoption`: the edition's step after the migrations, which adopts the
  organisations without a tenant (Adopting an instance whose organisations have no
  tenant, below).
- `ApiaryPro.Release`: the edition's release commands
  (`bin/apiary eval "ApiaryPro.Release.…"`), run as the core's are.

The edition's web side is under `lib/apiary_pro_web/`, `ApiaryProWeb.*`: its router
(`ApiaryProWeb.Router`), which calls the core's route macros (`ApiaryWeb.Routes`) with
the edition's pages in the core's `live_session`s and serves the edition's sign-up page at
the core's path, since it offers kinds; its web edition (`ApiaryProWeb.Edition`); the
edition's pages under `live/` (an operator's clients and its policy requests, Instance
settings' Organisations and Accounts, a client's policy requests, the organisation's
policy, the organisation's Ownership section, a member's workspaces, a new organisation
and the sign-up page with kinds); and what it renders in the core's pages: its notices
(`ApiaryProWeb.Notices`), its slots (`ApiaryProWeb.Slots`), its words for a reader
(`ApiaryProWeb.Readers`) and for its actions in the audit log
(`ApiaryProWeb.ActivityDescriber`). A core page never names a module of it: it links to
the edition's pages only through the places the core gives the edition, slots, sections of
the settings and navigation entries.

The edition's migrations are in `priv/repo/migrations/`, with the core's, and run with
them as one sequence by version. The edition's tests are under `test/apiary_pro/` for the
contexts and `test/apiary_pro_web/` for the pages, with their support under
`test/support/`: the fixtures for operators, clients and instance admins
(`ApiaryPro.OperatorsFixtures`), created the way the product creates them, the edition's rows of
the core's case templates, its test kit (`ApiaryPro.EditionKit`) and its race helpers
(`ApiaryPro.Races`).

### Organisation keys

The edition's tables follow the core's rules: every one that holds an organisation's rows
carries `organisation_id`, with `workspace_id` beside it and the composite key against
`workspaces` for a workspace's data, and is listed in `ApiaryPro.Deletion.Tables`, the
edition's `deletion_tables/0`, in delete order. A unique constraint is scoped by the
organisation: `(organisation_id, workspace_id, user_id)` on workspace access, and
`(organisation_id)` on transfers, one pending offer per organisation. The account
suspensions (`account_suspensions`) and the instance's branding belong to no organisation,
and are not listed.

### Workspace access

Which workspaces a member reaches is `workspace_access`, one row per person and
workspace, with the organisation keys of workspace data (`organisation_id`, and
`workspace_id` under the composite key against `workspaces`), so its rows go with their
workspace. The person is named by `(organisation_id, user_id)` under a composite key
against `memberships`, so a row never names someone who is not a member of that
organisation, and removing the member removes their rows.

- An owner and an admin reach every workspace and need no row; a row they have changes
  nothing while they hold the level. A member reaches the workspaces they have a row for.
  `Apiary.Access.reaches_every_workspace?/1` says which levels reach every workspace,
  from the edition's answer (`ApiaryPro.Reach.every_workspace_levels/0`), and nothing else
  compares a level for it.
- An invitation is an email address and the workspace it was sent from, and nothing
  else. Accepting it makes a membership at member and adds the row for that workspace
  (`ApiaryPro.Invitations`, the edition's `accepted/4`); an owner changes the level
  afterwards.
- An owner or an admin adds a member to a workspace and removes them from one on the
  member's Workspaces page, `/:org/settings/people/:id/workspaces`, which People leads
  to; each is an audit entry in that workspace.
- A person made a member from a level that reached every workspace keeps the rows they
  have; one with none gets a row for the workspace the change was made from, the one the
  owner's page carries, so the change does not lock them out, with a separate entry
  (`ApiaryPro.WorkspaceAccess`, told by the edition's `membership_changed/5`). The
  invitations a person sent stay when their level changes and when they leave or are
  removed, as the organisation's: none grants more than member, but an operator's
  invitation of its client's first owner.
- The scope carries the workspace the path names and the person's row for it, in its
  `edition` map (`ApiaryPro.WorkspaceAccess.of/1`). `Apiary.Access` checks the reach from
  that scope in `can?/3`, and reads both the membership and the row again in
  `authorize/3`; a workspace the person does not reach is not found.

### Tenants and the instance organisation

Every organisation is one row of the core's `organisations`, whatever it is, with the
same memberships, levels, workspaces, slugs, invitations, audit trail and deletion. What
the edition knows of it beyond that is its row of `tenants` (`ApiaryPro.Tenants.Tenant`),
keyed by `organisation_id`, written in the transaction that creates the organisation (the
edition's `organisation_created/2`) and gone with it: its kind, whether it is the instance
organisation, its operator and its suspension. The core's tables hold none of it, and a
page of the edition carries it on the organisation's `edition`, under `:tenant`
(`ApiaryPro.Tenants`). A tenant is written only under its organisation's row locked for
update (`ApiaryPro.Tenants`, Locks; [access.md](access.md), The lock order). Beside each
tenant, written with it, or by the migration for a tenant written before it, or as it is
first locked for one written without it, and gone with it, is its row of `people_locks`
(`ApiaryPro.Tenants.PeopleLock`), which holds nothing but its key and when it was written,
for the edition to lock at a change's one point (`ApiaryPro.Tenants.lock_rows/1`;
[access.md](access.md), The lock order).

- **A kind.** `tenants.kind` is `organisation`, an ordinary one, or `operator`, which
  provides a harness its clients run (Operators and clients, below). Any kind has
  workspaces and runs work in them. A sign-up sets the kind, and nothing casts it from a
  form (`ApiaryPro.Tenants.organisation_created/2`).
- **The instance organisation.** `tenants.instance_organisation` flags one organisation as
  the core's instance organisation
  (`c:Apiary.Edition.instance_organisation_id/0`), of either kind: the first sign-up gives
  it one (below), and the instance admins change it as any other organisation's (Operators
  and clients, below). A partial unique index lets one row carry the flag, checks keep it
  unsuspended and no client, and nothing in the product unsets it. Its owners are the
  instance admins. The core's instance step checks the instance actions
  ([access.md](access.md), The instance organisation and the instance actions), and
  `Apiary.Access.instance_admin?/1` returns whether a scope's person is one, for the checks
  with no action. `organisation.delete` is refused on it at every
  level, so an instance never loses it: without one, the instance would not be set up,
  and its next set-up would make another; nor is it purged, suspended or transferred.
  Its people see an organisation like any other; the words "operator" and "instance" are
  on no page of theirs but its settings, which say why it cannot be deleted, and, for its
  owners, Instance settings' pages; made an operator, it has a Clients page, which its
  sidebar lists once it has clients; until then its owners reach it from its
  row under Instance settings › Organisations.
- **The first sign-up** is the instance's set-up, by the set-up link the instance logs
  until it is used, or a release command (`Apiary.Setup`, through
  `Apiary.Organisations.sign_up_user/3`). It creates the instance's first organisation,
  with the person as its owner and no workspace yet, as in the core; nobody signs
  up before it, and the edition's sign-up page says to use the set-up link
  (`:not_set_up`). The edition makes it the instance organisation when it is told (the
  edition's `organisation_created/2`, `:first_sign_up`,
  `ApiaryPro.Tenants.organisation_created/2`), of the kind
  `ApiaryPro.Tenants.first_sign_up_kind/0` gives: `operator` where the instance has
  `managed_organisations` (`QORY_FEATURES`, `Apiary.Features`), so its owners may take
  clients at once, and `organisation` otherwise, an organisation like any other, with no
  Clients page. The set-up page's line says which it makes (the edition's
  `first_sign_up_line/0`, `ApiaryPro.SignUp.first_sign_up_line/0`). The unique index
  answers for anything the core's first-sign-up lock misses.
- **A later sign-up** without an invitation is the core's where the edition opens one
  (`sign_up_open?/0`, true while `ApiaryPro.SignUp.kinds/0` is not empty), and it hands
  the edition what the form sent beyond the core's fields (`{:sign_up, extra}`). The
  edition creates the kind the instance's settings open, from `extra["kind"]`: none by
  default, when the sign-up page says sign-up is by invitation; the one, with no choice;
  or the one chosen, when both are open. The instance organisation is never a kind to
  choose. `Apiary.Organisations.sign_up_offer/1`, and the edition's
  `ApiaryPro.SignUp.offer/0` with its kinds, are what the page offers, and the sign-up
  asks again before it creates anything. Both settings are closed when unset. A new
  organisation made by a sign-up starts with no workspace: after the sign-up the person
  lands on its overview, `/:org`, where its first owner chooses the kind of the first
  workspace from the cards (`Apiary.Organisations.create_workspace_of_kind/3`). The
  sign-up page, and both New organisation pages below, are the account's step of the
  set-up, in the core's frame (`ApiaryWeb.SetUpComponents.frame/1`); the frame lists the
  account's steps alone (`ApiaryPro.SetUp`): a sign-up and a New organisation have one
  step, which shows no indicator. An invitation to a client's organisation, while the
  client has no workspace, lists Invitation alone; one to any other organisation lists
  Invitation and Your account; one to a workspace lists Your account alone. The
  workspace's steps are set up inside the workspace. The kind is the core's choice field
  (`ApiaryProWeb.OrganisationComponents`), and what the page knows is under About this
  step.
- **A person who has an account** creates an organisation from the
  organisation switcher's New organisation entry, `/users/organisations/new`
  (`ApiaryPro.Organisations.create_organisation/2`, `organisation.create`), of a kind the
  same settings open, and is its first owner. Every organisation is made by the core's
  one way, `Apiary.Organisations.build_organisation/2`, with the account as it is instead
  of a new one: the slug, no workspace, the owner membership, the edition's steps
  and the entry. `Apiary.Access` answers the kind, before and inside the transaction; with
  both settings closed the entry is not there. The person is taken to the new
  organisation's overview, `/:org`, as after a sign-up. The organisation's address is
  made from its name, and a name whose address another organisation has is refused, with
  the core's words, not numbered (`taken: :refuse` of
  `Apiary.Organisations.build_organisation/2`); the same holds for a client and for an
  instance admin's New organisation.
- **An owner adds a workspace** from Workspaces in the organisation's settings, or from
  New on its pages, which lead to the core's type cards, `/:org/workspaces/new`
  (`ApiaryWeb.WorkspaceSetupLive`), through the core's one way,
  `Apiary.Organisations.create_workspace/2` (`workspace.create`): the edition's limit of
  workspaces is unlimited, nothing of the edition's is written for a new workspace
  (`ApiaryPro.Edition.workspace_created/3`), and the owners and admins reach it as they
  reach every one, a member once added (`ApiaryPro.WorkspaceAccess`).
- **Where a thing reaches** is the core's: each Add form of a model provider, a runtime, an
  integration or a service shows the setting "Available to every workspace in
  <organisation>", off by default, because the edition answers true to
  `c:Apiary.Edition.scope_setting?/1` (`ApiaryPro.Edition`). With it on, the thing reaches
  every workspace of the organisation; with it off, only the workspace the form is in. The
  core stores the reach and fixes it at the add; the edition stores none. A connection to
  an adapter reaches every workspace and has no setting.
- **Invitations, bounded.** Each organisation has a separate allowance of invitations, a
  client as any other; the one exception is the invitation of a client's first owner
  (`client.invite_owner`), which is in the client's trail and counts against its
  operator's allowance (`Apiary.Organisations.insert_invitation/3` with `allowance:`), so
  creating clients does not multiply what an operator may send. Its entry names the
  allowance it was counted against, `details.allowance_id`, as `member.invite`'s does,
  and the row locked while it is counted is the operator's.
- **Release commands.** The core's `Apiary.Release.grant_instance_admin/2` and
  `revoke_instance_admin/1` make an account an owner of the instance organisation, and one
  a member of it. `ApiaryPro.Release.purge_now/2` takes the address of the instance admin
  who asked for the erasure, and refuses anyone else's; nothing marks or purges the
  instance organisation.

### Adopting an instance whose organisations have no tenant

The organisations of an instance set up with a release without tenants, such as Qory
Apiary 0.1.0 or a build of `main` from before them, have no tenant. The first release with
tenants adopts them: `ApiaryPro.Adoption.run/0`, the edition's `after_migrate/0`,
which the release runs at boot and from the migrate command. Upgrading is swapping the
image and restarting. An instance goes back by deploying the previous image; the tables
the upgrade added stay in place.

- **A tenant for every organisation.** Every organisation without a tenant gets one of
  the kind `organisation`, with no operator and not suspended: what it was in the core.
- **The instance organisation.** While no tenant is the instance organisation, the
  organisation that the earlier release held as its instance organisation, the oldest in
  use, becomes it, and keeps the kind `organisation`, as every organisation adopted does:
  its owners ran the instance before, and stay its instance admins. Adopting never makes
  it an operator; an instance admin may, where the instance has `managed_organisations`.
  An instance with an instance organisation keeps it.
- **What a member reached.** In the earlier release every membership reached every
  workspace of its organisation; here a member reaches the workspaces they were added
  to. So each membership at member of an organisation adopted by this run is added to
  each workspace of it, and nobody loses what they reached. An organisation adopted
  before keeps its workspace access as it is.
- **The trail.** Each organisation adopted gets one entry, `instance.adopt`, by the
  instance, in the organisation's trail: its kind, whether it is the instance
  organisation, and how many rows of workspace access it gave; so does the instance
  organisation made so when it had its tenant already.

The adoption is idempotent: a second run finds a tenant for every organisation and an
instance organisation, and changes nothing. It runs in one transaction under an advisory
lock, so two nodes that boot at once adopt once, and takes its rows in the lock order
([access.md](access.md), The lock order).

### Operators and clients

An operator provides a harness, its agents, skills, workflows and integrations, that its
clients run on Qory Apiary; it keeps the harness working and debugs it, and does not
manage the client's people. The relationship is `tenants.operator_id`, one level deep.

- **Kept by the database.** `operator_kind`, a generated column, is `operator` where
  `operator_id` is set, and `(operator_id, operator_kind)` is a foreign key to
  `tenants (organisation_id, kind)`, which a unique index makes a key: a client's operator
  is an organisation of the kind `operator`, and an operator with clients neither becomes
  an organisation nor is deleted while one references it. A check keeps `operator_id` on
  an organisation of the kind `organisation`: an operator is never a client, and a client
  never becomes an operator. The relationship is set when the client is created, with
  `operator_since`, the time it was set, which the operator's Clients page shows; it ends
  when the operator drops it (Transfers, below); nothing else changes it, and a
  suspension leaves it as it is. The instance organisation, made an operator, may be the
  operator of clients, and is never a client itself, which a check keeps.
- **A client owns its people.** It has its owners, admins and members, its
  invitations, its settings and its security policy, as any organisation. The last-owner
  rule holds in it as anywhere, and `Apiary.Organisations.sole_owned_organisations/2`
  counts clients too.
- **Reach.** The operator's people, at any level there, read everything in each client,
  in every workspace: runs, terminals, the policy, the trail and the members; they change
  nothing there, the policy included (the role `reader`). A person of the operator who
  holds a membership in the client too changes what that membership allows, in the
  workspaces it reaches. Their level in the operator counts only inside the operator,
  and a suspended operator's people read its clients no more; an instance admin reads
  every organisation they reach neither way, as a `reader` too ([access.md](access.md),
  Reach). The scope carries how (`Apiary.Accounts.Scope`'s `reach`);
  `Apiary.Organisations.resolve_scope/4` finds it through the edition's `reach/1`, and
  `Apiary.Access.reload/2` reads it again.
- **Creating a client.** An owner or an admin of the operator creates it on the
  operator's Clients page (`ApiaryPro.Operators.create_client/3`), with a name and the
  email address of its first owner: an organisation with a slug, no workspace, the
  operator as its operator, no membership, and the invitation of its first owner
  (`client.invite_owner`), sent to the organisation alone and counted against the
  operator's allowance. The person who accepts lands on the client's overview, `/:org`,
  where the kind cards create its first workspace
  (`Apiary.Organisations.create_workspace_of_kind/3`). While operators run their
  clients, that person is the client's admin. A client's admins create workspaces as its
  owners do, with `operator_infrastructure` on or off (`workspace.create`,
  `ApiaryPro.Access`); an owner of the operator may too while the flag is on, from Set up
  in the client's row on the Clients page while the client has no workspace, which opens
  the client's overview. No line says that the operator makes the first workspace. A
  client's invitation read signed out, on its page and on the sign-up with
  `?invitation=`, lists Invitation alone while the client has no workspace
  (`ApiaryPro.SetUp`), with Invitation current and no Your account.
  That invitation is marked as the operator's by a row of `operator_invitations` beside
  it, written in the same transaction (`ApiaryPro.Operators.OperatorInvitation`), and its
  person joins as the owner, while the client has none and is still the operator's; every
  other invitation makes a member. While a client has no owner, an owner or an admin of
  the operator invites one again, makes a new link for a pending invitation of one, or
  revokes one, from the Clients page (`ApiaryPro.Operators.invite_owner/4`,
  `renew_owner_invitation/4`, `revoke_owner_invitation/3`), and an
  owner of the operator deletes it (`ApiaryPro.Deletion.delete_client/3`) rather than
  drops it; the first owner's joining deletes the other pending invitations of an owner.
  From then on the client's owners and admins invite and manage its people.
- **The instance actions.** The instance organisation's owners list every organisation on
  Instance settings' Organisations, `/instance/organisations`, create an organisation or an
  operator there, whose first owner is the one who creates it, make an organisation that
  is no client an operator, or an operator without clients an organisation
  (`ApiaryPro.Operators.change_kind/3`), purge an organisation at once on an erasure
  request (`ApiaryPro.Deletion.purge_on_request/3`), suspend and activate an account, an
  organisation or an operator (Suspension of accounts and organisations, below), grant
  features (Features below the instance, below), and offer the ownership of an
  organisation whose owners are all suspended to one of its admins as the arbiter
  (Transfers, below). Of these, the instance organisation is offered a change of kind
  alone, as any organisation that is no client: made an operator, it takes clients, and
  made an organisation again once it has none. The rest it is not offered, and refuses:
  it is never purged, suspended or transferred, and has what the instance has.
- **Deleting an operator** waits until it has no clients: `Apiary.Deletion` refuses to
  mark or purge one that still has a client, deleted or not (the edition's refusal,
  `:has_clients`), which the foreign key would refuse at the purge's end. A client is
  deleted by one of the client's owners, who cancels its deletion from their organisations
  page during the grace period.

### Policy requests

The policy is the client's, and the operator asks for what its harness needs
(`ApiaryPro.PolicyRequests`, with `security`; [access.md](access.md), Policy requests).

- **A request** (`policy_requests`, the operator's rows) holds the changes, rules of a
  workspace's baseline to add, change or remove and the mode, in the form
  `Apiary.Policy.requested_changes/1` gives them once it has checked them as a change of
  the policy is checked, and a note.
- **The answers.** Each client it goes to answers separately (`policy_request_answers`,
  the client's rows, one per request and client), `pending` until it is `accepted`,
  `declined` or `withdrawn`. The answers' `request_id` is the operator's row, so an
  operator's purge takes the answers of a former client with it; its trail keeps what was
  answered.
- **An acceptance** makes the changes through the same writes as any change of the
  policy, as the person who accepts, in the workspaces they choose, inside one transaction
  (`Apiary.Policy.lock_workspaces/2`, `Apiary.Policy.apply_requested/3`): every check,
  lock, render and audit entry of a change of the policy is the same, and one that no
  longer fits rolls the whole back.
- **A client that parts.** A client that is dropped or deleted has its pending
  answers withdrawn in that change (`ApiaryPro.PolicyRequests.withdraw_for_client/4`).

### The organisation's policy

The organisation's policy is the level above its workspaces' security policy
(`ApiaryPro.OrganisationPolicy`, with `organisation_policy`, which needs `security`;
[access.md](access.md), The organisation's policy). The core keeps the seam
(`Apiary.Policy.Above`, `c:Apiary.Edition.above_workspace/1`), resolves and renders the
level and draws it, saying its name and nothing else of it; the edition keeps the rows and
makes the writes.

- **The row** (`organisation_policies`, one per organisation, written on the first
  change) holds the two settings: `enforce_everywhere`, the floor, and `own_allows`, the
  switch. **The rules** (`organisation_policy_rules`, one per host) are host rules only,
  allow or deny, an allow held to paths or on every path. Neither has a `workspace_id`: the
  rows are the organisation's, in the edition's deletion tables before the tenants.
  `ApiaryPro.OrganisationPolicy.Rule.to_core_rule/1` is a rule as the core resolves it, an
  unpersisted `Apiary.Policy.Rule` of kind `host`.
- **The level** (`above_workspace/1`) is answered where the instance has the feature and
  the organisation has a row: its rules, its floor and its switch as an
  `Apiary.Policy.Above`. The organisation's grant of the feature only shows or hides its
  pages: the level holds above every workspace either way.
  The edition's answer carries the organisation's variables on it (The organisation's
  variables, below).
- **A write** (`allow/2`, `deny/2`, `remove_rule/2`, `set_floor/2`, `set_switch/2`) is
  one transaction in the lock order: the organisation and its operator `FOR SHARE`, then
  every workspace in use in the order of their ids `FOR NO KEY UPDATE`
  (`Apiary.Policy.lock_workspaces/2`), the membership and the account, the action asked
  again, then the row of the organisation's policy. The rules are checked as the core
  checks a host rule and resolved among themselves; then every workspace is rendered again
  (`Apiary.Policy.rerender_in/3` with `action: "above_changed"` and `all: true`, so a
  workspace with no version yet gets its version 1), each holder whose bytes change
  getting a separate change in the workspace's history naming this change as its `cause`;
  a render the resolution refuses rolls everything back, said with the workspace's name.
  One entry on the organisation (`organisation_policy.edit`, `set_floor` or `set_switch`)
  holds the rules and settings before and after, the kind of change, its subject and
  `rendered`, the version each workspace was left at, nil where its bytes stayed the same.
  After the commit, each workspace's pages are told (`Apiary.Policy.announce/1`) and the
  organisation's (`topic/1`).
- **A new workspace** is rendered under the level in the transaction that creates it
  (`c:Apiary.Edition.workspace_created/3`), so a deny of the organisation's holds in it
  from its first run.
- **The page** (`ApiaryProWeb.PolicyLive.Organisation`, `/:org/policy`) is the
  workspace's policy page's language: the core's `ApiaryWeb.PolicyLive.Common` mounted
  with the edition's writer and base path, the core's rule form and rows' menu, the list
  pattern of `ApiaryWeb.PolicyLive.RuleList`, and the core's components. Its Workspaces
  tab and the counts of its settings come from one resolution per workspace
  (`workspaces_summary/1`); its use column from each workspace's record
  (`rule_activity/2`, never partial). `ApiaryProWeb.Edition.above_policy_link/1` leads the
  workspace's policy pages and Network access to it.

### The organisation's variables

The organisation's variables are the level above its workspaces' variables
(`ApiaryPro.OrganisationVariables`, with `organisation_variables`, which needs `security`
and `secrets`; [access.md](access.md), The organisation's variables). The core keeps the
seam (`Apiary.Policy.Above`, its `variables`, which `c:Apiary.Edition.above_workspace/1`
answers), resolves the level first in every chain (`Apiary.Variables.Resolution`) and
refuses below it what the level refuses; the edition keeps the rows and makes the writes.
A run receives only its security policy: the core keeps and resolves variables at every
level, and the run configuration does not carry them.

- **The rows** (`organisation_variables`) are a name, a value and a lock each, with the
  core's checks of `variables` copied: a name's rule, a value of one line of at most 4096
  bytes, and one name per organisation whatever its case (a unique index on
  `lower(name)`). No `workspace_id`: the rows are the organisation's, in the edition's
  deletion tables after the organisation's policy.
  `ApiaryPro.OrganisationVariables.Variable` checks a change as the core's
  `Apiary.Variables.Variable` does, with its sentences, and `to_core_variable/1` is a row
  as the core resolves it, an unpersisted `Apiary.Variables.Variable` with the row's id.
- **The level** (`ApiaryPro.OrganisationVariables.for_above/1`) is the organisation's
  variables as the core's structs, where the instance has the feature; the organisation's
  grant of it only shows or hides its pages. The edition's answer
  (`c:Apiary.Edition.above_workspace/1` in `ApiaryPro.Edition`) is the organisation's
  policy, where one is in force, with `variables: for_above(workspace)`; where the
  organisation has variables and no policy in force (none kept, or `organisation_policy`
  off), a fresh level of variables alone (`ApiaryPro.OrganisationVariables.above_without_policy/1`),
  `%Apiary.Policy.Above{policy: false}` with the organisation's id, name and slug and its
  variables, never built from the stored policy's settings: no rules, no floor, and the
  switch on, which the core requires of such a level, and which its security policy
  takes as nil; and nil where it has neither.
  `ApiaryPro.OrganisationPolicy.above_workspace/1` stays the policy alone, for its
  callers: the link to its page, a new workspace's page and its first render.
- **A write** (`create/2`, `update/3`, `lock/2`, `unlock/2`, `delete/2`) is one
  transaction in the lock order, as the organisation's policy's: the organisation and its
  operator `FOR SHARE` (`Apiary.Access.lock_places/1`), then every workspace of the
  organisation in use or marked for deletion and still restorable, in the order of their
  ids `FOR NO KEY UPDATE`, as `Apiary.Policy.lock_workspaces/2` takes those in use, the
  membership and the account, the action asked again, then an advisory lock of the
  organisation's variables, then the row changed. A workspace marked for deletion is
  checked as one in use, since `Apiary.Deletion.restore_workspace/2` checks nothing of its
  variables; it takes the workspace's row as the write does, so the two take turns. A
  name beginning `QORY_` is refused (`Apiary.Variables.Denied`). After the write, in its
  transaction, the variables as they are now are checked alone, at most 128 names
  and 64 KiB, which the core's check does not see where there is no workspace, and
  against every workspace locked with the core's `Apiary.Variables.check_above/2`: a
  workspace or a repository that spells a name otherwise refuses the write, and so does
  any holder, a workspace or a repository, the level would take over the limits, each
  said with the workspace's name. A deletion adds no name and is checked only for a
  locked variable, whose deletion puts back the values its lock set aside below, as an
  unlock does. A refusal for another spelling says what the write was: saved, locked,
  unlocked or deleted. One entry on the variable (`organisation_variable.edit`) says the change,
  the name and `level: "organisation"`, and for a change whether the value changed, never
  the value; after the commit the organisation's pages are told (`topic/1`).
- **What is not checked**: the limits and the one spelling are checked on every write at
  either level, and on nothing else. Where the instance does not have the feature,
  `for_above/1` is empty, so a workspace's writes are checked against none of the
  organisation's variables; the instance having the feature again, as when
  `QORY_FEATURES` changes at a restart, checks nothing, and may leave a workspace with
  another spelling or over a limit. The organisation's next checked write is refused,
  naming the workspace, until the workspace changes or deletes its variable.
- **The counts** (`overrides/1`) are, per name of the organisation's, how many workspaces
  in use and repositories set it themselves: the values a lock sets aside, or the holders
  that override the organisation's value; and how many of the repositories' values their
  workspace's lock of the name sets aside, which an unlock
  of the organisation's leaves aside, so the page says how many come back. One grouped
  query.

### The organisation's secrets

The organisation's secrets sit beside its workspaces' secrets, not above them
(`ApiaryPro.OrganisationSecrets`, with `organisation_variables`, the feature of the
organisation's variables too, which needs `security` and `secrets`;
[access.md](access.md), The organisation's secrets). The core keeps them: their rows,
their values, encrypted, their checks, their audit entries and the sealing of a value to
a run (`Apiary.Secrets`, the organisation's level). For who may, it calls the edition's
`c:Apiary.Edition.organisation_secrets/2`, which `ApiaryPro.Edition` implements with
`ApiaryPro.OrganisationSecrets.may/2`. The edition keeps no row of them. The callback
stays beside `Apiary.Access`, with the 3 others that [access.md](access.md) lists (The 4
callbacks beside `Apiary.Access`), because sealing has no person to check.

- **Two levels, side by side.** A workspace gets no secret of the organisation's by its
  name: nothing is inherited, and nothing is locked. A workspace's secret with the same
  name is a different secret; names are compared without case among the organisation's
  secrets, as among a workspace's, and never across the two levels.
- **Read, write and use** are checked with the person's scope: `Apiary.Access.check/3`
  checks the action on the organisation, so the core's reload, its locks and a suspension
  hold as for any action of the organisation's. `ApiaryPro.Access.check/3` returns not
  found where the organisation does not have the feature (`ApiaryPro.Features.of/2`).
- **Sealing** is asked with no scope, and the instance alone answers
  (`Apiary.Features.on?/1`), as it does for the organisation's variables: an
  organisation that does not have the feature still has its secrets sealed where a link
  asks for one; where the instance does not have it, none is.
- **The page** (`ApiaryProWeb.SettingsLive.Secrets`, `/:org/settings/secrets`) is the
  first tab of the organisation's settings' Secrets and variables section
  (`ApiaryProWeb.Edition`, `settings_tabs/1`), laid out as the core's workspace Secrets
  tab (`ApiaryWeb.SecretLive.Index`), with its components and its query
  (`ApiaryWeb.SecretLive.Query`). It never renders a value, nor keeps one in an assign.
- **The keys of the organisation's model providers** are rows of the same page, listed by
  the core (`Apiary.Secrets.list_provider_keys/2`, `:organisation`) with their provider's
  name, "Model provider key" and a mask on each value: they need `factory` and `secrets`,
  not `organisation_variables`, and a person who changes them (`provider.write`) or reads
  the organisation's secrets sees them; a member does not. Change, add a value, rename and
  delete go through the core's `Apiary.Connections.add_provider_key/3` to
  `delete_provider_key/3`, under `provider.write`. Without `organisation_variables` the
  page has these rows alone, no Variables tab and no way to a secret or a variable of the
  organisation (`ApiaryProWeb.SettingsLive.SecretsAndVariables.shown?/1`).

### Suspension of accounts and organisations

A membership, a person's account and an organisation, an operator among them, are
suspended and activated again ([access.md](access.md), Suspension): a membership by the
organisation's owners and admins, as in the core
(`Apiary.Organisations.suspend_member/2`), an account and an organisation by the
instance admins (`ApiaryPro.Suspensions`).

- **Where they are kept.** A membership's suspension is `suspended_at` and
  `suspended_by_id` on `memberships`, the core's; an organisation's is the same two on its
  row of `tenants`; an account's is a row of `account_suspensions`
  (`ApiaryPro.Suspensions.AccountSuspension`), which suspending inserts and activating
  deletes. Activating ends the suspension and nothing else changes: no membership,
  workspace access, access key, history or managing relationship is removed. The rows
  they are about stay the ones to lock: a suspension of an account locks its `users` row
  and inserts or deletes its row of `account_suspensions` under the lock, since the
  absence of a row cannot be locked, and an organisation's locks its `organisations` row
  and writes its tenant under it. `Apiary.Access` reads a membership, its organisation and
  its person's account on every change it allows, and locks them where the change must
  stay allowed while it is written, then reads the suspensions in a statement after its
  locks, so one written while it waited is seen. The history is the trail's. A check
  keeps the suspender with the suspension, and one keeps the instance organisation
  unsuspended, since it holds the instance admins, who activate everything else.
- **Enforced in `Apiary.Access`.** The edition narrows the core's queries to the accounts
  and organisations in use (`ApiaryPro.Suspensions.active_accounts/2`,
  `active_organisations/2`, the edition's). `reload/2` reads the suspension of the
  membership, of the account, of the organisation and of a client's operator, and fails
  closed: a suspended membership or account is no membership, a suspended operator gives
  no reach into its clients, and a suspended organisation answers `forbidden` to every
  action but the reads, for every role but the instance's. Under `lock: :share` it holds
  the organisation, its operator and the account `FOR SHARE`; a suspension locks the row
  it suspends `FOR NO KEY UPDATE`, in the lock order of [access.md](access.md) (The lock
  order), so a write that holds the row is written before it, and one after it sees it.
  `Apiary.Organisations.resolve_scope/4`, the switcher and the organisations page read the
  same suspensions, so a page never opens what `Apiary.Access` would refuse.
- **An account** signs in nowhere: the password and a log-in link are checked first, and
  a suspended account then gets a sentence that names no reason
  (`ApiaryPro.Suspensions.account_refusal/1`, the edition's `account_refusal/1`); its
  session tokens are deleted and its open pages disconnected, and a session never finds
  it, nor gets a password link (`Apiary.Accounts.build_password_link/3`). Its access keys
  keep working: a key is a machine's, not a person's.
- **An organisation** answers the server contract as a revoked key does: its keys are
  refused at verification (`Apiary.AccessKeys.fetch_for_verification/1`). An invitation
  into it is not found and accepts no one: the acceptance holds the organisation
  `FOR SHARE` first, which the suspension waits for, or came first and is seen. The
  instance's jobs, the trail's pruning and a deletion's purge, go on.
- **No owner who may act.** The last-owner rule counts the owners whose membership and
  account are neither suspended nor deleted
  (`Apiary.Organisations.other_active_owner?/1`). Only an instance admin leaves an
  organisation without one, a client as any other, by suspending its only owner's
  account; it then runs below the owner level, which
  `ApiaryPro.Suspensions.owner_suspended?/1` says of the organisation's owners, and
  its pages tell its people (`ApiaryProWeb.Notices`).

### Transfers

An operator parts from a client by dropping it; an organisation whose owners are all
suspended gets an owner again by the arbiter's offer and its acceptance
(`ApiaryPro.Transfers`; [access.md](access.md), A client's drop and The instance
actions).

- **`transfers`** holds the pending offers, organisation-keyed by `organisation_id`,
  which is unique: one pending offer per organisation, deleted when it is accepted or
  withdrawn, so the trail keeps what happened. The arbiter's is of the kind `to_admin`,
  always `arbitrated` and with its `reason`, and `recipient_id`, the admin, under a
  composite key against their membership, so their removal takes the offer with it.
  Checks keep the fields of each kind together. The table is in the edition's deletion
  tables (`ApiaryPro.Deletion.Tables`).
- **Dropping.** An owner of the operator drops a client (`client.drop`), at once and
  with no offer, the client's name typed to confirm, which `ApiaryPro.Transfers` checks:
  its tenant's `operator_id` and `operator_since` are set to nil, the operator's grants
  to it are written out so it follows the instance, and one entry goes into the client's
  trail and one into the operator's. Its people, workspaces and policy stay as they are.
- **The arbiter.** An instance admin's offer of the ownership of an organisation whose
  owners are all suspended, a client as any other, replaces the one pending, which its
  entry names. Accepting it makes the admin an owner and changes no operator: a client
  stays its operator's. It is never for the instance organisation, nor for a suspended
  organisation, and it lapses once an owner may act again, and is refused at acceptance
  then too. An owner who may act again takes back what the arbiter offered (the edition's
  `membership_changed/5`, `ApiaryPro.Transfers.membership_activated/1`).
- **Race safety.** Every write takes its locks in the lock order of
  [access.md](access.md) (The lock order). A drop locks the client `FOR NO KEY UPDATE`,
  then its operator `FOR SHARE`; the arbiter's acceptance holds the organisation
  `FOR SHARE`, locks its owners, then the membership and account of the person who
  accepts, then the offer; a person the offer is not for, and an organisation with no
  offer, get not found from a read without a lock and take none of these. So a write in
  flight, which has the organisation `FOR SHARE`, is waited for; a
  change of the operator's kind, its suspension and a grant to it wait or are seen; and
  an entry, which holds the organisation only `FOR KEY SHARE`, never waits on an
  acceptance. A deadlock Postgres breaks all the same is taken again, and a page is told
  to try again, never the database's error.

### Features below the instance

The instance has its features (`QORY_FEATURES`, `Apiary.Features`), and the edition adds
three: `managed_organisations`, operators and their clients, and what an operator does for
them, which needs `observability`; `organisation_policy`, the organisation's policy above
its workspaces', which needs `security`; and `organisation_variables`, the organisation's
secrets beside its workspaces' and its variables above them, which needs `security` and
`secrets`. Below the instance the chain is instance, operator, client, and each link only
narrows the one above: `ApiaryPro.Features.of/2` answers what an organisation is shown,
and `ApiaryPro.Features.of_all/1` the same for each of a list; the edition's `hidden/1`
(`ApiaryPro.Features.hidden/1`) answers what a person is not shown in it, which the core
keeps on the person's scope; nothing else does. A workspace is shown what its organisation
is shown.

- **`feature_grants`**, one row per organisation and feature, under a unique index. A
  row says a feature is `granted`, to an operator or a client, or taken away, from an
  organisation with no operator. The table is in the edition's
  deletion tables (`ApiaryPro.Deletion.Tables`). `ApiaryPro.Grants` writes it, and nothing
  else.
- **Opt-in below an operator.** An operator has what an instance admin granted it, of the
  instance's; a client what its operator granted it, of the operator's, never
  `managed_organisations`. A feature a grant can name, added to the instance later,
  reaches neither until it is granted. The features no grant can name, the core's
  features but `observability` and `security`, such as `secrets`, are shown to both
  wherever the instance has them, as to any organisation: only the instance switches
  them. **Opt-out without one.** An organisation with no operator has what the instance
  has but what an instance admin took away, and gains what the instance gains. The
  instance organisation has what the instance has, whatever its kind. **A workspace** has
  what its organisation has.
- **Clipped where it is read.** A grant above what the granter has is refused at write;
  when a link narrows later, what is below it is clipped by `of/2`, with no rewrite. A
  feature is kept only with the features it needs.
- **Where an organisation sits.** Its grants are written out in the transaction that
  moves it: made an operator, it is granted what it had, and from then only a grant
  changes it; made an organisation again, it keeps what it had, opt-out; a new operator
  is granted what the instance has; a new client what the operator has; a client that
  is dropped follows the instance.
- **Absent, as off on the instance.** Every surface a person meets asks
  `Apiary.Features.visible?/2` with their scope, as in the core, so what an organisation
  is not shown is absent for its people there, and in its workspaces, as a feature the
  instance lacks is. Its machines and runs are served in full, as the instance's features
  say.
- **Pages.** Instance settings › Organisations grants operators and organisations with no operator their
  features; an operator's Clients page its clients. They offer only the
  features built (`Apiary.Features.built/0`); one not built yet keeps what its grants
  say.
- **Race safety.** A write locks what it narrows `FOR NO KEY UPDATE`, an operator's
  clients and then the operator, in the lock order of
  [access.md](access.md) (The lock order); a change that asked `Apiary.Access` holds them
  `FOR SHARE` while it is written and reads the features after its locks, so one of the
  two waits for the other and the second sees the first.

### The audit trail

The edition's changes are audited as the core's are, each in the trail of the organisation
it changes, written with the change (the core's section The audit trail, in this file).
What the edition adds:

- **What is audited.** Creating an organisation later by a person who has an account
  (`organisation.create`, `details.sign_up` false); adding a member to a workspace and
  removing them from one (`workspace_access.add`, `workspace_access.remove`), and the
  workspace a person made a member is kept in, a `workspace_access.add` with the reason
  `demoted`; creating a client (`client.create`, the first entry of the client's trail)
  and inviting its first owner (`client.invite_owner`, in the client's trail); the
  instance actions that change something (`instance.create_organisation`,
  `instance.create_operator` and `instance.change_kind`, each in the trail of the
  organisation created or changed, and `instance.purge_organisation`, in the instance
  organisation's, since the purged organisation's trail goes with it); who may sign up
  (`instance.change_sign_up`, in the instance organisation's trail, with each setting that
  changed, before and after); suspending and
  activating an account (`instance.suspend_account`, `instance.activate_account`, in the
  instance organisation's trail, naming the account by id) and an organisation or an
  operator (`instance.suspend_organisation`, `instance.activate_organisation`, in the
  trail of the organisation suspended, with no address or client); the arbiter's offer of
  an organisation's ownership (`instance.transfer`, in the organisation offered, with its
  reason), its lapse and its acceptance (`organisation.withdraw_transfer` and
  `organisation.accept_transfer`, in it); a client's drop (`client.drop`, in the client
  and in the operator);
  an operator's policy requests (`policy_request.send` in the operator and, as each
  client's receipt, in the client; `policy_request.accept`, `policy_request.decline` and
  `policy_request.withdraw` in the client and in the operator, a withdrawal of a client
  that parted with the reason); the grants of features (`instance.grant_features`,
  `client.grant_features`); the organisation's policy
  (`organisation_policy.edit`, `set_floor`, `set_switch`, on the organisation), its
  variables (`organisation_variable.edit`, on the variable, by name and never by value)
  and its secrets, which the core writes as a workspace's (`secret.write`, on the secret,
  by name and value IDs and never by value, with `details.level` `organisation`);
  and each organisation's adoption (`instance.adopt`). `Apiary.AuditCase` makes each audited change, the core's
  and the edition's (`ApiaryPro.AuditChanges`), in `test/apiary_pro/audit_test.exs`.
- **Who reads it.** Beside the owners and the admins, a client's operator's people and
  the instance admins read an organisation's audit log (`audit.read`, Audit log in the
  organisation's sidebar), as readers. The edition's actions are said in words by
  `ApiaryProWeb.ActivityDescriber`, which the audit log asks before the core's.

### Deletion

The edition's part in deleting and purging organisations is `ApiaryPro.Deletion`, over the
core's `Apiary.Deletion`.

- **What it refuses** (`ApiaryPro.Deletion.refusal/2`, the edition's
  `deletion_refusal/2`), asked on the locked row after the core's refusals: the
  instance organisation (`:instance_organisation`), which holds the instance admins, and
  an operator that still has clients (`:has_clients`): each is deleted or dropped first,
  and the database keeps the reference until then.
- **Whom it tells** (`ApiaryPro.Deletion.changed/4`, the edition's `deletion_changed/4`):
  a client's operator reads it through the operator, so the operator's people hear of its
  marking and its cancelling, and of its workspaces', as the client's members do.
- **An operator's deleting of a client** it created and nobody else is in
  (`ApiaryPro.Deletion.delete_client/3`, `client.delete`): marked and purged as any
  organisation, its pending invitations deleted at once, its entry in the operator's
  trail.
- **A purge at once.** `ApiaryPro.Release.purge_now/2`, and an instance admin on
  Instance settings › Organisations (`ApiaryPro.Deletion.purge_on_request/3`), purge an organisation at once,
  for an erasure request an instance admin received, over the core's erasure steps
  (`Apiary.Deletion.purge_now/3`, `lock_for_erasure/1`, `mark_for_erasure/2`,
  `purge_marked/2`), and record on its row who asked and why, which the instance's line
  keeps whichever run finishes the purge.
- **The edition's tables in the walk** (`ApiaryPro.Deletion.Tables`), purged before the
  core's: a policy request's answers before the request; the transfers, the feature grants
  and the workspace access before the core's memberships and workspaces they point to; an
  operator's invitations of its clients' first owners before the core's invitations; and
  the people locks, then the tenants, last. The rows of other organisations that name the
  one purged go with its row by their keys: an operator's invitations into its former
  clients, by `operator_invitations.operator_id`.
  `test/apiary_pro/deletion/tables_test.exs` compares the walk with the schema.
