# Operators and their clients

This guide covers operators and their clients, with the `managed_organisations` feature:
what an operator is, how it reaches its clients, and which features each has.

<!-- feature: managed_organisations -->
## The feature

`managed_organisations` is a feature, shown as Operators: operators, and the workspaces
of other organisations they operate. Support turns it on for an organisation. It needs
`observability`.

## Operators

An operator provides a ready harness, its agents, skills and workflows. Its clients run
the harness of the operator; the operator keeps it working and debugs it, and does not
manage its clients' people. Support makes an organisation an operator, or creates one, and
makes an operator without clients an organisation again.

## Clients

A client's owners and admins invite and manage its people, its settings and its
security policy, as in any organisation. An operator with clients is not deleted until
each client is purged.

Each organisation has a separate daily allowance of invitations, an operator's client as
any other.

## What the operator's people read

Every person of the operator, owner, admin or member, reads everything in each of its
clients: every workspace, the runs and their terminals, the security policy, the members
and the activity. They change nothing there, the policy included; their level in the
operator matters only inside the operator. Someone who is in the operator and also a member
of the client changes what their membership in the client allows, and reads the rest.

## Each side sees the other

A client's people see its operator on Ownership in its settings, and
"Operated by" it in its Organisation settings › People.

A suspended operator is read-only and its people no longer read its clients, which keep
running, with their runs, access keys, owners, admins and members, until it is activated.

## Features of an operator

Of the features a grant can name, an operator has only those support grants it. A feature
a grant can name, added to Qory Apiary later, reaches no operator until it is granted.
Every other organisation has the features of Qory Apiary but those support takes away. A
workspace shows the features of its organisation, to the people of its operator too.

An organisation made an operator is granted what it had. An operator keeps
`managed_organisations` until it is made an organisation again, which it is only once it
has no clients; its features page does not take it away.
<!-- /feature -->
