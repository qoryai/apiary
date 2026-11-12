# Operators and their clients

This guide covers operators and their clients, with the `managed_organisations` feature:
what an operator is, how it creates and reaches its clients, how an organisation becomes a
client and stops being one, and which features each has.

<!-- feature: managed_organisations -->
## The feature

`managed_organisations` is a feature: operators and their clients, and what an operator
does for them. Support turns it on for an organisation. It needs `observability`.

## Operators

An operator provides a ready harness, its agents, skills and workflows. Its clients run
the harness of the operator; the operator keeps it working and debugs it, and does not
manage its clients' people. Support makes an organisation an operator, or creates one, and
makes an operator without clients an organisation again.

## Clients

An owner or an admin of the operator creates its clients on its **Clients** page, each
with a name and the email address of its first owner: each is a separate organisation,
with no workspace yet, and the person who accepts that invitation becomes its owner and
creates its first workspace from the kind cards on its overview; any other invitation
there, as anywhere, makes a member. The invitation is emailed. While a client has no
owner, the Clients page invites one again, revokes an invitation of its owner, and deletes
the client, which nobody else is in; once it has an owner, it is dropped instead. From
then on the client's owners and admins invite and manage its people, its settings and its
security policy, as in any organisation. An operator with clients is not deleted until
each client is purged or dropped.

Each organisation has a separate daily allowance of invitations, an operator's client as
any other. The one exception is the invitation of a client's first owner: it counts
against the operator's allowance, so creating clients does not multiply what an operator
may invite.

## What the operator's people read

Every person of the operator, owner, admin or member, reads everything in each of its
clients: every workspace, the runs and their terminals, the security policy, the members
and the activity. They change nothing there, the policy included; their level in the
operator matters only inside the operator. Someone who is in the operator and also a member
of the client changes what their membership in the client allows, and reads the rest.
<!-- /feature -->
<!-- feature: managed_organisations, security -->
What an operator needs of a client's security policy, it asks for with a policy request
([Policy requests](policy-requests.md)).
<!-- /feature -->
<!-- feature: managed_organisations -->

## Dropping a client

An owner of the operator drops a client from the Clients page, typing the client's name to
confirm. It happens at once: the client is an organisation with no operator from then on,
which the operator's people no longer read, with its people, workspaces and policy as they
were.

Each side sees the other: the Clients page names each client, its owners and since when it
is a client; a client's people see its operator on Ownership in its settings, and
"Operated by" it in its Organisation settings › People.

A suspended operator is read-only and its people no longer read its clients, which keep
running, with their runs, access keys, owners, admins and members, until it is activated.

## Features granted down the chain

Of the features a grant can name, an operator has only those support grants it, and a
client only those its operator grants it, with **Features** on the Clients page, within
the operator's features. A feature a grant can name, added to Qory Apiary later, reaches
no operator and no client until it is granted. A client never has `managed_organisations`:
it manages no one.

An organisation made an operator is granted what it had, and a new client what its
operator has; a client that is dropped loses what the operator granted it and has what any
organisation with no operator has. An operator keeps `managed_organisations` until it is
made an organisation again, which it is only once it has no clients; its features page
does not take it away.
<!-- /feature -->
