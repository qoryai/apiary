# Editions

Qory Apiary comes as Apiary Community, which is this repository, and as Apiary Pro, which
8wonders GmbH, the company behind Qory, licenses. Apiary Pro is the same Qory Apiary:
Apiary Community's code, with more added to it, in one image.

**Nothing in Apiary Community will ever move to Apiary Pro.**

## Apiary Community

Apache License 2.0, this repository, self-hosted. It is complete for one team:

- **One organisation and one workspace.** The person who sets a new instance up, with the
  set-up link its log gives, creates the instance's organisation, with its workspace Main,
  and is its owner. Everyone after joins it by invitation.
- **Mail is optional.** Without it, people sign in with a password, and invitations and
  password links are copied by hand; with an SMTP relay, Qory Apiary emails log-in links
  and invitations.
- **The record.** Every run of every machine of the workspace: the session as a timeline,
  the terminal as it was written, every connection with the decision and the rule behind
  it, and how the run ended.
- **The wall and the policy.** The gateway records each connection and decides it
  by the policy in force: the machine's own until its workspace's first change, then the
  workspace's, narrowed by the machine's own; behind a wall it is the session's only way
  out. The policy observes or enforces, with rules per repository, locked rules and a history with a diff.
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
- **The docs.** The guides and the release notes, served by every instance at `/docs`, and
  the module reference, served by an instance with every feature.

## Apiary Pro

Apiary Pro adds, for a company that runs Qory Apiary for more than one team:

- more organisations and more workspaces;
- per-member workspace access: a member reaches the workspaces they are added to;
- narrowing features per workspace;
- the Admin area, where the instance's admins manage the organisations, accounts and
  features of the instance.

### Operator

Operator adds, for a company that provides a harness its clients run on Qory Apiary:

- operators and their clients: an operator creates its clients and reads everything in
  them, to support its harness, and changes nothing there;
- policy requests: an operator asks its clients for the changes to their security policy
  its harness needs, and each client answers;
- features granted down the chain, from the instance to the operator and from the operator
  to its clients.
