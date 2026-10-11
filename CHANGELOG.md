# Changelog

Every release of Qory Apiary, newest first, in the shape of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version numbers follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0 a minor release may
change what an existing installation does, and says so under Upgrading. Every section
says what the database migrations the release runs on boot do, so a self-hoster knows what a
restart does before doing it (the Upgrading guide, `guides/upgrading.md`).

## [Unreleased]

The first release of the open core of Qory Apiary: Qory Apiary Community, complete for
one team, as `EDITIONS.md` at the root of the repository describes it.

### Added

- One organisation and one workspace. The person who sets a new instance up creates the
  instance's organisation, with its workspace Main, and is its owner; everyone after joins
  it by invitation, which `INVITATIONS_PER_DAY` bounds. The release commands
  `Apiary.Release.grant_instance_admin/2` and `revoke_instance_admin/1` set a new instance
  up from a shell and change its admins.
- The set-up link. Until a new instance is set up, every start logs the same line, "Set up
  Qory Apiary at https://…/setup/<code>.", and nobody can sign up. The page at that link
  asks for an email address, a password and its confirmation, and the organisation's
  name; it creates the instance's organisation, its workspace Main and the account as its
  owner, and signs the person in. The code is 32 random bytes, stored in the instance's
  settings until it is used and then gone; any set-up link after says the instance is
  already set up, and a wrong one before is a page that does not exist. On an instance
  that is set up, a restored one included, a start logs no such line.
  `grant_instance_admin/2` on a new instance uses the code too.
- Mail is optional. With `SMTP_RELAY` set, Qory Apiary sends its email through that relay;
  without it, it starts all the same, sends no email, and says so in one line of its log at
  each start: people sign up and log in with a password, and invitations and password
  links are copied by hand. `.env.example` leaves the mail lines empty. `Apiary.Mail` says
  whether mail is set and where from. TLS, STARTTLS or from the start on port 465, checks
  the relay's certificate against the system's certificate authorities and the relay's
  name, TLS 1.2 or 1.3; a relay given as an IP address needs a certificate that names that
  address. The relay is the host connected to, not its MX records (`Apiary.Mail.TLS`).
- Without mail, an invitation is a link to copy. The invite page shows the link once, for
  the person who made it to send themselves, with when it stops working; their account
  need not be confirmed, since no email goes out in their name. A pending invitation's
  **Make a new link** replaces a lost one: the same invitation, seven days again, and the
  old link stops working at once. A link copied, and a new one made, count against
  `INVITATIONS_PER_DAY` as an emailed invitation does. `Apiary.Organisations.invite_member/3`
  and `send_invitation/4` hand the link back, `{:ok, invitation, {:link, url}}`, and
  `renew_invitation/4` (`invitation.renew`) makes a new one. With `action:`, as
  `insert_invitation/3` takes, an edition that asked `Apiary.Access` itself renews it: the
  entry records its action, charged to the allowance the invitation was counted against,
  and the token comes back for `send_invitation/4`, which sends it once the edition's
  transaction has committed.
- Without mail, the sign-up page asks for a password, 12 to 72 characters, and signs the
  person in as soon as the account is made; an invited person keeps the invitation's
  address. `Apiary.Organisations.sign_up_user/3` takes `password` and
  `password_confirmation`: a person's sign-up needs them without mail, and drops them
  with mail, whose address a link confirms first; the instance's own sign-up
  (`actor: :instance`) needs none and keeps one given.
  `ApiaryWeb.CoreComponents.new_password_fields/1` draws the two fields and never writes a
  password back to the page. Account settings do not change the email address without mail.
- Password links, without mail. An instance admin makes one for another member of the
  instance's organisation, never for themselves, from the ⋯ menu of their row on
  **People**, while no mail is set, after a recent sign-in as Account settings ask: a
  one-time link, shown once to copy, that sets the account's password at
  `/users/password/:token` and ends every session of the account. It works for 24 hours,
  and a new one ends the one before; only its hash is stored. Mail turned on, by the test
  link of Instance settings › Mail or a start with `SMTP_RELAY`, ends every such link
  (`Apiary.Mail.end_password_links/0`). Each is an
  `account.password_link` entry in the organisation's activity. The release command
  `Apiary.Release.password_link/1` prints one for an hour, mail or not, and
  `grant_instance_admin/2`'s set-up of a new instance prints one in place of the log-in
  link when no mail is set. `Apiary.Accounts.build_password_link/3` makes them.
- The log-in page follows mail. Without mail it asks for the email address and the
  password only, and says to ask an admin of the instance for a password link when the
  password is forgotten. An expired log-in link's page then leads to the log-in page, and
  an expired link, to log in or to change an address, says only that it has expired, not
  to ask for a new one; Account settings no longer call the password optional beside
  log-in links. With mail a log-in link stays the default and a password the other way
  in, whose form's **Email me a link** sends a log-in link to the address typed, counted
  as one asked for.
- An account whose password was set before its address was confirmed loses that password
  at its first log-in link, which confirms the address and ends every other session; the
  page says so. A sign-up whose confirmation email cannot be sent keeps the account made,
  and sends the person to the log-in page for a new link.
- Instance settings › Mail: an instance admin saves the SMTP relay, its port, TLS,
  username and password, and the sender, stored in the database with the password
  encrypted under a key derived from `APIARY_ENCRYPTION_SECRET` for that purpose alone.
  TLS is **Always** with a username, but on port 465, so the password is never sent
  unencrypted. The section, the save and the test link ask for a recent sign-in, as
  Account settings do. Saving sends a test link to that admin; mail is on once they follow
  it, signed in as themselves, and their address is confirmed. The link works once, for 60
  minutes, and does nothing for anyone else. Each save is an `instance.mail_save` entry in
  the activity of the instance's organisation, with the relay, port and TLS, and each link
  followed an `instance.mail_on`. With `SMTP_RELAY` set, the
  environment wins whole and the section is read only. Each node reads the settings again
  when they change. The boot's check of `APIARY_ENCRYPTION_SECRET` covers the stored
  password.
- A workspace is created by `Apiary.Organisations.create_workspace/2`, an owner's
  action, `workspace.create`, asked of the organisation: named, at a slug made from the
  name or given, empty, in observe, counted against the edition's limit of workspaces
  per organisation, which in the core is the one the organisation was made with, and
  told to the edition (`workspace_created/3`). No page of the core offers it. An
  organisation's pages open its oldest workspace where the person has opened none yet.
- A person an edition lets into an organisation without a membership is told they read it
  and change nothing there (`Apiary.Access.reader/1`) only while the role the edition
  gives them holds no action that changes anything, that is, none that leaves an entry in
  the audit trail (`Apiary.Access.reads_only?/1`). One whose role there changes something
  is told what a refusal tells anyone else. In the core no one is let in without a
  membership, so no page says it.
- The organisation's settings list its workspaces under Workspaces for whoever may rename
  or delete one (`workspace.rename`, `workspace.delete`, asked of the organisation,
  `Apiary.Organisations.lists_workspaces?/1`), owners and admins in the core. A
  workspace's Delete…, the deletions waiting to be cancelled and the note on what a
  deletion does are there for whoever may delete one.
- A page that refuses a person an action, or offers them no way to take it, says which
  levels may, such as "Only owners and admins add nodes.", through
  `ApiaryWeb.Access.who_may/3`: an edition may say it in its own words
  (`c:ApiaryWeb.Edition.who_may_sentence/2`, asked with the action and the scope), and
  the core's sentence stands where it has none, as it does in the core.
- The record of every run, reported by Forager over the server contract (version 1,
  revision 1: discovery, a run's registration and reload, events and enrolment): the
  session as a timeline, the terminal, every connection with its decision and rule, and
  how the run ended.
- A run's registration. A run opens with a signed `POST /v1/runs`, whose body holds its
  id, its labels, what it is about, the heartbeat interval it uses and when it was sent,
  read strictly, a body it refuses being `400` `invalid_request` with the member at fault
  in `names`; the answer is its run configuration, `{"version":1}` where the workspace
  serves no policy, always with `X-Qory-Run-Configuration`, an `ETag` and
  `X-Qory-Configuration`. The same bytes
  sent again under the same access key get the same answer; the run id under another key,
  or with other bytes, is `409` `run_id_used`; a run whose events retention pruned is
  `410`; a run configuration that cannot be read is `503`, never no policy. No run is
  stored on any refusal. `GET /v1/runs/<run_id>` reloads a run's configuration for the
  access key that registered it, by its registration's labels, and is `404` for any other
  key, for a run its batches created, and where the workspace serves no policy. Discovery's `run` section is always there, `…/v1/runs`. A batch that
  holds `dev.qory.ping` or `dev.qory.run.registered` is `400` `invalid_request`: a
  Forager that opens its runs with a ping starts none, so Forager and Qory Apiary are run
  from the same release.
- A run a gateway opened, with no session: no runtime, command or host, and no exit
  status. The runs list's Runtime column says "no session". Its page says how it ended in
  words after its state, as every run's does; its Terminal tab is the terminal, empty,
  with a note that the run has no session, and search, follow, wrap, the text size and the
  download disabled; its timeline starts "by a gateway with no session"; and its Details
  say what opened it and which Forager reported it, with no
  Command section, and its Session "none". A run through a separate gateway belongs to the
  gateway's node and instance, and its Host is the agent's machine.
- Qory Apiary records what a run reports and never ends a run it did not start; it starts
  none today. No run offers Close, on its page or as a lost run on the Overview, and a run
  has no Closed state. The events endpoint answers `410` only to a run whose events
  retention has pruned.
- Six states of a run, in four families: alive (Pending, Running), ended well (Completed),
  cancelled (Cancelled) and ended badly (Failed, Lost). A cancelled run was stopped
  before it said how it went, and counts neither as ended well nor as ended badly: the
  runs list's Ended badly view and the Overview's Ended badly count Failed and Lost, the
  share that ended well leaves cancelled runs out, the Filter menu's State section has a
  Cancelled heading, and the Overview's chart table a Cancelled column. Completed is a
  green check, Cancelled a grey stop, Failed a red x-mark and Lost an amber
  signal-slash.
- How a run ended, by one rule for a session's run and a run a gateway opened alike, from
  its exit's `state` (`succeeded`, `failed` or `cancelled`) and its open `reason`:
  `succeeded` is Completed, `cancelled` Cancelled and `failed` Failed, but a failed exit
  with `session_lost` or `gateway_lost` is Lost, for good, and a failed exit an older
  Forager wrote when it stopped a run itself (`timeout`, `quiet`, `credential_expired`,
  `run_ended_at_issuer`) is Cancelled. An exit without a `state` is read by its reason.
  A run that did not start, `dev.qory.run.refused`, is Failed, "did not start" with the
  refusal's code, and never turns Lost.
- How a run ended, in words, after its state in the run page's header, under State in its
  rail, in its timeline's last item, "Run ended", and in the runs list's preview: "time
  limit reached", "no activity for 30 minutes" (or hours, or seconds), "permission to run
  expired", "stopped, no outcome given", "interrupted" (a session's run stopped from where
  it was started, a Ctrl-C or a signal to `qory run`, which is Cancelled whatever its
  exit), "stopped responding", "end not recorded", "couldn't check whether the run may go
  on: no answer" (or "unreadable answer"), and any other code as the run's starter gave
  it, with spaces for underscores ("no longer needed"). An exit stored under one of Forager's earlier names reads in the words of the
  new one. A session run's Exit in the rail is the runtime's exit as recorded, "not
  recorded" for `-1` without a signal; the page announces a cancelled or lost end in the
  same words ("Run cancelled: time limit reached."); and a run whose exit said it was lost
  lists on the Overview as "Lost, stopped responding" or "Lost, end not recorded".
- Signed requests and signed answers. Every request the gateway makes names a node's access
  key and its instance and is signed with that key, Ed25519 (`X-Qory-Access-Key-Id`,
  `X-Qory-Instance-Id`, `X-Qory-Signature-Ed25519`), within 300 seconds of the server's
  clock for a GET and a registration's `time`; every answer to a verified request is signed with the server's own
  Ed25519 key, which every machine pins as `apiary_public_key`, and sent with
  `Cache-Control: no-store, no-transform`, while every `401` goes out unsigned. The
  refusals come in the contract's order, coded: a header sent twice or an instance id
  absent or malformed is `400` `bad_request` on every endpoint. Discovery names the key's node (`node_id`) and the
  server's keys (`apiary_public_key`), so its digest differs by node. The tests replay
  the contract's own fixtures at the commit `.forager-contract-ref` pins, 5ddac44 on
  Forager's main.
- A rate limit per access key on each node, `429` `rate_limited` with `Retry-After` past
  it: the events endpoint, and a run's registration and reload, each spend a bucket of
  their own, 50 requests a second and 100 at once, so a gateway flushing a backlog of
  events still registers a new run. Discovery is not limited.
- Limits on signing in, on each node: a log-in with a password, 5 per email address from
  one client network (an IPv4 /24 or an IPv6 /48) and then 1 a minute, 50 per email
  address from all networks and then 10 a minute, and 20 per client address and then 1
  every 3 seconds; a log-in link asked for, 3 per email address from one client network
  and then 1 every 5 minutes, and 30 from all networks and then 10 every 5 minutes, so a
  stranger's network does not lock an address's owner out of theirs; an invitation's pages and
  the set-up page, 20 per client address and then 1 every 3 seconds. Every attempt counts before the address
  is looked up, so past a limit an address with an account and one without get the same
  answer, "Too many attempts. Try again in a few minutes." The client address is the one
  the audit trail records, behind the proxies `TRUSTED_PROXIES` names; an IPv6 one counts
  with the rest of its /64.
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
  set `QORY_APIARY_PUBLIC_KEY`; point qory at Qory Apiary, the Forager file's
  `gateway.server.url`. Opened again, it says the secret is gone, and offers nothing of it to
  copy. A key's card shows its
  Key ID with Copy, how it was added ("Connected with a command by …", "Generated in a
  browser by …") and where its secret is. An active key's card opens the page Forager
  file for the key: for a key connected with a command, the Forager file's `server`
  lines under `gateway:` (`url`, `access_key_id`, `apiary_public_key`), each marked as
  Qory Apiary's or this key's; for a generated key, four numbered steps: where its secret belongs, then
  `QORY_ACCESS_KEY_ID`, `QORY_APIARY_PUBLIC_KEY` and `gateway.server.url`. The server's address
  and public key are the instance's own, the same for every organisation, workspace and
  node. A public key pasted into a node is no way to give it a key: the page that took
  one, Add a public key, was removed before the release.
  Owners and admins get and cancel commands and add and revoke keys, each in the audit
  trail; a node holds at most two keys at a time, and deleting a node revokes its keys
  and cancels its commands. Enrolment is limited per address, 1 a second and 10 at
  once, and answers in the contract's order: before the code is looked at, `413`
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
- A node's instances: what Forager, run with the node's access key, reports itself as, a
  claim kept for display, the audit and the instance limit, never for authorisation.
  Forager names its version in `User-Agent: qory-forager/<version>`, and Qory Apiary
  records it as a new run's `forager_version` when the run registers, which its
  `run.started` then replaces, and as the last `forager_version` of the access key and of the instance
  that sent it. An instance runs while it has a run the lost-run check holds alive. The Nodes list says
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
  registration of a new run from an instance beyond it is a signed `409` `instance_limit`,
  the run does not start and nothing is stored, and the node counts the starts refused.
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
- Retention prunes nothing of a lost run until 7 days after it was lost, however short the
  workspace's settings, so a gateway's record sent after a shorter outage is stored.
- A heartbeat counts by its own time, corrected by its run's clock offset, within 300
  seconds and never after its arrival, so a gateway's record sent after an outage revives
  no lost run and holds no instance slot: the run stays lost until its exit arrives,
  which keeps it Lost, for good, when it says `session_lost` or `gateway_lost`, and
  otherwise sets the state it says; and
  the access key's Last heartbeat says when its heartbeats were recorded. A run is held to
  the heartbeat interval its registration stated, and found lost after three of them with
  nothing heard, 90 seconds at Forager's 30. Three limits
  stay: after an outage shorter than about 6½ minutes, a run can still look alive for a
  moment; a session's run whose heartbeats all arrive late, because the outage began
  before its first one, still comes back for a few minutes; and a run whose machine's
  clock ran more than about 6½ minutes ahead and was then set back reads lost until its
  exit arrives.
- The console's shell: a top bar that says where a page is, the organisation first, and
  switches from it (on a phone, from the drawer's head), keeping the page you're on, or
  its list where the page is one item's (the organisation's menu lists the organisations
  beside the workspaces of the one pointed at, an organisation opening in the workspace
  you last used there, and the workspace's menu the organisation's workspaces, each with
  a search), Search or jump to
  (⌘K) for pages, repositories, runs and places, New, which offers a workspace's page a
  new node and an organisation's an invitation, and a sidebar of the page's workspace,
  organisation or account, which folds to icons, with the Qory Apiary menu (docs, the
  changelog with the version, source) at its foot. A workspace's settings, an
  organisation's and your own are each a place of their own with their own sections,
  GitHub's way, and deleting a workspace, an organisation or your account is the danger
  zone at the end of its General page or Profile.
  Pages start at one left edge and use the width of the screen: lists up to 1680 px, a
  run's page all of it, forms 720 px.
  Each name in the top bar's path is cut short with an ellipsis where it does not fit; on
  a phone the page's own name is cut first and its parent keeps up to 8rem, so no name
  runs over a separator or the buttons after it.
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
  to gateways with. The boot refuses it when it is missing, of another length, the same
  as `APIARY_ENCRYPTION_SECRET`, one of the contract's published fixture seeds, or the
  development or test seed this repository publishes. Every machine pins its public key, so changing
  or losing it means pinning every machine again.
- The two 32-byte keys, `APIARY_ENCRYPTION_SECRET` and `APIARY_SIGNING_SECRET`, in hex
  too (64 characters, either case), beside base64 (44 characters): both decode to the same
  bytes, and the boot compares the bytes.
- A key variable left blank counts as not set: a blank `SECRET_KEY_BASE` or
  `APIARY_ENCRYPTION_SECRET` now stops the boot as missing, unless the keys file holds it.
- The key check at boot. The instance records, at its first boot, a check value of
  `APIARY_ENCRYPTION_SECRET`, which tells nothing of it, and its signing key's
  fingerprint, and a later boot with another of either stops with a message that says
  which, where it served before with no access key verifying or every machine refusing its
  answers. `APIARY_ACCEPT_SIGNING_FINGERPRINT`, set to the fingerprint the refusal names,
  makes a new signing key the instance's on purpose at the next boot; any other value
  changes nothing, and it never accepts another `APIARY_ENCRYPTION_SECRET`.
  `Apiary.Release.accept_signing_key/0` does the same in a one-off container.
- The image, `ghcr.io/qoryai/apiary`, from the `Dockerfile`: CI builds it on every pull
  request and push, for `linux/amd64` and `linux/arm64`, and publishes nothing; only a
  release publishes it, tagged `X.Y.Z`, `X.Y` and `latest`, without the `v`. It carries the
  commit it was built from as the label `org.opencontainers.image.revision`, and
  `GET /health` reports it as `revision`, `null` in an image built without one, beside
  `version`, which its `503` has too. It writes no `erl_crash.dump`
  (`ERL_CRASH_DUMP_BYTES=0`), so a boot that stops leaves no copy of the release's memory,
  secrets included, on the container's disk. Its base is Debian from
  `public.ecr.aws/docker/library`, Amazon's public copy of Docker's official images, from
  which CI also pulls the Postgres, nginx and Docker images it runs, and the end to end
  job's SMTP sink, Mailpit, comes from `ghcr.io`; the jobs that still pull from Docker Hub
  log in to it when the repository's `DOCKER_HUB_TOKEN_SECRET` is set.
- Pre-release images: `.github/workflows/prerelease.yml`, run by hand only, from the
  Actions tab or by pushing a commit to the branch `prerelease`, never on a push to any
  other branch or a schedule, builds a branch, tag or commit as a release's image is
  built and publishes it to `ghcr.io/qoryai/apiary-prerelease` alone, a private package, as
  `sha-<7>` and, for `next`, as `next`; the AWS template's Test image field, under For
  testing only, runs such an image in place of the Edition's.
- `compose.yaml` in place of `docker-compose.yml`: the published image, as `.env` names it
  in `APIARY_VERSION` (and `APIARY_IMAGE`), Postgres 18 in the profile `postgres`, which
  `.env.example` turns on, and the server, published on `127.0.0.1:4100` alone.
  `.env.example` holds no secret, and no `POSTGRES_PASSWORD`. CI runs it as a person
  does: the install, a restart, the upgrade from the base commit's image, the path from a
  checkout, and an external Postgres over TLS.
- The AWS template, `deploy/aws/apiary.yaml`: Qory Apiary on ECS Fargate behind an
  Application Load Balancer, with RDS for PostgreSQL 18 and its keys in Secrets Manager,
  installed from the AWS console's form and upgraded with its Update, with no command. A
  release attaches it as `apiary.yaml` with the release's version written in
  (`scripts/aws-template-release.py`), so an upgrade is an Update with the new release's
  template, `VersionOverride` left empty. The form asks for the edition, Qory Apiary
  Community or Qory Apiary Pro; Qory Apiary Pro's download key, which the stack keeps as a
  secret of its own, deleted with the stack, for the image's pull alone; and the domain,
  with a Route 53 hosted zone, or without one, the stack then making the certificate and
  waiting for its validation record. Rules refuse Qory Apiary Pro without its download key,
  on ARM64, or with no version to install, and a test image without the download key.
  Under Recovery, `AcceptSigningKey` is passed as `APIARY_ACCEPT_SIGNING_FINGERPRINT`, and
  `DatabaseDeletionProtection` sets the database's deletion protection: a function of the
  stack's own turns it on once the service is first healthy, so a create that fails
  before then rolls back whole, and an Update with No turns it off before a delete. The
  stack sets its own stack policy, refusing any update that would replace or delete the
  database or a key's secret: an EventBridge rule sends this stack's own status changes to
  a function of the stack's, which sets the policy once the create completes, and again
  once each update completes or rolls back, as CloudFormation refuses a stack policy while
  the stack is in progress. The four secrets are kept when the stack is
  deleted, each named after the stack and the whole UUID of its stack ID, so they do not
  block a new stack of the same name, whose stack ID is its own, and the database leaves
  a final snapshot. The log groups, the task's and those of the stack's two functions,
  are kept too, when the stack is deleted and when a create rolls back, their events for
  30 days, under names made from the stack ID in the same way. The outputs are the
  address, the load balancer's DNS name, the edition and the version the stack runs, the
  key secrets' ARNs (their names, on a stack given the keys of a deleted one), and links
  into the console: the logs, the set-up link's line in
  them, the service, the key secrets and the database snapshots. CI lints the template
  with cfn-lint, and two copies a release would write, one with Qory Apiary Community
  first and one with Qory Apiary Pro first, and checks the stack policy and the rule,
  function, permission and role that set it, and that nothing sets it from inside the
  stack's create or update, that no output is
  a command, which secrets and log groups the stack keeps and that their names use the
  stack ID's UUID, the mappings' keys, that every value compared with the edition is one
  the form allows, and that the template and both copies are ASCII alone, as the AWS
  console shows any other character as "?".
- The keys made at first start: the one-shot service `keys` runs `bin/keys`, which
  generates `SECRET_KEY_BASE`, `APIARY_ENCRYPTION_SECRET`, `APIARY_SIGNING_SECRET` and
  `DATABASE_PASSWORD` into `/var/lib/apiary/keys/apiary.env` in the volume `keys`, keeps
  what the file holds, skips what the environment sets, and prints no value. The release
  reads the file where the environment does not set a name; the environment always wins.
- `DATABASE_URL` takes libpq's `sslmode`, `disable`, `require` or `verify-full`, and
  `sslrootcert`, a file or `system`, as managed Postgres services print them:
  `verify-full` checks the server's certificate and host name, `require` encrypts without
  checking and says so at boot, and any other `sslmode` stops the boot. `DATABASE_PASSWORD`
  is the password when the URL has none.
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
`20261009141000_name_the_forager_version` renames `runs.runner_version`,
`access_keys.last_runner_version` and `node_instances.last_runner_version` to
`forager_version`, `last_forager_version` and `last_forager_version`; rolled back, it
renames them back.
`20261009160000_say_what_opened_a_run` adds `runs.opened_by` (`session` or `gateway`, with
its check) and `runs.quiet_seconds`, NULL for every existing row, and lets `runs.state` be
`ended`; rolled back, a run that ended is failed.
`20261009230000_record_the_instances_keys` adds `instance_settings.encryption_secret_check`
(32 bytes) and `instance_settings.signing_key_fingerprint` (22 characters), NULL until the
first boot after it records them.
`20261009233000_allow_the_six_states_of_a_run` lets `runs.state` be `completed` and
`cancelled`, beside the names it held, and rewrites no row: a run stored `succeeded` reads
and counts as Completed, and one stored `timed_out` or `ended` as Cancelled. Rolled back, a
completed run is `succeeded`, and a cancelled one `timed_out` when it reached its time limit,
else `ended`.
`20261010120000_keep_the_mail_settings` adds the mail settings to `instance_settings`:
`smtp_relay`, `smtp_port`, `smtp_tls`, `smtp_username`, `mail_from`,
`smtp_password_ciphertext` with its `mail_key_id`, `mail_saved_at`, `mail_saved_by_id` and
`mail_verified_at`, all NULL, with checks on the port, the TLS mode and the password's key
id.
`20261010143819_register_a_run` adds `runs.registered_at`, `registration_labels`,
`registration_about`, `registration_digest` (32 bytes), `registration_interval_seconds` and
`registration_answer_digest`, NULL for every existing row, with a check that a run holds
all six or none.
`20261010190000_keep_a_registration_s_time` adds `runs.registration_time`, the `time` a
run's registration was built at, NULL for every existing row, with a check that it is set
only on a run that registered.

### Upgrading

Nothing to upgrade from: this is the first release. Install it on an empty database.
