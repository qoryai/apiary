# Changelog

Every release of Qory Apiary, newest first, in the shape of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version numbers follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0 a minor release may
change what an existing installation does, and says so under Upgrading. Every section
says what the database migrations the release runs on boot do, so a self-hoster knows what a
restart does before doing it (the Upgrading guide, `guides/upgrading.md`).

## [Unreleased]

The first release of the open core of Qory Apiary: the free edition, complete for one
team, as `EDITIONS.md` at the root of the repository describes it.

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
  revision 1: discovery, events, the run configuration and enrolment): the session as a
  timeline, the terminal, every connection with its decision and rule, and how the run
  ended.
- Signed requests and signed answers. Every request a runner makes names a node's access
  key and its instance and is signed with that key, Ed25519 (`X-Qory-Access-Key-Id`,
  `X-Qory-Instance-Id`, `X-Qory-Signature-Ed25519`), within 300 seconds of the server's
  clock for a GET; every answer to a verified request is signed with the server's own
  Ed25519 key, which every machine pins as `apiary_public_key`, and sent with
  `Cache-Control: no-store, no-transform`, while every `401` goes out unsigned. The
  refusals come in the contract's order, coded: a header sent twice or an instance id
  absent or malformed is `400` `bad_request` on every endpoint. Discovery names the key's node (`node_id`) and the
  server's keys (`apiary_public_key`), so its digest differs by node. The tests replay
  the contract's own fixtures at the commit `.runner-contract-ref` pins.
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
  node and New node pool, and each node has a page with Overview, Access key and
  Settings; a new node opens on its Access key tab.
- Access keys, one kind: a node's or a node pool's, each with one Ed25519 public key. The
  server never holds a key's secret, only its public half. A key is active from the
  moment it arrives until it is revoked. A node gets its key in one of two ways, both on its Access key tab, which
  asks owners and admins "How do you want to connect build-01?" while it holds no
  active key, with two equal options, each saying when to choose it, what happens and
  the same four facts (Key made, Secret, By hand, Needs), with one button (a node lists
  Connect with a command first, a pool Generate a key in the browser), and under Add a
  key, as two rows, once it holds one, with Configure a machine at the tab's foot for
  everyone: four steps, Qory Apiary's address and public key, the key's ID, and where
  its secret belongs. Connect with a command: Get the command makes, in one click, a
  single-use code valid for 15 minutes, and the page Connect build-01 with a command shows it,
  once, only inside the command `qory access-key enrol <server> <code>`, with
  `--replace` for a node that has or had a key, saying it moves the node to a new key,
  and the time it stops working; the machine makes its key, keeps its secret and posts the
  code with the new public key to `POST /.well-known/qory-enrolment`, which answers
  signed, and qory names the key after the machine's host name. The page turns, live,
  to "build-01 is connected." with the key's fingerprint, and says when the server's
  address is a loopback one that machines can't reach. A command not yet run shows on
  the tab as "A command is waiting to be run on build-01.", with Cancel the command….
  The code is the approval: the key it brings is active at once, and the code is
  refused unless its maker is still an owner or an admin of the workspace when it is
  redeemed. Generate a key in the browser: the browser makes the key (WebCrypto Ed25519, on a page
  served over HTTPS) and sends Qory Apiary its name and its public half alone; the page Key
  for the node then shows four numbered steps: store `QORY_ACCESS_KEY_SECRET` (`qak_`
  and the key's seed), shown once, from the browser's memory; set `QORY_ACCESS_KEY_ID`;
  set `QORY_APIARY_PUBLIC_KEY`; point qory at Qory Apiary, the runner file's
  `server.url`. Opened again, it says the secret is gone, and offers nothing of it to
  copy. A key's card shows its
  Key ID with Copy, how it was added ("Connected with a command by …", "Generated in a
  browser by …") and where its secret is. An active key's card opens the page Runner
  file for the key: for a key connected with a command, the runner file's `server`
  lines (`url`, `access_key_id`, `apiary_public_key`), each marked as Qory Apiary's or
  this key's; for a generated key, four numbered steps: where its secret belongs, then
  `QORY_ACCESS_KEY_ID`, `QORY_APIARY_PUBLIC_KEY` and `server.url`. The server's address
  and public key are the instance's own, the same for every organisation, workspace and
  node. A public key pasted into a node is no way to give it a key: the page that took
  one, Add a public key, was removed before the release.
  Owners and admins get and cancel commands and add and revoke keys, each in the audit
  trail; a node holds at most two keys at a time, and deleting a node revokes its keys
  and cancels its commands. Enrolment is limited per address, 1 a second and 10 at
  once, and answers in the runner contract's order: before the code is looked at, `413`
  for a body over 8 KiB,
  `415` `unsupported_media_type` for a `Content-Type` absent or not `application/json`,
  `400` `bad_request` for a `Content-Type` or `X-Qory-Contract-Version` sent twice, `429`
  over the address's limit, `400` `unsupported_contract_version` and `400`
  `invalid_request`; then `401` for a code not accepted and `409` `key_invalid` for a key
  the key checks refuse or a proof that does not verify, all unsigned; then, signed under
  `qory-enrol-answer-ed25519-v1`, `429` over the code's own limit, `409` `key_invalid`
  for a public key used before, `409` `key_limit` and `201`. Every public key received
  passes the contract's key checks, and a public key serves one access key, ever, on the
  instance. Each key's row carries an integrity code, checked before the key is trusted.
- A node's instances: what a runner using the node's access key reports itself as, a
  claim kept for display, the audit and the instance limit, never for authorisation. An
  instance runs while it has a run the lost-run check holds alive. The Nodes list says
  each node's state ("Running", "3 of 10 running", "Last seen", "Never seen"; a pool
  whose instances were pruned is last seen when its key was last used), with the
  views All, Running and Not running, Sort by name or last seen, and a pool's running
  instances under it; a node's Overview shows its instance or a pool's running
  instances, the starts refused at the limit, and its recent runs. Owners and admins
  clear an instance that stopped without saying so (`node.clear_instance`, audited): its
  open runs are marked lost and another instance can start at once. The runs list takes
  `node:` and has a Node column from 1300 px, and its Filter menu has Node; the run page
  says a run's node and instance. Every run records its node and the instance that
  started it, and every delivery its instance. A pool's instance limit is enforced: the
  ping of a new run from an instance beyond it is a signed `409` `instance_limit`, the run
  does not start and nothing is stored, and the node counts the starts refused.
- A workspace no run has reached opens on one box, Send your first run: Add a node (a
  node, or a node pool for a fleet that shares one key), Connect it (one command run on
  the machine, or a key generated in the browser for a CI or another system), and See
  runs here, with a panel beside it that explains the two ways, then asks "How do you
  want to connect build-01?" and makes the real command in place, shown once, while it
  waits for the machine.
  The first sign-in lands there. The overview's To review lists a node's active key
  nobody has used for 30 days, with Revoke on the node's Access key tab.
- Members at the levels owner, admin and member, and the suspension of a member. A workspace's settings list who
  reaches it and at what level under People, read there and managed in the
  organisation's People.
- The audit trail of every change, in the organisation's settings, under Audit log; retention of a
  run's events and log output, set per workspace in its settings under Runs
  (`/settings/retention` sends on there); deletion of a workspace or an
  organisation, marked first and purged after a grace period.
- The console's shell: a top bar that says where a page is, the organisation first, and
  switches to any organisation or workspace with a search, Search or jump to (⌘K) for
  pages, repositories, runs and places, New, which offers a workspace's page a new
  node and an organisation's an invitation, and a sidebar of the page's workspace,
  organisation or account, which folds to icons, with the Qory Apiary menu (docs,
  changelog, source, version) at its foot. A workspace's settings, an organisation's and
  your own are each a place of their own with their own sections, GitHub's way, and
  deleting a workspace, an organisation or your account is the danger zone at the end of
  its General page or Profile.
  Pages start at one left edge and use the width of the screen: lists up to 1680 px, a
  run's page all of it, forms 720 px.
- The runs list as a record read by filters, not groups: views (All, Alive, Ended badly,
  With denials) with their counts, one filter field that takes qualifiers (`repo:`,
  `state:`, `runtime:`, `host:`, `node:`, `started:>2026-09-01`, `denied:`) and free text
  over a run's id, title and target, one Filter menu, sorting, the repositories beside the
  list with their runs from 1280 px, pages of 25 to 100 with a jump to a date, and from
  1920 px a preview of the run chosen with the end of its log.
- A run can say what it is about, in `about` of its `run.started`: a kind, a title,
  subjects (each a type and a ref, with a url and a title when given) and details. A
  run's title is its `about` title; without one, the run page and its tab say "Run" and
  its short id, the lists show the short id, and the Overview its command line, else its
  short id. The runs list shows its kind and first subjects under the title; the run page
  shows them under its heading, each subject a link that opens in a new tab, and the whole
  of it in an About section of the Details rail. A `task` label is an ordinary label.
- Network access, in the sidebar's Guard beside the Policy (`/:org/:workspace/network`,
  and a tab of each run and each repository): every destination the runs reached, what
  decided it, and Allow or Deny from its row, narrowed the same way as the runs. Its
  rows are one line each, the denied number the one red, with Allow and Deny as icons on
  hover, a copy icon by the host, and host suggestions in its query field. The policy's host rules are its Network access section, which links back
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
- The features an instance has, switched at launch (`QORY_FEATURES`), and the
  documentation every instance serves at `/docs`: the guides and the release notes, and
  the module reference on an instance with every feature. An opt-in feature is on only when
  the list names it: `all`, `all-…`, and a value that is not set or empty leave it off.
- `APIARY_ENCRYPTION_SECRET`, required, 32 bytes: the integrity codes of stored rows are
  keyed from it.
- `APIARY_SIGNING_SECRET`, required, 32 bytes of its own, never derived from
  `APIARY_ENCRYPTION_SECRET`: the seed of the Ed25519 key the server signs its answers
  to runners with. The boot refuses it when it is missing, of another length, the same
  as `APIARY_ENCRYPTION_SECRET`, one of the contract's published fixture seeds, or the
  development or test seed this repository publishes. Every machine pins its public key, so changing
  or losing it means pinning every machine again.
- A `Content-Security-Policy` on every page of the console, the storybook and the
  documentation: only the console's own scripts run, and a script injected into a page,
  inline, in an `on…=` attribute or as a `javascript:` address, is refused by the
  browser. A reverse proxy must pass the header on, neither stripping nor replacing it.

### Migrations

The baseline, on an empty database, creates the schema an instance has, whatever its
features; among it: the accounts and their tokens (`users`, `users_tokens`),
`organisations`, `workspaces`, `memberships`, `invitations`, `access_keys`, `targets`,
`runs`, the record (`events`, `log_chunks`, `connections`, `deliveries`), the security
policy (`policy_rules`, `run_configurations`), `retention_runs`, `audit_entries`, the
instance's own tables (`purged_organisations`, `instance_settings`) and Oban's.

`nodes`: a workspace's nodes and node pools, with the trigger `nodes_kind_fixed`, which
refuses a change of a node's kind; `nodes.instance_ids_over_bound` and its time.

`node_instances`: a node's instances. `runs.node_id` and `runs.instance_id`,
`deliveries.instance_id`, all NULL for every existing row; the indexes
`runs_node_id_instance_id_alive_index` and `runs_workspace_id_node_id_started_index`,
created concurrently.

`access_keys` holds the keys of nodes: each row's node (`node_id`), Ed25519 public key
(`public_key`), the time it was received (`received_at`) and how it arrived
(`arrived_by`: `code`, with its `enrolment_code_id`, or `browser`), all NOT NULL, with
`rate`, `burst`, `revoked_by_id`, `integrity_code` and `integrity_key_id`, and no secret.
The trigger `access_keys_fixed_at_insert` refuses a change of a key's node, public key or
arrival. New: `access_key_enrolment_codes`, a node's enrolment codes, and
`access_key_public_keys`, the instance's ledger of public keys.
`20261007210000_make_an_enrolled_key_active_at_once` drops the approval's columns
(`approved_at`, `approved_by_id`, `last_pending_at`), their check and index, and the
ledger's `pending` state and `rejected` reason; it deletes every node's key, with its
deliveries, and every enrolment code, and makes every public key in the ledger a
tombstone, so machines enrol again with a new key.
`20261008090000_let_a_key_arrive_made_in_a_browser` lets a key arrive `browser`.
`20261008120000_remove_the_pasted_key` removes the paste arrival: it deletes every key
that arrived `paste`, with its deliveries, makes its public key a tombstone in the
ledger, and leaves the check `browser`, or `code` with its enrolment code.

`20261008180000_say_what_a_run_is_about` adds `runs.about_kind`, `about_title`,
`about_subjects` and `about_details`, NULL for every existing row, `about_subjects` `[]`.
`20261009090000_drop_the_task_of_a_run` drops `runs.task`; rolled back, it restores the
column from each run's `task` label.

### Upgrading

Nothing to upgrade from: this is the first release. Install it on an empty database.
