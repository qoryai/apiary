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
- A workspace is created by `Apiary.Organisations.create_workspace/2`, an owner's
  action, `workspace.create`, asked of the organisation: named, at a slug made from the
  name or given, empty, in observe, counted against the edition's limit of workspaces
  per organisation, which in the core is the one the organisation was made with, and
  told to the edition (`workspace_created/3`). No page of the core offers it. An
  organisation's pages open its oldest workspace where the person has opened none yet.
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
- The console's shell: a top bar that says where a page is, the organisation first, and
  switches to any organisation or workspace with a search, Search or jump to (⌘K) for
  pages, repositories, runs and places, New, which offers a workspace's page a new
  access key and an organisation's an invitation, and a sidebar of the page's workspace,
  organisation or account, which folds to icons, with the Qory Apiary menu (docs,
  changelog, source, version) at its foot. A workspace's settings, an organisation's and
  your own are each a place of their own with their own sections, GitHub's way, and
  deleting a workspace, an organisation or your account is the danger zone at the end of
  its General page or Profile.
  Pages start at one left edge and use the width of the screen: lists up to 1680 px, a
  run's page all of it, forms 720 px.
- The runs list as a record read by filters, not groups: views (All, Alive, Ended badly,
  With denials) with their counts, one filter field that takes qualifiers (`repo:`,
  `state:`, `started:>2026-09-01` and more) and free text, one Filter menu, sorting, the
  repositories beside the list with their runs from 1280 px, pages of 25 to 100 with a
  jump to a date, and from 1920 px a preview of the run chosen with the end of its log.
- Network access, in the sidebar's Guard beside the Policy (`/:org/:workspace/network`,
  and a tab of each run and each repository): every destination the runs reached, what
  decided it, and Allow or Deny from its row, narrowed the same way as the runs. Its
  rows are one line each, the denied number the one red, with the actions on hover and
  in a ⋯ menu. The policy's host rules are its Network access section, which links back
  to it. The page was called Connections; its old paths send on to the new ones.
- The policy's rules on the same list pattern, however long the list grows: views (All,
  Allowed, Denied, Locked) with their counts, "Find a host" with `seen:`, `paths:` and
  `by:` as tokens, one Filter menu, Sort, Add rule opening the composer over the list, and
  pages of 50, every choice in the address. A repository's Policy tab is its effective
  policy on that list, each rule with its source: its own first, changed there; the
  workspace's read there and changed on the workspace's page, which their menu leads to;
  what is not in force struck through, saying why. Its mode is one line: Follow the
  workspace, Observe or Enforce, and whose the mode is.
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
