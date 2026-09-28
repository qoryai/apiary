# Changelog

Every release of Qory Apiary, newest first, in the shape of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version numbers follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0 a minor release may
change what an existing installation does, and says so under Upgrading. Every section names
the database migrations the release runs on boot, so a self-hoster knows what a restart
does before doing it (the Upgrading guide, `guides/upgrading.md`).

## [Unreleased]

The first release of the open core of Qory Apiary, to be 0.1.0: the free edition, complete
for one team, as `EDITIONS.md` at the root of the repository describes it.

### Added

- One organisation and one workspace. The first person to sign up on a new instance
  creates the instance's organisation, with its workspace Main, and is its owner; everyone
  after joins it by invitation, which `INVITATIONS_PER_DAY` bounds. The release commands
  `Apiary.Release.grant_instance_admin/2` and `revoke_instance_admin/1` claim a new
  instance and change its admins.
- The record of every run, reported by the runner over the server contract (version 1,
  revision 1: discovery, events and the run configuration): the session as a timeline,
  the terminal, every connection with its decision and rule, and how the run ended.
- The security policy of a workspace: a baseline and rules per repository, observe or
  enforce, locked rules, a history with a diff, and an export for a machine without a
  server.
- Access keys, created, rotated and revoked in the console; members at the levels owner,
  admin and member, and the suspension of a member.
- The audit trail of every change, on the organisation's Activity page; retention of a
  run's events and log output, set per workspace; deletion of a workspace or an
  organisation, marked first and purged after a grace period.
- The features an instance has, switched at launch (`QORY_FEATURES`), and the guides and
  module reference every instance serves at `/docs`.

### Migrations

The baseline, on an empty database: the accounts and their tokens (`users`,
`users_tokens`), `organisations`, `workspaces`, `memberships`, `invitations`,
`access_keys`, `targets`, `runs`, the record (`events`, `log_chunks`, `connections`,
`deliveries`), the security policy (`policy_rules`, `run_configurations`),
`retention_runs`, `audit_entries`, the instance's own tables (`purged_organisations`,
`instance_settings`) and Oban's.

### Upgrading

Nothing to upgrade from: this is the first release. Install it on an empty database.
