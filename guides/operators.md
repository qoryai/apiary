# Operators

This guide covers operators, with the `managed_organisations` feature: what an operator is,
what its people reach, and which features it has.

<!-- feature: managed_organisations -->
## The feature

`managed_organisations` is a feature, shown as Operators: operators, and the workspaces
of other organisations they operate. Support turns it on for an organisation. It needs
`observability`.

## Operators

An operator is an organisation whose people reach the workspaces it operates in other
organisations. A workspace has one operator at most. Everything else an operator does, it
does as any organisation.

Support makes an organisation an operator, or creates one, and makes an operator an
organisation again. An organisation with a workspace that has an operator is not made an
operator, and an operator that operates a workspace is not made an organisation. Neither
an operator that operates a workspace nor a workspace with an operator is deleted.

## What the operator's people reach

Every person of the operator, owner, admin or member, reads everything in each workspace
it operates, the runs and their terminals and the security policy among them, except the
workspace's secrets and variables. They change nothing there. They reach nothing the
organisation has as a whole: its people, its policy, its secrets and variables, its
connections and its other workspaces. Their level in the operator matters only inside the
operator.

Someone who is in the operator and also a member of the organisation changes what their
membership in the organisation allows, and reads the rest of the workspace.

The organisation menu of the operator's people lists each workspace the operator operates,
under its organisation.

A suspended operator is read-only, and its people do not reach the workspaces it
operates. Those workspaces keep running, with their runs, access keys and people, until
the operator is activated.

## Features of an operator

Of the features a grant can name, an operator has only those support grants it. A feature
a grant can name, added to Qory Apiary later, reaches no operator until it is granted.
Every other organisation has the features of Qory Apiary but those support takes away. A
workspace shows the features of its organisation, to the people of its operator too.

An organisation made an operator is granted what it had. An operator keeps
`managed_organisations` until it is made an organisation again, which it is only once it
operates no workspace; its features page does not take it away.
<!-- /feature -->
