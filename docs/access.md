# Who may do what

`Apiary.Access` is the one way to check whether someone may do something. A page calls
`Apiary.Access.can?/3`. A context function calls `Apiary.Access.authorize/3`, or
`Apiary.Access.check/3` after `Apiary.Access.reload/2` inside its transaction (The context
function asks before it acts, and The page asks the same question, below). Roles grow, and
an edition may add actions, roles and ways into an organisation (An edition's part,
below). A rule written in one place grows there; a comparison repeated across the contexts
and pages would be changed in some places and missed in others.

These stay outside `Apiary.Access`:

- **Authentication**, which establishes who the caller is: signatures, run keys, enrolment
  codes, tokens, nonces, sessions and a recent sign-in.
- **Data rules**, which apply whoever the caller is: a run pushes only the artifacts of the
  run's work item (`Apiary.Artifacts`), quotas, and queries that narrow rows to what the
  caller already reaches.
- **The last-owner rule** (The last owner, below). `Apiary.Organisations` compares levels
  to count the owners who may act (`Apiary.Organisations.other_active_owner?/1`).
- **Wording and lists on a page.** A page may read a level, or
  `Apiary.Access.instance_admin?/1`, to choose a sentence or to list the owners. This stops
  no action.
- **Feature gates** on a route or a part of a page (`ApiaryWeb.Features`). A gate depends on
  what the instance has, not on the person.
- **The callbacks of `Apiary.Edition` listed under Callbacks beside `Apiary.Access`**, below.

## A new action goes into the module

Anything a person, an access key or a job can do that changes something, or that reads
something a role could one day be refused, is an **action**. A new one, or a new feature's
actions:

1. is added once to the action list in `Apiary.Access`, or to an edition's
   (`c:Apiary.Edition.actions/0`), as an `Apiary.Access.Action`: the feature it belongs
   to (none: every instance has it), and the part where it belongs to one (`part:`, one
   of `Apiary.Features.parts/0`: a part of that feature, or for an action of no feature a
   part of none), a line saying what it is, which the
   module's documentation tabulates, whether it leaves an audit entry, and what it is
   asked of;
2. is given to the roles that may take it, in the action's `roles`, from which the
   module's role table is built;
3. gets its row in the access test's rows modules (`Apiary.AccessRows` for the core,
   an edition's rows module for the edition's actions): the kinds of actor that may take
   it. `Apiary.AccessCase` fails for an action in the list without a row. The tests
   test each rule of `can?/3` and `authorize/3` once, not each action of each actor:
   `test/apiary/access_test.exs`, and for the keys, the dispatch actions and the
   approvers `test/apiary/pool_key_role_test.exs`,
   `test/apiary/gateways_instance_test.exs`, `test/apiary/adapters_test.exs`,
   `test/apiary/adapters/connections_test.exs` and
   `test/apiary/access_approvers_test.exs`. A change to an action's `roles` shows in the
   diff of `Apiary.Access`, and no test fails for it.

An action only the instance admins take sets `instance: true` (The instance's admins,
below). An edition's action follows its `roles`, unless `c:Apiary.Edition.check/3` returns
something other than `:continue` for it (An edition's part, below).

## A new role goes there too

A role of the core goes into the role list in `Apiary.Access` (`@roles`), and
`Apiary.Access.role/1` returns it for the scopes that act in it. Each action the role may
take lists it in `roles`. The access test's rows module gets an actor in that role
(`actors/0`, `setup/1`, `Apiary.AccessCase`).

An edition adds a role with `c:Apiary.Edition.roles/0`, and assigns it to a person with
`c:Apiary.Edition.role/1`. The boot stops for an edition's role that has the name of a role
of the core, and for an action whose `roles` list a role nobody defines.

## Levels, and the workspaces a person reaches

A person's **membership** is in an organisation, once, and carries their level there:
**owner**, **admin** or **member**. The level is the organisation's; no workspace changes
it, and the rule that an organisation keeps an owner counts the organisation's owners
who may act (The last owner, below).

In the core every level reaches every workspace of its organisation. Whether a level
reaches every workspace is `Apiary.Access.reaches_every_workspace?/1`, which asks the
edition (`c:Apiary.Edition.every_workspace_levels/0`), the one place that says so: the
core's edition answers all three levels. An edition may narrow it, and then says which
workspaces a membership at another level reaches: from what the scope carries
(`c:Apiary.Edition.reaches_workspace?/3`), and for a query over the workspaces
(`c:Apiary.Edition.reached_workspaces/2`). An invitation is sent from a workspace.

Opening a workspace needs the membership and a workspace the person reaches. The path
scope (`Apiary.Organisations.resolve_scope/4`) answers a workspace a person does not
reach as not found, as it answers one that does not exist, and `Apiary.Access` asks it
again for every question about a workspace's subject. A person who reaches no workspace
of the organisation, which only an edition that narrows the levels can leave, signs in to
it and is told so on the organisation's path, `/:org`.

## What an admin may not

An admin may what an owner may inside the organisation, with these exceptions, each an
owner's alone:

- changing a person's level (`member.change_level`), to owner, admin or member;
- locked rules of the security policy (`security_policy.lock`);
- deleting the organisation and cancelling its deletion (`organisation.delete`,
  `organisation.restore`).

An edition may add more actions that are an owner's alone, in their `roles`.

Deleting a workspace and cancelling it (`workspace.delete`, `workspace.restore`) are an
admin's as well as an owner's: an admin manages the workspaces.

Over people, an admin acts on members only. Inviting, changing a level, removing,
revoking an invitation, making a new link for one (`invitation.renew`), suspending and
activating (`member.suspend`, `member.activate`) are **actions over people**: asked of the membership they are about, whose level decides,
or of the invitation, which is at member: an invitation is an email address and nothing
else, and its person joins as a member, whom an owner makes an admin or an owner
afterwards, at a level the edition does not refuse (An edition's part, below). An owner
takes them on anyone, within the last-owner rule, but suspends and activates admins and
members only, never another owner; an admin takes them on a member
and on any invitation, never on an owner or an admin. Nobody suspends or activates their
membership, whatever their level. Asked of a workspace or the organisation, as a page
asks whether to show a button at all, the role alone answers; the context function asks
of the row. An invitation is the organisation's whichever workspace it was sent from, so
an owner or an admin revokes it, or makes a new link for it, from any page of the
organisation. An action over people
that an edition adds asks the same rule (`Apiary.Access.acts_on?/2`). An edition that
makes a new link with an action it adds asks it itself, and passes it as `action:`
(`Apiary.Organisations.renew_invitation/4`), which then does not ask `invitation.renew`.

## Reach

A person reaches an organisation through their membership there, at its level: what they
may change there is that level's. `Apiary.Access.reach/1` names how, and the scope carries
it (`Apiary.Accounts.Scope`, its `reach`); in the core it is `:membership`, or nil for one
who does not reach it.

An edition may let a person into an organisation where they hold no membership
(`c:Apiary.Edition.reach/1`), and give them a role there (`c:Apiary.Edition.role/1`): such
a person reaches every workspace of it, and holds what that role holds.
`Apiary.Access.level/1` is the level of a membership there, and nil for one the edition
lets in without one; `Apiary.Access.reader/1` names the edition's way in for a person
without a membership there whose role holds no change (`Apiary.Access.reads_only?/1`: no
action of it leaves an audit entry), or is nil, and a page tells such a reader they read
it and change nothing (`c:ApiaryWeb.Edition.reader_sentence/2`) rather than the level a
change would take. One let in with a role that changes something is no reader: a
refusal tells them what it tells anyone else. The
path scope (`Apiary.Organisations.resolve_scope/4`) opens an organisation for its members
and for whom the edition lets in (`Apiary.Organisations.put_reach/2`); the switcher lists
the places the edition gives (`Apiary.Organisations.list_places/1`,
`c:Apiary.Edition.places/1`), in the core a person's memberships.

`can?/3` answers from the reach the scope carries. `authorize/3` reads the membership
again, and what the edition put on the scope (`c:Apiary.Edition.reload/2`), and fails
closed: a membership removed or suspended, or one whose account is no longer in use, is
no source of reach. A write that must stay allowed while it is written, the security
policy's, holds the organisation `FOR SHARE`, with the organisations the edition holds
beside it (`Apiary.Access.lock_places/1`), and reads the membership `FOR SHARE`
(`reload/2` with `lock: :share`), in the lock order below.

## An edition's part

`Apiary.Access` asks the edition at a few places, each a callback of `Apiary.Edition`; the
core's edition (`Apiary.Edition.Core`) adds nothing and narrows nothing. An edition
may:

- add actions and roles (`c:Apiary.Edition.actions/0`, `c:Apiary.Edition.roles/0`), which
  join the core's in one registry: an action named twice, a role that is one of the
  core's, or an action of a role or a feature nobody defines stops the boot;
- answer first for what it adds or narrows (`c:Apiary.Edition.check/3`), once the
  action's feature is on and shown to the scope and before the place is checked, or leave
  the answer to the core;
  an answer that must come after the place's asks `Apiary.Access.check_place/3` first.
  Asked with no scope, as `Apiary.Access.refused_on?/2` asks, `forbidden` says the subject
  refuses the action whoever asks, which a page asks to say why a control is not there.
  An instance action reaches this callback after its feature and the instance step (The
  instance's admins, below);
- let a person into an organisation without a membership, with a role there, and read
  what it gave again under the write's locks (Reach, above);
- put on the organisation what its checks read of it, where
  `Apiary.Organisations.load_scope/2` and `Apiary.Organisations.load_home_scope/2` put a
  membership's organisation into the scope without `c:Apiary.Edition.reach/1`
  (`c:Apiary.Edition.put_organisation/1`): read once for the scope, so a check for each
  row of a list reads no row;
- narrow the levels that reach every workspace, and say which workspaces another level
  reaches (Levels, above);
- hold more organisation rows beside the organisation's row with a write that must stay
  allowed (`c:Apiary.Edition.places_to_lock/1`, The lock order, below);
- lock its rows for a change, at one point right after the organisation rows
  (`c:Apiary.Edition.lock_rows/1`, The lock order, below);
- hold an account or an organisation out of use beyond what the core knows: the core's
  queries leave out what it holds so (`c:Apiary.Edition.active_accounts/2`,
  `c:Apiary.Edition.active_organisations/2`), `reload/2` among them, so a membership whose
  account it holds out of use is no membership, and signing in asks it why an account may
  not (`c:Apiary.Edition.account_refusal/1`);
- give the level an invitation's person joins at, or refuse the acceptance
  (`c:Apiary.Edition.accepting/3`), and add to it once the membership is made
  (`c:Apiary.Edition.accepted/4`);
- refuse a level in an organisation, with a reason (`c:Apiary.Edition.level_refusal/4`,
  `Apiary.Access.level_refusal/4`): an invitation, its acceptance, a change of level and
  the release commands that grant and revoke an instance admin each refuse it, the
  People page offers only the levels it refuses none of
  (`Apiary.Access.grantable_levels/1`) and says a refusal in the edition's words
  (`c:ApiaryWeb.Edition.level_refusal_sentence/2`); a membership keeps the level it holds
  (The lock order, below, says where it is asked);
- refuse a deletion or a purge, and hear of each (Marked for deletion, below);
- say who may take an action in the edition's words (`c:ApiaryWeb.Edition.who_may_sentence/2`),
  where the core's sentence names the levels that may, such as "Only owners and admins
  add nodes.", which stays where the edition has none (`ApiaryWeb.Access.who_may/3`). It
  is asked for the refusals, and the notices to whoever may not act, of the nodes' pages
  and a node's Access key tab, the workspace overview's Get the command, the
  organisation's and the workspace's settings, and People; for People's line of what each
  level does; for the refusal to cancel an
  organisation's deletion on Your organisations; for the security policy's refusals
  (`Apiary.Policy`); for the policy pages' refusals of a click on the mode or a lock; and,
  with `:"security_policy.lock"`, for each sentence that says who may change a locked rule:
  a locked rule's lock on the policy pages, the rule form's refusal, a target's
  Destinations, the lock hint of a connection's Allow or Deny panel and the workspace
  overview's hint on a locked rule. Where the core's sentence first says what is locked,
  that part stays and the edition's sentence follows it
  (`ApiaryWeb.Access.who_may_after/4`). The policy pages' mode row, the workspace
  overview's hint on the mode and the Lock confirm's "Only an owner can unlock." keep the
  core's words.

### Callbacks beside `Apiary.Access`

These callbacks of `Apiary.Edition` decide something about access outside `Apiary.Access`:

- `c:Apiary.Edition.organisation_secrets/2` decides whether the scope's person reads,
  changes or links an organisation's stored secrets (`:read`, `:write`, `:use`), and, with
  a nil scope, whether such secrets may be sealed (`:seal`), where no person is involved.
  The core keeps no secret at an organisation and has no action for them: it returns
  `{:error, :not_found}` for every verb. An edition's implementation may call
  `Apiary.Access` with actions it adds.
- `c:Apiary.Edition.operator_chain_writer?/1` decides whether the person writes the chain
  of model providers and choices an operator keeps for its clients. `Apiary.Connections`
  and `Apiary.ModelChoices` call it beside `provider.write`. The core has no operator and
  returns false.
- `c:Apiary.Edition.harness_owner/1` returns the organisation that owns a harness document
  the person saves (`Apiary.Stacks.put_stack/4`): an id, not a yes or no. With nil, the save
  stops, `{:error, :forbidden}`.
- `c:Apiary.Edition.scope_setting?/1` decides whether a form shows the setting
  `Available to every workspace in %{organisation}`. It stops no action. The core returns
  false.

`c:Apiary.Edition.client_reads/4` is a data rule. It narrows the query or the row of a read
to what the scope's person reads of a run, and the core returns it unchanged.

## The instance's admins

The instance's organisation is the one its first sign-up creates
(`c:Apiary.Edition.instance_organisation_id/0`, [architecture.md](architecture.md), The
instance's organisation), and its owners are the **instance admins**, who run the
instance. Inside it they act at their level, as anyone there does. No role of that name
exists: an instance admin is a person with the role `owner` in the instance's organisation,
whose membership is not suspended and whose account is in use. The level is
`Apiary.Access.instance_admin_level/0`.

### Instance actions

An **instance action** is an `Apiary.Access.Action` with `instance: true`. Each of the
core's has `owner` in its `roles`. `account.password_link` also has `instance`, for a
release command. The last column shows which actions also need a recent sign-in.

| Action | Function or page | Feature | Recent sign-in |
|---|---|---|---|
| `instance.read` | Instance settings, the documentation for instance admins, and the machine logs of a run's dispatch | none | no |
| `instance.read_machine` | the vendor's type of the machine that a run's dispatch started, on the run's page (`Apiary.Runs.Preparation`) | none | no |
| `instance.review_connections` | `Apiary.Setup.review_connections/1` | none | no |
| `instance.mail_save` | `Apiary.Mail.save_settings/3` | none | yes |
| `instance.mail_resend` | `Apiary.Mail.resend_test_link/2` | none | yes |
| `instance.mail_on` | `Apiary.Mail.turn_on/2` | none | yes |
| `instance.rename` | `Apiary.ProductName.rename/2` | none | no |
| `instance.configure` | `Apiary.InstanceConfig.save/3`, and `Apiary.MachineTypes.create/2`, `update/3`, `make_default/2` and `delete/2` | none | yes |
| `instance.support_save` | `Apiary.SupportAddress.save/2` | none | no |
| `account.password_link` | `Apiary.Accounts.build_password_link/3` | none | yes, for a person |
| `instance.read_factory` | the reads of the instance's adapters, pool and gateway, with their keys and codes, and Instance settings › Machine types | `factory` | no |
| `adapter.create` | `Apiary.Adapters.create_adapter/2` | `factory` | yes |
| `adapter.edit` | `Apiary.Adapters.rename_adapter/3` | `factory` | no |
| `adapter.set_interval` | `Apiary.Adapters.update_sync_interval/3` | `factory` | no |
| `adapter.delete` | `Apiary.Adapters.delete_adapter/2` | `factory` | no |
| `adapter.setup` | `Apiary.Adapters.setup/2`, and the changes to an adapter's keys and codes in `Apiary.AccessKeys` | `factory` | only to make an enrolment code |
| `node.set_instance_limit` | `Apiary.Nodes.Installed.set_instance_limit/3` | `factory` | no |
| `harness.assigned` | `Apiary.Harnesses.assign/3` | `factory` | yes |
| `harness.unassigned` | `Apiary.Harnesses.unassign/2` | `factory` | yes |
| `instance.read_observability` | the reads of the instance's diagnostics keys | `observability` | no |
| `diagnostics_key.create` | `Apiary.AccessKeys.create_diagnostics_code/2` | `observability` | yes |
| `diagnostics_key.revoke` | `Apiary.AccessKeys.revoke_diagnostics_key/2` | `observability` | no |
| `workspace_type.edit` | `Apiary.Processes.TypeTemplates.save/4` | `workflow_model` | no |
| `machine_type.rekey` | `Apiary.MachineTypes.update/3`, for a key change, after `instance.configure` | `workflow_model` | yes, through `instance.configure` |

`instance.read`, `instance.read_factory` and `instance.read_observability` differ only by
feature, so an instance without a feature has none of that feature's pages for its
instance admins. `instance.read_machine` is one value on a run's page, which the run's
organisation reads too. `adapter.read` is a different action: every
member has it, for the adapters an organisation connects. `node.set_limit` also stays
outside this table: it is the organisation admins' action on an organisation's pool.

A machine type's key change checks `machine_type.rekey` once, in its transaction, and then
writes the new versions of the processes and workspace types that use the key, with a
`process.edit` entry in each workspace and a `workspace_type.edit` entry for each type.
With `workflow_model` off, the key changes in the machine type alone: no process or
workspace type gets a version, and the trail gets no entry for either. With
`workflow_model` off, processes and workspace types keep the old key; once the feature is
on again, their runs start on the default machine type until the key is fixed.

`Apiary.Access.check/3` takes these steps for an instance action, in place of the steps
for any other action, and returns at the first that fails:

1. **The feature**, read from the instance (`Apiary.Features.visible?/2` with no scope),
   whatever an edition hides from the person: off, `{:error, :not_found}`.
2. **The instance step.** The instance's scope (role `instance`) passes. Any other scope
   passes only in the instance's organisation, while it is not marked for deletion;
   elsewhere, `{:error, :not_found}`.
3. **The edition** (`c:Apiary.Edition.check/3`): anything but `:continue` is the result.
4. **The subject.** `account.password_link` needs an account in use, and
   `instance.mail_resend` and `instance.mail_on` need the mail settings
   (`Apiary.Mail.Settings`). Every other instance action needs the instance's organisation.
   Anything else is `{:error, :not_found}`.
5. **The role** (`Apiary.Access.role/1`): one not in the action's `roles` is
   `{:error, :forbidden}`.
6. **The one-person rules**, below.

So a person outside the instance's organisation gets `{:error, :not_found}`, and an admin
or a member inside it `{:error, :forbidden}`. A page shows not found for both.

### The instance scope

A person's page may be in any organisation. An instance action takes the person's scope in
the instance's organisation:

- A context function calls `Apiary.Access.authorize/3` with `Apiary.Access.in_instance/1` of
  the scope, and with `Apiary.Access.instance_organisation/0` as the subject, or the account
  or the mail settings for the actions on those.
- A page of Instance settings mounts on `on_mount {ApiaryWeb.Access, :instance}`, which puts
  `Apiary.Access.instance_scope/1` into `@scope`, and shows not found to anyone else. The
  page calls `Apiary.Access.can?/3` with `@scope` and `@scope.organisation`.
- Any other page or controller calls `ApiaryWeb.Access.instance_can?/2`, or
  `Apiary.Access.can?/3` with the scope from `Apiary.Access.instance_scope/1`.

A page on `:instance` computes `@scope` again when the reader's memberships change. A reader
who is no longer an instance admin moves to `/`. A page that sets
`ApiaryWeb.UserAuth.on_membership_change/2` itself computes `@scope` again itself. A write
fails as soon as the membership changes, because `Apiary.Access.authorize/3` reads the
membership again.

The scope `Apiary.Access.in_instance/1` puts in the instance organisation contains that
organisation's id, so `Apiary.Access.can?/3` reads no row for an instance action, beyond
whatever the edition's check (`c:Apiary.Edition.check/3`) reads. `Apiary.Access.reload/2`, and
so `Apiary.Access.authorize/3`, clears the id, and the check compares with the id read then. A
page on `:instance` keeps this id in `@scope` until it mounts again, or computes `@scope`
again when the reader's memberships change. These moves to another organisation clear the
id too: `Apiary.Organisations.put_reach/2`, and so `Apiary.Organisations.resolve_scope/4`;
`Apiary.Organisations.load_scope/2`; `Apiary.Organisations.load_home_scope/2`;
`Apiary.Organisations.accept_invitation/2`, on the scope in the invitation's organisation; and
`Apiary.Accounts.Scope.in_organisation/2`.

`Apiary.Access.instance_admin?/1` is true where `instance.read` passes in that scope, by the
membership as the database has it now. It is for what takes no action: a page's wording, the
set-up steps a page lists, and the core's `c:Apiary.Edition.harness_owner/1`. An edition may
call it too. The release commands call `Apiary.Access.instance_admin_membership?/1`.

### The one-person rules

These rules depend on who the person is, after the role passes:

- Only the instance admin who saved the mail settings (`mail_saved_by_id`) sends their test
  link again or turns mail on by that link. For anyone else, and where no settings row
  exists, `instance.mail_resend` and `instance.mail_on` return `{:error, :not_saver}`.
  `Apiary.Mail` makes the check with the settings row locked, and `Apiary.Mail.turn_on/2`
  returns `:error` for that result.
- Nobody makes a password link for the account they are signed in with:
  `account.password_link` returns `{:error, :own_account}`. They change their password in
  Account settings. The instance's scope has no account, so this rule does not apply to it.

The mail form and People call `Apiary.Access.can?/3` for the same rules. The audit entries
keep their actions. Other actions have rules about one person too: `member.suspend` and
`member.activate` (What an admin may not, above), `member.remove` (Leaving, below), and
`work_item.comment_delete`, which the comment's author may take while their role still has
`work_item.comment`.

### A recent sign-in

A recent sign-in is authentication, so `can?/3` and `authorize/3` do not read it. The context
function calls `Apiary.Accounts.sudo_mode?/2` after `authorize/3`, and returns
`{:error, :sudo}` when the sign-in is not recent. A page already open stays open, and a save
there leads the person to sign in again.

### Release commands and the set-up

Granting and revoking an instance admin (`instance_admin.grant`, `instance_admin.revoke`,
`Apiary.Release.grant_instance_admin/2` and `revoke_instance_admin/1`) are release
commands, taken on the strength of a shell on the release, which no role has.
A password link is a one-time link that sets an account's password. An instance admin makes
one only while the instance sends no mail: `{:error, :mail_set}` once it does. A release
command makes one mail or not (`Apiary.Release.password_link/1`), in the instance's scope,
with no recent sign-in.
Revoking the last owner who may act is refused, `{:error, :last_owner}`. The set-up of a
new instance (`Apiary.Setup`) is taken on the strength of its set-up code, which only the
instance's log shows, or, with `QORY_SETUP_CODE_SHA256` set, only the install that made the
code, likewise beyond any role, by the instance (`actor: :instance`), and acts on no
instance that has its organisation.

### The instance's organisation stays

The instance's organisation is never deleted nor purged: an instance without it is
one that is not set up, where nobody signs up, and its next start would log a new set-up
link (`Apiary.Setup`) that gives whoever opens it the instance; with
`QORY_SETUP_CODE_SHA256` set, the start logs no link, and the code that set the instance up
is refused. `Apiary.Deletion` refuses to mark or purge it,
`:instance_organisation`, the core edition's answer to
`c:Apiary.Edition.deletion_refusal/2`. An edition may also refuse `organisation.delete` on
it for every role (`c:Apiary.Edition.check/3`), which its settings page asks through
`Apiary.Access.refused_on?/2` to say why the control is not there.

## Suspending a member

A suspension pauses and removes nothing: a membership gets `suspended_at` and
`suspended_by_id` (`member.suspend`, `member.activate`,
`Apiary.Organisations.suspend_member/2` and `activate_member/2`), on the members page, and
activating empties them again. What the membership reaches, the invitations its person
sent, the history and the access keys all stay.

It is an action over people: an owner suspends and activates admins and members, an admin
members, and nobody another owner or themselves. A suspended membership counts
as none: its person acts there no more and reaches nothing there, their switcher leaves
the organisation out, and opening it says the membership is suspended rather than not
found; their organisations page lists it
(`Apiary.Organisations.list_suspended_memberships/1`). Each suspension and activation is
an audit entry in the organisation's trail, written in its transaction, which names the
person by user id; the edition hears of an activation in that transaction
(`c:Apiary.Edition.membership_changed/5`).

**Enforced in `Apiary.Access`.** `reload/2` reads the suspension of the membership with
its level, and fails closed: a scope loaded before a suspension acts on nothing after it.
Under `lock: :share` it holds the membership `FOR SHARE`, which the suspension's update of
it waits for, so a change that holds it is written before the suspension, and one asked
after it waits and then sees it. An owner of the instance's organisation whose membership
is suspended is no instance admin.

## The last owner

The last-owner rule counts only the owners who may act, whose membership is not suspended
and whose account is in use, neither deleted nor held out of use by the edition
(`Apiary.Organisations.other_active_owner?/1`): inside an organisation its last such owner
is not demoted, removed or suspended, `{:error, :last_owner}`, nor does their account's
deletion leave the organisation without them
(`Apiary.Organisations.sole_owned_organisations/2`). Nor is the instance's last admin
revoked; granting one (`Apiary.Release.grant_instance_admin/2`) is the recovery when none
may act.

## Access keys

An access key is a node's or a node pool's, with one Ed25519 public key. The keys are
owners' and admins' alone, and a member adds or revokes none: making and cancelling an
enrolment code (`access_key.create_code`, `access_key.cancel_code`), adding one made in
their browser (`access_key.add`, `arrived_by` `browser`) and
revoking one (`access_key.revoke`). Each is asked of the node, the
code or the key, and leaves its audit entry. An adapter has no organisation: a change to its
keys and codes takes `adapter.setup` (The instance's admins, above), and its audit entry
keeps the `access_key.*` action. A key is active from the moment it is made. A
machine that enrols a key with a code asks no one: the code is the authority and the
approval, as long as the person who made it may still make it, an owner or an admin of its
workspace, neither suspended nor removed, their account in use (`access_key.create_code`,
asked again of their membership as it is at the enrolment; `adapter.setup` for an adapter's
code and `diagnostics_key.create` for a diagnostics key's, in the instance's organisation);
the key's arrival is an entry
of `access_key.add` by the key itself, `arrived_by` `code`. Deleting a
node (`node.delete`, owners and admins) revokes its keys in the same transaction, each with
its entry of `access_key.revoke`. Which runs a key posts for is
`Apiary.Runs.Sender`'s: a direct run's batches, reloads, repeated registration and outcome
are taken from the active keys of the node or node pool that registered it, whichever of
them signs, so a second key keeps the run going while the first is replaced; a key of
another node of the workspace, a gateway's included, is refused, and a revoked key
verifies under no key. A run through a gateway takes its batches and reloads from the
gateway that attached it instead. Setting a pool's instance limit, as it is made or after,
is a separate action (`node.set_limit`), held by owners and admins as `node.edit` is, so
an edition may keep it from some who change the rest; its change is recorded in the
entry of the node's creation or edit. Making a pool needs `node.set_limit` too, with a
limit or without one, so one who may not set the limit makes no pool. The limit of the
instance's pool is an instance action (`node.set_instance_limit`), recorded in the same
entry. Everyone in the
workspace reads the nodes (`node.read`), and a page shows a node's keys under it.

A key acts in the role its node's kind gives it (`Apiary.Access.role/1`): a node's key and
a gateway's in `access_key`, a node pool's in `pool_key`, an adapter's in `adapter_key`, and
a key of the instance's diagnostics node in `diagnostics_key`.
`pool_key` holds `run.post_events` and `run_configuration.fetch`, as `access_key` does,
so a pool registers its runs, posts their events and their outcome and is served the run
configuration as a node is; reading the configuration document needs no role, only the
signed request (`ApiaryWeb.Contract.SignedRequest`). `pool_key` also has the
dispatch actions, `dispatch.claim`, `dispatch.dispatched`
and `dispatch.release`, of the feature `factory`.

`access_key` alone has `secret.seal` and `run_credential.issue`, both of `factory`, for a
gateway's secrets request:

- `Apiary.Runs.SecretsRequest` calls `Apiary.Access.check/3` with `secret.seal` and the run,
  for a request for one or more of the run's model keys. A key that fails gets `404`. A
  request for the registry alone takes no action.
- `Apiary.Runs.WorkCredential` calls it with `run_credential.issue` and the run, before the
  call to the adapter and again as it records the credential. A key that fails the first
  check gets `404`, with no call to the adapter and no Activity entry.

While `factory` is off and `registry` is on, a request for the registry alone gets `200`.
A request for the work entry gets that `404`, even for a run made while `factory` was on.
A request for a model key gets `409` `credentials_differ`, because no model key exists
without `factory`. The run key, the sender and `allow_secrets` stay checks of the
secrets request: they are data of the run and of the key it verified under.

`diagnostics_key` has two actions, both of the feature `observability`:

- `ApiaryWeb.Contract.DiagnosticsController` calls `Apiary.Access.check/3` with
  `run.read_diagnostics` and the run. The key is at the instance and reads the
  diagnostics of a run of any organisation and workspace.
- `ApiaryWeb.Contract.RunListController` calls it with `run.list_instance` and `%Run{}`, a
  run with no organisation and no workspace, which stands for every run of the instance,
  for `GET /v1/runs`. A key that fails gets `401`.

Any other action, or any other subject than a run, is `{:error, :not_found}`.

A
pool's key acts on its workspace and, there, on its pool: another node and the
organisation are not found to it. A dispatch action is asked of the workspace, the one
queue every pool of it claims a waiting run from, or of a dispatch of that workspace its
pool claimed; another workspace's queue, or a dispatch another pool claimed or that names
no pool, is not found to it. The instance's node pool has no workspace and no
organisation: its key acts on its pool and on the dispatches it claimed, in any
workspace, and claims from the queue of every workspace that has no node pool in use;
every other node, workspace and organisation is not found to it. A release leaves an
audit entry; a claim and the start of its machine do not.

A gateway of an organisation, which has no workspace, is asked at the organisation: its
making and listing (`node.create`, `node.read` of the organisation), its changes and
deletion, and its keys and codes, by owners and admins of the organisation. An
enrolment code's maker is read again at the organisation, without a workspace, and a key
of such a gateway is asked at its organisation (`Apiary.Accounts.Scope.key_place/1`).
Everyone in the organisation reads its gateways. While its organisation is out of use,
such a gateway keeps its keys, which are verified for the runs of other organisations it
serves (`Apiary.AccessKeys.fetch_for_verification/1`), and enrols no new one: an
enrolment code of an organisation out of use is found by none. A workspace's gateway is
held to its organisation's use as any node is.

A gateway acts for a run only while it may serve the run's workspace. This is the place
rule of a gateway's key in `Apiary.Access`: with a run as the subject, `run.post_events`,
`run_configuration.fetch`, `secret.seal` and `run_credential.issue` pass only for a workspace
at one of the gateway's levels, and otherwise return `{:error, :not_found}`. A caller that has the
gateway's row and no key calls `Apiary.Access.may_serve?/2`, which applies the same rule: a
node's choice of gateway, a claim, the registration, and each attach, batch, heartbeat and
reload (`Apiary.Runs.Sender.serves?/2`). The rule reads the ids of the place alone; a place
marked for deletion has a separate check (`Apiary.AccessKeys.place_in_use?/2`). Once a
gateway may not serve the workspace, it is refused
with nothing of the run told: no policy, no event, no outcome, no digest. Two things
stay known to such a gateway, and are accepted:

- **Whether the run is still sending, has ended, or was lost.** At the events endpoint the
  sender's check comes first: a batch from another instance of the gateway than the one
  that attached the run is `409` `wrong_gateway` while the run is still sending, and the
  `410` `workspace_not_served` once its sending has ended (its exit arrived, it was lost
  after its attach, or its events were pruned). At the attach, the run key's holder is
  answered before the serving check: an ended run is `410`; a run never attached whose
  attach window has closed, or that was already lost, is `409` `run_key_expired`; any
  other is `409` `workspace_not_served`. A run of a workspace's queue takes no outcome; an
  outcome stored on it before that rule ends it there too, and which outcome is never
  told. The gateway a run key names knows the run's id from its
  run key, before any attach; only the gateway that attached the run is answered at the
  events endpoint and the reload, any other `409` `wrong_gateway` and `404`.
- **Whether the run's place is in use.** The place's check comes before the serving
  check, as it does for every key. At the events endpoint and the attach, it is `401`
  while the run's workspace or organisation is out of use, and `404` while `Apiary.Access`
  does not let the run's workspace post (`run.post_events`); at the reload, `404` while
  the run's workspace or organisation is out of use. Only then comes the serving check's
  answer.

## Model keys

A model provider's keys are values of its secret (`Apiary.ModelKeys`), and their pages
need the features `factory` and `secrets`. Every member reads a provider's page with its
keys and their states (`connection.read`). Adding a key, changing its name, its Resets
and its Pause for, and changing or deleting it, are `provider.write`, owners' and admins',
checked at the organisation: **Add key** and **Edit key** on the provider's page
(`ApiaryWeb.ProviderLive.Key`), and **Add value**, **Change value**, **Rename value** and
**Delete value** of the provider's key on Workspace settings › Secrets and variables. For
anyone else Add key and Edit are not on the page, their paths are not found, and
`Apiary.Connections.add_provider_key/4` and `Apiary.Connections.update_provider_key/4`
check it again inside their transaction. Each change leaves the provider's
`provider_keys_changed` entry; a save of Edit key that changes nothing leaves none.

A model choice's fallbacks, on Workspace settings › Model, are saved with the choice,
under the choice's action: `model_choice.write` of the workspace or the target, owners'
and admins', of the feature `factory`.

Two requests of the run endpoint are a gateway's for a run, signed by its access key, and
each is checked under the action `run.post_events`: the model keys report, and the
transcript of a paused run:

- **The model keys report**, `POST /v1/runs/<run_id>/model-keys`, needs the features
  `factory` and `secrets`. The run must be, as for the gateway's secrets request, a run
  through that gateway, whose run key lists the key, that the key and the
  request's instance may reload, of a workspace the gateway may still serve (the place
  rule, under Access keys). Then `Apiary.Access.check/3` checks `run.post_events` on the
  run for the key (`Apiary.ModelKeys.Report`). Any other run, and a key that fails, gets
  `404`. The answer has the states of the run's keys alone, under the run's credential
  names.
- **The transcript of a paused run**, `GET /v1/runs/<run_id>/resume/transcript`, needs the
  feature `observability`. The run must be one the run API finds for the key, a run of a
  work item, still live, whose `resume` is set; and the paused run must
  be the one it continues, of the same organisation, workspace, work item and stage
  (`ApiaryWeb.Contract.TranscriptController`, `Apiary.Runs.Transcript.paused_run/1`).
  Then `Apiary.Access.check/3` checks `run.post_events` on the run for the key. Any other
  case, and a key that fails, gets `404`, so a run configuration with another run's id
  reads no other run's transcript.

## Leaving

Anyone with a membership may remove it, whatever their level: leaving the
organisation is `member.remove` of the person's membership, which the module allows beside
its role table (`Apiary.Access.own/0`). The last-owner rule still holds, so the last owner
who may act cannot leave.

## Features

The feature an action belongs to is asked first, of `Apiary.Features.visible?/2` with the
scope, and a feature that is off, or hidden from the scope's person, is
`{:error, :not_found}`: absent, as a feature the instance lacks. A feature is hidden from a person
where a feature it needs is, directly or through another: hiding `observability` hides
`security` (`Apiary.Features.hidden_of/1` adds it). An action
that belongs to a part of its feature is asked of the part, which is hidden where it or
its feature is: `run.read_log` belongs to `observability.terminal`, the run's Terminal, so
an edition that hides it hides the run's whole log from that person, the Terminal tab, the
log's address with every stream and the download, the ⋯ menu's Raw log and Download log,
the runs list's preview of the last lines and the terminal's size on Details, and the
notes on session events leave the terminal out; the rest of the run is as it is. A part may
belong to no feature, and is then hidden where it is named alone: the `node.*` and
`access_key.*` actions belong to `nodes`, so an edition that hides it hides from that
person the nodes, the node pools, their access keys and the gateways: their pages, which
answer not found and leave once open, their entries in the navigation, New and the
palette, the Overview's box for a workspace with no run yet and its link to the nodes
page, Go to nodes on the empty Runs list, and the links to a node's page from the runs
list, the run preview and the run page, which name the node without a link. The Activity
filter leaves out their actions, and their entries keep their labels. The nodes keep
working: what a node is served never asks what is hidden, and an enrolment code's maker
approves the key it brings by their role and place, whatever is hidden from them
(`Apiary.Access.check_code_maker/2`), so their codes keep working where the nodes are
hidden from them. A page of the nodes open when they are hidden leaves, and so does one
whose act is asked after they are hidden; a switch of workspace never lands on one. What a
person is not shown in an organisation is the edition's answer
(`c:Apiary.Edition.hidden/1`), the one answer ([architecture.md](architecture.md),
Features): in the core, nothing. A person's scope carries it (`hidden`):
`Apiary.Organisations.resolve_scope/4` loads it with the organisation and the workspace,
and `reload/2` asks it again after the edition's reload, under the edition's locks, so
what an edition changes of it under the organisation's lock is waited for, or seen. An
access key, and its scope, and the instance answer as the instance: `run.post_events` and
`run_configuration.fetch` follow the instance's features alone. An instance action reads its
feature from the instance for every scope (The instance's admins, above).

## Who asks

A **scope** is who asks: a person with the membership in the organisation the page's path
names, the workspace it names and what the edition says of their place there, an access
key at the server contract, or **the instance**, in a job no person enqueued
(`Apiary.Accounts.Scope.for_instance/2`, which `Apiary.Job` gives such a job). The
instance has a separate role in the role table, with only what its jobs need: pruning
the audit trail, deleting the invitations expired for 30 days, purging a workspace or
an organisation whose deletion's grace period is over, and making the adapters its
setting lists and giving them their one-time codes (`adapter.install`,
`Apiary.Adapters.install/2`, `Apiary.AccessKeys.issue_installed_code/2`), and the same
for the node pool and the gateway its settings declare (`node.install`,
`Apiary.Nodes.Installed.install/2`), in the instance's organisation. A release command
that makes a password link acts in that role too (`account.password_link`). Any other scope
without a person may nothing, whatever it carries.

An action taken on the strength of something other than a role, signing up, accepting an
invitation with its token, or a release command run on the release's machine, is in the
action list too, so the audit trail can name it: the context function checks the sign-up
or the token, and asks nothing; whoever runs a release command controls the instance
already. No role of the core has these. A sign-up's `organisation.create` is one: the
account it creates does not exist until it commits; an edition may give the action to a
role it adds, for an organisation created another way. Deleting one's account is
no action at all: an account belongs to no organisation, and the account page asks for a
recent sign-in instead.

The subject is what is acted on, with one exception: deleting a workspace and cancelling
its deletion are asked of the organisation, from its settings, where an owner or an admin
deletes any workspace of it; the scope's workspace is whichever the page opened.

## Marked for deletion

A workspace or an organisation marked for deletion (`Apiary.Deletion`) answers not found
to every action, as one that is gone would, but cancelling the deletion
(`organisation.restore`, `workspace.restore`) and the purge (`organisation.purge`,
`workspace.purge`), `Apiary.Access.on_marked/0`. It is read with the membership: the
marks of the scope's organisation and workspace are read again by `authorize/3`, locked
with the membership under `lock: :share`, so a page opened before the marking acts on
nothing after it, and the purge waits for a change that asked first. A subject that is a
marked organisation or workspace answers the same. A job refused so is cancelled.

The edition may refuse a deletion or a purge (`c:Apiary.Edition.deletion_refusal/2`),
asked on the row locked for it after the core's refusals, and is told of each
marking, cancelling and purge inside the transaction that makes it
(`c:Apiary.Edition.deletion_changed/4`).

## The context function asks before it acts

Every context function that changes something calls `Apiary.Access.authorize/3` with its
action and the subject first, and returns the result. A function that makes more than one
check in one change, or that reads under locks, calls `Apiary.Access.reload/2` once and then
`Apiary.Access.check/3` for each check, inside its transaction. The result is `:ok` or one of:

- `{:error, :not_found}` for a feature that is off or hidden, a subject of another
  organisation or workspace, a subject of a workspace the person does not reach, and what
  the edition answers so (`c:Apiary.Edition.check/3`);
- `{:error, :forbidden}` for a role that does not allow the action, or allows it over
  other people than the subject's, and what the edition refuses so;
- `{:error, :not_approver}` where the role allows the action and the stage the work item
  is in lists approvers the person is not among;
- `{:error, :not_saver}` and `{:error, :own_account}` for an instance action (The
  one-person rules, above).

A read that a role could one day be kept from has an action too.
`Apiary.Organisations.list_members/1` calls `can?/3` with `member.read`, from the scope as
loaded, because every page's counts read the list, and returns `[]` when the result is no.

The last step, after the role, is the stage's approvers. It applies to approving a
stage's gate (`gate.approve`), approving Explore's proposal (`work_item.confirm`) and
the comments on a stage's outputs or round (`work_item.review_comment`), asked of a
work item.
`Apiary.Stages.check_workflows/3` takes `gate.approve` before it reads the harness, so a
person the stage does not list reads nothing.
An answer, a send of the review comments, Run another round and Explore again take
`gate.approve` too where the next round they start settles an open escalation, while the
stage is escalated or waits for answers beside it, or runs a stage after Explore's again
from its gate (`Apiary.Stages.member_round/3`). The escalation then records the person
who settled it, with a `gate.approve` audit entry, `escalation_another_round`; a run again
from the gate has the entry `another_round`.
Every person the role allows may take them with the workflow model off, on a work item
the runner did not place, and at a stage that lists no approvers; an answer to the
questions (`work_item.answer`) stays every member's, except while the stage's escalation
is open: then only an approver answers its questions. Asked of a workspace, as a page asks
whether to show the gates at all, the role alone answers; asked of any other subject,
they are `{:error, :not_approver}`. To answer, Qory Apiary reads the work item's process
version, unless the work item has it loaded. An edition that answers the action
(`c:Apiary.Edition.check/3`) answers before this step, and its answer stands.

This is the check that counts. `authorize/3` reads the membership again, with what the
edition put on the scope, so a scope loaded earlier cannot act on a level that has
changed since, nor in a workspace the person reaches no more: it fails closed. A job and
a contract endpoint reach the change through the same function, so they are asked too.

A change that must stay allowed while it is written reads them locked: a write of the
security policy holds the organisation rows (`Apiary.Access.lock_places/1`), then takes
the workspace's lock, then reads the membership, what the edition reads again and the
account `FOR SHARE` (`Apiary.Access.reload/2` with `lock: :share`), so a change of the
level, a suspension, a marking, and what an edition changes under the same rows, wait for
it, and none committed before it is missed. The same function writes the change's audit
entry in the change's transaction (`Apiary.Audit`, [architecture.md](architecture.md)),
with the action it asked.

## The lock order

Every change that can wait on another takes its rows in one order, so two changes wait
for each other and never on each other at once:

1. **Organisation rows**: the organisation's row, then the organisations an edition holds
   with it (`c:Apiary.Edition.places_to_lock/1`). Every change that locks more than one
   organisation row in one transaction, in any mode, the core's and an edition's, takes
   them through `Apiary.Organisations.lock_organisations/2`, so what it holds in the end
   was taken in one statement, in the order of `Apiary.Organisations.lock_order/1`: first
   those the edition holds another organisation with, then the rest, each in the order of
   their ids, so an organisation that holds others comes before those that hold none; with
   the core's edition, in the order of their ids. In the core these are a write that must
   stay allowed and a change of people, which hold the organisation and those the edition
   holds with it `FOR SHARE` (`Apiary.Access.lock_organisations/1`: should what the
   edition names, asked again of the organisation held, name one it did not take, it lets
   go of what it took and takes the fresh set in one statement, three attempts in all),
   and an account's deletion, which holds every organisation the account is a member of,
   those it owns `FOR SHARE` and the rest `FOR KEY SHARE`
   (`Apiary.Organisations.sole_owned_organisations/2` with `lock: true`). The
   organisations an edition names besides an organisation hold none in turn,
   which makes this one order that every change agrees on. `lock_organisations/2` reads
   the order without a lock; should what `c:Apiary.Edition.places_to_lock/1` names change
   between the read and the lock, so that two changes wait on each other, the one whose
   lock Postgres refuses (`deadlock_detected`) reads the order again, which sees the
   change, as the core's transactions run at `READ COMMITTED`, and locks them once more. A
   change that takes more than one in a mode that conflicts with `FOR SHARE` takes them at
   one point, before its first write; each change of the core that locks an organisation
   row in such a mode locks that one row alone. Then the edition's rows for the change
   (`c:Apiary.Edition.lock_rows/1`), which the core's edition does not have.
2. **Workspace rows**, in the order of their ids where a change takes several, as a write
   of the policy of several workspaces at once does (`Apiary.Policy.lock_workspaces/2`),
   and as a change of the level an edition keeps above the workspaces' policies does
   (`c:Apiary.Edition.above_workspace/1`): it takes every workspace of the organisation,
   then renders each again (`Apiary.Policy.rerender_in/3`). A write to an integration
   takes them later, in step 5.
3. **Memberships**: the owners' of the organisation, in the order of their ids
   (`Apiary.Organisations.lock_owners/1`), then any other.
4. **Accounts.**
5. **Everything else**: the organisation's integrations lock, a transaction-level advisory
   lock that every write to its runtimes, integrations and services takes
   (`Apiary.Connections.lock/1`), then the rows it changes; invitations, access keys,
   nodes, then runs. A write to an integration other than a model provider takes the
   integrations lock and the connection's row `FOR UPDATE`, then every workspace row of
   the organisation `FOR NO KEY UPDATE`, in the order of their ids, before it writes, and
   then renders again the policy of each workspace the integration reached before the
   write or reaches after it (`Apiary.Policy.rerender_in/3`). Adding a model provider for
   one workspace takes the integrations lock, then that workspace's row
   `FOR NO KEY UPDATE`, before it writes the workspace's secret of the provider's keys
   (`Apiary.Secrets.create_provider_keys/3`). Those two writes are the changes that take
   workspace rows after the integrations lock. No change that holds a workspace row takes
   the integrations lock or locks the row of an integration other than a model provider,
   so the two never wait on each other. A save of a deny rule reads the integrations'
   hosts while it holds its workspace's row, with no lock of theirs
   (`Apiary.Policy.check_deny/3`): a write to an integration holds every workspace row
   before it writes, so the save reads that write whole or not at all. It reads the hosts
   of the model providers' API endpoints the same way. A change to an existing model
   provider takes no workspace row, so a save at the same moment may read the provider as
   it was before the change; the document composed for a run has the provider's hosts in
   `allow_first` either way (`Apiary.Policy.ComposedConfiguration`). A write of a model
   choice at levels 2 to 5 holds the workspace row and then takes a provider's row
   `FOR SHARE`. A change to a model provider takes the integrations lock, then the
   provider's row `FOR UPDATE`. To change or delete the provider's keys, it then takes,
   for keys kept as the organisation's secret, the organisation's advisory lock for its
   secrets, and the row of the keys' secret `FOR UPDATE`, of the organisation or of a
   workspace, with no workspace row; to choose the default key, that row `FOR SHARE`. It
   reads what uses the keys without a lock (`Apiary.Secrets.Usage`).
   A write of a model choice (`Apiary.ModelChoices`) at levels 2 to 5 takes the security
   policy's order, then the provider's row `FOR SHARE`, then the rows of the fallbacks'
   providers `FOR SHARE`, then the choice's row `FOR UPDATE`. A write of the
   organisation's default takes the organisation's rows and the membership, then the
   integrations lock, then the provider's row `FOR SHARE` and the choice's row. A change
   to a provider takes the provider's row `FOR UPDATE`, so it waits for a save of a choice
   of that provider, or is seen by it: the change reads the choices that use the provider
   without a lock, and refuses while one does. No change to a provider takes a lock on an
   adapter's connection.
   A write of a time limit (`Apiary.TimeLimits`) takes the security policy's order, then
   the limit's row `FOR UPDATE`.
   The claim of an explore run (`Apiary.Dispatches.RunSettings`) holds the pool's row, the
   gateway's row, the environment records, the run of the queue and its dispatch
   (`Apiary.Dispatches.Slots`), then reads the choices and their fallbacks without a lock,
   then takes the rows of the providers they name, as a provider or a fallback,
   `FOR SHARE`, by id, then the rows of those providers' keys' secrets `FOR SHARE`, by id.
   It reads the keys' settings and states without a lock. A change to a provider or to its
   keys locks nothing of the queue while it runs; once it has committed, a change of a
   model provider or of a model choice writes the model providers of the queue's waiting
   runs again, one run at a time: it takes the run's row `FOR UPDATE`, then reads the
   run's model choice, writes only a row that still waits, and lets a row it leaves as it
   is go at once (`Apiary.Dispatches.refresh_model_providers/1`). A change that came first
   is seen by the claim; one that comes after waits for the claim to commit. A deletion of
   the provider then reads the run the claim registered, and refuses while that run is
   pending or running.
   A gateway's secrets request for a run's model keys reads the run, the provider's row
   and the row of its keys' secret without a lock, checks the provider's integrity code,
   and decrypts each key in the request, whose row is bound to its secret, with the time
   its value was set. Then, in one transaction, for each key by id, it takes the run's row
   and the key's row in `secret_values` `FOR KEY SHARE`, then writes the key's row in
   `model_key_copies`, then the audit entry `secret.seal`: a key or a run deleted
   meanwhile is left out of the copies. A request for the model keys alone ends there. A
   request that also lists the work entry then, in the same transaction, writes the apply
   items on the entry's row in `run_credentials`, and last the Activity entry
   `run_credential.issue`. A run's deletion locks the run's row, then its rows in
   `model_key_copies` and `run_credentials`, so both take the run's row first and cannot
   deadlock. A request for the work entry alone takes no lock on the run's row. A
   deletion of a secret, as when a provider is deleted with its keys, locks the rows of
   its values `FOR UPDATE` by id before it deletes the secret, as the delete's cascade
   would take them in an order the statement does not fix. So the deletion and a secrets
   request take the keys' rows in the same order, and cannot deadlock.
   A model keys report reads the run's copies without a lock, then takes the rows of its
   keys in `secret_values` `FOR SHARE`, by id, then the locks of their state rows in one
   order, so two reports of the same keys at once cannot deadlock, a key deleted before
   the report writes is left out of it, and a new value of a key, which updates its row
   and then deletes its state rows, waits for the report or comes before it: the report
   then leaves out a key whose value is not the one the run has, a `value_set_at` other
   than the run's copy.
   A provider's deletion is refused while a pending or running run uses it, so the run's
   provider columns are empty only on a run that ended, and the request for such a run is
   refused.

An edition takes all its rows for a change at one point, `c:Apiary.Edition.lock_rows/1`,
before the change's first write, in its fixed order and in the strongest mode the
change needs, and none later in that change; otherwise two changes can wait on each other.
The rule is the change's, not a callback's: a change that spans several organisations, as
an account's deletion does, takes its whole set at its one point. The edition never locks a
membership or any other row of the core's there. What it reads or writes of its rows later
in the change (`c:Apiary.Edition.reload/2`, `c:Apiary.Edition.level_refusal/4`,
`c:Apiary.Edition.membership_changed/5`, `c:Apiary.Edition.accepted/4`) it holds from
then, and locks nothing more. The core asks it:

- `{:places, scope}` at the end of `Apiary.Access.lock_places/1`, before any workspace,
  membership or account, in every write that must stay allowed. The rows it takes for a
  scope must not depend on the scope's workspace: a write may ask it more than once in
  one change, with the same organisation, as the security policy's writes do, before and
  after their workspaces' rows and writes and once for each workspace of a request;
- `{:people, scope, organisation}` once the organisation rows are held, before the
  owners' memberships (`Apiary.Organisations.lock_people/1`, which `lock_owners/1` calls,
  and which asks no `{:places, scope}`): a change of level, a removal or leaving, a
  suspension, an activation, and the release commands that grant and revoke an instance
  admin; and once an invitation's organisation is held, in its acceptance and in a
  sign-up with it, `scope` nil for the sign-up. There the edition takes, all at once in
  its fixed order, every row it would take at `{:places, scope}` for that scope, in at
  least the same mode, and its rows of the organisation's people;
- `{:account, user_id, organisation_ids}` in an account's deletion, once every
  organisation the account is a member of is held, in one pass in the order above, those
  it owns `FOR SHARE` and the rest `FOR KEY SHARE`, and before their owners and the
  person's memberships: `organisation_ids` are the organisations held, and the edition
  takes rows of those organisations only, none of one the account joins after they were
  read.

A repeat of `{:places, scope}` later in the same change, after its point, must take no new
row and no stronger mode: the edition answers it with rows it holds already, in the mode
it holds them.

The modes keep a row that only names another out of it:

- A write that must stay allowed while it is written holds the organisation `FOR SHARE`,
  and the organisations the edition holds with it (`Apiary.Access.lock_places/1`), and the
  edition's rows for it, the workspace `FOR KEY SHARE`, the membership `FOR SHARE`, what
  the edition reads again under the rows it holds (`c:Apiary.Edition.reload/2`), then the
  account `FOR SHARE` (`reload/2` with `lock: :share`). A change that may make an owner,
  or counts the owners who remain, as a change of a level, a removal and a suspension do,
  holds the organisation rows `FOR SHARE` too (`Apiary.Access.lock_organisations/1`), and
  the edition's rows for a change of people, then locks the organisation's owners'
  memberships `FOR UPDATE` (`Apiary.Organisations.lock_owners/1`).
- A change of a node's access keys or enrolment codes (`Apiary.AccessKeys`) locks the
  node's row `FOR UPDATE`, then the key's or the code's: the keys of one node take turns,
  so the limit of two keys at a time counts every change before it. An enrolment
  (`Apiary.AccessKeys.enrol/2`) first reads the membership of the code's maker again with
  `reload/2` and `lock: :share`, the organisation, workspace, membership and account rows
  before the node's, so a change of the maker's level, a suspension or a removal waits for
  it, or came first and refuses the code. Deleting a node (`Apiary.Nodes.delete_node/2`)
  holds the same row, and revokes its keys under it.
- A change of the gateways, of their default marks or of a node's or a pool's choice of
  gateway (`Apiary.Gateways.lock/1`) takes its organisation rows first, at one point,
  through `Apiary.Organisations.lock_organisations/2`. A change at a workspace holds its
  organisation and the organisations whose organisation-level gateways may serve it
  (`c:Apiary.Edition.serving_organisations/1`) `FOR SHARE`, then the workspace's row
  `FOR NO KEY UPDATE`. A change of an organisation-level gateway holds its organisation
  `FOR NO KEY UPDATE` and the organisations whose workspaces it may serve
  (`c:Apiary.Edition.served_organisations/1`) `FOR SHARE`. So a change at an organisation
  takes turns with every change at a workspace it may serve. Then the node's row
  `FOR UPDATE`. A deletion holds the gateway's row `FOR UPDATE` while it reads the runs
  that hold it, and a registration through the gateway and an attach by it read that row
  `FOR SHARE`. The seams read and lock nothing, and are read once, not again under the
  lock: an edition's change of the relation they answer takes a row these writes take
  too, in a mode that conflicts with theirs.
- A write of the security policy holds the organisation
  `FOR SHARE` (`Apiary.Access.lock_places/1`),
  then locks its workspace's row `FOR NO KEY UPDATE`, then reads the membership again
  under `FOR SHARE` (`reload/2` with `lock: :share`): writes to one workspace take turns.
- A write of an organisation's stored secrets, those without a workspace
  (`Apiary.Secrets`), holds the organisation `FOR SHARE` (`Apiary.Access.lock_places/1`),
  reads the membership again under `FOR SHARE` (`reload/2` with `lock: :share`), asks
  the edition (`c:Apiary.Edition.organisation_secrets/2`, Callbacks beside
  `Apiary.Access`, above), then takes the organisation's
  advisory transaction lock for its secrets (`pg_advisory_xact_lock`), which locks no row
  and which only these writes take, after every row lock above; then a change to a
  secret locks the secret's row `FOR UPDATE`. The writes of one organisation's secrets
  take turns, and its first secret makes its data key alone. A write of a workspace's
  stored secrets takes the security policy's order above, then the secret's row.
- A marking for deletion locks the organisation's row `FOR NO KEY UPDATE`, and a
  workspace's marking locks every workspace of the organisation in use: they wait for a
  write in flight, and one asked after them waits and then sees them. What an edition
  keeps of an organisation or an account is written under that row's lock too, and read
  by a change that holds the row in a statement after its lock: the `organisations` and
  `users` rows stay the ones to lock.
- An invitation locks the row of the organisation whose allowance it counts against
  `FOR NO KEY UPDATE` while it is counted and written: the invitation's organisation
  for `member.invite`, or the one an edition's invitation names
  (`Apiary.Organisations.insert_invitation/3`). A new link for a pending invitation
  (`Apiary.Organisations.renew_invitation/4`) reads the invitation without a lock to find
  the allowance it was counted against (`Apiary.Organisations.allowance_of/1`, which an
  edition asks for the row it will lock), locks that allowance's row the same way, then
  the invitation's `FOR UPDATE`; never the invitation's first. An edition's renewal
  (`action:`) runs inside the edition's transaction, which may hold the allowance's row already.
- A level given, by a change of level, an invitation, its acceptance or a release
  command, is asked of the edition (`c:Apiary.Edition.level_refusal/4`, `lock: :share`)
  before the membership is written, once the edition's rows are held, for all but the
  invitation, which writes no membership and holds none of them. It reads, and locks
  nothing.
- An invitation's acceptance, and a sign-up with an invitation, let the edition hold the
  organisation first, more strongly if it will (`c:Apiary.Edition.accepting/3`), then hold
  it `FOR SHARE`, then the edition's rows for a change of its people, before the account
  and the invitation, so the organisation's marking, and what the edition holds out of
  use, wait for it, or came first and refuse it.
- An account's deletion holds every organisation it is a member of, those it owns
  `FOR SHARE` and the rest `FOR KEY SHARE`, then the edition's rows for the deletion, and
  locks the owners of those it owns (`sole_owned_organisations/2` with `lock: true`),
  then its memberships
  (`Apiary.Organisations.lock_memberships/1`), then the account `FOR NO KEY UPDATE`. An
  invitation's acceptance holds the account `FOR SHARE`, so of the two one waits for the
  other, and a deleted account never becomes a member.
- A row inserted that names an organisation or an account, an audit entry among them,
  takes `FOR KEY SHARE` of it through its foreign key, whenever it is written: that
  conflicts only with `FOR UPDATE`, which nothing takes of an organisation or an account
  but a change of a key: the purge's deletion of the row, an account's tombstone, and a
  change an edition locks so, first and alone.

- A node's instance limit is checked under the node's row, `FOR UPDATE`
  (`Apiary.Nodes.check_instance_limit/3`), before the registration that would create a
  run inserts the run's row: two starts for a node's last slot take turns, and the second
  counts the first's run and is refused. Clearing an instance (`node.clear_instance`)
  locks the node's row the same way before it marks the instance's runs lost, so a
  clearing and a start take turns too. Nothing locks a run and then its node. A node's
  changes (`node.*`) are owners' and admins' and ask `authorize/3` without holding the
  organisation, as a rename does.

A workspace's deletion locks the organisation's workspaces without the organisation's
row first, and then takes no organisation row `FOR UPDATE`. An account's deletion holds
every organisation it is a member of before anything below them, as above.

A change that asks `authorize/3` without holding the organisation, such as a rename or an
access key, reads the membership and the suspension without a lock, and can commit just
after a suspension, a demotion or a marking that began after its answer. Only the writes
that must stay allowed while they are written, the policy's and the ones above, hold the
organisation.

The races are tested outside the sandbox, on connections that commit
(`test/apiary/access_races_test.exs`, `deletion_races_test.exs`,
`sign_up_races_test.exs`, `suspension_races_test.exs`, `nodes_races_test.exs`,
`model_choices_races_test.exs`).

## The page asks the same question

- A page shows a button, a link or a tab by `Apiary.Access.can?/3` with the same action as
  the function behind it, so the two cannot disagree. `can?/3` uses the scope as loaded, so
  a page may call it on every render. It reads the database in two cases, beyond whatever the
  edition's check (`c:Apiary.Edition.check/3`) reads: for the stage's approvers, a work item's
  process version when the work item does not have it loaded; for an instance action in a
  scope without the id (`instance_organisation_id`, which `Apiary.Access.in_instance/1` sets
  on a scope it puts in the instance organisation), the instance organisation's id, at most
  once per call, and not when the action's feature is off.
- A page that reads asks its read action on mount, `on_mount {ApiaryWeb.Access, action}`,
  after the path scope and the feature gate, and answers not found when refused.
- A page of Instance settings mounts on `on_mount {ApiaryWeb.Access, :instance}`, and any
  other page or controller calls `ApiaryWeb.Access.instance_can?/2` for an instance action
  (The instance scope, above).
- A work item's permanent address, `/work-items/wi_…`
  (`ApiaryWeb.WorkItemRedirectController`), runs the checks of the work item's page before
  it redirects there: the path scope of the workspace the work item is in at that moment,
  and `work_item.read` (`Apiary.WorkItems.locate/2`). A person who fails them gets the
  plain `404` of an unknown or malformed id. Every id takes the same reads in the same
  order: the person's scope in each workspace they reach, then one read of the work item
  among those workspaces; `Apiary.Access.can?/3` then checks that scope, with no read.
  So the response time does not show whether the work item exists either. A suspended member gets that `404`
  too, where the page sends them to `/users/organisations`, so the address does not show
  which organisation the work item is in.

## Who may do what: operators, clients and the instance

The code under `lib/apiary_pro` and `lib/apiary_pro_web` is the edition that the
configuration names (`Apiary.Edition`, `ApiaryWeb.Edition`). In this section, the core
means the rest of the code, and the sections before this one are the core's.

What the edition adds to the core's rules: the roles `reader` and `person`;
reach into an organisation through its operator and as an instance admin; a member's
access to the workspaces they were added to; an operator's actions over its clients;
gateways at the organisation level; an operator's policy requests; the instance
organisation and the instance actions; the suspension of accounts and organisations;
features below the instance; a person's new organisation; the organisation's policy, its
variables and its secrets; and the lock order as the edition takes it. Everything the
core's sections say holds here, and the sections below say what the edition adds to it or
narrows. The edition answers what `Apiary.Access` asks of it through
`ApiaryPro.Access` (its actions, its roles and its part of the answer, `check/3`) and
`ApiaryPro.Reach` (reach, workspace access and the rows a write holds). How the edition is
laid out is in [architecture.md](architecture.md).

### One way to check access

The edition checks access through `Apiary.Access`, as the core does. A page calls
`Apiary.Access.can?/3`; where it needs the reason, it calls `Apiary.Access.check/3` (The
arbiter, below). A context function calls `Apiary.Access.authorize/3`, or
`Apiary.Access.check/3` after `Apiary.Access.reload/2`. `ApiaryPro.Access` is the edition's
part of that check (`c:Apiary.Edition.check/3`).

The core's sections of this file list what stays outside `Apiary.Access`: authentication,
data rules, the last-owner rule, wording and lists on a page, feature gates, and the 4
callbacks below. The edition adds one more: the **operator parts**, its code for an
operator and its clients, also check beside `Apiary.Access`. `ApiaryPro.Operators`
compares a client's operator with the operator that acts, `ApiaryPro.PolicyRequests` reads
a feature, and `ApiaryProWeb.ClientLive.Index` reads the flag
`ApiaryPro.Flags.operator_infrastructure?/0`. While the flag is on, the pages of a
client's first owner's invitation and of a drop are not found; while it is off, the page
of the first admin's invitation is not found.

#### The 4 callbacks beside `Apiary.Access`

Four callbacks of `Apiary.Edition` affect access outside `Apiary.Access`. Each entry here
states what the callback is and why it stays.

- `c:Apiary.Edition.organisation_secrets/2` is whether the scope's person reads, changes or
  links the organisation's secrets, and, with no scope, whether they are sealed
  (`ApiaryPro.OrganisationSecrets.may/2`). Reading, changing and linking call
  `Apiary.Access.check/3` alone. It stays because sealing has no person to check: the
  result comes from the instance's feature alone (The organisation's secrets, below).
- `c:Apiary.Edition.operator_chain_writer?/1` is whether the person writes the chain of
  model providers an operator keeps for its clients. While `operator_infrastructure` is on,
  `ApiaryPro.Edition` returns true for an owner or an admin of an operator through their
  membership there, and reads that level by hand. The core's `Apiary.Connections` and
  `Apiary.ModelChoices` call it beside `provider.write`. It stays for the operator-managed
  organisation model, until operator-managed workspaces replace that model.
- `c:Apiary.Edition.harness_owner/1` is the organisation that owns a harness document the
  person saves: an id, not a yes or no. While `operator_infrastructure` is on,
  `ApiaryPro.Edition` returns the operator for a person of the operator who saves in its
  client. It returns the core's result for everyone else. It stays because it returns an
  id, and `Apiary.Access` returns only a yes or a reason. Its operator branch serves the
  same operator-managed organisation model.
- `c:Apiary.Edition.scope_setting?/1` is whether a form shows the setting that makes what
  it adds available to every workspace. It stays because `ApiaryPro.Edition` returns true
  for everyone, so it stops no action.

### Its actions and rows

The edition's actions are in `ApiaryPro.Access`, the edition's `actions/0`, each an
`Apiary.Access.Action` as the core's are, and join the core's in one registry. Its rows
of the access test are `ApiaryPro.AccessRows` (`test/support/access_rows.ex`), which
`test/apiary_pro/access_test.exs` passes to `Apiary.AccessCase` with
`ApiaryPro.CoreAccessRows`, the core's `Apiary.AccessRows` without `:instance_admin` on
`organisation.delete`. `Apiary.AccessCase` checks that every action, the core's among
them, has a row. `Apiary.AccessCase.answering/1` reads the edition's rows from
`ApiaryPro.EditionKit`, beside the core's. These files test the edition's rules of the
answer; the list is not complete:

- `test/apiary_pro/access_test.exs`: reach, suspension, the marks for deletion, workspace
  access, an operator's actions over its clients, the instance step, the instance actions
  on the instance organisation itself, the recipient of an offer of ownership, the actions
  a flag hides and the creation of an organisation;
- `test/apiary_pro/instance_organisation_test.exs`: an instance admin changes nothing in
  an organisation they read;
- `test/apiary_pro/instance_admin_test.exs` and `test/apiary_pro/transfers_test.exs`: the
  instance organisation is never deleted, purged or transferred;
- `test/apiary_pro/suspensions_test.exs`: an instance admin suspends neither the account
  they are signed in with nor the instance organisation;
- `test/apiary_pro_web/live/transfers_flag_test.exs`: the actions that are not found while
  `ApiaryPro.Flags.transfers?/0` is off;
- `test/apiary_pro_web/live/operator_infrastructure_flag_test.exs` and
  `test/apiary_pro/model_chain_test.exs`: the first admin's invitation and the choice of
  model providers, not found while the operator does not own its clients;
- `test/apiary_pro/operator_as_owner_access_test.exs`: the rules while the operator owns
  its clients.

The edition's roles, beside the core's levels, the access key and the instance:

- **`reader`**: a person who reaches an organisation with no membership there, through
  its operator or as an instance admin (Reach, below). It holds every read, `member.read`,
  `run.read`, `run.read_log`, `security_policy.read`, `secret.read`, `variable.read`,
  `connection.read`, `audit.read`, `node.read`, `client.read`,
  `organisation_policy.read`, `organisation_variable.read` and
  `organisation_secret.read`.
- **`person`**: anyone signed in, whose account is neither deleted nor suspended, in any
  organisation or none: it holds `organisation.create`, for a kind of organisation the
  instance opens (A person's action, asked of no place, below).

The edition's actions are held by the core's levels too, as each one's `roles` say.

### Levels, and the workspaces a person reaches

The level is the organisation's, as in the core, and the rule that an organisation keeps
an owner counts the organisation's owners who may act (Suspension, below). A client of an
operator is no exception: its owners, admins and members are the people with a membership
in the client, as in any organisation (Reach, below).

In the edition an owner and an admin reach every workspace of the organisation, and a
member reaches the workspaces they were added to, and no other. Which workspaces a member
reaches is **workspace access**, a separate table (`ApiaryPro.WorkspaceAccess.Row`): one
row per person and workspace, workspace data, which goes with its workspace. An owner and
an admin need no row. `ApiaryPro.Reach.every_workspace_levels/0` answers owner and admin,
the edition's `every_workspace_levels/0`, which `Apiary.Access.reaches_every_workspace?/1`
asks; the scope carries the member's row for its workspace in its `edition` map, under
`:workspace_access` (`ApiaryPro.WorkspaceAccess.of/1`), which
`ApiaryPro.Reach.reaches_workspace?/3` answers from. An invitation is sent from a
workspace and grants it (`ApiaryPro.Invitations`); an owner or an admin adds a member to
another workspace and removes them from one (`workspace_access.add`,
`workspace_access.remove`, `ApiaryPro.WorkspaceAccess`), each an audit entry.

Opening a workspace needs both: the membership, and for a member the row. The path scope
(`Apiary.Organisations.resolve_scope/4`) answers a workspace a member does not reach as
not found, as it answers one that does not exist, and `Apiary.Access` asks it again for
every question about a workspace's subject. A member who reaches no workspace signs in to
the organisation and is told so at the organisation's address, `/:org`.

### What an admin may not

Beside the core's exceptions, and the instance actions of the instance organisation's
owners, these are an owner's alone:

- in an operator, dropping a client (`client.drop`; A client's drop, below);
- the features of its clients, in an operator (`client.grant_features`; Features,
  below);
- the organisation's policy: its rules (`organisation_policy.edit`), the floor
  (`organisation_policy.set_floor`) and the switch (`organisation_policy.set_switch`),
  which an admin reads (The organisation's policy, below).

Adding a member to a workspace and removing them from one are actions over people, as
the core's are (`Apiary.Access.acts_on?/2`): an owner takes them on anyone, an admin on a
member. An invitation grants the workspace it was sent from, none for one sent to an
organisation that had no workspace, and makes a member, whatever the organisation's
state, with one exception: an operator's invitation of its client's first owner, which
is marked so (its row of `operator_invitations`), and whose person joins as the owner
(An operator's actions, below).

### Reach: a membership, an operator, the instance

A person reaches an organisation in one of three ways. `Apiary.Access.reach/1` names
which, and the scope carries it (`Apiary.Accounts.Scope`, its `reach`;
`ApiaryPro.Reach`):

1. **Their membership there**, at its level, as in the core: what they may change there
   is that level's.
2. **Their membership in its operator**, when the organisation is a client of one (its
   tenant's `operator_id`, [architecture.md](architecture.md), Operators and clients;
   `{:operator, membership}` in the scope). An operator provides a harness, its agents,
   skills, workflows and integrations, that its clients run on Qory Apiary, and keeps it
   working. Every person of the operator, owner, admin or member, reads everything in
   each of its clients, in every workspace: the runs, their terminals, the policy, the
   trail in its audit log, and its members. They change nothing there, the policy
   included, for which the operator sends a request the client answers (Policy requests,
   below): the role `reader`. Their level in the operator counts only inside the
   operator. A person of the operator who also holds a membership in the client changes
   what that membership allows, in the workspaces it reaches, and reads every workspace
   besides.
3. **As an instance admin**, an owner of the instance organisation, in an organisation
   they reach neither way (`:instance` in the scope): the role `reader` too. They read
   every other organisation, an operator or another operator's client included, and change
   one only by the instance actions (below). The instance organisation's admins and
   members reach the instance organisation, at their level, and, once it is an operator,
   read the instance organisation's clients as any operator's people read theirs, and
   nothing beyond.

`Apiary.Access.level/1` is the level of a membership there, and nil for a reader, who
holds none; `Apiary.Access.reader/1` says how a person without a membership there reads
it, `:operator` or `:instance`, or nil, and the edition's pages say so to them
(`ApiaryProWeb.Readers`). The path scope (`Apiary.Organisations.resolve_scope/4`) opens a
client for the operator's people and any organisation for an instance admin, with no
membership there; the organisation menu lists the clients a person reads through their operator
(`Apiary.Organisations.list_places/1`, `ApiaryPro.Places`, each an
`ApiaryPro.ClientReach`), under a heading of the operator's name
(`ApiaryProWeb.Edition.place_group/1`); the instance admins open another organisation from the instance
page.

`can?/3` answers from the reach the scope carries. `authorize/3` reads each source again
(`ApiaryPro.Reach.reload/2`): the membership there, the membership in the operator, and,
with neither, whether the person is an instance admin; a person removed from the
operator reads its clients no more, and neither do the operator's people once a client
has been dropped (A client's drop, below). A suspended membership, a suspended
account and a suspended operator are no source of reach (Suspension, below). A write that
must stay allowed while it is written, the security policy's, holds the client and its
operator `FOR SHARE` (`Apiary.Access.lock_places/1`, with the edition's
`ApiaryPro.Reach.places_to_lock/1`) and reads the membership there `FOR SHARE`
(`reload/2` with `lock: :share`), in the lock order below. The membership in the operator
it reads without a lock: it gives only reads, which no change holds.

A client owns its people as any organisation does: its owners, admins and members, its
invitations, its settings and its security policy. Its owners and admins invite and
manage its people, the last-owner rule holds there as anywhere, and its policy belongs
to the client: the operator's people read it and do not change it.

### An operator's actions

An organisation of the kind `operator` has clients. Its actions over them are asked in
the operator, and are not found in an organisation of another kind; they belong to the
feature `managed_organisations`:

- `client.read`: its Clients page, which lists them with their status, their owners and
  since when each is its client; its people at every level.
- `client.create`: a new client, on the Clients page, with its name, no workspace and the
  email address of its first owner, whom it invites to the organisation; an owner's or an
  admin's of the operator.
- `client.invite_owner`: the invitation of a client's first owner, sent to the
  organisation alone while the client has no workspace, and to its first workspace once
  it has one; an owner's or an admin's of the operator. Creating a client sends it, and
  while the client has no owner the Clients page sends one again
  (`ApiaryPro.Operators.invite_owner/4`): emailed with mail, and without it
  (`Apiary.Mail.configured?/0`) kept, its link shown once on the page for the operator's
  person to copy and send themselves. It counts against the operator's allowance of
  invitations, not the client's, emailed or copied, so creating clients does not multiply
  what an operator may invite. The invitation is marked as the operator's (a row of `operator_invitations`,
  written with it), and its person joins as the client's owner. It stands only while the
  client has no owner and is still that operator's client: accepted after, it is refused
  as an expired one is. When the first owner joins, the operator's other pending
  invitations of an owner there are deleted in the same transaction, each an
  `invitation.revoke`, the reason `owner_joined` (`ApiaryPro.Invitations`). From then on
  the client's owners and admins invite and manage its people, as anywhere. The person who
  accepts opens the client's overview, `/:org`, where the kind cards create its first
  workspace; a client's admins create it as its owners do, with `operator_infrastructure`
  on or off, and no line says that the operator does. The invitation's page and the
  sign-up page with `?invitation=` list Invitation alone before the person joins, while
  the client has no workspace (`ApiaryPro.SetUp`).
- `client.revoke_owner_invitation`: a pending invitation of a client's first owner
  revoked, on the Clients page, while the client has no owner; an owner's or an admin's
  of the operator. In a client with an owner, its owners and admins revoke its
  invitations, as in any organisation (`invitation.revoke`).
- `client.renew_owner_invitation`: a new link for a pending invitation of a client's
  first owner, on the Clients page, while the client has no owner and is not suspended;
  an owner's or an admin's of the operator (`ApiaryPro.Operators.renew_owner_invitation/4`,
  which passes the action to the core's `Apiary.Organisations.renew_invitation/4` as
  `action:`, so the core's `invitation.renew` is not asked). The same invitation, its row
  of `operator_invitations` kept, with a new token: the old link stops working at once,
  and the new one is shown once without mail, emailed with it. It counts against the
  operator's allowance, as the invitation did, and its entry names it. In a client with
  an owner, its owners and admins make new links for its invitations, as in any
  organisation (`invitation.renew`).
- `client.grant_features`: the features of a client, out of the operator's features, on
  its Clients page; an owner's of the operator (Features, below).
- `client.drop`: a client dropped, at once, on the Clients page; an owner's of the
  operator (A client's drop, below). A client with no owner yet is not dropped, which
  would leave nobody in it: `{:error, :no_owner}`.
- `client.delete`: a client with no owner yet marked for deletion, on the Clients page,
  its name typed to confirm (`ApiaryPro.Deletion.delete_client/3`); an owner's of the
  operator. Nobody else is in it. It is purged after the grace period, as any
  organisation, and its pending invitations are deleted at once, each an
  `invitation.revoke`, the reason `client_deleted`; the entry of `client.delete` is the
  operator's, which outlives the client's trail. A client with an owner is dropped
  instead, `{:error, :has_owner}`.

Each organisation has a separate allowance of invitations, a client as any other:
`Apiary.Instance.invitations_per_day/0` a day, and three times as many attempts. The
invitation of a client's first owner is the one counted against another organisation's
allowance, its operator's (`Apiary.Organisations.insert_invitation/3` with `allowance:`).
Each invitation's entry (`member.invite`, `client.invite_owner`), and each new link's
(`invitation.renew`, `client.renew_owner_invitation`), names the allowance it counted
against, `details.allowance_id`. An invitation withdrawn because it could not be
delivered does not count against the day's invitations, and does count against the
attempts.

Deleting an operator waits until it has no clients: each is deleted or purged first.

### Gateways at the organisation level

A gateway lives at a workspace or at an organisation (the core's `Apiary.Gateways`). The
core asks the edition two questions about the organisation level, which the edition
answers in `ApiaryPro.Gateways`:

- `serving_organisations/1`: the other organisations whose organisation-level gateways
  may serve an organisation's workspaces, in the order its workspaces resolve their
  default through them;
- `served_organisations/1`: the other organisations whose workspaces an organisation's
  organisation-level gateways may serve.

While an operator runs its clients' infrastructure (the flag
`ApiaryPro.Flags.operator_infrastructure?/0`), a client's workspaces are served by its
operator's organisation-level gateways, and an operator's serve its clients' workspaces.
Otherwise the edition answers none to both: an organisation's gateways serve its
workspaces alone.

### Policy requests

A client's security policy is the client's: the operator's people read it and change
nothing, and the operator asks for what its harness needs (`ApiaryPro.PolicyRequests`).
The four actions belong to the feature `security`: the operator needs it to send, and a
client to receive and to answer; a client without it is not offered as a recipient.

- `policy_request.send`: a request for changes to the clients' policy, rules of a
  workspace's baseline to add, change or remove and the mode, with a note, to the clients
  chosen, all by default; an owner's or an admin's of the operator, asked in the operator.
- `policy_request.withdraw`: a request withdrawn from the clients that have not answered
  it; an owner's or an admin's of the operator, asked in the operator. An answer given
  stays.
- `policy_request.accept` and `policy_request.decline`: a request of the client's operator
  answered, asked in the client, and not found in an organisation with no operator; every
  level of the client has them, since every level may change the policy
  (`security_policy.edit`), and a reader, the operator's people among them, has neither.
  An answer is the whole client's, so the person must also be able to change the policy
  of at least one workspace of it, asked under the answer's locks: a member added to no
  workspace answers nothing, `forbidden`, and the page offers them no answer.
  An acceptance makes the changes through the same writes as any change of the policy,
  as the person who accepts, in the workspaces they choose among those their membership
  reaches (`Apiary.Policy.lock_workspaces/2`, `Apiary.Policy.apply_requested/3`): each
  change asks what a change of the policy asks, so a locked rule is an owner's
  (`security_policy.lock`) and the mode an owner's or an admin's
  (`security_policy.set_mode`), and a refusal of one refuses the whole. A workspace of
  another organisation, or one marked for deletion, is not found.

A client that is dropped or deleted by its operator has its pending answers withdrawn in
that transaction, each an entry of `policy_request.withdraw` in both trails with the
reason.

### The organisation's policy

The organisation's policy holds above its workspaces' security policy
(`ApiaryPro.OrganisationPolicy`, [architecture.md](architecture.md), The organisation's
policy). Its four actions belong to the feature `organisation_policy`, which needs
`security`, and are asked of the organisation:

- `organisation_policy.read`: the rules every workspace follows, the floor and the
  switch, the workspaces under them and the history; an owner's, an admin's and the
  reader's, so the people of a client's operator and an instance admin read it and
  change nothing. A member has no page of it.
- `organisation_policy.edit`: adding, changing and removing the organisation's rules, an
  owner's alone.
- `organisation_policy.set_floor`: requiring `enforce` in every workspace, or no longer;
  an owner's.
- `organisation_policy.set_switch`: letting the workspaces allow more hosts, or allowing
  only the organisation's; an owner's.

Each change renders every workspace of the organisation again, inside the change's
transaction, as a write of the policy by the person who made it: the entries in each
workspace's history are theirs (`security_policy.edit`, `above_changed`), beside the one
entry on the organisation. A suspended organisation is read-only here as everywhere.

### The organisation's variables

The organisation's variables hold above its workspaces' variables
(`ApiaryPro.OrganisationVariables`, [architecture.md](architecture.md), The
organisation's variables). Its two actions belong to the feature
`organisation_variables`, which needs `security` and `secrets`, and are asked of the
organisation:

- `organisation_variable.read`: the variables every workspace inherits, their values and
  locks, and how many workspaces and repositories set each themselves; an owner's, an
  admin's and the reader's, so an instance admin reads them, values included, as they read
  a workspace's (`variable.read`), and changes nothing. A member does not read them here;
  a workspace's variables are a member's to read where they reach it, as the core says.
- `organisation_variable.edit`: creating, changing, locking, unlocking and deleting the
  organisation's variables, an owner's and an admin's, as a workspace's variables are
  (`variable.edit`).

A change is one entry on the variable, by name and never by value. A suspended
organisation is read-only here as everywhere: its variables are read, and changed by no
one.

### The organisation's secrets

The organisation's secrets sit beside its workspaces' secrets
(`ApiaryPro.OrganisationSecrets`, [architecture.md](architecture.md), The organisation's
secrets). The core keeps them and asks the edition who may
(`c:Apiary.Edition.organisation_secrets/2`, The 4 callbacks beside `Apiary.Access`, above).
`ApiaryPro.OrganisationSecrets.may/2` calls `Apiary.Access.check/3` for each action and
checks nothing else.

Their three actions belong to the feature `organisation_variables`, as the organisation's
variables' do, which needs `security` and `secrets`, and are checked on the organisation.
`ApiaryPro.Access.check/3` returns not found, for every role, where the organisation does
not have the feature (`ApiaryPro.Features.of/2`). This is a place rule and not only the
actions' feature: `Apiary.Features.visible?/2` goes by what the person is shown, and while
`ApiaryPro.Flags.feature_visibility?/0` is on, an instance admin and an operator's people
are shown more than the organisation has.

What each action covers:

- `organisation_secret.read`: their names, notes and value IDs, never a value; an
  owner's, an admin's and the reader's, so an instance admin reads them, as they read a
  workspace's (`secret.read`), and changes nothing. A member does not read them; a member
  reads the secrets of the workspaces they reach, as the core says.
- `organisation_secret.write`: creating one, changing its name, note and values, and
  deleting it, an owner's and an admin's, as a workspace's secrets are (`secret.write`).
- `organisation_secret.use`: linking one to what uses it, an owner's and an admin's, as
  `secret.use`. No page of the edition's makes a link.

Sealing a value to a run is the instance's alone: it is asked with no person, and
answered by whether the instance has the feature.

The keys of the organisation's model providers are listed on the same page, where the
features `factory` and `secrets` are shown. With the feature `organisation_variables`,
whoever reads the organisation's secrets sees them, and whoever changes them under
`provider.write` changes them. Without it, nobody reads the organisation's secrets, and the
page is the keys alone for whoever changes them under `provider.write`, an owner's and an
admin's, or the operator's while it holds a client's model chain. A member does not open
the page. The keys are not organisation secrets: the three actions above do not apply to
them, and nobody reaches a secret or a variable of the organisation through that page
without the feature.

A change is the core's entry on the secret (`secret.write`), by name and value IDs and
never by value, with the organisation's level. A suspended organisation is read-only here
as everywhere: its secrets are read, and changed by no one.

### The instance organisation and the instance actions

An organisation has a kind, an ordinary organisation or an operator, and one organisation
is the **instance organisation**, which the instance's first sign-up, its set-up
(`Apiary.Setup`), creates ([architecture.md](architecture.md), Tenants and the
instance organisation): an
operator where the instance has `managed_organisations`, an organisation otherwise
(`ApiaryPro.Tenants.first_sign_up_kind/0`). It is the instance's organisation of the core
(`c:Apiary.Edition.instance_organisation_id/0`,
`ApiaryPro.Reach.instance_organisation_id/0`). Inside it, its people act at their level
as in any organisation, and what the kind decides holds there as anywhere: an
operator's actions over its clients are found in it only while it is an operator.

The instance's admins are the owners of the instance organisation; its other people reach
it at their level, read its clients once it is an operator, as any operator's people read
theirs, and reach nothing beyond.
`Apiary.Access.instance_admin?/1` answers whether a scope's person is one, by their
membership as the database has it now, neither it nor their account suspended. It is for
the checks with no action: `ApiaryPro.Reach` calls it for an instance admin's reach, and
`ApiaryPro.Release.purge_now/2` calls it for the account that asked for an erasure. The
instance actions do not call it. The level that makes one is
`Apiary.Access.instance_admin_level/0`, and
whether a membership of the instance organisation is at it is
`Apiary.Access.instance_admin_membership?/1`, which the release commands ask: nothing else
compares a level for it.

The **instance actions** are its owners', on Instance settings' pages,
`/instance/organisations`, `/instance/accounts` and `/instance/configuration`. The
edition's are marked `instance: true`, as the core's are. For each,
`Apiary.Access.check/3` first checks the feature and the instance step: a person's scope
outside the instance organisation, or in it while it is marked for deletion, is not found.
For the edition's actions, `ApiaryPro.Access.check/3` then checks these, in order:

1. the instance's scope outside the instance organisation, and a scope whose organisation
   or workspace is marked for deletion: not found, because the core's step passes the
   instance's scope anywhere and reads no workspace's mark;
2. the role: `forbidden` for its admins and members;
3. the subject;
4. the edition's rules.

For the core's actions it returns `:continue`, and the core checks the subject, the role and
the one-person rules. `instance.read` is the core's, beside `instance.read_factory` and
`instance.read_observability`. The list below includes it because
`ApiaryPro.Operators.list_organisations/1` and `ApiaryPro.Suspensions.list_accounts/1`
call it.

- `instance.read`: every organisation on the instance, with its kind and its operator;
- `instance.create_organisation` and `instance.create_operator` (the latter with
  `managed_organisations`): a new organisation or operator, whose first owner is the
  instance admin who creates it;
- `instance.change_kind` (with `managed_organisations`): an organisation that is no client
  made an operator, or an operator without clients made an organisation, the instance
  organisation as any other;
- `instance.purge_organisation`: an organisation purged at once, on an erasure request,
  its slug typed to confirm (`ApiaryPro.Deletion.purge_on_request/3`);
- `instance.suspend_account` and `instance.activate_account`: a person's account
  suspended and activated again, never the account of the instance admin who acts
  (Suspension, below);
- `instance.suspend_organisation` and `instance.activate_organisation`: an organisation
  or an operator suspended and activated again;
- `instance.transfer`: the arbiter's offer of the ownership of an organisation whose
  owners are all suspended, a client as any other, to one of its admins, with a reason
  (The arbiter, below);
- `instance.grant_features`: what an operator is granted, or what an organisation with no
  operator keeps (Features, below);
- `instance.change_sign_up`: whether someone without an invitation may sign up and create
  an organisation, and an operator, saved on Instance settings › Configuration after a
  recent sign-in (`ApiaryPro.SignUp.save/2`).

Changing a kind, purging, suspending and activating an organisation, the arbiter's offer
and granting features are asked of the organisation acted on. Of these only a change of
kind is taken on the instance organisation itself; the rest are `forbidden` on it: it is
never purged, suspended or transferred, and has every feature the instance has. A kind is
not changed, and an organisation not transferred or granted features, once it is marked
for deletion. Suspending and activating an account are asked of the account, which
belongs to no organisation.

Instance settings › Organisations and › Accounts mount on `on_mount/4` of
`ApiaryProWeb.InstanceLive.Components`, not on the core's
`on_mount {ApiaryWeb.Access, :instance}`. `instance_scope/1` of that module calls
`Apiary.Access.instance_scope/1`, which calls `Apiary.Access.can?/3` with `instance.read`.
`on_mount/4` puts its scope into `@scope`, and shows not found to anyone else. Neither page
computes `@scope` again when the reader's memberships change. A person who is no longer an
instance admin still sees the page until they reload, and a write fails, because
`Apiary.Access.authorize/3` reads the membership again.

**The arbiter** is for recovery only. An instance admin, under Instance settings › Organisations, offers the
ownership of an organisation whose owners are all suspended, a client as any other, to
one of its admins, with a reason (`instance.transfer`), replacing any offer pending. The
admin accepts it on the Ownership section of the organisation's settings, which every page
of the organisation leads them to while the offer stands
(`organisation.accept_transfer`), and becomes an owner; a client stays its operator's.
The offer names no operator: a client's is in its entry alone, so the purge of an
operator that dropped a client takes no offer of it with it. A suspended organisation is
activated first. The offer lapses once one of its owners may act again, their membership
or account activated, and an acceptance then is refused: the instance does not overrule
an owner.

Accepting the arbiter's offer is taken on the strength of the offer, and no role has
`organisation.accept_transfer`. `ApiaryPro.Access.check/3` checks it, with the offer as the
subject: anyone but the person it is offered to gets not found, and that person gets
`forbidden` once they are no admin in use. A suspended organisation passes this check, and
`ApiaryPro.Transfers.accept/1` then returns `:suspended`. `accept/1` calls
`Apiary.Access.check/3` with the offer and the person's membership locked; a suspended
membership or account counts as no membership there. The Ownership page shows the offer
through `ApiaryProWeb.SettingsLive.Ownership.offered_to_reader?/2`, which calls
`Apiary.Access.check/3` and not `can?/3`: a recipient who is no longer an admin gets
`forbidden`, still reads the offer, and Accept shows why the acceptance fails. The arbiter's
offer, its lapse and its acceptance are each an entry in the trail of the organisation
offered.

Nobody deletes or purges the instance organisation: `organisation.delete` and
`organisation.purge` on it are refused for every role, the instance's included, since an instance without one would
give its next sign-up the instance (`Apiary.Access.refused_on?/2`, which its settings
page asks to say why). Granting and revoking an instance admin (`instance_admin.grant`,
`instance_admin.revoke`) are the core's release commands, which no role has.

One more instance action is taken by no role: `instance.adopt`, the entry of an
organisation that Qory Apiary 0.1.0 created, adopted at the upgrade
([architecture.md](architecture.md), Adopting an instance upgraded from Qory Apiary
0.1.0).

Instance settings › Accounts also offers the core's password links while no mail is set
(`Apiary.Accounts.build_password_link/3`, Make a password link in an account's menu): a
link that sets the account's password, for any account on the instance but the account of
the admin who acts and a suspended one, a client's owner as a member of any organisation.
It is the core's instance action `account.password_link`, asked of the account, and the
edition adds no exception to it. The page calls `Apiary.Access.can?/3` for each account,
beside its checks that no mail is set and that the account is not suspended. For the
admin's account, `Apiary.Access.check/3` returns `{:error, :own_account}`. The core then
checks whether mail is set and whether they signed in recently
(`Apiary.Accounts.sudo_mode?/2`, within 20 minutes; the page sends an admin whose sign-in
is older to log in again first), returns an error for an account that cannot log in (the
edition's `account_refusal/1`), and records `account.password_link` in the instance
organisation's trail. Mail turned on, by the test link of Instance settings › Mail or a
start with `SMTP_RELAY`, ends every such link (`Apiary.Mail.end_password_links/0`). The
page shows the link once, and never in a path, a flash or a title.

### Suspension

A suspension pauses and removes nothing (`ApiaryPro.Suspensions`): a membership gets
`suspended_at` and `suspended_by_id`, as in the core, and so does an organisation's
tenant (`ApiaryPro.Tenants.Tenant`), which activating empties again; an account's
suspension is its row of `account_suspensions` (`ApiaryPro.Suspensions.AccountSuspension`),
which activating deletes. Memberships, workspace access, history, access keys and the
managing relationship all stay.

- **A membership** (`member.suspend`, `member.activate`,
  `Apiary.Organisations.suspend_member/2` and `activate_member/2`), the core's, in
  Organisation settings › People. An owner who must not act is the instance admins' to stop, by suspending
  their account. A suspended membership in an operator reaches none of its clients.
- **An account** (`instance.suspend_account`, `instance.activate_account`), by an
  instance admin under Instance settings › Accounts, never the account of the admin who
  acts. It signs in nowhere, its sessions are deleted and its open pages disconnected,
  and every membership of it counts as none.
  Signing in says so, in a sentence that names no reason and no one, only once the
  password or a log-in link has shown the account is the person's
  (`ApiaryPro.Suspensions.account_refusal/1`, the edition's `account_refusal/1`). **Its
  access keys are not affected**: an access key belongs to a machine of a workspace, not to
  the person who added it, so the keys it added keep working. An owner or an admin
  revokes them on the machine's Access key tab if they should stop.
- **An organisation or an operator** (`instance.suspend_organisation`,
  `instance.activate_organisation`), by an instance admin under Instance settings › Organisations, never the
  instance organisation, which a check in the database keeps unsuspended too. It is
  read-only: its people sign in and read everything in it, under a notice, and
  `Apiary.Access.check/3` refuses every action there but the reads, `forbidden`, for every
  role but the instance's jobs, leaving included. It sends no invitation, and an
  invitation into it accepts no one. The access keys of its machines and pools are
  refused at verification (`Apiary.AccessKeys.fetch_for_verification/1`), as a revoked key
  is, and a gateway's key acts for no run of its workspaces, so no run starts or reports
  there. The workspaces of a suspended operator are suspended with it, and its people
  read its clients no more; the clients keep running, their runs, their access keys and
  the clients' owners, admins and members working as before.

Each suspension and activation is an audit entry, written in its transaction: a
membership's in its organisation's trail; an account's in the instance organisation's,
which names the account by id; an organisation's in the trail of the organisation
suspended, with no address or client, since the instance admin acts from outside it.

**Enforced in `Apiary.Access`.** `reload/2` reads the suspension of the membership, of
the person's account, of the organisation and of a client's operator with the level, and
fails closed: a scope loaded before a suspension acts on nothing after it. The edition
narrows the core's queries to the accounts and organisations in use
(`ApiaryPro.Suspensions.active_accounts/2`, `active_organisations/2`, the edition's).
Under `lock: :share` it holds the organisation, its operator and the account `FOR SHARE`,
and reads their suspensions again in a statement after its locks; a suspension locks the
row of what it suspends, the organisation's or the account's, `FOR NO KEY UPDATE`, in the
lock order below, and writes the tenant or the account's suspension under that lock, since
the absence of a row cannot be locked. So a change that holds that row is written before
it, and one asked after it waits and then sees it. `ApiaryPro.Access.suspended?/1` says
whether the scope's organisation is suspended, for the page's notice; `can?/3` answers no
to every change there, so no control that changes something shows. An owner of the
instance organisation whose membership or account is suspended is no instance admin.

**The last owner.** The core's rule counts only the owners who may act, whose membership
and account are neither suspended nor deleted
(`Apiary.Organisations.other_active_owner?/1`, which asks the edition's
`active_accounts/2`): inside an organisation its last such owner is not demoted or
removed, `{:error, :last_owner}`, nor does their account's deletion leave the organisation
without them. Nor is the account of the instance organisation's last owner who may act
suspended, `{:error, :last_owner}`; the release command
(`Apiary.Release.grant_instance_admin/2`) is the recovery. Only the instance admins leave
an organisation without an owner who may act, a client as any other, by suspending the
account of its only owner. It then runs below the owner level
(`ApiaryPro.Suspensions.owner_suspended?/1`, which asks of the organisation's owners
alone: a client's operator has no part in it): its admins and members work, its runs
continue, what only an owner does waits, and its people see a notice, until an instance
admin activates the owner again or offers the ownership to one of its admins (The instance
actions, above).

### A client's drop

A client parts from its operator when the operator drops it (`ApiaryPro.Transfers`).
Nothing else changes a client's operator, and a suspension leaves it as it is.

- **Dropping a client.** An owner of the operator drops a client that has an owner at
  any time, on the Clients page (`client.drop`). One with no owner yet is deleted instead
  (`client.delete`, An operator's actions, above), so no client is left with nobody in
  it. It takes the whole client out of its operator, and nobody's membership changes.

A drop takes effect at once and is an entry in the client's trail and one in the
operator's. It is confirmed by typing the client's name, which
`ApiaryPro.Transfers.drop/3` checks too, `{:error, :confirmation}` otherwise, so an event
sent without the confirmation changes nothing. The confirmation is in place on the
client's row of Clients, never a dialog.
The client is an organisation with no operator from then on: the operator's people read
it no more, and the grants the operator made it go, so it has what an organisation with
no operator has and follows the instance (Features, below). Its people, its workspaces
and its policy stay as they are.

Each side sees the other. The operator's Clients page names each client, its owners and
since when it is the operator's client (its tenant's `operator_since`). A client names
its operator to all of its people: in an Operator part of the Ownership section of its
settings, which every reader of a client's settings has in the list, and which says that the operator's people read everything in it to support its
harness and change nothing, and in a line under the title of its People page,
"Operated by" the operator.

### Features

The feature an action belongs to is asked first, as in the core: an action of a feature
hidden from the person who asks is not found. Below the instance each organisation is
shown a set of features, the same in each of its workspaces (`ApiaryPro.Features.of/2`,
[architecture.md](architecture.md), Features below the instance), and the scope carries
what its person is not shown, `hidden` (`c:Apiary.Edition.hidden/1`, answered by
`ApiaryPro.Features.hidden/1`): `Apiary.Organisations.resolve_scope/4` loads it with the
organisation and the workspace, and `reload/2` reads it again after its locks, so a grant
withdrawn while a change is asked is waited for, or seen. An access key, and what a node
is served, follow the instance's features alone. Who changes them (`ApiaryPro.Grants`):

- `instance.grant_features`: an instance admin's, under Instance settings › Organisations, of the
  organisation acted on: what an operator is granted, or what an organisation with no
  operator keeps. Never a client, whose operator grants it, nor the instance organisation,
  which has what the instance has.
- `client.grant_features`: an owner's of the operator, on its Clients page: what a client
  is granted, out of the operator's features.

A client that is dropped loses what its operator granted it: from then on it follows the
instance, as any organisation with no operator does.

A suspended organisation or client is granted nothing. An operator's
`managed_organisations` is not a grant's to take away: it goes when it is made an
organisation again. A write changes only the features its page shows, the built ones the
granter has; a grant of a feature the granter lacks for now is kept, and back in force
once the granter has it again.

### A person's action, asked of no place

Anyone signed in may create an organisation, whose first owner they are, from the
organisation switcher's New organisation entry (`organisation.create`,
`ApiaryPro.Organisations.create_organisation/2`). It is the role `person`'s in the role
table: asked of the new organisation before it exists, an `Organisation` not inserted yet,
of the kind asked for, and of no place, so whichever organisation the page is in, the
level held there and whether the person belongs to any organisation at all play no part.
What decides is the instance: a kind whose sign-up setting is open, as an instance admin
saves it on Instance settings › Configuration, applied at once, unless
`SIGNUP_ORGANISATIONS` for an organisation or `SIGNUP_OPERATORS` for an operator overrides
it (`ApiaryPro.SignUp.kinds/0`), the same settings a sign-up follows. A kind whose setting
is closed is `forbidden`, whatever the form says, and so is anything but a new
organisation of no operator; with both closed the entry is not there. A scope without a
person, and an account that is deleted or suspended, may not. The context function asks
again inside its transaction, which reads the settings again, and holds the account
`FOR SHARE` there, so its deletion waits or is seen.

A sign-up creates an organisation by the same steps, and its entry is the same action, but
it asks nothing here: the account it creates does not exist until it commits (the core's
`docs/access.md`, Who asks).

### Who asks

Beside what the core takes on the strength of something other than a role, accepting the
ownership offered to one is taken on the strength of the offer (The instance actions,
above), and no role has it. A person who has an account asks `organisation.create` as the
role `person` (A person's action, asked of no place, above); a sign-up still asks nothing.

### The context function asks before it acts

The edition's part of the answer (`ApiaryPro.Access.check/3`, the edition's `check/3`)
adds to the core's:

- `{:error, :not_found}` for an operator's action in an organisation that is no operator,
  a client's action (answering a policy request) in an organisation with no operator, and an instance action anywhere but in the instance organisation;
- `{:error, :forbidden}` for any action but a read in a suspended organisation, for
  anything but a read by a reader, and for what is refused on the instance organisation
  itself.

`authorize/3` reads the workspace access too where the level needs one, so a scope
loaded earlier cannot act in a workspace the person was removed from. A write of the
security policy holds the organisation rows, the client and its operator
(`Apiary.Access.lock_places/1`), then takes the workspace's lock, then reads the
membership, the workspace access and the account `FOR SHARE`, so a change of the level,
a removal from the workspace, a suspension, a transfer, a client's drop and a grant wait
for it, and none committed before it is missed.

### The lock order

Every change that can wait on another takes its rows in one order, so two changes wait
for each other and never on each other at once. This is the core's order with the
edition's rows in it:

1. **Organisation rows**, a client before its operator. A write that must stay allowed
   holds the organisation and its operator (`ApiaryPro.Reach.places_to_lock/1`, which
   reads the organisation's tenant and locks nothing). It names a client's operator
   besides the client, and for any other organisation that organisation alone, so an
   operator named besides its client brings no third organisation. Several organisations,
   as an account's deletion and its suspension hold every organisation the account is a
   member of (`Apiary.Organisations.sole_owned_organisations/2` with `lock: true`), and
   its activation the organisations it owns, are locked in the order of
   `Apiary.Organisations.lock_order/1`: the clients first, then the rest, each in the
   order of their ids, so a client always comes before its operator. Every change that
   locks more than one organisation row in one transaction, in any mode, the core's and
   the edition's, takes them through the core's
   `Apiary.Organisations.lock_organisations/2`, so what it holds in the end was taken in
   one statement, in that order. A write that must stay allowed and a change of people
   hold the organisation and its operator `FOR SHARE` so
   (`Apiary.Access.lock_organisations/1`, which `Apiary.Access.lock_places/1` and
   `reload/2` with `lock: :share` take first): should `places_to_lock/1`, asked again of
   the organisation held, name one it did not take, it lets go of what it took and takes
   the fresh set in one statement, three attempts in all. A change of the edition's that
   locks several itself (`ApiaryPro.Tenants.lock_organisations/2`) takes them at one
   point, before its first write, each in the strongest mode the change needs. A function
   of the core it calls after, `Apiary.Organisations.lock_owners/1`,
   `Apiary.Access.reload/2` with `lock: :share` or the count of an invitation against its
   allowance, takes some of those rows again, in the same mode or a weaker one, and none
   it does not hold. A deadlock Postgres breaks all the same, once the core has taken the
   rows again, is the change's answer to try again where it has one, and an error
   otherwise. Where the modes conflict with `FOR SHARE`, the rows are only those whose
   place in the order cannot change while they are held. Two changes take several so. The
   adoption of the organisations the core created (`ApiaryPro.Adoption`) locks those
   without a tenant, which are no clients, and the one it makes the instance organisation.
   A change of an operator's features (`ApiaryPro.Grants.set_organisation/3`) locks its
   clients, then the operator, since a new workspace in a client holds the client alone
   while it reads its features; a client stays the operator's while its row is held, since
   every change of a client's operator locks the client's row first. It reads the clients
   again once it holds them: a client created between the read and the lock means a set
   taken stale, which it lets go of, rolling back to a savepoint taken before the lock,
   and takes afresh, three attempts in all, and `{:error, :busy}` after. A grant to a
   client (`ApiaryPro.Grants.set_client/3`) locks the client `FOR NO KEY UPDATE` and holds
   its operator `FOR SHARE`, at one point, then asks `client.grant_features` again, so a
   suspension of the operator that came while it waited is seen.
2. **People locks** (`people_locks`, one per organisation, `ApiaryPro.Tenants.lock_rows/1`),
   after the organisation rows, in the order of their ids: all of a change's at one point,
   before its first write, in the strongest mode it needs, and none later. A write in a
   client that must stay allowed for its person holds its operator's `FOR SHARE`
   (`Apiary.Access.lock_places/1`). A change of an operator's people locks its row
   `FOR UPDATE`, with the rows a write by the same person would hold: a change of a
   level, a removal or leaving, a membership's suspension and activation, and the grant
   and revoke of an instance admin, once the organisation is held
   (`Apiary.Organisations.lock_people/1`), and an invitation's acceptance and a sign-up
   with one, once the core holds the invitation's organisation. An account's deletion
   locks the rows of the organisations it is a member of, and its suspension those and
   the instance organisation's, `FOR UPDATE`, once they hold those organisations, and no
   other. A people lock missing beside a tenant is written at the same point, the missing
   ones first, in the order of their ids, then locked as the others are: whatever writing
   one waits for, it waits for before any people lock of the change is held.
3. **Workspace rows**, in the order of their ids where a change takes several, as an
   acceptance of a policy request does.
4. **Memberships**: the owners' of the organisation, in the order of their ids
   (`Apiary.Organisations.lock_owners/1`), then any other.
5. **Accounts.**
6. **Everything else**: offers of ownership, invitations, grants, policy requests and
   their answers (a request before its answers), access keys, runs.

The modes keep a row that only names another out of it:

- A write that must stay allowed while it is written holds the organisation and a
  client's operator `FOR SHARE` (`Apiary.Access.lock_places/1`), the workspace
  `FOR KEY SHARE`, the membership and the workspace access `FOR SHARE`, then the account
  `FOR SHARE` (`reload/2` with `lock: :share`). The membership in a client's operator is
  read without a lock, once the operator's people lock is held: a change of the
  operator's people waits for the write, or came first and is seen. A change that may
  make an owner, or counts the owners who remain, holds the organisation and a client's
  operator `FOR SHARE` too, then the people locks, a client's change its operator's
  first, then locks the memberships of the organisation's owners
  (`Apiary.Organisations.lock_owners/1`); the operator's owners are no part of it.
- A write may ask for its people locks more than once in one change, at
  `Apiary.Access.lock_places/1`, once for each workspace a policy write takes, and again
  at `reload/2` with `lock: :share`, and each time it takes the same row in the same
  mode: a client's operator does not change while the write holds the client
  `FOR SHARE`, since every change of a client's operator locks the client's row
  `FOR NO KEY UPDATE` first.
- A change in a client may take its operator's people lock without holding the
  operator's organisation row, as an invitation's acceptance does: no change that holds
  an operator's organisation row or its tenant's row `FOR UPDATE` or `FOR NO KEY UPDATE`
  takes that people lock.
  An operator with clients is never purged, and a change of an organisation's kind and
  its suspension take no people lock.
- A client's drop (`ApiaryPro.Transfers.drop/3`) locks the client's row
  `FOR NO KEY UPDATE`, then holds the operator's `FOR SHARE`. So a policy write in the
  client, which holds the client `FOR SHARE`, and a drop wait for each other, and a
  locked reload of an operator's person in the client waits for a drop or sees it.
- The acceptance of the arbiter's offer (`ApiaryPro.Transfers.accept/1`) changes no
  operator: it holds the organisation `FOR SHARE`, locks its people lock `FOR UPDATE`
  where it is an operator, and its owners (`Apiary.Organisations.lock_owners/1`), then
  the membership of the person who accepts, their account, and the offer. It reads the
  offer without a lock first, so a person it is not offered to, and an organisation with
  no offer, get not found and take no lock.
- A change of gateways (`Apiary.Gateways.lock/1`), the core's, takes organisation rows
  first, in one statement in the lock order, and the edition takes no other row for it: a
  change of an organisation-level gateway (its creation, a new default mark, its
  deletion) holds the organisations it serves `FOR SHARE` and its organisation
  `FOR NO KEY UPDATE`; a change at a workspace (a node's or a pool's, or a
  workspace-level gateway's) holds the organisation and those that serve it `FOR SHARE`,
  then the workspace `FOR NO KEY UPDATE`; then the node rows `FOR UPDATE`.
- An organisation's suspension, its grants and its marking for deletion lock its row
  `FOR NO KEY UPDATE`, a change of an operator's features its clients' rows first, and a
  suspension of an account locks it the same way: they wait
  for a write in flight, and one asked after them waits and then sees them. What the
  edition keeps of them, the organisation's tenant and the account's row of
  `account_suspensions`, is written under that lock, and read by a change that holds the
  row in a statement after its lock (`ApiaryPro.Tenants`, Locks): the `organisations` and
  `users` rows stay the ones to lock. A tenant's row is locked only by a write of the
  tenant, under its organisation's lock, and by the key a client's tenant holds on its
  operator's (`FOR KEY SHARE`), taken after the operator's organisation row, which a
  change of the operator's kind locks `FOR UPDATE` first. A people lock is not a tenant's
  row: it is locked only as its place in the order says, and writing one takes
  `FOR KEY SHARE` of its tenant.
- An invitation locks the row of the organisation whose allowance it counts against
  `FOR NO KEY UPDATE` while it is counted and written: the inviting organisation's for
  `member.invite`, the operator's for `client.invite_owner`; a new link for a pending
  invitation (`invitation.renew`, the core's, and `client.renew_owner_invitation`) the
  one it was counted against, then the invitation.
  `ApiaryPro.Operators.create_client/3` locks the operator's row `FOR NO KEY UPDATE`
  first; `ApiaryPro.Operators.invite_owner/4` holds the client `FOR SHARE`, then locks the
  operator `FOR NO KEY UPDATE`; `revoke_owner_invitation/3` holds the client
  `FOR SHARE`, then locks the invitation; `renew_owner_invitation/4` reads the
  organisation the invitation was counted against first
  (`Apiary.Organisations.allowance_of/1`), the operator, or the client itself where the
  client's trail no longer names it, then holds the client `FOR SHARE` and locks that one
  `FOR NO KEY UPDATE`, or the client alone `FOR NO KEY UPDATE` where it is the one, and
  the core's renewal, in the same transaction, then locks that row again, in the same
  mode, and the invitation `FOR UPDATE`. Where it finds no such invitation, or no
  organisation it was counted against, it holds the client alone `FOR SHARE`, and the
  renewal is refused.
- An invitation's acceptance, and a sign-up with an invitation, hold its organisation
  `FOR SHARE` first, before the account and the invitation, so the organisation's
  suspension and marking wait for it, or came first and refuse it. An operator's
  invitation of its client's first owner locks the client `FOR NO KEY UPDATE` instead
  (`ApiaryPro.Invitations`, the edition's `accepting/3`, before the core holds it
  `FOR SHARE`), so two such acceptances, and the client's drop and deletion, are one
  after the other. `ApiaryPro.Deletion.delete_client/3` locks the client
  `FOR NO KEY UPDATE`, then holds the operator `FOR SHARE`, as a drop does.
- A policy request (`ApiaryPro.PolicyRequests`). Sending one holds the operator's clients
  and the operator `FOR SHARE`, in one statement in the lock order, the clients in the
  order of their ids, then the operator, then the person's membership and account
  (`reload/2` with `lock: :share`, which takes the operator again in the same mode), so a
  client's drop waits for it or came first and is not sent to. An acceptance takes the
  client and its operator `FOR SHARE` (`Apiary.Access.lock_places/1`), then the
  workspaces chosen in the order of their ids `FOR NO KEY UPDATE`, as a policy write
  takes its one
  (`Apiary.Policy.lock_workspaces/2`), then the membership and the account `FOR SHARE`,
  then the person's workspace access `FOR SHARE`, which a removal from a workspace locks
  alone, to find a workspace whose policy they may change, then the answer `FOR UPDATE`;
  each change it makes is a policy write, which takes the rows it already holds. A
  decline takes the same without the workspaces. A withdrawal holds the operator, the
  person's membership in it and their account `FOR SHARE` (`reload/2` with
  `lock: :share`), then locks the request, then the answers pending, in the order of
  their ids, and asks `policy_request.withdraw` again of what it holds, so a demotion of
  its author waits for it, or came first and refuses it. A drop and a client's deletion
  lock the client `FOR NO KEY UPDATE` first, then its answers pending. So an acceptance
  and a withdrawal, two acceptances of one answer, and an acceptance and a drop are one
  after the other, and the second finds the answer given or withdrawn; a withdrawal and
  its author's demotion are one after the other too
  (`test/apiary_pro/policy_request_races_test.exs`).
- The organisation's policy (`ApiaryPro.OrganisationPolicy`). A write holds the
  organisation and its operator `FOR SHARE` (`Apiary.Access.lock_places/1`), then takes
  every workspace of the organisation in use in the order of their ids
  `FOR NO KEY UPDATE` (`Apiary.Policy.lock_workspaces/2`), as a write of one workspace's
  policy takes that workspace, then the membership and the account `FOR SHARE`, then the
  row of the organisation's policy `FOR NO KEY UPDATE`; each workspace is rendered under
  the rows it holds. So a write of a workspace's policy and a write of the organisation's
  wait for each other, and the second resolves against what the first wrote
  (`test/apiary_pro/organisation_policy_races_test.exs`).
- A change of what an organisation is shown (`ApiaryPro.Grants`) takes organisation rows
  only.
- The organisation's variables (`ApiaryPro.OrganisationVariables`). A write takes the
  rows a write of the organisation's policy takes, in the same order: the organisation
  and its operator `FOR SHARE`, then every workspace of the organisation in use in the
  order of their ids `FOR NO KEY UPDATE`, as `Apiary.Policy.lock_workspaces/2` takes them
  and as a write of one workspace's variables takes that workspace, and with them, in the
  same order of ids, every workspace marked for deletion that may still be restored, whose
  restore (`Apiary.Deletion.restore_workspace/2`) takes its row `FOR NO KEY UPDATE` and
  checks nothing of its variables; then the membership and the account `FOR SHARE`; then
  a transaction's advisory lock of the organisation's variables, last, so two of their
  writes take turns even with no workspace in use; then the variable changed
  `FOR UPDATE`. So a write of a workspace's variables and a write of the organisation's
  wait for each other, and the second checks its names against what the first wrote
  (the edition's level carries the organisation's variables to the workspace's checks,
  `c:Apiary.Edition.above_workspace/1`); a restore and a write of the organisation's wait
  for each other too, and the write checks the workspace marked as one in use; and two
  writes of the organisation's take turns
  (`test/apiary_pro/organisation_variables_races_test.exs`).
- The adoption of an instance upgraded from Qory Apiary 0.1.0 (`ApiaryPro.Adoption`) locks
  the rows of the organisations it adopts `FOR NO KEY UPDATE`, in the order of their ids,
  and the instance organisation's the same way, whose flag it sets and whose kind it
  leaves as it is, under an advisory lock, so their tenants are written under their rows'
  locks as every tenant is.
- A row inserted that names an organisation or an account, an audit entry among them,
  takes `FOR KEY SHARE` of it through its foreign key, whenever it is written: that
  conflicts only with `FOR UPDATE`, which nothing takes of an organisation or an account
  but a change of a key: an organisation's kind (`ApiaryPro.Operators.change_kind/3`),
  locked first and alone, the purge's deletion of the row, and an account's tombstone.

A deadlock Postgres breaks all the same in a transfer is taken again, twice at most, and
answers `{:error, :busy}` after, which a page says as "try again"
(`ApiaryPro.Transfers`). `test/apiary_pro/lock_order_races_test.exs` pauses each kind of change
half way against an acceptance and finds no deadlock.

A workspace's deletion locks the workspace without the organisation's row first, and
then takes no organisation `FOR UPDATE`, so it cannot close a cycle. An account's
deletion holds every organisation the account is a member of, those it owns `FOR SHARE`
and the rest `FOR KEY SHARE`, then locks the people locks of those organisations, before
its memberships; its suspension holds them the same way, with the instance organisation
`FOR SHARE`, then the same people locks, then the instance organisation's owners, then
the account.

A policy write in a client holds its operator `FOR SHARE`, so an operator's invitation of
a client's first owner, and the operator's creation of a client, wait for a policy write
in any of its clients; both are short.

A change that asks `authorize/3` without holding the organisation, such as a rename or an
access key, reads the membership and the suspensions without a lock, and can commit just
after a suspension, a demotion or a marking that began after its answer. Only the writes
that must stay allowed while they are written, the policy's and the ones above, hold the
organisation.

The edition's races are tested outside the sandbox, with `ApiaryPro.Races` beside the
core's helpers, in `test/apiary_pro/`: `access_races_test.exs`,
`feature_grant_races_test.exs`, `gateway_races_test.exs`, `lock_order_races_test.exs`,
`operators_races_test.exs`, `organisation_policy_races_test.exs`,
`organisation_variables_races_test.exs`, `people_lock_races_test.exs`,
`people_rows_races_test.exs`, `policy_request_races_test.exs`, `suspension_races_test.exs`
and `transfer_races_test.exs`.
