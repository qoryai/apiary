# Who may do what

Whether someone may do something is answered by `Apiary.Access` and nowhere else. No code
outside it compares a membership's level. Roles grow, and an edition may add actions,
roles and ways into an organisation (An edition's part, below); a rule written in one
place grows there, where a comparison repeated across the contexts and pages would be
changed in some places and missed in others.

## A new action goes into the module

Anything a person, an access key or a job can do that changes something, or that reads
something a role could one day be refused, is an **action**. A new one, or a new feature's
actions:

1. is added once to the action list in `Apiary.Access`, or to an edition's
   (`c:Apiary.Edition.actions/0`), as an `Apiary.Access.Action`: the feature it belongs
   to (none: every instance has it), a line saying what it is, which the module's
   documentation tabulates, whether it leaves an audit entry, and what it is asked of;
2. is given to the roles that may take it, in the action's `roles`, from which the
   module's role table is built;
3. gets its rows in the access test's rows modules (`Apiary.AccessRows` for the core,
   which `test/apiary/access_test.exs` asks of the core's actions through
   `Apiary.AccessCase`, and an edition's rows module, which the edition's own access test
   gives with the core's to ask of every action): yes or no for every kind of actor that
   matters. The test fails for an action in the list without rows.

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
it and is told so on its own path, `/:org`.

## What an admin may not

An admin may what an owner may inside the organisation, with these exceptions, each an
owner's alone:

- changing a person's level (`member.change_level`), to owner, admin or member;
- locked rules of the security policy (`security_policy.lock`);
- deleting the organisation and cancelling its deletion (`organisation.delete`,
  `organisation.restore`).

An edition may add actions of its own that are an owner's alone, in their `roles`.

Deleting a workspace and cancelling it (`workspace.delete`, `workspace.restore`) are an
admin's as well as an owner's: an admin manages the workspaces.

Over people, an admin acts on members only. Inviting, changing a level, removing,
revoking an invitation, making a new link for one (`invitation.renew`), suspending and
activating (`member.suspend`, `member.activate`) are **actions over people**: asked of the membership they are about, whose level decides,
or of the invitation, which is at member: an invitation is an email address and nothing
else, and its person joins as a member, whom an owner makes an admin or an owner
afterwards. An owner takes them on anyone, within the last-owner rule, but suspends and
activates admins and members only, never another owner; an admin takes them on a member
and on any invitation, never on an owner or an admin. Nobody suspends or activates their
own membership, whatever their level. Asked of a workspace or the organisation, as a page
asks whether to show a button at all, the role alone answers; the context function asks
of the row. An invitation is the organisation's whichever workspace it was sent from, so
an owner or an admin revokes it, or makes a new link for it, from any page of the
organisation. An edition's own
action over people asks the same rule (`Apiary.Access.acts_on?/2`). An edition that
makes a new link with an action of its own asks it itself, and passes it as `action:`
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
without a membership there, or is nil, and a page says so to them
(`c:ApiaryWeb.Edition.reader_sentence/2`) rather than the level a change would take. The
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
core's own edition (`Apiary.Edition.Core`) adds nothing and narrows nothing. An edition
may:

- add actions and roles (`c:Apiary.Edition.actions/0`, `c:Apiary.Edition.roles/0`), which
  join the core's in one registry: an action named twice, a role that is one of the
  core's, or an action of a role or a feature nobody defines stops the boot;
- answer first for what it adds or narrows (`c:Apiary.Edition.check/3`), once the
  action's feature is on and before the place is checked, or leave the answer to the core;
  an answer that must come after the place's asks `Apiary.Access.check_place/3` first.
  Asked with no scope, as `Apiary.Access.refused_on?/2` asks, `forbidden` says the subject
  refuses the action whoever asks, which a page asks to say why a control is not there;
- let a person into an organisation without a membership, with a role there, and read
  what it gave again under the write's locks (Reach, above);
- narrow the levels that reach every workspace, and say which workspaces another level
  reaches (Levels, above);
- hold more organisation rows beside the organisation's own with a write that must stay
  allowed (`c:Apiary.Edition.places_to_lock/1`, The lock order, below);
- hold an account or an organisation out of use beyond what the core knows: the core's
  queries leave out what it holds so (`c:Apiary.Edition.active_accounts/2`,
  `c:Apiary.Edition.active_organisations/2`), `reload/2` among them, so a membership whose
  account it holds out of use is no membership, and signing in asks it why an account may
  not (`c:Apiary.Edition.account_refusal/1`);
- give the level an invitation's person joins at, or refuse the acceptance
  (`c:Apiary.Edition.accepting/3`), and add to it once the membership is made
  (`c:Apiary.Edition.accepted/4`);
- refuse a deletion or a purge, and hear of each (Marked for deletion, below).

## The instance's admins

The instance's own organisation is the one its first sign-up creates
(`c:Apiary.Edition.instance_organisation_id/0`, [architecture.md](architecture.md), The
instance's organisation), and its owners are the **instance admins**, who run the
instance. Inside it they act at their level, as anyone there does.
`Apiary.Access.instance_admin?/1` answers whether a scope's person is one, by their
membership as the database has it now, neither it suspended nor their account out of
use, and is the one place that says so; an edition asks it for what it gives the instance
admins. The level that makes one is `Apiary.Access.instance_admin_level/0`, and whether a
membership of the instance's organisation is at it is
`Apiary.Access.instance_admin_membership?/1`, which the release commands ask: nothing
else compares a level for it.

Granting and revoking an instance admin (`instance_admin.grant`, `instance_admin.revoke`,
`Apiary.Release.grant_instance_admin/2` and `revoke_instance_admin/1`) are release
commands, taken on the strength of a shell on the release, which no role has. A password
link (`account.password_link`, `Apiary.Accounts.build_password_link/3`), a one-time link
that sets an account's password, is no role's either: an instance admin makes one while
the instance sends no mail, asked by `Apiary.Access.instance_admin?/1` in the context
function, and a release command makes one mail or not (`Apiary.Release.password_link/1`). Revoking
the last owner who may act is refused, `{:error, :last_owner}`. The claim of an instance
nobody has signed up to at its first start (`FIRST_ADMIN_EMAIL`, `Apiary.FirstAdmin`) is
taken on the strength of the release's environment, likewise beyond any role, and acts on
no instance that has its organisation.

The instance's own organisation is never deleted nor purged: an instance without it would
give its next sign-up the instance. `Apiary.Deletion` refuses to mark or purge it,
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
members, and nobody another owner or their own membership. A suspended membership counts
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
code or the key, and leaves its audit entry. A key is active from the moment it is made. A
machine that enrols a key with a code asks no one: the code is the authority and the
approval, as long as the person who made it may still make it, an owner or an admin of its
workspace, neither suspended nor removed, their account in use (`access_key.create_code`,
asked again of their membership as it is at the enrolment); the key's arrival is an entry
of `access_key.add` by the key itself, `arrived_by` `code`. Deleting a
node (`node.delete`, owners and admins) revokes its keys in the same transaction, each with
its entry of `access_key.revoke`. Everyone in the workspace reads the nodes (`node.read`),
and a page shows a node's keys under it.

## Leaving

Anyone with a membership may remove their own, whatever their level: leaving the
organisation is `member.remove` of their own membership, which the module allows beside
its role table (`Apiary.Access.own/0`). The last-owner rule still holds, so the last owner
who may act cannot leave.

## Features

The feature an action belongs to is asked first, of `Apiary.Features.on?/2` with the
scope, and a feature that is off is `{:error, :not_found}`: absent, as a feature the
instance lacks. What an organisation, or a workspace of it, has is `Apiary.Features.of/2`,
the one answer ([architecture.md](architecture.md), Features): in the core the instance's
features, in every organisation and workspace alike; an edition may narrow them below the
instance, and never adds to them. The scope carries them:
`Apiary.Organisations.resolve_scope/4` loads them with the organisation and the
workspace, and `reload/2` reads them again after its locks, so what an edition changes of
them under the organisation's lock is waited for, or seen. An access key's are read from
its organisation and workspace when asked.

## Who asks

A **scope** is who asks: a person with the membership in the organisation the page's path
names, the workspace it names and what the edition says of their place there, an access
key at the server contract, or **the instance**, in a job no person enqueued
(`Apiary.Accounts.Scope.for_instance/2`, which `Apiary.Job` gives such a job). The
instance has a role of its own in the role table, with only what its jobs need: pruning
the audit trail, deleting the invitations expired for 30 days, and purging a workspace or
an organisation whose deletion's grace period is over. Any other scope without a person
may nothing, whatever it carries.

An action taken on the strength of something other than a role, signing up, accepting an
invitation with its token, or a release command run on the release's machine, is in the
action list too, so the audit trail can name it: the context function checks the sign-up
or the token, and asks nothing; whoever runs a release command controls the instance
already. No role of the core has these. A sign-up's `organisation.create` is one: the
account it creates does not exist until it commits; an edition may give the action to a
role of its own, for an organisation created another way. Deleting one's own account is
no action at all: an account belongs to no organisation, and the account page asks for a
recent sign-in instead.

The subject is what is acted on, with one exception: deleting a workspace and cancelling
its deletion are asked of the organisation, from its settings, where an owner or an admin
deletes any workspace of it; the scope's own workspace is whichever the page opened.

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
asked on the row locked for it after the core's own refusals, and is told of each
marking, cancelling and purge inside the transaction that makes it
(`c:Apiary.Edition.deletion_changed/4`).

## The context function asks before it acts

Every context function that changes something calls `Apiary.Access.authorize/3` with its
action and the subject first, and returns what it answers:

- `{:error, :not_found}` for a feature that is off, a subject of another organisation or
  workspace, a subject of a workspace the person does not reach, and what the edition
  answers so (`c:Apiary.Edition.check/3`);
- `{:error, :forbidden}` for a role that does not allow the action, or allows it over
  other people than the subject's, and what the edition refuses so.

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

1. **Organisation rows**: the organisation's own, then the organisations an edition
   holds with it (`c:Apiary.Edition.places_to_lock/1`). Several organisations, as an
   account's deletion locks the organisations it owns
   (`Apiary.Organisations.sole_owned_organisations/2` with `lock: true`), are locked
   first those the edition holds another organisation with, then the rest, each in the
   order of their ids, so an organisation always comes before the ones it holds; with the
   core's edition, in the order of their ids.
2. **Workspace rows**, in the order of their ids where a change takes several, as a write
   of the policy of several workspaces at once does (`Apiary.Policy.lock_workspaces/2`),
   and as a change of the level an edition keeps above the workspaces' policies does
   (`c:Apiary.Edition.above_workspace/1`): it takes every workspace of the organisation,
   then renders each again (`Apiary.Policy.rerender_in/3`), or checks its variables
   against each (`Apiary.Variables.check_above/2`).
3. **Memberships**: the owners' of the organisation, in the order of their ids
   (`Apiary.Organisations.lock_owners/1`), then any other.
4. **Accounts.**
5. **Everything else**: invitations, access keys, nodes, then runs, and an edition's
   rows.

The modes keep a row that only names another out of it:

- A write that must stay allowed while it is written holds the organisation `FOR SHARE`,
  and the organisations the edition holds with it (`Apiary.Access.lock_places/1`), the
  workspace `FOR KEY SHARE`, the membership `FOR SHARE`, what the edition reads again under
  its own locks (`c:Apiary.Edition.reload/2`), then the account `FOR SHARE` (`reload/2`
  with `lock: :share`). A change that may make an owner, or counts the owners who remain,
  as a change of a level, a removal and a suspension do, holds the organisation rows
  `FOR SHARE` too, then locks the organisation's own owners' memberships `FOR UPDATE`
  (`Apiary.Organisations.lock_owners/1`).
- A change of a node's access keys or enrolment codes (`Apiary.AccessKeys`) locks the
  node's row `FOR UPDATE`, then the key's or the code's: the keys of one node take turns,
  so the limit of two keys at a time counts every change before it. An enrolment
  (`Apiary.AccessKeys.enrol/2`) first reads the membership of the code's maker again with
  `reload/2` and `lock: :share`, the organisation, workspace, membership and account rows
  before the node's, so a change of the maker's level, a suspension or a removal waits for
  it, or came first and refuses the code. Deleting a node (`Apiary.Nodes.delete_node/2`)
  holds the same row, and revokes its keys under it.
- A write of the security policy, of a stored secret (`Apiary.Secrets`), of a variable
  (`Apiary.Variables`) or of a connection (`Apiary.Connections`) holds the organisation
  `FOR SHARE` (`Apiary.Access.lock_places/1`),
  then locks its workspace's row `FOR NO KEY UPDATE`, then reads the membership again
  under `FOR SHARE` (`reload/2` with `lock: :share`): writes to one workspace take turns,
  so the checks that span its rows, a secret's data key made once, a variable's names and
  limits across the workspace and its repositories, and the overlap of the connections,
  see every write before them. A change to one secret, variable or connection then locks
  its row `FOR UPDATE`.
- A marking for deletion locks the organisation's row `FOR NO KEY UPDATE`, and a
  workspace's marking locks every workspace of the organisation in use: they wait for a
  write in flight, and one asked after them waits and then sees them. What an edition
  keeps of an organisation or an account is written under that row's lock too, and read
  by a change that holds the row in a statement after its lock: the `organisations` and
  `users` rows stay the ones to lock.
- An invitation locks the row of the organisation whose allowance it counts against
  `FOR NO KEY UPDATE` while it is counted and written: the organisation's own for
  `member.invite`, or the one an edition's invitation names
  (`Apiary.Organisations.insert_invitation/3`). A new link for a pending invitation
  (`Apiary.Organisations.renew_invitation/4`) reads the invitation without a lock to find
  the allowance it was counted against, locks that allowance's row the same way, then
  the invitation's `FOR UPDATE`; never the invitation's first. An edition's renewal
  (`action:`) runs inside its own transaction, which may hold the allowance's row already.
- An invitation's acceptance, and a sign-up with an invitation, let the edition hold the
  organisation first, more strongly if it will (`c:Apiary.Edition.accepting/3`), then hold
  it `FOR SHARE`, before the account and the invitation, so the organisation's marking,
  and what the edition holds out of use, wait for it, or came first and refuse it.
- An account's deletion holds the organisations it owns `FOR SHARE` and locks their
  owners (`sole_owned_organisations/2` with `lock: true`), then its memberships
  (`Apiary.Organisations.lock_memberships/1`), then the account `FOR NO KEY UPDATE`. An
  invitation's acceptance holds the account `FOR SHARE`, so of the two one waits for the
  other, and a deleted account never becomes a member.
- A row inserted that names an organisation or an account, an audit entry among them,
  takes `FOR KEY SHARE` of it through its foreign key, whenever it is written: that
  conflicts only with `FOR UPDATE`, which nothing takes of an organisation or an account
  but a change of a key: the purge's deletion of the row, an account's tombstone, and a
  change an edition locks so, first and alone.

- A node's instance limit is checked under the node's row, `FOR UPDATE`
  (`Apiary.Nodes.check_instance_limit/3`), before the batch that would create a run
  locks the run's row: two starts for a node's last slot take turns, and the second
  counts the first's run and is refused. Clearing an instance (`node.clear_instance`)
  locks the node's row the same way before it marks the instance's runs lost, so a
  clearing and a start take turns too. Nothing locks a run and then its node. A node's
  changes (`node.*`) are owners' and admins' and ask `authorize/3` without holding the
  organisation, as a rename does.

A few changes lock rows below an organisation without its row first: an account's
deletion locks its memberships in organisations it does not own, and a workspace's
deletion locks the organisation's workspaces. None of them then takes an organisation
`FOR UPDATE`, so none can close a cycle.

A change that asks `authorize/3` without holding the organisation, such as a rename or an
access key, reads the membership and the suspension without a lock, and can commit just
after a suspension, a demotion or a marking that began after its answer. Only the writes
that must stay allowed while they are written, the policy's and the ones above, hold the
organisation.

The races are tested outside the sandbox, on connections that commit
(`test/apiary/access_races_test.exs`, `deletion_races_test.exs`,
`sign_up_races_test.exs`, `suspension_races_test.exs`, `nodes_races_test.exs`).

## The page asks the same question

- A page shows a button, a link or a tab by `Apiary.Access.can?/3` with the same action as
  the function behind it, so the two cannot disagree. `can?/3` answers from the scope as
  loaded, with no database read, and is cheap on every render.
- A page that reads asks its read action on mount, `on_mount {ApiaryWeb.Access, action}`,
  after the path scope and the feature gate, and answers not found when refused.
