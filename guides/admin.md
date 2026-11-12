# Instance admins

This guide is for the instance admins: the owners of the instance's organisation, the one
made when the instance was set up with its set-up link. The Install guide says who they
are, how the release commands `Apiary.Release.grant_instance_admin/2` and
`revoke_instance_admin/1` make and unmake one, and what an owner does inside an
organisation. This guide covers sign-up beyond invitations, **Instance settings** and what
the instance admins do there, a client's first invitation without mail, rendering the
organisations' policies again, the grace period of a deletion, purging an organisation at
once on an erasure request, and what becomes of an instance upgraded from a release
without operators.

<!-- feature: organisation_variables -->
It covers organisation secrets and variables without their feature too.
<!-- /feature -->

## Sign-up

An instance admin opens or closes sign-up on Instance settings › Configuration, under
Sign-up, and a change applies at once. Both settings are **closed** by default.
`SIGNUP_ORGANISATIONS` and `SIGNUP_OPERATORS`, set and not empty, override the page, which
then shows them read only:

| Variable | Required or default | Meaning and accepted values |
|---|---|---|
| `SIGNUP_ORGANISATIONS` | `closed` | Whether someone without an invitation may sign up and create an organisation, to work in, and whether someone signed in may create another from the organisation switcher: `open` or `closed`. Not set, or empty, the page's setting applies. |
| `SIGNUP_OPERATORS` | `closed` | Whether someone without an invitation may sign up and create an operator, an organisation that provides a harness its clients run, and whether someone signed in may create one from the organisation switcher: `open` or `closed`. Not set, or empty, the page's setting applies. |

The instance owner is made by its set-up link, which the instance writes to
its log at each start until the link is used, or from a shell, whatever the two settings
say, as the Install guide describes
([Set up a new instance](install.md#set-up-a-new-instance)). Nobody signs up before then:
the sign-up and log-in pages say "This Qory Apiary is not set up yet: use the set-up link
from its install."
<!-- feature: managed_organisations -->
On an instance with `managed_organisations` it is an operator from the start, so its
owners may create clients at once; without the feature it is an organisation like any
other. An instance admin changes its kind under Instance settings › Organisations as any other
organisation's.
<!-- /feature -->

After set-up, both settings are `closed` unless you open them on Instance settings ›
Configuration: the release cannot tell an instance you host for your colleagues from one
you host for others, so nobody else signs up until you decide. With both closed, the
sign-up page says sign-up is by invitation, and the landing and log-in pages offer none;
people join through an invitation from an owner or an admin of an organisation. With one
open, a sign-up creates that kind, and the page asks nothing about it. With both open, the
page asks which. There is no waiting list: a sign-up the instance allows is working at
once, and one it does not allow is not offered. Someone with an invitation signs up
whatever the settings say, and joins the organisation that invited them. An organisation
created by a sign-up sees nothing of any other.

Until the instance has mail ([Mail](install.md#mail)), a sign-up asks for a password and
signs the person in at once, and an invitation gives a link to copy and send yourself. It
is shown once; **Make a new link** on the pending invitation replaces a lost one, and the
old link stops working. A forgotten password is a password link: an instance admin makes
one under Instance settings › Accounts for any other account, except a suspended one
([Instance settings](#instance-settings)), and whoever has a shell on the release prints
one for any account with `Apiary.Release.password_link/1`, as the Install guide
says. Once the instance has mail, a sign-up and an invitation send their link by email, a
log-in link is the way in, and a password stays the other.

The same two settings decide what people who are signed in already may start. Where one is
open, the organisation menu in the top bar (the chevron beside the organisation) ends with **New
organisation**, and their organisations page offers it too: anybody signed in, whatever their level where
they are and whether they came by invitation or not, creates an organisation of the open
kind, or of the kind they choose when both are, and is its first owner. As after a sign-up,
the organisation has no workspace yet: the person is taken to its overview, where
the kind cards create its first workspace. With both closed the entry is not there, and nobody
but the instance admins, under Instance settings › Organisations, creates an organisation.
<!-- feature: managed_organisations -->
The one exception is an operator's clients, which its owners and admins create on its
**Clients** page ([Operators and their clients](operators.md)).
<!-- /feature -->
Opening sign-up of organisations on an instance you host for your colleagues
therefore lets them start organisations too.

Each organisation has a separate allowance of the invitations a day the instance allows,
on Instance settings › Configuration or by `INVITATIONS_PER_DAY`, as the Install
guide says, however the organisation was created.

A value of `SIGNUP_ORGANISATIONS` or `SIGNUP_OPERATORS` these do not accept stops the
boot. `SIGNUP_ORGANISATIONS` is checked first, and a wrong `SIGNUP_OPERATORS` is reported
the same way:

```text
environment variable SIGNUP_ORGANISATIONS is not valid: it is open or closed, got: "yes".
Leave it unset for closed, or set it, for example:
SIGNUP_ORGANISATIONS=open
```

## Instance settings

The instance admins have separate pages, **Instance settings**, in the Qory Apiary menu:
General, then Organisations and Accounts, then the other sections, with Mail and
Configuration last. **Organisations**, `/instance/organisations`, lists every organisation
on the instance, with its slug, its kind, its operator, its features and its status: in
use, suspended, without an owner who may act, or deleted, with the day it is purged.
**Accounts**, `/instance/accounts`, lists every account, with how many organisations it is
in and whether it is suspended. Instance settings' former addresses, under the instance's
organisation (`/<its slug>/instance`), lead there.

While the instance has no mail, an instance admin makes a password link on Accounts,
with **Make a password link** in the ⋯ menu of the account's row, for any other account,
except a suspended one: a client's owner or a member of any organisation, as well
as a person of the instance's organisation, whose People page offers it too. It needs a
recent sign-in, as **Account** settings do: an admin who signed in more than 20 minutes
ago logs in again first. The page shows the link once, to copy and send to the person; it
works once, for 24 hours, a new one ends the one before, and each is an entry in the
instance's organisation's activity. Once mail is set, by the test link of **Mail** or a
start with `SMTP_RELAY`, every such link ends, and the menu has no such item: the person
asks for a log-in link on the log-in page.

On **Mail**, `/instance/mail`, an instance admin sets the instance's mail; with
`SMTP_RELAY` set, the environment wins, and the page shows it read only
([Mail](install.md#mail)).

On **Configuration**, `/instance/configuration`, an instance admin opens or closes
sign-up, under Sign-up, and it applies at once; a `SIGNUP_*` variable that is set and not
empty wins, and the page shows it read only.

On Organisations the instance admins create an organisation, of which they are the first
owner; they invite its people, make one of them an owner and leave from its Organisation
settings › People, and Organisations reminds them while they are its only owner, with **Invite an
owner** leading there. They purge an organisation at once on an erasure request
([Purging at once](#purging-at-once-on-an-erasure-request)). The instance
owner is offered neither, and is never purged.
<!-- feature: managed_organisations -->
They also make an organisation an operator there, or create one, and make an operator
without clients an organisation again, the instance owner as any other
([Operators and their clients](operators.md)).
<!-- /feature -->

An instance admin opens any other organisation from there and reads everything in it, its
runs, terminals, policy, members and activity, and changes nothing in it. The instance's
organisation's admins and members see no such page; they reach that organisation, at their
level, and nothing beyond.
<!-- feature: managed_organisations -->
Once it is an operator, they read its clients as any operator's people read theirs.
<!-- /feature -->

## Suspending and activating

**Suspending** pauses and removes nothing, and **Activate** undoes it; each is an entry in
the activity. Under Instance settings › Accounts an instance admin suspends another person's
account: it signs in nowhere, and is told so, with no reason given, once its password or
log-in link has shown it is theirs, and its open pages are closed. Before it is suspended,
the page names the organisations it would leave without an owner who may act. **The
access keys it added keep working**: an access key belongs to its machine, not to a person,
so an owner or an admin revokes it on the machine's **Access key** tab if it should stop.

An instance admin also suspends an organisation or an operator, never the instance owner:
it becomes read-only, its people sign in and read everything under a notice and change
nothing, it sends no invitation and accepts none, and its access keys are refused as
revoked ones are, so no run starts or reports there. Inside an organisation, an owner
still suspends an admin or a member in Organisation settings › People, and an admin a member, as the
Install guide says.

The last owner of an organisation who may act is not suspended there, and the last
instance admin's account is not suspended at all; should every instance admin be locked
out, `Apiary.Release.grant_instance_admin/2` is the way back.

## Transfer ownership

An instance admin who suspends the account of an organisation's only owner, an operator's
client as any other, leaves it without an owner who may act: its admins and members work,
its runs continue, and what only an owner does waits, until the owner is activated again
or an instance admin offers the ownership to one of its admins with **Transfer ownership**
under Instance settings › Organisations, giving a reason. Every page of the organisation tells the admin of
the offer, and they accept it on **Ownership** in the organisation's settings and
become an owner; a client stays its operator's. This is the only transfer of ownership an
instance admin makes, and the offer lapses once one of the organisation's owners may act
again.

## Features

Below the instance, an instance admin may take features away from an organisation, with
**Features** under Instance settings › Organisations: it has what the instance has, a
feature the instance gains included, but what is taken away. The instance owner has every
feature the instance has. A workspace has its organisation's features: what is taken away
is not shown to its people, in the organisation and its workspaces, and still works for
its machines: its runs are recorded and served their policy. The documentation at `/docs`,
the sign-in page and the landing page follow the instance only.
<!-- feature: managed_organisations -->
Of the features a grant can name, an operator other than the instance owner, and every
client, have only what is granted to them ([Operators and their clients](operators.md)).
<!-- /feature -->
<!-- feature: organisation_policy -->
`organisation_policy`, the organisation's policy above its workspaces'
([The organisation's policy](organisation-policy.md)), needs `security`, and is granted
like the others.
<!-- /feature -->
<!-- feature: organisation_variables -->
`organisation_variables`, the organisation's secrets beside its workspaces' secrets and
its variables above its workspaces' variables
([The organisation's secrets](organisation-secrets.md),
[The organisation's variables](organisation-variables.md)), needs `security` and
`secrets`, and is granted like the others.
<!-- /feature -->

<!-- feature: managed_organisations -->
## Operators: a client's first invitation without mail

This section is for operators and their clients ([Operators and their
clients](operators.md)). Until the instance has mail, nothing is emailed when an operator
creates a client: the Clients page shows the invitation's link once, to copy and send
yourself, and while it is pending, **Make a new link** in the client's row menu replaces a
lost one, and the old link stops working. Once the instance has mail, the invitation is
emailed. The invitation of a client's first owner, emailed or copied, and each new link
made for it, count against the operator's allowance of invitations a day.
<!-- /feature -->
<!-- feature: organisation_policy -->

## Rendering the organisations' policies again

To render every workspace of every organisation that has a policy again, as when a
workspace's documents were rendered without it, run `bin/apiary eval
"ApiaryPro.Release.render_organisation_policies()"`. It renders the unmanaged workspaces
too, writes nothing where a workspace's documents already say what they should, and is
safe to run again. It does nothing where the instance does not have `organisation_policy`.
`Apiary.Release.policy_rerender()` renders only the workspaces that serve a
document ([The organisation's policy](organisation-policy.md)).
<!-- /feature -->
<!-- feature: organisation_variables -->

## Organisation secrets and variables without the feature

This section is about the feature `organisation_variables`, which holds the organisation's
secrets and variables ([The organisation's secrets](organisation-secrets.md), [The
organisation's variables](organisation-variables.md)). Where the instance does not have
it, the organisation's secrets are given to no run: a link to one stays, but does not work
until the instance has the feature again.

Where the instance does not have `organisation_variables`, the organisation's variables
reach no workspace, and a workspace's changes are not checked against them. When the
instance has the feature again, as when `QORY_FEATURES` changes at a restart, nothing is
checked: a workspace may then spell a name of the organisation's otherwise, or be over a
limit with the organisation's variables. The organisation's next change to its variables,
but the deletion of one that is not locked, is then refused, naming the workspace, until
the workspace changes or deletes its variable.
<!-- /feature -->

## Deleting an organisation: the grace period

An owner deletes an organisation ([Workspaces and deleting an
organisation](organisations.md#deleting-an-organisation)), and a job purges it once its
grace period is over. The instance's grace period is set on Instance settings ›
Configuration or by `DELETION_GRACE_DAYS`, as the Install guide says. The grace
period is not 0 days, since a deletion must be restorable, and not more than 90, since an
organisation that leaves is owed its deletion. The instance organisation is never deleted.

A purge does not reach the backups taken before it: those hold the data until they expire,
so how long you keep dumps bounds how long a deletion takes to be complete.

## Purging at once on an erasure request

An organisation that asks in writing for its data to be erased need not wait for the grace
period. An instance admin purges it with **Purge now** under Instance settings › Organisations, typing its
slug; whoever has a shell on the release does the same with a command, given the
organisation's slug or id and the email address of the instance admin who asks:

```sh
bin/apiary eval 'ApiaryPro.Release.purge_now("acme", "admin@qory.example")'
```

It marks the organisation for deletion when it is not marked yet, ends its grace period at
once and purges it for good. The row the instance keeps says it was an erasure request, and
by whom. The address must be an instance admin's account. It refuses the instance
owner,
<!-- feature: managed_organisations -->
and an operator that still has clients, each of which is deleted first,
<!-- /feature -->
and says what it did. Should it stop half way, running it again goes on where it stopped.

## An instance upgraded from a release without operators

An instance set up with a release without operators, such as Qory Apiary 0.1.0 or a
build of `main` from before them, is adopted the first time a later release migrates its
database, at boot or with `bin/migrate`, in one transaction that is safe to run again.
Every organisation becomes one with no operator, not suspended, and the instance
organisation of the earlier release becomes the instance owner, so its owners stay the
instance admins; it stays an organisation, and becomes an operator only if an instance
admin makes it one. In the earlier release every member reaches every workspace, so each
member of an adopted organisation is added to each of its workspaces, and nobody loses
what they reached. Each adopted organisation has one entry of it in its activity, by the
instance.

To go back, deploy the previous image ([Upgrading](upgrading.md#rolling-back)). The
tables the upgrade added stay in place. On the previous image, these stop taking effect
until the next upgrade:

- suspensions of accounts and organisations: a suspended account signs in again, and a
  suspended organisation is no longer read-only;
- workspace access: each member reaches every workspace of their organisation again;
<!-- feature: organisation_policy -->
- each organisation's policy;
<!-- /feature -->
<!-- feature: organisation_variables -->
- each organisation's secrets and variables;
<!-- /feature -->
<!-- feature: managed_organisations -->
- the relationships between operators and their clients;
<!-- /feature -->
- the features an instance admin took away from an organisation or granted to it: every
  organisation has every feature the instance has.

A member added to an adopted organisation while the previous image runs gets no
workspace access at the next upgrade, because the adoption covers only organisations it
has not adopted. They reach no workspace until they are added to one.
