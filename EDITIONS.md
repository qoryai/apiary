# Editions

Qory Apiary comes in a free edition, which is this repository, and in paid editions, which
8wonders GmbH, the company behind Qory, licenses. Every paid edition is the same Qory
Apiary: the free edition's code, with more added to it, in one image.

**Nothing in the free edition will ever move to a paid one.**

## The free edition

Apache License 2.0, this repository, self-hosted. It is complete for one team:

- **One organisation and one workspace.** The first person to sign up creates the
  instance's organisation, with its workspace Main, and is its owner. Everyone after joins
  it by invitation.
- **The record.** Every run of every machine of the workspace: the session as a timeline,
  the terminal as it was written, every connection with the decision and the rule behind
  it, and how the run ended.
- **The wall and the policy.** The runner's proxy records each connection and decides it
  by the workspace's policy; behind a wall it is the session's only way out. The policy
  observes or enforces, with rules per repository, locked rules and a history with a diff.
- **Nodes and their access keys.** A node is one machine, a node pool a fleet of
  short-lived instances. A machine makes its own Ed25519 key and enrols it with a code
  from its node, or an owner or admin generates a key in the browser; a key is active as
  soon as it arrives, and revoked in the console.
- **Members and their levels.** Owners, admins and members, invited by email address.
- **Suspension of a member.** An owner or an admin stops a person acting in the
  organisation, and activates them again; nothing is removed.
- **The audit trail and the Activity page.** Every change to what the organisation holds,
  who made it, when and from where.
- **Deletion.** A workspace or an organisation is marked for deletion first, and purged
  after a grace period.
- **The docs.** The guides and the module reference, served by every instance at `/docs`.

## Pro

Pro adds, for a company that runs Qory Apiary for more than one team:

- more organisations and more workspaces;
- per-member workspace access: a member reaches the workspaces they are added to;
- narrowing features per workspace;
- the Admin area, where the instance's admins manage the organisations, accounts and
  features of the instance.

## Operator

Operator adds, for a company that provides a harness its clients run on Qory Apiary:

- operators and their clients: an operator creates its clients and reads everything in
  them, to support its harness, and changes nothing there;
- policy requests: an operator asks its clients for the changes to their security policy
  its harness needs, and each client answers;
- features granted down the chain, from the instance to the operator and from the operator
  to its clients.
