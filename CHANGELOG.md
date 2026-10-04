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
  server. Its rules are hosts and paths; credentials are not part of it, and the run
  configuration selects none of a machine's. An edition may keep a level above it (`c:Apiary.Edition.above_workspace/1`,
  an `Apiary.Policy.Above`; the core keeps none): its denies hold everywhere, its allows
  reach every workspace and can be narrowed, never widened, it may require enforce
  (then `Apiary.Policy.set_mode/3` refuses with `:fixed`) and may allow only its own
  hosts; the pages list its rules first and link to where it is changed
  (`c:ApiaryWeb.Edition.above_policy_link/1`), and a change of it renders every
  workspace again (`Apiary.Policy.rerender_in/3`, an `above_changed` change in each
  workspace's history).
- Nodes and node pools, the places a workspace's runs run: a node is one permanent
  machine that runs one instance at a time, a node pool a fleet of short-lived instances
  up to its instance limit, or any number without one; the kind is fixed when one is
  made. Owners and admins add them, rename them, change a pool's limit and delete them
  (`node.create`, `node.edit`, `node.delete`, each in the audit trail); everyone in the
  workspace reads them (`node.read`). The list is at `/:org/:workspace/nodes`, with New
  node and New node pool, and each node has a page with Overview and Settings.
- Access keys of nodes, beside today's keys: each holds one Ed25519 public key and belongs
  to one node or node pool, with its stored-secrets flag fixed when it is made. Owners and
  admins make single-use enrolment codes, valid for 15 minutes, add a pasted key, approved
  at once, approve or reject a key that awaits approval, and revoke one, each in the audit
  trail; a node holds at most two approved keys and one awaiting approval, and deleting a
  node revokes its keys. Every public key received passes the contract's key checks, and
  a public key serves one access key, ever, on the instance. Each key's row carries an
  integrity code, checked before the key is trusted. Revoking today's keys is now the
  action `access_key.revoke_secret_key`; nothing else about them changes.
- A node's instances: what a runner using the node's access key reports itself as, a
  claim kept for display, the audit and the instance limit, never for authorisation. An
  instance runs while it has a run the lost-run check holds alive. The Nodes list says
  each node's state ("Running", "3 of 10 running", "Last seen", "Never seen"), with the
  views All, Running and Not running, Sort by name or last seen, and a pool's running
  instances under it; a node's Overview shows its instance or a pool's running
  instances, the starts refused at the limit, and its recent runs. Owners and admins
  clear an instance that stopped without saying so (`node.clear_instance`, audited): its
  open runs are marked lost and another instance can start at once. The runs list takes
  `node:` and has a Node column from 1300 px; the run page says a run's node and
  instance. The receiving side records none yet: runs and deliveries name a node and an
  instance once access keys name their node and requests carry the instance id, and the
  instance limit is enforced at the ping from then.
- Access keys, created, rotated and revoked in the console; members at the levels owner,
  admin and member, and the suspension of a member.
- The audit trail of every change, in the organisation's settings, under Audit log; retention of a
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
- Every form answers a field that is wrong under it, in the page's words, and never with
  the browser's own bubble: the log-in form says an address cannot be one before it
  sends a link, and still says the same of an address with an account and one without.
- The features an instance has, switched at launch (`QORY_FEATURES`), and the guides and
  module reference every instance serves at `/docs`.
- Stored secrets and variables, kept for the runs: a workspace's
  secrets (`Apiary.Secrets`), each with one value or several, each of those with a value
  ID, written once and never shown again, and not deleted while something uses them; and
  the variables of a workspace and of each repository (`Apiary.Variables`), which the
  workspace may lock against its repositories, with names compared without case, names
  beginning `QORY_` refused, and at most 128 names and 64 KiB for each repository. Who
  may read and change them are the actions `secret.read`, `secret.write`, `secret.use`,
  `variable.read` and `variable.edit`, and every change is in the audit trail by name,
  never by value.
- The workspace's settings have **Secrets and variables**, with the security feature: a
  view of the secrets, by name, value ID, who changed each value and when, and what uses
  it, never a value, with New secret, Add value, Change value, Rename value, Delete value
  and Delete secret; and a view of the variables, each with its value, its lock and the
  repositories that set their own, with New variable, Change value, Lock, Unlock and
  Delete variable. Members read them; owners and admins change them. A parameter named
  `value` is filtered out of the logs, a LiveView event's included.
- `APIARY_ENCRYPTION_SECRET`, 32 bytes, encrypts what the database holds secret: the
  access key secrets, and each workspace's stored values under a data key of its own,
  with AES-256-GCM, wrapped by a key derived from it. Losing it loses every stored
  value. Integrity codes for stored rows are keyed from it as well.
- Runtimes, integrations and services for the runs, without a page yet
  (`Apiary.Connections`, `Apiary.Integrations`): a runtime of the runner contract's
  catalogue; an integration added from a release on GitHub, GitLab or Forgejo, or at an
  https address of its `description.json`, which a job fetches and checks against the
  release's `checksums.txt` and the integrations contract; a service from a built-in
  definition or one the workspace writes. Each applies to every repository or to chosen
  ones, an integration in the ways chosen per repository, and two that would collide on a
  repository are refused. The fetch connects only to public addresses, checked again on
  every redirect, within size and time limits, with no token sent to a self-hosted host;
  `INTEGRATION_PRIVATE_HOSTS` names the hosts that may resolve to private addresses. Who
  may read and change them are the actions `connection.read` and `connection.write`, every
  change is in the audit trail, and each row carries an integrity code.

### Migrations

The baseline, on an empty database: the accounts and their tokens (`users`,
`users_tokens`), `organisations`, `workspaces`, `memberships`, `invitations`,
`access_keys`, `targets`, `runs`, the record (`events`, `log_chunks`, `connections`,
`deliveries`), the security policy (`policy_rules`, `run_configurations`),
`retention_runs`, `audit_entries`, the stored secrets (`workspace_data_keys`, `secrets`,
`secret_values`), `variables`, the connections (`integration_releases`,
`service_definitions`, `workspace_connections`, `connection_targets`), the instance's own tables (`purged_organisations`,
`instance_settings`) and Oban's.

`nodes`: a workspace's nodes and node pools, with the trigger `nodes_kind_fixed`, which
refuses a change of a node's kind; `nodes.instance_ids_over_bound` and its time.

`node_instances`: a node's instances. `runs.node_id` and `runs.instance_id`,
`deliveries.instance_id`, all NULL for every existing row; the indexes
`runs_node_id_instance_id_alive_index` and `runs_workspace_id_node_id_started_index`,
created concurrently.

`access_keys` gains a node's key's columns (`node_id`, `public_key`, `received_at`,
`approved_at`, `approved_by_id`, `allow_secrets`, `rate`, `burst`, `arrived_by`,
`enrolment_code_id`, `revoked_by_id`, `integrity_code`, `integrity_key_id`,
`last_pending_at`), its secret becomes nullable for a node's key, and the trigger
`access_keys_fixed_at_insert` refuses a change of a key's node, public key, stored-secrets
flag or arrival. New: `access_key_enrolment_codes`, a node's enrolment codes, and
`access_key_public_keys`, the instance's ledger of public keys.

### Upgrading

Nothing to upgrade from: this is the first release. Install it on an empty database.
