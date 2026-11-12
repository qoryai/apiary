# Changelog

Every release of Qory Apiary, newest first, in the shape of
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). The version numbers follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html); before 1.0 a minor release may
change what an existing installation does, and says so under Upgrading. A section whose
migrations change an existing database says what they do under Migrations, so a
self-hoster knows what a restart does before doing it (the Upgrading guide,
`guides/upgrading.md`).

## [Unreleased]

### Added

- A run's version of the artifact type `mockup` with a `screens.json` is a mockup of
  HTML pages: the version's page shows it under “Mockup”, with the start screen in a
  frame and the list of screens beside it, each a link that opens its screen in the
  frame. The frame has the sandbox with no permission, and each screen is served with
  a policy that lets it run no script and load nothing but `data:` images and fonts.
  The frame's address has a token that Qory Apiary signs for the reader, valid for an
  hour, so the links between screens work inside the sandbox, which sends no session
  cookie. Qory Apiary checks on each request that the reader's session lasts, so
  signing out ends the token, and that the reader may read the work item. The logs
  show `:token` in the token's place. After an hour, reload the page.
  A run's push of a mockup page that runs a script, loads an outside address, sends a
  form or links to a page that is not a screen fails with `422` `invalid_artifact`,
  and its message has the file and the fix. A version of pictures, and
  every version added on **Add a version**, shows as before, under “Image”.
- On an integration's page in **Organisation settings › Integrations**, each collection
  assigned to a workspace, such as a repository, has **Unassign** for owners and admins.
  **Unassign** shows a confirmation in the row's place, then unassigns the collection:
  its tickets leave the workspace's Backlog, and work items taken in from it stay where
  they are. After **Unassign**, the row keeps its place until the list sorts again: when
  the page loads again, when you open another page, view, search or filter, or after
  **Assign to workspace**. In a list filtered by workspace, the row leaves the list. A row
  on a deleted workspace shows “Deleted, purged on” and the day under the workspace's
  name, and has **Unassign** too.
- An organisation with no workspace shows the kind cards on its overview,
  `/<organisation>`, under “What will your first workspace do?”, and
  `/<organisation>/workspaces/new` shows them under “What will this workspace do?”.
  Each card is a link to the kind's page, such as `/acme/workspaces/new/qory.software`,
  which shows the kind's stages, its summary and how it works. **Create workspace** on
  that page creates the workspace, named after its kind, such as “Software factory” at
  `/acme/software-factory`, then “Software factory 2”, and opens its step **Name**. A
  workspace's address follows its name: a rename, on **Name** or in
  Workspace settings, changes it, and links to the old address stop working, with no
  redirect. A name whose address another workspace has, or Qory Apiary keeps, is
  refused, never numbered: “Choose another name. Another workspace already has the
  address /acme/payments.”
<!-- feature: factory -->
- `/<organisation>/workspaces/new` shows one card for each template, in groups: the Qory
  harness, the organisation's shared harness, the sources assigned to it, and its connected
  repositories. A card opens the template's page, `/<organisation>/workspaces/new/<key>`,
  with the harness the template is read from. **Create workspace** on that page makes
  the workspace from that template.
<!-- /feature -->
- An instance admin can change the name, summary and “How it works” of each workspace
  type in Instance settings › Workspace types › **Details**. Each save makes a new version
  and an audit entry. A blank field shows the text that Qory Apiary ships.
<!-- feature: workflow_model -->
- The stages canvas lays the stages out from top to bottom on a dotted background, and
  fills the window beside its side panel. **Focus** (`f`) and **Full screen** enlarge it.
  On a workspace type's page the canvas is view-only. Workspace settings › Workflows and
  Instance settings › Workspace types show the canvas on a **Stages** tab and the other
  settings on a **Details** tab.
- With this feature on, the settings menu lists **Workflows**, at `/settings/workflows`, the
  page that sets the stages. It replaces **Stages** at `/settings/stages`, which is gone,
  with no redirect. The settings menu lists **Harness** with this feature on or off.
- With this feature on, the Harness page shows the commit in use and the process version
  under **Version**, and “main is now at 4960195” where the branch the harness follows
  is at another commit. For a harness that follows a branch, it has the switch **Keep
  the process at the latest**: on by default for the Qory harness, and off by default
  for a harness repository and for a workspace whose first process version is a version
  of its workspace type that an instance admin saved. With the switch on, each new
  commit on that branch is saved as a new version of the stages. Edits saved on the
  Workflows page turn the switch off.
- **Update from harness** on the Harness page compares the current version of the
  stages with the process at the version the workspace follows: the changed stages,
  the artifact types it adds and a changed stack. **Save** saves it as the current
  version, copies the stack and turns the switch on again. **Try first** saves it as a
  trial with the artifact types, and copies no stack; making that trial current copies
  the stack and turns the switch on. Work items in progress stay on their version.
  Where the process came from another harness, the comparison takes the one template
  of the workspace's type that the harness repository has.
- A run on a harness that follows a branch composes the commit its process version
  came from. The Workflows page lists and checks the workflows at that commit, so a
  workflow that the branch adds is listed after Update from harness saves it.
  Before, a run on the Qory harness composed the commit `main` was at when a machine
  claimed the run, and a run on a harness repository the commit read when the run was
  queued.
- Workflows › **Details** shows the harness with the commit the current version came
  from, and **Open Harness**. Its History lists a version saved from the harness as
  “Updated from main at 4960195”, with a person's name before it when a person saved
  it, and the stages and artifact types it changed.
- Each stage has an optional **Description** under its name in the stage editor: plain
  text of at most 500 characters, with line breaks. A stage's card on the canvas shows it
  under the name, cut to three lines. A template's `process.yaml` may set `description` on
  a stage.
<!-- /feature -->
- An address under an organisation that matches no workspace the person reaches, such as
  an old address after a rename, shows inside the app's layout, with status 404: “You
  have no workspace at this address in Acme. Its address changes when the workspace is
  renamed.”, then the workspaces of Acme the person can open, as links. New workspace for
  a person who may not create one shows, the same way and with no kind cards, the
  Community limit's line where the organisation has its one workspace, else who creates
  workspaces. An organisation the person does not reach still shows the plain “Not
  Found”.
- Organisation settings › Workspaces shows each workspace's address, `/acme/payments`,
  beside its name; with no workspace, it shows “Acme has no workspace yet.” and a link
  to the overview, in place of the empty list.
- On every page of a workspace, the sidebar's first line is the organisation's name, a
  link to the organisation's overview.
- An instance admin can rename the product in Instance settings › General: the browser
  tab, the sidebar, the log-in pages and every email show the name, with “Powered by Qory
  Apiary” beside it.
- An instance admin can change, in Instance settings › Configuration, how long the audit
  log keeps an entry and the IP address it came from, the grace period before a deleted
  workspace or organisation is purged, and the invitations an organisation makes a day:
  each part a form with its Save, after a recent sign-in. A variable of the server's
  environment that is set, `AUDIT_RETENTION_DAYS`, `AUDIT_ADDRESS_RETENTION_DAYS`,
  `DELETION_GRACE_DAYS` or `INVITATIONS_PER_DAY`, still wins, and the page shows its value
  read only; one set empty counts as not set. A shorter retention applies at the next
  daily job, a new grace period to what is deleted after it, and a new number of
  invitations at once. Each change is an `instance.configure` entry in the trail of the
  instance's organisation, with the values before and after.
- `bin/apiary eval 'Apiary.Release.demo()'` loads synthetic runs, people and nodes into a new
  instance set up with the organisation name Acme, to try Qory Apiary with data in it
  (`guides/install.md`, "Load the demo into a test instance"). It writes nothing when the
  instance is not set up, its organisation is not Acme, or its workspace Main already has
  runs or nodes.
- Qory Apiary keeps each step of a run from `dev.qory.run.step_started` and
  `dev.qory.run.step_exited`: a fetch, compose, image, setup, join or wall, with its state,
  exit code and duration, and its log lines under the step's number.
- A run's Timeline starts with **Run**, the run as one list of steps in the order they
  ran, on every pool, with its total time and a heading with the pool and the run's
  state, such as “Run on Qory Pool · Failed”: **Queue the run** and **Request a
  machine**, with the pool and the machine type, for a run a node pool claimed; **Start
  the machine**; **Prepare the machine**, a row for each step that ran before the first
  agent session, except the joins and walls; for each agent session, **Agent session
  <n>** with **Prepare the session**, the session's join and wall and any step that ran
  after the start of the session before, **Run the agent**, with when the session
  started and finished, its result and its model, which opens to the Timeline of that
  session's events and its **Main session** row, open while the run runs and closed once
  it has ended, and **Save the outputs**, with the artifact versions the session saved
  and its push steps; and **Remove the machine**. A session whose runtime is not Claude
  Code shows, above its Timeline, that only Claude Code sends session events and where
  its output and connections are. A prebuild has **Build the image**, its session, with
  its join as **Start the build**, and **Save the outputs**, the image it built, as
  steps of the run, with no Agent session. Each top-level row shows its start time and
  how long it took; the rows inside a step show no times. After a failed step, the steps
  that did not run show as **Skipped** until a step after it runs; **Remove the
  machine** still shows its result. The step that copies the run's work back, and the
  join and wall steps of the helper session it starts, have no row.
  Owners, admins and members open a step's row to read its output, the last 64 KiB. A
  failed step's row is open, with what happened and no advice, such as “Start the wall
  failed with exit code 125.” “How it ended” in the header shows the same line, or the
  line of a failed push; when the copy of the run's work back fails, it reads “The run's
  work did not come back from the machine.” A run that stopped before its session
  started has no note above the Timeline. An instance admin also reads the machine log
  under **Start the machine**. The list updates without a reload while the run runs.
- A run whose pull of its image ends with `image_access_denied`, `image_rate_limited` or
  `image_registry_unreachable` shows the failed step under **Pull the images** and ends
  as any failed run does: it queues no build and no run again.
- **Remove the machine** shows what the node pool reported about removing the run's
  machine: "Machine removal requested" or "Removal failed: the machine still exists",
  or, once the machine is gone, how long the removal took and why: "Run ended" or
  "Keep-alive lost". With no report, a run that ended shows "Waiting for a report" for
  15 minutes, then "No removal report". A run on a permanent machine ends with **Machine
  stays registered** in place of **Remove the machine**. A pool's starter reports at
  `POST /v1/dispatches/<dispatch_id>/machine-end`, and the audit log records its first
  report, its first failed removal and the removal.
- **Copy diagnostics**, in the menu of a run's page, copies the run's diagnostics as
  JSON, for owners, admins and members who may read the run's log. The diagnostics
  contain the run with its machine type's key and name, its queue entry and claim, how
  its machine was prepared, its latest 5,000 events at most, the output that belongs to
  no step, its last 1 MiB, the output of each step, and the secrets found printed in the
  run, at most 8 MiB in all. Only an instance admin's copy contains the machine logs. A
  copy contains no key, no run code and no variable value, only the variables' names.
  Text is copied as Qory Apiary stored it, so a secret a run printed is in the copy.
  When the copy fails, the menu shows the fix first, such as “Sign in again, then copy
  again. Your session ended.”
- Instance settings › **Diagnostics keys**, for instance admins, lists the diagnostics
  keys. With a diagnostics key, a computer lists the runs on this instance, with their
  organisation, workspace and work item title, and reads the diagnostics of any of them,
  and nothing else. It reads the diagnostics at `GET /v1/runs/<run id>/diagnostics`, in a
  request signed with the key. **Get the command**, after a recent sign-in, shows
  `qory apiary enrol <address> <code>` with **Copy command**: the code starts with
  `qecd_` and works once, within 15 minutes, and the computer makes the key and sends
  Qory Apiary only its public half. Each key shows who made it, when, when it was last
  used, and **Revoke…**. An instance has at most 20 diagnostics keys. The audit log
  records each code, each key added and each key revoked.
- A diagnostics key also lists the runs of the instance at `GET /v1/runs`, in a request
  signed with the key, 25 runs to a page by default and 100 at most, the last created
  first. Each run shows its id, number, organisation, workspace, state and creation time,
  and, where the run has them, its workflow, work item, reason, start time and duration.
  The query narrows the list to a workspace, such as `workspace=example-org/example`, a
  work item of that workspace, a workflow, a state, or the runs created since a time
  (`since`). `before`, set to the answer's `next`, reads the next page. A query gets
  `400` with the name of the parameter for a parameter that is unknown, given twice,
  empty or outside its rule, for `work_item` without `workspace`, for a workspace that
  does not exist, and for a `before` that is the id of no run.
  Qory Apiary records no read of a run for the list.
- Qory Apiary scans the text a run stores, as it arrives, for keys of a known form: Qory
  Apiary's keys and codes, and Anthropic, OpenAI, GitHub and GitLab tokens. It scans the
  run's output, its events, its machine log and the reason its machine was released. It
  stores where each key is, never the key, at most 1,000 for a run's output and events,
  and 1,000 each for its machine log and release reason. In the diagnostics, each one
  found has the line “This secret is compromised: it was printed into the run's log.
  Replace it.”, or the same with the event, the machine log or the release reason as the
  place. Text stored before the upgrade is not scanned.
- `QORY_SETUP_CODE_SHA256` takes the SHA-256 of a set-up code that the install makes. With
  it set, the log shows no set-up link, and the code sets the instance up once
  (`guides/install.md`).
- **Connect Qory Apiary**, at `/instance/set-up`, opens after the set-up link, one step a
  page. Its **Mail** step has the form of Instance settings › Mail: **Save and send a
  test** saves the mail server and emails a test link, and **Skip** leaves mail for later.
  Where the server's environment sets mail, the page has no **Mail** step, because there
  is nothing to configure. Each sign-in of an instance admin opens this page until an
  instance admin finishes or skips its last step. On an instance set up before the
  upgrade, the next sign-in of an instance admin opens it too. Where the page has no
  step, a sign-in of an instance admin opens what it opens for anyone else.
- Instance settings › Mail and the **Mail** step of **Connect Qory Apiary** show the last
  test send, also after a reload: when the link was sent and until when it works, or the
  fix first, by cause, such as “Check the username and password, and that the relay allows
  this server's IP address, then send the test link again. The log-in to the relay failed
  at 30 Oct 2026, 14:02:09 UTC.” While mail waits for the link, the instance admin who
  saved the settings has **Send the test link again**, which ends the old link and sends
  another through the saved settings, with no change to a setting. Qory Apiary sends at
  most one test link a minute, for a save and a resend alike. The **Mail** step is done
  once mail is on or the last test link was sent. Qory Apiary stores the time, the result
  and the relay's reply code of the last send, never the relay's text. In Activity, a save
  is “Saved the mail settings and started a test send”.
- While an organisation has no workspace, its owners and admins invite people from
  **People** into the organisation. The invitation page and the sign-up show the
  organisation's name, and **People** lists the invitation with **None** as its workspace.
  Accepting it opens the organisation's overview. Once the organisation has a workspace,
  an invitation needs a workspace again.
- Each page of the set-up with more than one step shows a list of the steps of its part,
  with the part's count. The instance set-up, which an instance admin goes through once,
  has **Your account** and the steps under **Connect Qory Apiary**. The sign-up lists
  **Your account**, then the workspace's steps, with no heading. Above the list, “Step 1
  of 2” and a bar; below 1280 px the list is a bar with **All steps**. A step done or
  skipped is a link to it where it has a page, once you are signed in; **Your account** is
  not. **Back** at the foot of a form opens the step before in the same part, and each
  step has an address, such as `/instance/set-up?step=mail` and
  `/<organisation>/<workspace>/set-up/name`. The page of a workspace's step shows no list:
  with the `factory` feature, the workspace's sidebar lists its steps. A person who waits
  for another to create the first workspace sees no list.
- The organisation's overview moves on without a reload when another person creates the
  organisation's first workspace while it shows the kind cards or the line for a person
  who waits.
- An edition can change the set-up's steps and their notes, and, for a person who waits
  for the first workspace, the line on the organisation's overview, “An owner of Acme
  creates the first workspace.” in the core, through the callbacks `set_up_steps/2` and
  `first_workspace_waiting_line/1` of `Apiary.Edition`, and the line of New workspace
  where the organisation has as many workspaces as the edition allows, through
  `workspace_limit_line/1`. The core keeps its steps.
- The kind cards show a card for each workspace type, with what you do in that kind of
  workspace, what you connect, and **Choose**. This release has one type, **Software
  factory**: “Agents change code in your repositories. You connect: where work comes
  from, where changes go, a model.” `/<organisation>/workspaces/new` is where an owner
  adds a workspace where the edition allows another. Where the organisation has as many
  workspaces as the edition allows, that page is headed “New workspace” and shows, in an
  information notice in place of the cards, “Qory Apiary Community allows one workspace
  per organisation, and Acme has it.” Only owners see the cards: anyone else reads who creates the
  first workspace, and `/<organisation>/workspaces/new` is not found for them. Each
  workspace stores the type it was made from.
<!-- feature: factory -->
- **Connect Qory Apiary** has a step for each adapter that **Instance settings ›
  Adapters** lists, before **Mail** where the page has that step. Where an adapter's
  description has steps for setting it up or connecting it, that step and the workspace
  set-up's **Work sources** and **Destinations** list them in the column **About this
  step**, under **In the new tab** or **On** and the adapter's name. Qory Apiary stores
  those steps at each start of the adapter.
- After a kind's card, the workspace set-up has 7 steps: **Name**, **Work sources**,
  **Destinations**, **Model**, **Harness**, **Machines** and **Test run**. **Choose** on
  the card creates the workspace, **Name** renames it, and each later step sets up that
  workspace. Each step is a page of the workspace, such as `/acme/main/set-up/harness`,
  and opens in any order; an address with a step you do not see is not found. **Work
  sources**, **Destinations**, **Model** and **Harness** each show where you change them
  later, such as “You can change this later in Workspace settings › Harness.” Where the
  edition allows more than one workspace, a workspace added later goes through the same 7
  steps.
- Where the edition shows the setting “Available to every workspace in Acme”, **Model**,
  and **Harness** for a harness repository, list first what the organisation shares,
  under “Shared in Acme”, each marked “· every workspace”. On **Model**, **Key** lists
  each model provider with a key that applies to every workspace, then the providers of
  the workspace alone and **Add a key**; the first is chosen while the workspace has no
  model choice. On **Harness**, a harness repository the organisation shares comes
  first, chosen while the workspace has no saved choice, with its version as text under
  it, such as “triage · acme/harness · main”. Where the organisation shares the Qory
  harness, **Harness** shows the plain **Qory harness** row, with no mark and no
  heading, and **Version** under it while **Qory harness** is chosen. **Continue** with
  the shared harness chosen removes the workspace's saved choice, so its runs use the
  shared harness. **Continue** with **Qory harness** at the version of the shared Qory
  harness does the same where the workspace has no saved choice, or its saved Qory
  harness is at the same commit. With any other choice,
  **Continue** saves the workspace's choice, also where it is the same as a shared
  harness repository, so a later change of the shared harness leaves the workspace's
  harness as it is. With nothing shared, neither step shows the heading.
- **Work sources**, “Where does work for Main come from?”, shows a card for each account
  that the organisation's connections reach, of the adapters that bring tickets for the
  workspace's type. **Destinations**, “Which repositories may runs in Main change?”,
  shows one for each account of the adapters with repositories that runs can change. A
  card shows the adapter and the account, such as “GitHub · acme”, how many of the
  account's collections the workspace has, such as “2 of 14 repositories”, or “All
  repositories”, and **Choose**. An adapter connected with no account yet shows
  **Connected**, and one whose connection is pending **Connecting…**. With nothing
  connected, owners and admins see on the step the adapters the instance has set up for
  the workspace's type, each with **Not connected**, or **Connecting…** while the
  connection is pending, and **Connect**, which returns to the step after the adapter's
  steps. Once the step has a card or a **Connected** line, **Connect another source**, or
  **Connect another destination**, opens a page of the step,
  `/acme/main/set-up/sources/connect`, with the adapters not connected yet, or “Every
  system is connected.” **Back** on that page, and on the chooser, returns to the step,
  and the breadcrumb shows the step, a link to it, then the page: “Work sources /
  Connect another source”. **About work sources** shows “Bring tickets in from a system
  such as an issue tracker. Owners and admins of Acme connect it once for the
  organisation.” and “Connect opens the system in this tab. After its steps, it sends
  you back here.”
  Anyone else sees no **Connect** and reads “Only owners and admins of Acme connect work
  sources.”, or “… connect destinations.” A connection to an adapter is the
  organisation's and serves every workspace, so its **Connect** has no setting of where
  it applies: one connection to GitHub serves both steps of every workspace. With no
  adapter to list, the step shows “No work source for this type is set up on this
  instance. An instance admin sets one up in Instance settings › Adapters.”, or the same
  for a work destination. The step updates without a reload.
- **Choose** opens “Choose repositories · GitHub · acme”, at
  `/acme/main/set-up/sources/choose?grant=<id>`, with two choices, in the
  adapter's word for its collections. **All repositories, including new ones** assigns
  to the workspace every repository of the account that no other workspace has. It also
  assigns each one the adapter lists for the account later. **Only selected** lists the
  account's repositories 50 to a page, with the search field **Find a repository** and a
  count, such as “3 selected”. Each row has a checkbox, and one in the table head
  selects every row shown. A repository of another workspace has no checkbox and shows
  “In Billing (cannot be ticked)”. The selection stays across pages and searches until
  **Save**, which saves it and returns to the step; **Back** returns without saving. The
  chooser opens on **All** while the workspace has All for the account, else on **Only
  selected**, with the workspace's repositories ticked. While another workspace has All
  for the account, the chooser shows **Only selected** alone, and “All new repositories
  of acme go to Billing.” In **Destinations**, while **Work sources** has All for the
  account, it shows **All** alone, and “Work sources is set to All for acme. Change it
  there first.” All in **Work sources** turns on the Backlog of each repository it
  assigns to the workspace. All in **Destinations** leaves it off on one that was in no
  workspace. Only where the adapter sent a line on its access, the chooser shows “Not
  listed?” and that line, with **Change access** for owners and admins. **Change
  access** opens the adapter's install for the connection, and returns to the step.
  Owners and admins choose; anyone else sees the choices disabled, no **Save**, and who
  may choose.
- A collection joins a workspace only through **All** or a tick. Qory Apiary assigns a
  collection that the adapter lists later to the workspace with All for its account,
  and leaves it in no workspace where none has All, also in an organisation with one
  workspace. The end of the account's grant or of the connection, and the purge of a
  deleted workspace, remove that All.
- **Work sources** is done once a collection is the workspace's with its Backlog on, and
  **Destinations** once a repository is the workspace's.
- **Workspace settings › Work sources**, “Which work sources does Main use?”, and
  **› Destinations**, “Which repositories may runs in Main change?”, show the same cards
  as the set-up's steps, with **Connect a source** or **Connect a destination** for
  owners and admins, which reads **Connect another …** once the page has a card or a
  **Connected** line. Anyone else reads the step's line, such as “Only owners and admins
  of Acme connect work sources.” **Choose** opens the same chooser in the workspace's settings, at
  `/acme/main/settings/choose?step=sources&grant=<id>`. Its **Save** and **Back** return
  to the settings page. **Connect** and **Change access** return to the set-up's step of
  the workspace. Under **Only selected**, ticking a work source assigns it to the
  workspace and turns its Backlog on. Unticking it turns its Backlog off, and removes it
  from the workspace unless it is a repository, which stays a destination. Ticking a
  destination assigns it to the workspace, with its Backlog off unless it is chosen as a
  work source. Unticking a destination removes it from the workspace and stops its
  tickets. Owners and admins choose; owners, admins and members read the settings pages.
- **Model**, “Which model do runs in Main use?”, has three fields. **Key** lists each
  model provider with a key that reaches the workspace, by its name, then **Add a key**.
  **Add a key** is the one option where there is no provider to reuse. It opens
  **Provider**, **Key**, and an address for a provider that needs one, as **Organisation
  settings › Model providers** does. It adds the provider for the workspace: its key is
  a secret of the workspace, and the provider reaches that workspace alone. Under
  **Key**: “Qory Apiary stores the key encrypted, and nobody can view it again. You can
  replace it in Settings › Secrets and variables.” **Runtime** lists the runtimes the
  provider serves, as text where there is one. **Default model** suggests the provider's
  models for it. **Continue** saves the workspace's model choice, with the provider's
  default key; **Workspace settings › Model** shows that choice. Where the edition shows
  “Available to every workspace in Acme”, two workspaces can reuse one key and choose
  different models. The step is done once the workspace has a model choice whose
  provider reaches the workspace and has a key. Owners and admins fill it in. For a
  Claude subscription, **About models** shows `claude setup-token` on a separate
  line, with **Copy command**.
- **Harness**, “Which harness do runs in Main use?”, sets the harness of the
  workspace's runs. **About harnesses** explains what a harness is, which harness a run
  uses, and the versions. The choices are two: **Qory harness**, with **Version**,
  **Always the latest on** a branch, `main` unless you change it, or **A fixed version**,
  a tag or a commit; or **A harness repository**:
  a **Repository** from a searchable list of the connected repositories, a
  **Stack** it exports, and **Version**, **Always the latest on** a branch, `main` unless
  you change it, or **A fixed version**, a tag or a commit. Where the repository exports
  no stack, “acme/tools exports no stack. Add a qory.yaml or harness.yaml at its root
  that lists the stack under exports.” takes the place of **Stack**. Where the
  organisation has no connected repository, “Acme has no connected repository. Connect a
  work source to pick one.” shows under **Repository**. Where an adapter of the connected
  repositories has no call address, or one Qory Apiary does not call, its repositories
  are not listed, and **Repository** shows, before any pick, a line for that adapter,
  such as “Qory Apiary cannot read the repositories of the GitHub adapter: the adapter
  has no call address. An instance admin sets the call address. The Qory harness needs
  no call address.”
  **Continue** saves the choice. The save reads the branch, tag or commit. Where Qory
  Apiary does not read the stacks of a harness source, or does not save it, the Harness
  step, **Workflow** and the form of **A stack of another repository…** show the cause
  and what to do, with no address, host or IP of the instance's set-up. A call to an
  adapter that fails shows its cause, such as “The GitHub adapter did not answer within
  10 seconds. Try again. If it repeats, an instance admin checks that the adapter is
  running.” The other main causes are a version the repository does not have, with
  “acme/tools has no branch, tag or commit named v9. Correct the version.”; a listed
  stack with no stack file, with “acme/tools lists the stack web under exports, but
  stacks/web has no qory-stack.yaml. Add that file.”; a file that is not valid, with
  “Correct qory.yaml in acme/tools:” and the rule; an address, folder or version in a
  form Qory Apiary does not read, with the rule it breaks, such as “Correct the version:
  a branch, tag or commit name has 1 to 255 letters, digits, dots, underscores, slashes
  and hyphens, and no spaces.”; a harness whose content breaks a rule, with “Correct the
  harness in acme/tools:” and the rule, such as “it has no harness file and no harness is
  set”; and an error in Qory Apiary, with “Qory Apiary could not read acme/tools because
  of an error in Qory Apiary. Try again. If it repeats, tell an instance admin.” A run on
  a branch uses the branch's newest commit: on the Qory harness, the commit when a machine
  claims the run; on a harness repository, the commit when the run is queued. With the
  `workflow_model` feature, a run on a branch uses the commit its process version came
  from instead. A workspace
  with no saved choice uses the Qory harness. Owners and admins choose. The test run
  keeps its built-in harness.
- Under the choices, **Repositories** lists the workspace's repositories from
  **Destinations**, each with a **Stack**: **Workspace's harness** until you choose
  another, a stack the workspace's harness exports, or **A stack of another
  repository…**, which opens **Repository**, **Stack** and **Version**, and also offers the
  harness sources an instance admin assigned and a **Public address**. A chosen stack
  shows as “review · acme/tools · main”. A stack from the workspace's harness follows the
  workspace's version; when the workspace's harness moves to another repository, the row
  keeps its repository and stack at the version it followed. Owners and admins choose.
  **Workspace's harness** or a stack of the workspace's harness saves at once; the form of
  a stack of another repository saves with **Save**.
- **Repository** narrows the connected repositories as you type. Qory Apiary reads only
  the repository you pick.
- A run's harness is the first of: the repository's root `harness.yaml`, or the
  `harness` section of its root `qory.yaml`, where it extends or defines a stack; the
  stack set for the repository; the workspace's harness choice, else the harness the
  organisation shares; the Qory harness.
- **Machines**, “Which machines run the runs in Main?”, shows the node pools that run
  the workspace's runs: the workspace's pools, or the instance's pool while it has none.
  Each shows “Ready · gateway: <gateway>”, or **Not ready** and why. The reasons are: no
  pool, no active key, a gateway choice of Direct, no gateway, a gateway the pool's runs
  may not go through, or a gateway with no active key. While the workspace has no pool,
  owners and admins choose **Qory Pool**, chosen first, or **A pool for Main**: “Runs in
  Main then wait for this pool, and the Qory Pool stops taking them.” Its **Add pool**
  adds a node pool to the workspace with the workspace's name, cut to 80 characters.
  Where another node of the workspace has that name, the step shows a line to rename
  that node first. Once the workspace has one pool, owners and admins keep the same
  choice, with the workspace's pool chosen. While the instance has no pool, **Qory Pool**
  then shows “Not ready: no pool”, cannot be chosen, and the step offers no removal.
  Otherwise, choosing **Qory Pool** shows “Remove the pool Main? Runs in Main then use
  the Qory Pool.”, with **Remove pool** and **Cancel**. For a pool with an active key, it
  also shows “The machines in Main stop taking runs, because the pool's access key is
  revoked.” **Remove pool** deletes the pool, and the instance's pool runs the
  workspace's runs again. With 2 pools or more, and for anyone else, the step shows the
  pools with no choice and offers no removal. On a pool of the workspace with fewer than
  2 active keys, **Get the command** makes an enrolment code. The step then shows “On
  the machine for the pool Main, run:” and the enrol command on a separate line with
  **Copy command**, until the code expires or a machine enrols with it; **Get a new
  command** makes another. Under the enrol command, the step shows “Run this on the
  Linux machine with Docker that runs the runs in Main. It joins that machine to the
  pool Main. Install qory there first:” and the install command on a separate line with
  **Copy command**:

  ```sh
  curl -fsSL https://raw.githubusercontent.com/qoryai/qory/main/install.sh | sh
  ```

  Under a Qory Pool that is not ready, an instance admin has **Check the Qory Pool and
  Qory Gateway**; anyone else sees no Qory Pool on this step; whoever may add a pool is
  offered only a pool for the workspace. For a pool of the workspace, owners and admins have its name as a
  link to its page. Anyone else reads who acts: “Only owners and admins add a pool and
  join a machine to it.” While the workspace has no pool, anyone who may not add one sees
  a ready Qory Pool, read only. The step is done once a pool is ready. **About
  this step** explains what a pool does, which pool takes the workspace's runs, what
  makes a pool ready, and that every run gets an isolated environment.
- **Test run**, “Run a test”, makes a test work item of the line in **Say hi to your
  agent** with **Run the test**, with no work source; owners, admins and members run it
  once a pool that serves the workspace is ready. Before that, the step shows “Runs need
  a ready pool. See Machines.”, and **See Machines** opens that step. **About test runs**
  explains when the test passes, which harness the test run uses, and that the set-up of
  the workspace is finished once the test passes. The test run uses a
  harness built into Qory Apiary: qory's `examples/hello` at a fixed commit, workflow
  `hello`, which the machine fetches from github.com without a credential. The step
  shows “The test run is queued for a machine.”, then “The test run is running.”,
  without a reload, with **See the run** once a machine has registered the run. It shows
  what to fix first when no machine takes the run within 5 minutes, the gateway has no
  model key, or the run sends nothing for 10 minutes. Once the test run passes, **Go to
  Main** opens the workspace. **Work items** lists each test work item with the mark
  **Test**.
- When the set-up's test run fails, the **Test run** step shows why and what fixes it, by
  cause, with **Run the test** above it. A test run that stopped while its machine was
  prepared shows “The test run stopped at <step>.”, the cause line of the run's Timeline,
  and **Open the run's Timeline**. A test run that ended shows how, such as “The test run
  failed after the session started: <reason>.” or “The test run failed: the run's settings
  did not pass a check on the machine (image_unknown).”, with **See the run**. A test run
  that ended before a machine started it shows the fix where the set-up has one: shorten
  the line in **Say hi to your agent**, choose the model again on the **Model** step, or
  have an instance admin install the instance's gateway with `QORY_INSTALLED_GATEWAY`
  where the run's gateway is not allowed to receive its secrets. Else the step shows “No
  run was recorded, so this step cannot show why.” For a missing model key, the line is
  “Add a model key on the Model step. The gateway had no model key for the run.”
- While a workspace's test run has not passed, every link to the workspace and a sign-in
  open its Overview, which shows “Finish setting up Main”, each step with a check once it
  is done and a link to its page, and **Continue: Model**, to the first step that is not
  done. The workspace's sidebar starts with “Set up · 3 of 7” and a link to each step, the
  page's step current, above its other pages. The organisation's list of workspaces shows
  “Set-up: 3 of 7 steps” under the workspace's name. A person who may not act on a step
  reads who may; on the Overview, “Main is being set up” and “Owners and admins of Acme
  finish the set-up.”, with no **Continue**. Under each step's name, a done step shows its
  value, such as the workspace's name, and Test run “Starts one run to check the
  set-up”. Once the test run has passed, the Overview, the sidebar and the organisation's
  list show no set-up. The workspace's other pages, such as **Backlog** and
  **Runs**, open whatever the state of its set-up.
- **Organisation settings › Model providers** lists the organisation's model providers,
  and **New model provider** adds one with its key, and an address for a provider that
  needs one, such as LiteLLM; no page shows a key once it is saved. Under **Key**: “Qory
  Apiary stores the key encrypted, and nobody can view it again.” The provider is added
  for one workspace, the one in the help beside the form: “After you save, choose the
  model for Main in Workspace settings › Model.” Its key is a secret of that workspace,
  and it reaches that workspace alone. While the organisation has no workspace, the
  page shows “Set up a workspace first, then add a model provider in its Model step.” in
  place of the form, and adds nothing. For a Claude subscription, **About model
  providers** shows `claude setup-token` on a separate line, with **Copy command**.
  **Workspace settings › Model** sets the model of the workspace's runs. Its field
  suggests each provider's models from the models.dev list in the release, which the
  Mix task
  `apiary.models.update` writes before a release; Qory Apiary downloads nothing while it
  runs. **Another model** takes any model id, and a model provider keeps no list of
  models. A model choice also has a runtime: the **Runtime** field shows only while the
  runtime catalogue has more than one, and the catalogue of this release has one,
  `claude`. When the gateway had no model key for a run, the work item page puts “Add a
  model key in Organisation settings › Model providers.” first on the step card,
  Explore's tab and the Thread, in place of “The run ended with an error.”
- **Workspace settings › Secrets and variables** lists the key of each model provider
  added for the workspace among the workspace's secrets, with the provider's name and
  “Model provider key · 1 value”, and a mask in place of each value. Owners and admins
  add, change, rename and delete a key's values there; the secret's name and note stay
  as they are. Deleting the secret fails while the provider uses it, with “Change or add
  a value instead. Model provider Anthropic API key uses this secret, so it cannot be
  deleted.” The gateway receives such a key only for a run of that workspace, its
  provider cannot be the organisation's default model, and purging the workspace deletes
  the provider with the model choices that use it.
- Where an edition shows the setting “Available to every workspace in Acme”, off, the
  **Model** step's **Add a key** and **New model provider** have it: on, the provider is
  the organisation's, reaching every workspace, with its key a secret of the
  organisation. The **Harness** step has it too, except while **Qory harness** is
  chosen: on, with **A harness repository** chosen, **Continue** saves the harness
  repository as the harness the organisation shares, which each workspace with no saved
  choice uses.
  While the organisation shares a harness repository, sharing a second fails, and the
  step shows “Choose the shared harness, or turn off “Available to every workspace in
  Acme”. Acme shares a harness already.” Where Acme shares the Qory harness, sharing a
  harness repository replaces it. The core shows the setting nowhere.
- **Workspace settings › Harness**, at `/settings/harness`, for owners and admins, replaces
  **Workflow** at `/settings/workflow`, which is gone, with no redirect. It shows
  the workspace's harness in the rows **Source**, with the harness's address as a link,
  **Stack** and **Version**, such as “Follows main” or “Tag v2.4.0”. Where the workspace
  has no saved choice, the rows show the harness the organisation shares.
  **Change** opens the two choices of the set-up's **Harness** step, with **Save** and
  **Cancel**. Under the harness, **Repositories** shows the same rows as the Harness
  step, with the same **Stack** field. **About harnesses** also has the Harness step's
  five paragraphs.
  Under it, the page sets the workflow of the workspace's runs, from a harness
  repository: **Workflow source** lists the repositories connected to the organisation, and the
  harness sources an instance admin assigned to it;
  **Enter an address** takes a **Public address**. **Save** sets the workflow the runs
  use; no run reads that source's stack as its harness. When an adapter's result
  marks a repository as public, a run reads it through that adapter with no link to the
  organisation and no credential.
- The documentation at `/docs` describes the `factory` feature: its steps in the guides,
  the variables of the instance's node pool and gateway, and its modules in the module
  reference. An instance without `factory` serves none of that text.
- A run of Explore pushes the proposal, the questions and `review-comments` as artifacts
  of its work item while it runs, through the run API, each with the name `main`.
- A run records a decision on a question it adds, as a question in the state `decided`
  of the questions format, and a member may change the decision by answering the
  question. The run API returns 422 for a push that adds an open question with a
  decision, decides a question already in the questions, changes, drops or adds a
  decision later, changes the question or options of a question with a decision, or its
  context while it stays decided, or gives a decision an option or a run that does not
  match its question.
- On a work item's **Explore** tab, the newest proposal is one Markdown text in the
  frame **Proposal**, under the caption “Version 2”, and after **Approve** “Version 2.
  You approved it 5 minutes ago.” An approved proposal has the badge **Approved**. The
  page draws the text with raw HTML dropped, links only to http, https and mailto
  addresses, and headings two levels down. It shows the PNG, JPEG, GIF, WebP and SVG
  images of the same proposal version, and a reference to a file that version does not
  have as “Image not in this version: …”. A reader not shown the `workflow_model`
  feature sees each image as its words, such as “Image: Checkout page”, with no link.
  The list under the text's last top-level `## Sources` heading is in the fold “Sources
  (3)” at the foot of the frame, closed. Mermaid diagrams of five types are drawn as
  images, in the app's colours: flowchart, state, class and ER diagrams in a hand-drawn
  look; sequence diagrams in Mermaid's classic look. Each has its source in the fold
  “Diagram source”; the settings a diagram sets, in a directive or front matter, are
  dropped. A diagram of another type, or one that would load an address, shows as
  written under “Qory Apiary does not draw this diagram, so it is shown as written.”,
  and one with an error under “This diagram has an error, so it is shown as written.”
  One fold at the foot of the tab lists each of Explore's runs in the take in; its first
  line shows how many there are and the versions of the newest proposal and questions.
  An earlier run that wrote a proposal opens to that version. The fold also lists the
  work item's artifacts under **Artifacts**, where, at the Explore stage, a version a run
  made reads “Run 14”, without its round; artifact pages keep “Run 14 · round 2”.
  At the Explore stage, the stage's runs and artifacts no longer show above the tabs; its
  notes stay there. At every stage after Explore, the runs and artifacts move to one
  closed fold at the foot of the **Ticket** tab and the **Thread**: its first line shows
  how many runs the take in has and the versions of the current stage's outputs, each
  attempt links to its run, and **Add a version** is inside it. A stage's tab has the
  same fold for that stage's runs and outputs. Each row of the fold, on every tab, shows
  the attempt, the workflow, the round, the verdict and the time, for example
  “Attempt 2 (Run 14) · shape-a-ticket · round 1 · passed · 12 hours ago”. Until a run has
  its verdict, the row shows “queued” or “running”, or “Failed”, “Lost” or “Cancelled”
  when the run ended without one. The run's number shows where the reader may open the
  run, and “Attempt 2 (Run 14)” links to it. The notes stay above the tabs. A wide table
  on the tab scrolls in a frame with a visible bar, as on the **Document** view, and its
  words stay whole.
- An open work item whose current stage is Explore opens on the **Explore** tab from
  every link that names no tab, and the **Ticket** tab has the address
  `/work/<number>/ticket`.
- A work item has a tab for each stage of its process that runs a workflow, once the
  stage is the current one or has a run. The tab has the stage's name and the address
  `/work/<number>/stages/<stage id>`, which stays when the stage is renamed. An open
  work item opens on its current stage's tab from every link that names no tab, and on
  the **Ticket** tab at a stage with no workflow. `/work/<number>/explore` goes to the
  tab of the first stage with a proposal output. A stage's tab shows a frame for each
  of the stage's outputs that has a version, the first one open, and the questions, runs
  and artifacts of that stage's runs.
- On the current stage's tab after Explore, **Run another round** works as on the
  **Explore** tab. Where the stage waits for answers, it sends your answers; at the
  stage's gate, the decisions of the stage's runs that you changed. It also sends one
  comment on the whole round, from the field **Comment on the stage's outputs**, and the
  open comments of that stage. The stage's next run reads them and updates the outputs.
  The questions and comments of another stage stay on that stage's tab.
- On a work item's **Explore** tab, step card and **Details**, a text about one run
  links to that run's page, and the link ends with the run's number in the workspace: a
  line with no attempt number, such as “Explore is running again, with your comments
  (Run 14).”, as a whole, and a line with “Attempt 3 (Run 14)” on those words. While a
  run is queued or running, the top row of the step card reads “Explore”, the state and
  “Run 14”, “Run 14” is the link, and the sentence under the row has no link and no
  number. The line under the title, “Explore is running”, links to the run with no
  number. A run with no page yet, or a reader who may not read the run, sees the same
  text with no link and no number. On an earlier attempt that opens a fold, a click on
  the link opens the run's page and a click beside it opens the fold. In the wait block,
  only the heading links to the run: its sentence is plain, as “Attempt 3 reads the
  ticket…”.
- The dot of a running Explore run on the line under a work item's title and on its step
  card follows the run's page: it is blue and pulses while the run is alive, and it is
  amber with no pulse once the heartbeat is late. A queued run's dot stays still. A
  running run's badge and word on a work item's page are blue too. On its step card and
  Explore tab, those of a running Explore run are amber once the heartbeat is late, and
  so is the word of a later stage's run in the fold at the foot. The dot changes with the
  page open, as on the run's page: on each heartbeat, and within 5 seconds once the
  heartbeat is late. On the Work items list, a running row and the stages strip's “N
  exploring” have the same blue dot, still.
- The **Document** view of an artifact draws Mermaid diagrams as the **Explore** tab
  does: the same five types in the same looks, each with its source in the fold “Diagram
  source”, and any other diagram as written, under the same lines. On that view, a table
  wider than the text column scrolls in a frame, and a long word wraps, so neither runs
  under **Details**. A proposal's **Sources** on that view are a closed fold under the
  text, as on the tab.
- The **Questions** frame under the proposal lists the questions that a run of this take
  in wrote or reopened. For a member who may answer, the first line is “Run another
  round starts the next run. That run reads your answers and your comment, and updates
  the proposal.”, or “Run another round starts the next run. That run reads your answers
  and updates the proposal.” where the tab has no comment field. Answered questions fold
  to one line; the open ones follow under “Open questions”. Each question shows the
  options the run wrote as cards, up to 4, then the card “Give your own option”, and one
  field with the placeholder “Add details (optional)”, or “Your option” while **Give
  your own option** is picked. That field is then required: “Write your option, or pick
  one above.” A question with no options shows the field alone, with the placeholder
  “Give your own option”. The option a run recommends has the mark “Recommended by the
  agent” on its card, and on a closed answer that chose it. A reopened question shows
  its earlier answer under “Earlier answer”, a question that follows another links to it
  with “Follows question 1”, and a withdrawn one has the badge “Withdrawn”. Under the
  last question, a member who may write comments, where a proposal exists, has the field
  **Comment on the whole proposal**. **Run another round** sends every answer given, the
  comment and the open comments to one run, at any count of runs. It is enabled once an
  answer, a comment or an open comment the member may send is there. A question with no
  option and no text stays open. With every answer blank, a member who may send comments
  (with the workflow model, only the stage's approvers, where the stage lists them)
  sends the open comments of this take in instead. With none open, or for any other
  member, the form shows “Choose an option or write an answer. If nobody knows, say so:
  Explore reads that too.” Questions that changed after the page showed them get no
  answer, and the form shows “Check the questions and your answers, then click Run
  another round again. The questions changed after the page showed them, so no answer
  was sent.” While a run runs, and to a person who may not answer, the open questions
  show as text.
- Each card under **Comments** shows who wrote it and on which version (“You, on version
  1”), or, for a comment on the whole round, on which attempt (“You, on the round of
  attempt 3”). The card also has the badge “Open” or “Reopened”, the text, its replies,
  and **Reply**; the first card is open and the others are folded to their first line; a
  click on that line opens or folds it. A run's reply closes a comment with its outcome,
  “Changed in version 2”, “Answered in version 2”, “Declined in version 2” or “Asked as
  question 4”, and the card turns muted, with a tick. A member's reply opens it again. A
  reply takes up to 2,000 characters and starts no run; so does the comment on the whole
  round, which goes with **Run another round**. While a run reads an open comment, its
  card shows “Attempt 3 (Run 14) reads this comment.” From 1007 px the cards are in the
  right column beside the tabs, and the column stays in view while the page scrolls;
  below 1007 px they are at the top of the Proposal frame. A stage's tab lists the
  comments of that stage, and the **Ticket** tab and the **Thread** those of the current
  stage. Owners, admins and members write comments and replies; with the `workflow_model`
  feature, only the stage's approvers, where the stage lists them. Any other member has
  no comment field and no **Reply**, and the address of the Reply page goes back to the
  tab. A member who stopped being an approver after the Reply page opened sees “Ask one
  of this stage's approvers to write comments on the proposal. Only approvers of the
  stage can write them.” under the field when they send, with the text kept. A text that
  breaks a rule shows the fix under the field: “Write your reply.”, “Shorten the comment
  to 2,000 characters or fewer.”, “Shorten the reply to 2,000 characters or fewer.”,
  “Remove the invisible or control characters from the comment.” or “Remove the invisible
  or control characters from the reply.”
- At the gate, under the proposal, **Approve** approves it, for a member who may
  approve. A member who may write comments sees “Run another round starts the next run.
  That run reads your comment and updates the proposal.”, the field **Comment on the
  whole proposal**, **Run another round**, which sends the comment and every open
  comment of this take in to one run, and **Approve**, beside “Approve leaves 2 comments
  unread.” while comments are open. **Run another round** is enabled once a comment is
  written or a comment is open. With the workflow model, where the stage lists approvers,
  a member who is not one of them sees neither button and neither line. Where the stage
  lists approvers, the header reads “You approve next” for a member who may approve; any
  other member reads “Dana approves next”, “Dana or Sam approves next” or “One of 3
  approvers approves next”, and the step card “Dana approves the proposal or runs
  another round.”, “Dana or Sam approves the proposal or runs another round.” or “One of
  the stage's 3 approvers approves the proposal or runs another round.” A listed member
  who may not approve does not see their name there. Beside other approvers, the step
  card adds “You are listed as an approver, but you may not approve in this workspace.”
  When that member is the only listed approver, the header shows “No listed approver may
  approve” and the step card shows “You are the only listed approver, but you may not
  approve in this workspace.” The Work items list shows the same words on the row, and
  its **Waiting on you** view, its Approve band's count and the sidebar's count go to
  the members who may approve, not to an owner who is not listed. Elsewhere the header
  shows the owner as before, “You approve next” or “Dana approves next”. A member who
  stopped being an approver after the page showed the gate, and clicks **Run another
  round**, sees “Ask an approver of Explore to act on it.” under the gate, and no run
  starts. With the workflow model, where the stage lists approvers, only they approve a
  gate. Every member answers the questions. The access action `work_item.review_comment`
  covers the comment on the whole proposal, a reply and a send of the open comments.
- When **Run another round** or a reply sends nothing, the answers, the comment or the
  text stay, and the form shows the fix under it: “Send it again when attempt 3 ends.
  Attempt 3 (Run 14) started first, so nothing was sent.” when another run started
  first, and the Reply page stays open; “Copy your text if you need it. You can no
  longer send this reply, because the work item changed.” on that page after an
  approval, a close or an undo by another member, and that page has no button to send
  it; “Try again in a minute. The artifact store cannot be reached.”; “Check the page,
  then send again. The work item changed after the page showed it, so nothing was sent.”
  (the questions form shows its changed-questions text instead); “Reload the page. Your
  access or the work item changed, so nothing was sent.”; “Send again. Qory Apiary could
  not save it.” for any other error. At the run limit, no line shows. **Approve** shows
  no line when it fails.
- A comment on the whole proposal shows in the work item's Thread as “Dana wrote a
  comment on the proposal”, or “You wrote a comment on the proposal”, with its text, and
  answers sent with a comment as “You answered 1 question and wrote a comment”, and a
  reply as “Dana replied to a comment”; in Activity as “Wrote a comment on a work item's
  proposal”, “Answered 2 questions and wrote a comment on a work item”, “Replied to a
  comment on a work item's proposal” and “Sent 2 comments on a work item's proposal”;
  and in the Runs list, on the run it started, as “Attempt 2 of 3, after a comment from
  Dana”. The Thread also shows Explore's runs: “Explore started in attempt 1”, “Explore
  started again, with the answers, in attempt 2”, “Explore started again, with the
  comments, in attempt 3” after **Run another round** sends a comment or open comments
  without answers, “Explore wrote 2 questions, after 30 s”, “Explore wrote a proposal,
  after 30 s”, with who approves next, as in the header (“… You approve next”), only on
  the proposal that waits at **Approve**, and “Explore wrote replies to 2 comments,
  after 30 s”, with the icon of a run that ended well, for a run that wrote only
  replies. A run that wrote nothing shows “Attempt 2 ended without a result”.
- While a run that **Run another round** started without answers is queued, the tab
  shows “Explore is queued again, with your comments (Run 14).” to the member who sent
  them, else “…with the comments (Run 14).”, over “Attempt 3 starts when the workspace's
  pool takes it. It reads the ticket, the newest proposal and the comments.” While it
  runs: “Explore is running again, with your comments (Run 14).” over “Attempt 3 reads
  the ticket, the newest proposal and your comments, then writes the next proposal and
  questions.”; for other members both say “the comments”.
- In **Earlier take ins**, a run's questions are headed “Question” or “Questions”, or
  “Question and answer” or “Questions and answers” where answers show, over “Attempt 1
  (Run 13) wrote this question.” or “Attempt 1 (Run 13) wrote these questions.”
- From this release, Explore counts only the open questions that a run of the current
  take in wrote or reopened, when it decides whether a work item waits for answers. A
  work item whose Explore outcome was stored before this release shows that outcome as
  it was stored.
- A work item's permanent address, `/work-items/<id>`, opens the work item.
- Explore's tab has one field, **Comment on the whole proposal**, and one button, **Run
  another round**. The button sends the answers, the comment and the open comments to
  one run. A proposal's Background shows its first paragraph, **Read more** shows the
  rest, and **Read less** closes it again. The field replaces the **Add review comment**
  page; its address, `…/explore?review=new`, opens the **Explore** tab.
- Explore's tab shows the questions a run chose an option for without a member, as
  **Decisions**: one line each, with the question, the option the run chose and its
  reason. Opened, a decision shows the full reason, “Run 2 chose it 25 minutes ago” and
  the options, with “Chosen by the agent” on the run's option. A member who may answer
  picks another option or writes one, and **Run another round** sends the change as that
  member's answer; until then the change shows only to that member, and **Approve** is
  disabled with “Run another round to apply your change.” A sent change shows
  **Changed**, the member's option, who changed it and when, and under “Changed from”,
  the run's option and reason. A note sent with the run's option shows under the
  options, with who added it and when, and the decision shows no **Changed**. While
  questions are open, the decisions sit in the questions frame, above the open
  questions; otherwise in a **Decisions** frame above the comment field. Explore's rows
  are numbered top to bottom, as they show; **Follows question** and **Asked as
  question** use those numbers.
<!-- /feature -->
- The Policy page's **Rules** tab lists **Allowed for every run**: the hosts Qory Apiary
  allows for every run of the workspace, by group, such as **Harness sources**,
  **Runtimes**, **Integrations** and **Model providers**, each with its source, what
  requires it, and a lock: “Host rules do not remove this host.” Anyone who reads the
  policy sees the list; an IP address shows as “Address hidden” to anyone but an instance
  admin. Network access lists, under the destinations, the hosts that runs reached to
  fetch their harness before the first session started, in a table **Harness fetch**,
  each with its source, such as “The Qory harness”, its runs, attempts and last time
  seen, and a lock: “Host rules do not apply to a harness fetch.” That table is outside
  the page's counts, views and rule options. Neither list changes which hosts a run may
  reach.
- Every security policy document that Qory Apiary serves allows the hosts that the
  runtimes need, such as `api.anthropic.com` for Claude Code, in `egress.allow_first`, on
  every path, as it allows the hosts of the integrations that reach the workspace. A rule
  saved before a host became a runtime's stays on the page: a deny of the host does not
  stop a run from reaching it, and an allow held to paths does not limit the host.
- A row of Network access, on the workspace page or a run's **Network access** tab, has a
  lock with the hint “Allowed for every run” in place of **Allow** and **Deny** when every
  run is allowed its host: a runtime's, an integration's or a model provider's host. An
  item of the Overview's **To review** list for such a host has the lock in place of
  **Allow here**. A path that no rule limits an integration's or provider's host to keeps
  **Allow** and **Deny**.
<!-- feature: secrets -->
- Where an agent, an API or a program of **Workspace settings › Integrations** applies is
  set when it is added, and never changed after. Added from a form with no setting, it
  applies to the workspace you add it in alone. Where an edition shows the setting
  “Available to every workspace in Acme”, off, on each form that adds one, it applies with
  the setting on to every workspace of the organisation, those added later included. The
  callback `scope_setting?/1` of `Apiary.Edition` returns whether an edition shows the
  setting; the core shows it nowhere. The **Workspaces** tab shows where it
  applies, with no way to add or remove a workspace, and **Settings** has no field for
  it. After an add, the page opens the **Overview** of what was added. A workspace's
  purge takes the workspace from every list.
<!-- /feature -->
<!-- feature: workflow_model -->
- A stage's workflow, in Workspace settings › **Stages** and Instance settings ›
  **Workspace types**, is a text field: it suggests the workflows the harness lists and
  takes any name of lower-case letters, digits and hyphens that starts with a letter.
  Each workflow on the canvas and in the stage's panel shows a check, “A stage can run
  it”, when it is a workflow the harness listed at its last read, or a workflow saved
  on the **Workflow** page; else a cross, “Not in the harness”, with
  what to do and when the stage waits. Before the first read of the harness, **Stages**
  shows “The harness has not been read yet.” and no marks.
  **Stages**, **Workflow** and **Check again** read the same harness: the workspace's
  choice, else the harness the organisation shares, else the Qory harness. The Qory
  harness is not read: its workflows are those its stack lists. On the `software` stack
  **Stages** shows “The Qory harness's workflows: explore-a-ticket.” A run that qory ends with
  `workflow_not_in_harness`, because the harness it composed has no skill for the run's
  workflow, shows that workflow and where the harness comes from on the run's page and
  on the work item.
- In Workspace settings › Artifact types, owners and admins switch each standard type on
  or off, and each change is an audit entry. Forms and the stage editor offer only the
  types that are on. A push of a type that is off returns `422 unknown_type`, and the
  message says to switch the type on. `proposal`, `questions`, `review-comments` and
  `verdict` are always on. A person adds no version of `questions` or `review-comments` by
  hand: members write them on the **Explore** tab. A type stays on while an artifact of
  the workspace has it, or while the current process or a process version in use includes
  it. A workspace keeps every standard type until a person switches one off.
- The version page of a questions or review-comments artifact has no **Add a version**
  button. People answer questions and write comments in the work item's Explore tab.
- A stage's workflow runs at the level its harness declares. A stage entry's `access`, or
  a **Workflow** page row with that workflow, lowers it.
- In the notes for the next run, a comment on Explore's proposal is labelled “Comment ·
  Explore”. The run API sends it as a note of kind `answer`.
- When a run of Explore fails after it pushed a proposal, its stage escalates with “The
  run failed after it wrote proposal version 2.” Questions wait for answers at any count
  of runs and in any round: a stage no longer escalates them at its last round.
- `GET work-item` returns the run's number in `run.number`.
<!-- /feature -->
- The **Run** list in a run's Timeline shows the run's `push` steps under **Save the
  outputs**, as they happen. A failed push opens its row with the step's output, and it does
  not count as a failed preparation.
<!-- feature: factory -->
- Qory Apiary reads a harness source's templates: `process.yaml` in each of the first 20
  modules that the root `qory.yaml` or `harness.yaml` lists under `exports`, as one of
  the 10 reads of a source a person has each minute. A module with no such file is left
  out, and a file that is not a usable template is listed with the reason. A source
  narrowed to a stack or a folder has no templates, and its modules are not read. No
  page changes.
- A factory's `process.yaml` can list `artifact_types`; a workspace made from it gets
  those types.
- **Take in** keeps the comment a member writes as a comment on the ticket, under the
  member's name, and Explore's input has it. A comment has at most 65,000 characters.
  Where an adapter sets `comments: true` on its source role, Qory Apiary writes a
  `comment` entry to the adapter's change feed. The adapter posts the comment on the item
  at the source and sends it back with its `comment_id`. An adapter that stops trying to
  post a comment reports it with `POST /v1/work-items/changes/failed`, and the comment is
  marked not posted with the reason. Posting it again writes a new entry with the same
  `comment_id`. `GET /v1/work-items/changes` ends a page before its body passes 4 MiB.
<!-- /feature -->
- **Instance settings › General** has a **Support address** under Support: an https
  address or an email address where “Contact support” leads for people in an
  organisation. `SUPPORT_ADDRESS` sets it in the server's environment and wins; General
  and Configuration then show it read only. With none, “Contact support” is plain text.
- A workspace made from the software template runs on the `software` stack of the Qory
  harness. The first workspace of an organisation starts from that template. A workspace
  with no template uses the `core` stack. Stages and Workflow show the stack: “Harness:
  Qory harness, stack software”.
- The Qory harness exports the stacks `core`, `software`, and `authoring`, and its
  `explore-a-ticket` pushes the proposal, the questions and the replies in
  `review-comments` as artifacts. On the Qory harness, the Stack select of each
  repository lists `software`.
- A workspace made from the software template gets the artifact type `branch`, and every
  standard type stays shown.
<!-- feature: factory, workflow_model -->
- Owners and admins can export a workspace's process as process.yaml from the Workflows page.
<!-- /feature -->
<!-- feature: factory -->
- A work item whose run waits in the queue while no pool of its workspace is ready
  shows “Waiting: no pool can take the run” in its header. Explore's tab shows why, with
  the step to take on the Machines page and **Open Machines**, and the step card shows
  “No pool can take the run.” The page shows the run as queued again once a machine
  enrols a key that makes a pool ready.
<!-- /feature -->
- On a run's page, **Start the machine** shows an instance admin the machine type that
  the node pool started, such as “Started as (instance admins) example-type”, above the
  machine log. Nobody else sees it, and the line is absent when
  the pool reports no type. A pool's starter reports the type as the optional
  `machine_type` of `POST /v1/dispatches/<dispatch_id>/dispatched`: 1 to 64 printable
  ASCII characters with no space. Qory Apiary keeps the type from the first `dispatched`
  of a dispatch. A body with any other value gets `400` `invalid_request`.
- The **Details** of a run's page show what the run used, after **Duration**: **Peak
  memory**, the highest peak memory that a session of the run reported, such as
  “9.8 GiB”, or “9.8 of 16 GiB” for a run on a machine type with 16 GiB; and **CPU
  time**, the CPU time of the run's sessions added up, written as a duration, such as
  “12 s”, “41 m 10 s” or “5 h 00 m”. Both cover everything behind the session's wall,
  such as the agent, a nested Docker daemon and the containers the agent starts.
  A session's `dev.qory.session.exited` may have both, as the optional
  `peak_memory_bytes` and `cpu_time_ms`. A row is absent while no session reported its
  value.
<!-- feature: factory -->
- **Instance settings › Machine types** lists the machines that runs start on: each
  type's name and key, its spec, the workflows that run on it, and the pools that serve
  it. A new instance has two types: Standard (`standard`), the default, and Browser
  tests (`browser`), each 2 vCPUs, 4 GiB, 30 GiB of disk, amd64; the migration adds
  `browser` to an instance without one (Migrations, `machine_types`). An instance admin
  adds a type with **Add machine type**, edits it, makes it the default and deletes it,
  each after a recent sign-in and each an `instance.configure` entry in the instance's
  trail. A type has a name of 1 to 100 characters on one line, with no control
  character, that no other type has, ignoring case, such as Browser tests, and a key,
  such as `browser`, that process files and stages use: 1 to 64 lowercase letters,
  digits and hyphens, starting with a letter, not `default`. The default type, and a
  type that a workspace's process or a workspace type uses, cannot be deleted; the page
  shows how many workflows in how many organisations use it, such as “4 workflows in 2
  organisations use it”, how many workspaces in how many organisations have it as their
  default machine type, and the names of the workspace types that use it.
- An instance admin can change a type's key. **Save** first shows a warning: the change
  breaks every file that uses the key, the counts of what it updates, such as “3
  workspaces, 2 workspace types, 1 waiting run”, and the `process.yaml` files to fix.
  The files are those that the workspaces' current and trial processes that use the key
  were read from, where the version read from the file uses the key too, and the Qory
  harness's file where a workspace type's copy of it uses the key. The admin fixes the
  Qory harness's files, each shown with its repository, its path and its commit. Each
  organisation fixes the files in its harness, shown as one line per organisation, such
  as “2 files in Acme's harness”. The warning shows no workspace name, workflow name or
  repository address of an organisation. **Change key** saves
  the key, and saves a version of each workspace's current and trial process and of each
  workspace type's process that an instance admin saved, where it uses the key, with the
  key replaced, authored by the admin. A workspace type whose process is a copy of the
  Qory harness's keeps that copy, with the key of before: its runs start on the default
  type until the harness changes the key. A trial saved by **Update from harness** keeps
  the harness commit it was read at in its new version, so **Make current** still copies
  the template's stack and turns on **Keep the process at the latest**. Earlier
  versions, runs and dispatches keep the key they had. Afterwards the list shows the
  files to fix until the admin dismisses the message.
<!-- /feature -->
<!-- feature: factory, workflow_model -->
- A machine type's key change rewrites workspace types and processes only with the
  workflow model on. It checks the instance action `machine_type.rekey`, which only
  instance admins take.
- A workflow's **Machine type**, and the **Default machine type** of a workspace and of
  a workspace type, are lists of the instance's machine types by name. A harness's
  `process.yaml`, and a save, keep a key that no type has. Until a type has the key, the
  runs of that workflow start on the workspace's default type, else on the instance's,
  and the workflow's settings show “Pick a machine type for <workflow>.” with the key
  and the type the runs start on. **Export process.yaml** on Workflows writes each
  machine type key as the process has it.
<!-- /feature -->
<!-- feature: factory -->
- A run is queued on the type its workflow picks, else on its workspace's default, else
  on the instance's default, and keeps that type's key and spec, so a later change of
  the type changes no queued run. A prebuild runs on the default type.
- A node pool's claim may have `offers`, the machines the pool can start, each a
  `machine_spec` of the provisioner contract. A pool with offers takes only the runs
  whose type one of them fits, and its claim answer has the type as `machine` and its
  spec as `machine_spec`. A pool without offers takes only the runs of the default type,
  as before, and the runs queued on the type that was the default then, also after
  another type becomes the default; its answer has neither, as before. Qory Apiary keeps
  each pool's offers from its latest claim. While any pool has offers, a save on Machine
  types fails for a type that none of them fits.
- A work item whose queued run is on a type that no pool of its workspace can start
  shows “Waiting: no pool can start machine type <name>” in its header, with the type's
  name, or its key where no type has the key.
- The runs list reads `machine-type:<key>`: the runs queued on that type.
- On a run's page, **Request a machine** shows the run's type by name and key, and its
  spec, such as “Large `large` (4 vCPUs, 16 GiB, 60 GiB disk)”, and **Details** show
  **Machine type** after **Key**, by name and key, then **Image**.
- A run that waits in the queue for a machine shows on the runs list and has its page
  from the moment it is queued, with its number. The list shows it first, newest first,
  as **Queued**, and the **State** filter and `state:queued` select it. Its page shows
  **Queue the run** running, the steps to come, and why it waits, such as “Waiting for
  a machine: build-pool runs 3 of its 3 machines.” At the claim, the page becomes the
  page of the running run without a reload. A run that ends while it waits keeps its
  number.
- Every run starts in its target's prebuilt image, else the machine's default image; a
  machine type sets the size only.
- When an instance admin changes a type's key, every run that waits in the queue on a
  version of a workspace's process that the change replaces moves to the new version,
  and the runs on the key move to the new key. A run that started keeps its key.
- A queued run on a type that no pool offer fits shows **Why it waits** in its header,
  and under **Queue the run**, as “Waiting for a machine: no pool offers a machine that
  fits UI tests, large (`ui-tests-large`: 8 vCPUs, 32 GiB, 100 GiB disk).”, then, for an
  instance admin, “An instance admin makes the type fit an offer in Instance settings ›
  Machine types, or the admin of build-pool adds an offer that fits.” with the first
  pool that serves the workspace, and for anyone else, in plain text, “Contact support
  with run rn_…, or ask the admin of build-pool to add an offer that fits.”, or “Contact
  support with run rn_….” where the instance's pool serves the workspace. **Queue the
  run** shows the run's **Machine type** by name and key.
<!-- /feature -->
<!-- feature: factory, secrets -->
- On **Organisation settings › Model providers › a provider**, each key's row shows its
  name and its state, in the reader's time zone: “Available”, then the use and the reset
  of each limit window, such as “Available · 5-hour 89%, resets 14:00 · 7-day 40%,
  resets Mon 09:00”; or “In cooldown until Fri 14:00”, then where that time comes from:
  “from the provider's answer”, “from this key's schedule” or “no reset time given;
  paused for 1 hour”. The windows read “5-hour”, “7-day”, “7-day Opus”, “7-day Sonnet”,
  “Extra usage”, “Requests per minute”, “Tokens per minute”, “Input tokens per minute”,
  “Output tokens per minute”, “Spend limit” and “Limit”. The default key comes first,
  then the other keys in the order they were added. Owners and admins have **Add key**
  above the keys and **Edit** on each row, each a separate page. **Add key** has
  **Name**, **Key**, **Resets** and **Pause for**; **Edit key** has the same fields,
  with **New value** in place of **Key**. A provider with 32 keys shows
  “Northwind Claude has 32 keys, the most it can have. Delete a key to add another.”
  under **Key**, and a name that another key of the provider has shows “Another key of
  Northwind Claude has this name.” under **Name**.
- **Resets**, optional, is the day, time and time zone of each week at which a key's
  allowance resets, for a provider that sends no reset time. Set all three or
  none: “Set the day, the time and the time zone, or leave all three empty.” **Pause
  for**, optional, is how long runs skip a key after its limit error when no reset time
  is known, from 1 minute to 7 days, in minutes, hours or days: “Enter a time from 1
  minute to 7 days.” Empty, it is 1 minute for an API key and 1 hour for a
  subscription. **Workspace settings › Secrets and variables** has both fields on **Add
  value** and **Change value** of a model provider's key.
- A key's cooldown ends when **Change value** saves a new value of the key. A save with
  **New value** empty and a rename keep the cooldown.
- **Edit key** of a model provider's key, on **Organisation settings › Model providers ›
  a provider**, has the optional field **New value**: “Leave it empty to keep the
  value.” A new value replaces the key's value, for example after you rotate a
  subscription's token, and ends the key's cooldown, as **Change value** does. A new
  value has the checks of **Key** on **Add key**, and the page never shows it.
- **Workspace settings › Model** has the part **Fallbacks** under Runtime, Model and
  Effort: “When every key of Northwind Claude is in cooldown, runs use these, in order,
  from the next run.” Each fallback has Provider, Model, Another model and Effort, with
  **Move up**, **Move down** and **Remove**. **Add fallback** adds a provider that
  applies to the workspace, serves the chosen runtime, and is neither the chosen
  provider nor a fallback already, with the chosen model where the provider has a model
  of the same id. **Save** saves the fallbacks with the model choice. With no such
  provider left, the part shows “Add another model provider that serves Claude Code in
  Organisation settings › Model providers, then add it here as a fallback.”
- Only a run of Explore uses a model key. Such a run gets up to 6 keys of its model
  provider at its claim, each a separate credential of the run, named after the
  provider's public id: `con_…-1` to `con_…-6`. The run starts with the key chosen in the
  model choice while that key is out of cooldown, else a key with no known reset, the
  default key first, else the key whose known reset is closest. Forager's gateway moves
  to the next key when a key reaches its limit. Where every key of the provider is in
  cooldown, the run gets the keys of the first fallback with a key out of cooldown, and
  that fallback's model and effort. Where every key of the provider and of each
  fallback is in cooldown, the run waits in the queue, and its page shows “Waiting for a
  model key: every key of Northwind Claude is in cooldown until 14:00.”, for the
  provider whose key leaves its cooldown first. The first claim after that time takes
  the run.
- A gateway reports the state of a run's keys with a signed
  `POST /v1/runs/<run_id>/model-keys`: one entry per key and limit window, with its
  status, its reset, its use and its cooldown. Qory Apiary keeps the newest state of
  each key and window, by the time the provider's answer arrived, whichever gateway
  sent it, and the `200` has that state for each key of the run. So a run on another
  machine skips a key that is in cooldown. The route returns `404` without the features
  `factory` and `secrets`, and `410` for a run that ended.
- A run whose gateway ended it at its keys' limit, with the state `paused` and the
  reason `model_key_limit`, ends **Paused**, and so does one with the state `cancelled`
  and that reason, from a gateway of the earlier contract. With another state, which the
  contract does not allow, the run ends in that state, without a pause; the state
  `paused` with another reason, or none, is read as an unknown state. A paused run
  counts as no failure and moves no stage. While its work item is still in Explore, at
  the same take in and stage, that stage runs, and its other runs have ended, a run that
  continues it is queued at once, at the paused run's place in the queue, as the next
  run of the stage. The continuation starts on a new machine, and its session reads the
  paused run's transcript with the signed `GET /v1/runs/<run_id>/resume/transcript`,
  under the feature `observability`, to resume the agent's session. **How it ended** on
  the run page, the work item's runs and the stage show “Paused: every key of Northwind
  Claude is in cooldown until Fri 14:00. It continues in run 15.”, with the run's number
  a link to its page. Once that time has passed, or with no time known, the line is
  “Paused: a key of Northwind Claude reached its limit. It continues in run 15.” A
  paused run that no run continues shows “Paused: a key of Northwind Claude reached its
  limit.” Where the provider was deleted since, the line starts “Paused: a model key
  reached its limit.” A provider that the instance admin set up is not named: the line
  is “Paused: every model key is in cooldown until Fri 14:00. It continues in run 15.”
  while that time is to come, else it starts “Paused: a model key reached its limit.”,
  and a waiting run shows “Waiting for a model key: every model key is in cooldown until
  14:00.” The runs list's Filter menu has the family Paused, with the state Paused,
  between Cancelled and Ended badly, and `state:paused`; a filter of that family alone
  that finds no run shows “No runs paused.”
- A run of Explore that pushed its questions or a proposal, and then reached its keys'
  limit, ends **Completed** with its result: no run continues it, its stage goes on as
  after any completed run, and it shows no Paused line. A result that an earlier run
  of the take in pushed does not count.
- The workspace overview's runs per day count paused runs: the table under the chart
  has **Paused** after **Cancelled**, and each day reads “Today: 6 runs (1 ended well, 1
  cancelled, 1 paused, 3 alive or ended badly), 0 denied attempts, open that day's
  runs”.
- On the run page, **Run the agent** of a session that paused at its keys' limit, and
  its **Agent session**, show **Paused**, with the ring of a paused run, as the run does.
- Qory Apiary stores the transcript of a run's agent session, which the gateway sends as
  `dev.qory.session.transcript` events, up to 64 MiB and fewer than 100,000 chunks for
  each file. It scans the transcript for keys of a known form, as it scans the run's
  events, and the diagnostics leave the transcript out. The daily retention job
  deletes a run's transcript with the run's log output, by **Keep a run's log output
  for**, or by **Keep a run's events for** when the log setting is empty; a paused
  run's transcript stays until the run that continues it ends.
<!-- /feature -->
- `GET /health` returns `set_up` in its `200`: `false` until the instance's first set-up
  and `true` after it, for a deploy script or an instance admin. The `503` has no
  `set_up`, and a `200` has no `set_up` when the lookup fails.

### Changed

- `QORY_FEATURES` unset, empty, `all` or `all-…` turns on every feature: `secrets`,
  `factory`, `workflow_model` and the Paths field of a policy rule's form are on by
  default, and the private image registry's feature, `registry`, is on where
  `QORY_REGISTRY` is set. Up to this change, those values turned on `observability` and
  `security` alone. An instance whose `QORY_FEATURES` is a list keeps the features in the
  list. To keep an instance with an unset, empty or `all` value as it was, set
  `QORY_FEATURES=observability,security` before you upgrade. An `all-…` value stops the
  boot when it leaves out a feature that a feature it keeps needs, such as `all-security`,
  `all-secrets`, `all-factory` or `all-security,path_rules`. Where `QORY_REGISTRY` is set,
  a value that leaves out `security` but not `registry` stops the boot too. To leave out a
  feature, also leave out every feature that needs it, as in `all-factory,workflow_model`,
  or list the features you want.
- When a run escalates, the work item page shows the block “What the run needs from
  you”, with one numbered item for each point: the run's sentence on what is wrong or
  missing, then what you can do, “Answer question 4.”, with “question 4” linked to the
  question, or “Run another round.” A stop cause that has a fix, such as “Owners and
  admins choose a harness.”, shows that fix in place of “Run another round.” The block
  takes the place of the red banner “The run ended without a result” at the top of the
  Explore tab or of the stage's area, and the stage's note field and **Run another
  round** sit in it. In the side panel, the line “Waits for you: 2 points” links to the
  block; **Accept as it is**, **Move back** and **Close** stay there and take the note
  too. The step card is hidden while the stage is escalated. For a cause Qory Apiary
  sets itself, it writes one point: “3 of 3 rounds ran.”, “No spec was stored in this
  stage.” for each failed check, both at a round limit after failed checks, “The run
  stopped: it ended without a result.”, or “The run stopped before its verdict.” An
  escalation that was open before this change shows the agent's text as its points, one
  for each line. For a cause Qory Apiary sets itself, it shows the point of that cause.
  After a failed check whose outputs were all stored since, it shows no point. An
  `answer` point whose question the run withdrew asks for another round instead. A run
  that leaves questions open and escalates waits for answers first: its escalation is
  kept, the block shows its points above the questions, and the answers run the next
  round and resolve it; **Accept as it is**, **Move back** and **Close** are refused
  while the answers wait. “Waiting on you” counts an escalated work item for the
  approvers its gate lists who may resolve the escalation, else for its owner. A work
  item that left Explore while its proposal still waits, as after Explore's gate `none`,
  is not highlighted in the Work items list and is not counted in “Waiting on you”.
  Where a run ends without a result, with an error, lost or cancelled, and a proposal of
  an earlier round shows below its banner, the banner says “The proposal below is from
  an earlier round.” in place of “There is nothing to show or approve.”, and the
  proposal shows “· from an earlier round”. A run's verdict has `points` in place of
  `gaps`: 1 to 20 points, each `{text, action, question?}`, with `action` `answer` or
  `run_again`, required with `escalate` and absent otherwise; the schema is a copy of
  qory's `contracts/harness/v1/verdict.schema.json`. The run API refuses a verdict whose
  `answer` point is about a question that is not open: “Push the questions first, or
  point at an open question in verdict.json: point 2 is about question q7, which is not
  open.” The work item's answer to a run has `verdict.points` in place of
  `verdict.gaps`.
- Making a pool needs `node.set_limit`, the action that sets a pool's machine limit,
  with a limit or without one. One who may make machines and pools but may not set the
  limit is refused the pool; before, such a pool was made with a limit of 1. That person
  sees no **New pool** on **Machines**, in the **New** menu or in the workspace
  overview's **Send your first run**, and no **Add pool** on the set-up's **Machines**
  step. On an empty **Machines**, they read “Add a machine for one computer that stays
  registered.”, and `/machines/new-pool` shows “Ask an owner or admin to add the pool.
  Adding a pool needs the right to set its machine limit.” Owners and admins hold both
  actions, so what they can do stays the same. A machine's limit stays 1.
- Every workspace has a security policy, version 1, and each machine applies it narrowed
  by the `egress` section of its Forager file. With version 1, a run gets no tools and no
  credentials from the Forager file, and a machine in observe no longer reaches a private
  host in `gateway.egress.allow`.
- At start, and from `bin/migrate`, Qory Apiary writes a new policy version for each
  workspace whose document changes, shown as “Qory Apiary changed the policy”. The same
  render runs from `bin/apiary eval "Apiary.Release.policy_rerender()"`. If the key check
  fails, none of the three renders a policy, and the log has the line “Set
  APIARY_ENCRYPTION_SECRET and APIARY_SIGNING_SECRET to the instance's keys and run
  bin/migrate again: policy version 1 is not written and no policy is rendered again,
  because the key check failed.”
- A deny rule of a runtime's host is refused: “Remove api.anthropic.com from the rule.
  Claude Code needs this host, so no rule can deny it.” A rule that holds a runtime's
  host to paths is refused too: “Remove the paths from the rule. Claude Code needs every
  path on this host, so no rule can limit it.” A `*.` rule with paths is saved, and the
  runtime's host stays on every path. The rule form shows each refusal under **What this
  rule does** before **Add rule**.
- **Export** of a policy allows each runtime's host in `allow`, in the Forager file and
  in the policy file, once, sorted in with the other names. The export leaves out a deny
  of a runtime's host and the paths that a rule holds a runtime's host to, and writes
  `/*` for a runtime's host that a `*.` entry held to paths covers, as the served
  document does. A `*.` deny written in the file still blocks the runtime's host there,
  while a run served by Qory Apiary reaches it. The **Export** panel then shows the note
  “A `*.` deny still blocks a runtime's host that the text lists as allowed.”, and shows
  no note when the text has no `*.` deny that covers a runtime's host. A saved `*.` deny
  that an allow outranks is left out of the file, as before.
- The count of attempts with no rule on the Policy page, the list when you pick
  **Enforce**, and **Enforce would deny N destinations** on the Overview leave out the
  hosts of the runtimes, the integrations and the model providers, which enforce does
  not deny. A rule's paths on an integration's or a provider's host still count, because
  the document keeps them. Before, those three counted such a host as a destination
  enforce would deny. The Policy page's mode card shows “No run has reached out in the
  last 14 days.” only when no run reached out. When runs did, it shows “Every
  destination that runs reached in the last 14 days is covered by a rule or allowed for
  every run.” in observe where that is true, and “No destination that runs reached in
  the last 14 days was denied.” in enforce where none was.
<!-- feature: secrets -->
- `mix apiary.policy.rerender` prints “Rendered N workspaces again: M new versions, R
  refused, F failed.”, with “workspace” and “version” for a count of 1, such as
  “Rendered 1 workspace again: 1 new version, 0 refused, 0 failed.”, and exits with
  status 1 when a workspace's render raised or exited.
  Before, it printed the workspaces and the new versions only, and exited with status 0.
<!-- /feature -->
- The run page's **Timeline** shows an overview of the run: its stages, a row for each
  agent, the agents' messages, the artifact versions the run pushed, failures, denials,
  and the tool calls that were the only call running when a network connection was made.
  Each row that has a duration shows it under **Took**, and each row with a line in the
  **Terminal** links to that line. The **Terminal** lists every tool call.
- A run's Timeline folds each subagent into one row: its agent type, how long it ran or
  that it is running, its calls, and the first line of its last message. A finished
  subagent is closed and a running one is open. The row's chevron shows or hides the
  subagent's events, which stay in time order among the other agents' events. A link to
  one of those events, or the subagent's lane button, opens the subagent. The x and
  Shift+x keys move to the next and previous denied call, including one inside a closed
  subagent, and open that subagent.
- A run's Timeline loads more rows only through **Load earlier** and **Load newer**, so j,
  k and x work on a run with more than 300 items. The buttons count only events, and show
  no count of 0. The window drops rows only past 600 rows on the page, so **Load newer**
  skips no row.
<!-- feature: factory -->
- The Qory Apiary release contains no copy of the Qory harness. Qory Apiary reads the
  repository at `QORY_HARNESS_URL`, default `https://github.com/qoryai/harness`, at boot
  and every 5 minutes, and keeps each commit's files in the database. A test work item
  reads `examples/hello` on `main` of `QORY_BUILTIN_HARNESS_URL`, default
  `https://github.com/qoryai/qory`. Allow the server outbound HTTPS to the hosts of both
  repositories (`guides/install.md`).
- After a run on the Qory harness is queued, Qory Apiary reads the harness once. If the
  host is out of reach or returns `502`, `503` or `504`, the read runs again after 10 s
  and after 30 s, and the third failure ends the run before it starts. Any other failure
  ends the run at once.
- When a machine claims a run on the Qory harness, Qory Apiary reads the commit that the
  branch, tag or commit in the workspace's harness settings is at, and the machine
  composes the harness at that commit. A run at a full commit id makes no read at claim.
  A ref the repository does not have ends the run before it starts. If the read times
  out, finds no address or connection, or the host returns `429`, `500`, `502`, `503` or
  `504`, the run stays queued, and it ends if the reads still fail 10 minutes after the
  first failure. A run on a harness repository runs at the commit Qory Apiary read when
  the run was queued. With the `workflow_model` feature, a run on a branch composes the
  commit its process version came from, with no read at claim.
- **Request a machine** on a run's page shows “pool default” only for a run whose pool
  sent no offers in its claim. A run on a machine type shows the type and its spec.
- A run's page shows the run's work item first on the line under the title, such as
  “#1 Add currency to orders”, with a link to the work item's page, as the runs list
  shows it. That line no longer shows the work item's id as one of the run's subjects;
  Details still does. For a run with no work item, the line is unchanged.
<!-- /feature -->
<!-- feature: workflow_model -->
- The hint “It does not choose the machine that runs it.” under **Default machine type**
  on Workflows and on Instance settings › Workspace types is gone. On Workflows it reads
  “Workflows that pick no machine type run on this one. The people who run this Qory
  Apiary add machine types.” On Workspace types it reads “New workspaces of this type
  start with this default. Add machine types in Instance settings › Machine types.”
- The stage form and a member's read-only panel show Inputs, Sequence, Outputs, and Gate in
  separate boxes, and each workflow's machine type opens from its row. A machine type that
  a save refuses shows an error on its row.
- The software workspace type's default stages and texts come from the Qory harness that
  Qory Apiary reads from its repository. Its Explore stage runs `explore-a-ticket` once
  per run, without a loop of 3 rounds. An instance with no save on Instance settings ›
  Workspace types gets them as one more version of the type. New workspaces copy that
  version.
- A workspace on a harness repository no longer has `explore-a-ticket` added to the
  workflows it lists: a stack that does not list it gets a cross on Stages, and Explore
  waits. A workspace on the Qory harness gets the same cross when its stack does not
  list it: `core` lists no workflows, so Explore waits there.
- The copies of the run, explore, integration and provisioner contracts are at
  integrations commit `e33240a`, and the copy of the diagnostics contract at `8178d27`,
  which adds the run's machine type, `run.machine`. A workflow name has at most 55
  characters: a lower-case letter, then lower-case letters, digits and hyphens.
  Workflows shows “Write a workflow name of lower-case letters, digits and hyphens that
  starts with a letter, at most 55 characters.”
<!-- /feature -->
<!-- feature: factory -->
- A run's requests to the run API show the host of `PUBLIC_URL`, such as
  `qory.example.com`, with no port, in place of `run-api.qory.invalid`: on Network access,
  on a run's Network access and Timeline, in the runs list's preview, in the workspace
  overview's To review, and in a repository's “Denied, 14 days”. The `host:` filter, the
  search and the Host filter find them by either host, and **Copy** copies the host shown.
<!-- /feature -->
- An action that starts a run or a build machine opens a confirmation dialog over the
  page first: the action's name as a question, what starts and whether the run uses
  model tokens, the action's note where it has one, and Cancel. Run Explore again, the
  stage card's Run another round and Rebuild open it on every click. Explore's **Run
  another round** opens it where it sends an answer, a comment or open comments; Run the
  test opens it for a line that is not blank while no test run is running. Approve,
  Request changes, Accept as it is, Move back, Check again and Add version open it only
  where they start a run: a stage with no workflow starts none.
<!-- feature: factory -->
- Take in, Take in again and Take in here open a wide dialog before anything starts:
  the ticket's text and comments on the left, and an optional comment on the right,
  which is added to the ticket's comments and posted to the ticket at its source where
  the source takes comments. The work item's Ticket tab shows each such comment as
  “Posting to <source>”, “Posted to <source>” with a link, or “Not posted to
  <source>” with the reason and **Post again**, where <source> is the name of the
  ticket's source. The ticket over the Backlog shows which work item a ticket whose
  work item ended is, who closed it or undid the take in and when, with **Take in
  again**; for a work item in another workspace the row reads “In <workspace>” and
  the button **Take in here**; a person who may not read that workspace sees **Take in
  here** on the row too, without the workspace. Details no longer has a First
  instruction row. Beside **Undo**, the work item shows that Qory Apiary removes its
  label from the ticket, and that the comment of the person who took it in stays,
  where they wrote one.
- A person approves a proposal with **Approve**, which replaces **Confirm** on the
  gate's button, the stage name, the status lines, the Thread, the audit label and the
  permission.
<!-- /feature -->
- A harness document's `bind`, in Workspace settings › Harness and the set-up's Harness
  step, is set by kind, then by role: `bind: {agents: {developer: web-developer}}`. Only
  the kinds `agents`, `commands` and `skills` are taken, with one name per role. A save
  of a flat key fails with “Write bind by kind, then by role, such as bind: {agents:
  {developer: web-developer}}: agents/developer is a flat key.”, of another kind with
  “Use agents, commands or skills under bind: tools is not a kind.”, and of a list of
  names with “Give one name per role: bind.agents.reviewer is a list.”
- The pages people in an organisation read no longer contain “instance”, “instance admin”
  or “this server”. Where only support can fix a case, the page shows “Contact support”,
  which links to the support address where one is set, and what Qory Apiary offers is
  named “Qory Apiary”. **Add an integration**, the work source and destination lists, and
  a target's Environment card keep their old lines for an instance admin. An integration
  that cannot be installed yet shows only to an instance admin, unless the organisation
  already has a connection to it. A flash or a form error has no link, so the support
  address follows “Contact support” there. The 503 error of the registry token endpoint
  contains “contact support” in place of the instance's log.
- `Apiary.Edition` has no callback `first_workspace_line/1`, and the callback
  `machines_who_may/2` takes the scope and the workspace, with no `:instance` pool:
  organisation people no longer see a Qory Pool that is not ready on the Machines step.
  The fixer of a stopped
  preparation (`Apiary.Runs.Preparation`) is `:support` in place of `:instance_admin`; the
  diagnostics document keeps the value `instance_admin`.
  The callback `connects_line/2` of `Apiary.Edition` returns an edition's sentence on who
  connects a system, for the steps Work sources and Destinations, or nil for the core's.
- The guides Install and configure and Hosting checklist are only for signed-in instance
  admins: `/docs` leads an instance admin to `/docs/admin`, which has every guide, and
  gives anyone else 404 there. The public documentation leaves them out of its pages,
  sidebar and search, and a link to them is its words. `mix docs` builds both trees. The
  guides stay in the repository's `guides` directory.
- Each workspace counts its runs from 1, and the console shows a run by its number and
  uses the number in its address: "Run 3" at `/acme/main/runs/3`, in the run page's header
  and breadcrumb, the Runs list, the Overview, a work item's page, Activity and the search
  results. A work item that moves into a workspace whose count is lower raises that count
  to the work item's highest number, so the workspace's numbers jump. A run's title, when
  it sent one, is the line under the header. An address with the run's `rn_`
  id, such as a link built from the API, sends on to the number's address in the same
  workspace. An address with a number the workspace does not have shows not found.
  Details shows **Run id**, the `rn_` id, with Copy, the run's menu copies the `rn_` id,
  a line that sends you to support has the `rn_` id, and the file name of a downloaded log
  is that id, `rn_0123456789abcdef.log`. A run's place in a take in reads "Attempt 2 of
  3". The API keeps the `rn_` id, and the diagnostics endpoint,
  `GET /v1/runs/<run id>/diagnostics`, takes only the `rn_` id; a number is `404`
  `not_found`.
- The Runs list shows, for each run, the workflow it ran (such as `explore-a-ticket`,
  with the stage and round that placed it), its work item as a link, and how it started,
  such as "Taken in by dana". The Host column is gone, and the Target column and the
  rail show only where a run has a target. `item:3` in the query, or the Filter menu's
  Work item section, keeps the runs of work item 3. Below 640 px a run is a card.
- A run's harness, Workspace settings › Harness and the set-up's Harness step read a
  public harness repository from its host over HTTPS, with no connection and no
  adapter: a repository the host serves to anyone is public. A harness source that is
  neither linked nor public fails with “… is not public, or does not exist, and no
  connection of Acme reaches it.” A repository too large to read, a host out of reach or
  on a private address, and a host that serves no git repository each fail with a
  separate line: the fix, then the cause. An instance admin allows the Qory Apiary server outbound HTTPS to
  each host the harnesses use, such as `github.com:443`.
- The workspace's **Nodes** page is **Machines**, at `/<organisation>/<workspace>/machines`:
  machines and pools first, then the gateways under the heading **Gateways**. On every
  page a node is a machine, a node pool is a pool, and an instance of a pool is one of
  its machines: **Machine limit**, **Running machines** and **Clear machine…**.
  **Instance settings › Nodes** is
  **Pool and gateway**, a page headed **Qory Pool and Qory Gateway**, at
  `/instance/qory-pool-and-gateway`. The old `/nodes`
  addresses send on to the new ones. The runs query takes `machine:`, and `node:` still
  works.
- An organisation's address follows its name, as a workspace's does. A rename in
  Organisation settings › General changes it, the page opens at the new address, and
  links to the old one stop working, with no redirect. A sign-up, the set-up link's page
  and the release command's claim make the address from the name too. A name whose
  address another organisation has, or Qory Apiary keeps, is refused there, never
  numbered: “Choose another name. Another organisation has the address /acme.” The audit
  log records the old and the new name and address of a rename.
- A name of an organisation or a workspace with no letter or digit from A to Z or 0 to 9,
  such as “—”, is refused at a sign-up, a creation and a rename, with “Choose a name with
  at least one letter or digit from A to Z or 0 to 9. The address is made from those
  characters.”
- Where the documentation is not built, `/docs` shows `mix docs` on a separate line, in
  code font, with an icon button **Copy command** that copies the command alone.
- An enrolment code starts with the prefix of its node's kind: `qecn_` for a node, `qecp_`
  for a node pool and `qecg_` for a gateway, then its 26 characters as before. A code
  enrols a key only on a node of the kind its prefix names; a code with another kind's
  prefix is refused as an unknown code is. A code made before the upgrade, `qec_`, no
  longer enrols: get a new command.
- Network access: a destination's row that shows “Rule added”, “Rule changed” or “In
  force in this run” gives its reason in the past tense, such as “No rule matched.
  Enforce mode denied it.”
- The organisation slug `integrations` is reserved as well: a sign-up or a rename to the
  name Integrations is refused with “Choose another name. Qory Apiary keeps the address
  /integrations.”
- An account's email address, at sign-up and when it is changed, and an invitation's
  address refuse a control or format character (a right-to-left override, a zero-width
  space and the like), a Unicode space, and bytes that are not UTF-8 text. Their 160
  characters are counted in code points, so a letter's accent marks count too. An account
  whose address already holds such a character still logs in with it. An invitation to an
  address with a NUL in it is refused with the address's error, not a server error.
- The AWS CloudFormation template is removed. A Qory Apiary release no longer attaches
  `apiary.yaml`.
- Forager opens a run once, at its gateway, and each session joins it. The events endpoint
  takes `dev.qory.run.started` only with `opened_by` `run`, and each session as
  `dev.qory.session.started` and `dev.qory.session.exited`. A batch with a
  `dev.qory.run.started` whose `opened_by` is absent or `session`, as Forager 0.7.0 sends
  it, gets `400 invalid_request`. Qory Apiary reads runtime events under their
  `dev.qory.runtime.*` names, and a run's runtime, command, image and terminal size are
  those of its last session with a runtime. A run recorded before the upgrade keeps its
  runtime, cost and log, and its Timeline shows no prompts, turns or results. Do not run
  `Apiary.Release.rebuild()` after this upgrade: it clears the runtime and cost of those
  runs, and the command, arguments, folder, image and terminal size.
- A gateway's address follows the contracts' rule: `https://`, a host name or an IPv6
  address in brackets, an optional port, and nothing after them, at most 300 characters.
  Before, an address could end in a dot and be up to 2,048 characters long. Qory Apiary does
  not start while a gateway's address breaks the rule: the migration stops, lists those
  gateways' ids, deleted gateways included, and changes nothing. Give each gateway that is
  not deleted a new address in its **Settings › General** on the release before, then
  start the upgrade again.
<!-- feature: secrets -->
- An integration description is refused when it goes past the limits the integration
  contract states (1024 list entries, 1024 members in an object, 4096 values, strings of
  16 KiB, 64 levels of nesting) or when an object in it repeats a member. An integration's
  settings are checked within a time and memory limit, and schemas no longer create atoms
  or apply casts.
- An integration's settings check counts large text toward its memory limit.
- An integration's settings check refuses a schema, or settings checked as regular
  expressions, whose patterns would take more than 16 MiB of memory once compiled.
<!-- /feature -->
<!-- feature: factory, secrets -->
- The access action `connection.write` is split in three. `provider.write` covers model
  providers, their keys and models, and the organisation's default model choice;
  `runtime.write` covers runtimes; `connection.write` keeps integrations, services, an
  integration's release and the organisation's service definitions. Owners and admins hold
  all three, so what they may do is as before; an edition can grant one without the
  others. A change to a model provider or a runtime leaves an audit entry of its new
  action, and the Audit log's “Integration changed” filter finds the entries of all
  three, those written before the split included.
<!-- /feature -->
- The sign-in cookies are `__Host-` cookies with `Secure`. The upgrade signs everyone out
  once. Over plain `http://`, sign-in works only in Chrome and Firefox, on `localhost` and
  loopback addresses; for any other host, Qory Apiary logs a warning at start.
- The image runs as uid and gid 65532 in place of `nobody` (65534). The Compose service
  `keys-owner` gives the volume `keys`, and everything in it, to 65532 at every start,
  without following a symbolic link. Without Compose, give the volume `keys` and its
  contents to 65532 before the upgrade, or the release cannot read the keys.
- The set-up link creates the instance's organisation and its owner's account with no
  workspace. After **Connect Qory Apiary**, the owner creates the first workspace on the
  kind cards of the organisation's overview, `/<organisation>`. Until the organisation
  has a workspace, each sign-in of a member of the organisation opens that page.
  On a new instance, `Apiary.Release.grant_instance_admin/2`, the release command an
  instance admin runs, creates no workspace either. Where an edition offers a sign-up
  without an invitation, that sign-up creates no workspace either. Before you load the
  demo, create a workspace and name it Main: `Apiary.Release.demo()` writes nothing while
  Acme has no workspace Main.
- Where a step of the set-up needs context, its page has a column headed “About” and the
  step's topic, such as **About harnesses**, beside the form, or under it below 1024 px,
  that shows what the step does.
<!-- feature: factory -->
- **Organisation settings › Model providers**, **Workspace settings › Model** and
  **Workspace settings › Harness** have a column headed “About” and the page's topic,
  such as **About model providers**, beside the form.
  **Provider**, **Model** and **Workflow source** are choice fields.
- The `factory` feature needs `secrets` as well as `observability` and `security`: a
  `QORY_FEATURES` list with `factory` and without `secrets` stops the boot. Set
  `QORY_FEATURES=observability,security,secrets,factory`; `all` leaves `factory` off, as
  it leaves off every opt-in feature.
- A set-up pass now includes the instance organisation's short name (organisation_slug).
  An adapter may use it to suggest a name, such as the GitHub App's name.
- Pages show an adapter's title from its description, such as GitHub, in place of its
  short name, such as github. The short name stays in settings and identifiers.
- Qory Apiary calls an adapter whose host resolves to a loopback address, `127.0.0.0/8`
  or `::1`, so an adapter may run on the instance's machine. Link-local, metadata,
  unspecified, multicast and broadcast addresses stay refused, and the host must still be
  `<adapter name>.<host of PUBLIC_URL>`.
- With `SSL_CERT_FILE` set to a PEM file, adapter calls trust its certificates in
  addition to the operating system's certificate authorities, and still check the
  certificate and the host. A file that is missing or contains no certificate stops the
  boot.
<!-- /feature -->
- An organisation at the address `/work-items` moves to `/work-items-2`, because
  `/work-items` is now reserved for the addresses of work items.
- Account settings, **Connect Qory Apiary**, and Instance settings › Mail and ›
  Configuration accept a sign-in from the last 15 minutes, up from 10: the time a set-up
  pass of the GitHub adapter lasts.
- A run keeps the runtime, command, image and terminal size of its last session with a
  runtime when a helper session with no runtime starts or resizes its terminal. A run with
  only helper sessions shows the values of the first one.
- A run whose machine never started it stays as a failed run, with its page and id. The
  cause is one of: the pool made no machine, the claim lapsed before the handover, or the
  machine stopped before it started the run. The run page, its preview and the runs list
  show the cause, the pool's name and the pool's reason. A run whose machine stops before
  it starts the run ends failed at once, not 15 minutes later.
- A run that did not start because its settings did not pass a check on the machine shows,
  on its page and in the runs list's preview, “The run's settings did not pass a check on
  the machine (image_unknown).” in place of “did not start: image_unknown”, and for
  `engine_unreachable`, “The machine could not check an earlier run's container
  (engine_unreachable).” Any other code keeps “did not start: <code>”.
<!-- feature: factory -->
- With a private image registry set (`QORY_REGISTRY` and the `registry` feature), Qory
  Apiary sends each prebuild the image address of its target, under the instance and the
  organisation, and a run starts only in an image at its organisation's address. A run
  whose stored image is elsewhere starts in the pool's default image. Without a registry,
  no prebuild runs, and a target's page shows “Ask an instance admin to set up a registry
  to build this target's environment image. Until then, runs start in the pool's default
  image.” A prebuild in a workspace with no policy version runs under Qory Apiary's
  default policy, in observe mode with the hosts the integrations require, and its run
  page shows why on **Not a version made in this workspace**.
<!-- /feature -->
<!-- feature: factory -->
- A work item has no Declined state. A person who does not want a work item closes it,
  and **Take in again** in the Backlog brings it back. **Decline** and its question
  “Decline work item #12?” are removed from the step card, the questions and the
  run-limit card, and the **Declined** tab from Work items and the Backlog. The tabs of
  Work items are **Open**, **Waiting on you** and **Closed**. The run-limit card shows
  “To explore again, close the work item and use Take in again in the Backlog: the run
  count starts again, without this take in's answers.”, or “Close the work item if it is
  not wanted.” where the Backlog is off, and **Close work item…** for whoever may close
  the work item. The upgrade closes every declined work item (Migrations). Activity
  still describes an earlier decline as “Declined a work item”, and its filter no longer
  offers “Work item declined”.
- At Approve, the step card shows “Approve the proposal, or add a comment and run
  another round.” and **Read the proposal**, which opens the **Explore** tab, where
  **Approve** is. A reader who may not act reads “You approve next” or “Dana approves
  next”. A person changes a proposal with a comment: **Change**, the edit page with
  **Confirm changes**, **Show Qory's words**, the caption “Qory shows it as plain text”
  and the proposal's sections (Complexity, Understanding, In scope, Out of scope,
  Approach, Not chosen, Facts and sources) are removed. The edit page's address,
  `/<organisation>/<workspace>/work/<number>/explore/edit`, returns 404. A proposal
  stored before the upgrade has no Markdown text: its frame shows the caption and no
  text.
- When a ticket closes at its source, Qory Apiary closes its live work item in the same
  transaction, and the work item shows “Closed when its ticket closed”. A run not yet
  handed to a machine ends; a run already handed over goes on to its end, and its result
  moves no stage. A ticket that moved to another collection of the same adapter, and is
  open there, closes no work item. Qory Apiary writes no audit entry for this close.
- The Backlog has two tabs, **Open** and **Taken in**. A ticket closed at its source
  leaves the Backlog: it is in neither tab, and its filter values go with it. Its ticket
  page still opens at its address.
- Explore's contract follows integrations commit `e33240a`. A run of Explore returns no
  result: `result.schema.json` is removed, and the run pushes `proposal`, `questions` and
  `review-comments` through the run API, where it reads them too. The run's inputs no
  longer have `answers`, `proposal`, `changes` or `run.of`, and `attempt` has no maximum.
  `GET work-item` no longer returns `answers`; a note of kind `answer` is an answer, a
  review comment or a reply. A version of `proposal` is one Markdown file of up to
  256 KiB, PNG, JPEG, GIF, WebP or SVG images, and an optional `sources.json`, at most 10
  files and 5 MiB together; an SVG uses only the elements and attributes that
  `docs/contract/run-api.md` lists. A question in `questions` has 0 to 4 `options`, each
  a `title`, an `explanation` and an optional `recommended`, true on at most one option
  of the question. `questions` and `review-comments` take only the name `main`, and a
  run's version that changes what members wrote returns `422 invalid_artifact`. A JSON
  file of a standard type with a key twice in one object returns `422 invalid_artifact`.
  A push that the end of its run overtakes returns `409 run_ended`, and no version is
  stored. Explore needs the `workflow_model` feature: without it the run API returns 404,
  and every run of Explore ends with no result.
- The access action `work_item.decline` is removed. **Close work item…** on the run-limit
  card needs `work_item.close`.
- After a run ends, a node pool with a machine limit waits until its starter reports the
  run's machine `gone`, or up to 1,530 minutes after `dispatched` (150 minutes for a
  prebuild). A starter that never reports `gone` keeps each slot that long. The limit
  counts the machines that may still exist. A claim whose machine was made, by
  `dispatched`, by the redemption of its run code, or by a report to
  `POST /v1/dispatches/<dispatch_id>/machine-end`, keeps its slot after its run ends,
  after a release or a close, until the starter reports the machine `gone`. `deleting`
  and `delete_failed` keep the slot. A claim with no machine frees its slot when it
  ends, as before. A lapsed lease still frees the slot and puts the run back in the
  queue. A machine that shows up after the slot was freed takes the slot back, even past
  the limit, so the pool's next claims wait: after a lapse, a release, a close or an
  undo, a `dispatched` refused with `409` or `410`, or a report other than `gone`; after
  a lapse, a release or a close, a run code redemption refused because the claim is
  stale or ended. The 1,530 or 150 minutes are the machine's lifetime (1,470 or 90) plus 60,
  counted from the last `dispatched`, handover, report or late machine, or from the
  claim when there is none. The endpoints' responses do not change.
<!-- /feature -->
<!-- feature: workflow_model -->
- On **Work items**, every tab shows a box for each stage of the workspace's process,
  with the stage's name and how many live work items are in it under the search and the
  filters. A stage that the current version removed keeps its box while work items are in
  it, with “From version 2. This stage is not in the current version.” The boxes list no
  work item. **Open** groups its rows under a heading for each stage, with the stage's
  count; a stage with no row on the page has no group, and a group has nothing to fold.
  A row under its group leaves out the stage's name: “Explore · Waits for a person”
  becomes “Waits for a person”. **Open** shows “Work items at a stage of the process. A
  finished one moves to Closed.”, and **Closed** shows “Finished work items, and work
  items that stopped: a member closed one or undid its take in, its ticket closed, or its
  integration was removed. Where the ticket of a stopped one is still in the Backlog,
  Take in again brings it back.”
- A work item closes when its last stage finishes, with no person, and shows “Every stage
  done” in **Closed** and in its Thread. In **Closed**, a work item with every stage done
  has an amber ring, and one that ended any other way a grey ring. Its ticket stays in
  the Backlog's **Taken in**, with a link to the work item and no **Take in again**,
  until the ticket reopens at its source. A reopened ticket shows in **Open** with
  **Take in again**, which moves the same work item back to Explore at attempt 1 of 3;
  the work item's page offers **Take in again** too. A work item whose last stage
  finished before the upgrade stays in **Open** until a person closes it or its ticket
  closes.
- An escalation card has no **Decline**. Its other buttons stay.
- The artifact type `proposal` is a document: one Markdown file of up to 256 KiB, in
  place of structured JSON, with images and an optional `sources.json`, up to 10 files
  and 5 MiB. A `questions` artifact contains every question of a work item with its
  answers, up to 1 MiB; a question has 0 to 4 `options`, and an option has an optional
  `recommended`, at most one per question. `review-comments` is a new standard type, up
  to 1 MiB. The page of a `questions` version shows each question's `context` as
  Explore's tab does, with raw HTML dropped and links only to http, https and mailto
  addresses.
<!-- /feature -->
- In a run's **Details**, the image a run started in has an **Image** row after
  **Wall**, and **Policy** and **Policy in force** show only for a run whose policy
  event arrived.
- Only an instance admin takes the instance actions: `instance.read`,
  `instance.review_connections`, `instance.mail_save`, `instance.mail_resend`,
  `instance.mail_on`, `instance.rename`, `instance.configure`, `instance.support_save` and
  `account.password_link`. An instance admin is an owner of the instance's organisation
  whose membership is not suspended and whose account is in use. A person outside that organisation gets not
  found, and an admin or a member inside it gets forbidden. A release command still makes a
  password link.
<!-- feature: observability -->
- `instance.read_observability`, `diagnostics_key.create` and `diagnostics_key.revoke` are
  instance actions.
<!-- /feature -->
<!-- feature: factory -->
- `instance.read_factory`, `adapter.create`, `adapter.edit`, `adapter.set_interval`,
  `adapter.delete`, `adapter.setup`, `node.set_instance_limit`, `harness.assigned` and
  `harness.unassigned` are instance actions.
- A gateway's request for a run's work credential while `factory` is off returns 404, with
  no call to the adapter and no Activity entry.
<!-- /feature -->
<!-- feature: workflow_model -->
- `workspace_type.edit` is an instance action.
<!-- /feature -->
<!-- feature: observability -->
- Two access actions are added: `run.list_instance`, which a diagnostics key takes to
  list the instance's runs (`GET /v1/runs`), and the instance action
  `instance.read_machine`, which shows an instance admin **Started as (instance admins)**
  on a run's page.
<!-- /feature -->
- An instance admin who stops being one while a page of Instance settings is open moves to
  `/`. Before, the page and its buttons stayed until it was reloaded, and each save failed.
<!-- feature: factory, secrets -->
- The Keys column of **Organisation settings › Model providers** shows how many keys each
  provider has and how many of them are in cooldown, such as “3 keys, 1 in cooldown”, in
  place of a number. A provider's page shows each key's state in place of a mask.
<!-- /feature -->

### Fixed

- A run's notes on missing session events sit inside or after the run's steps, never
  above them. Each Claude Code session's **Run the agent** has the note about the wall
  or the hooks, and each session on another runtime the note about its runtime. A run
  whose sessions ran no agent has the runtime note after the list, above the Timeline.
  Before, such a run showed no runtime note, and a run of Claude Code and another
  runtime lost the note about the wall.
- A prebuild's run page shows **Save the outputs** failed, with a cause line, when the
  image was not saved: its report failed the check that stores it, or the run failed
  after the build and sent no image. “How it ended” shows the first sentence of that
  line. A prebuild lost or cancelled after its build shows **Save the outputs** failed
  too, and “How it ended” shows that sentence only when the run has no other line on how
  it ended. The cause line shows the addresses that differ and what to do. Before, the
  step read “Outputs saved” for an image that was not saved, or had no row, and Build
  the image was green. A long image reference wraps inside the step's column instead of
  covering **Details**.
- Where the run's Terminal is hidden from a reader, the run's Timeline, header and
  Details show no text of the session: no prompt, text, command, argument, tool input or
  output, subagent message, notification message, or error. Each row keeps its kind,
  tool, agent, status, times and counts. Before, the run page showed these texts beside
  the hidden Terminal.
- A run's page shows “No heartbeat for 47 s”, counted from when the workspace first
  heard of the run, for a running run with no heartbeat after one heartbeat interval.
  Before, the page ended in an Internal Server Error for a run with no event either, and
  the count restarted at each event for a run with events.
- A page of a workspace that is open when its test run passes, such as the run's page,
  drops the sidebar's group Set up within a second. Before, the group stayed, with the
  Test run step not done, until the page was opened again.
- The built-in harness uses qory's hello example at a commit that allows extending it.
  With the earlier commit, composing the built-in harness failed, so every test run
  failed.
- Clicking a lane on a run page, or opening a run page's address with `?lane=`, keeps the
  browser tab working. Before, the tab stopped responding.
- A password change after a sign-in that is no longer recent leads to the log-in page with
  “You must re-authenticate to access this page.”, and changes nothing. Before, it failed
  with a 500 error.
<!-- feature: factory -->
- A person who may not connect an integration gets not found (404) at
  `/<organisation>/settings/integrations/<adapter>/install`. Before, they got 403.
- On a target's page with no registry, an instance admin reads “Set `QORY_REGISTRY` on the
  server to build this target's environment image. Until then, runs start in the pool's
  default image.” Before, the line read “Ask an instance admin to set up a registry to
  build this target's environment image. Until then, runs start in the pool's default
  image.”
<!-- /feature -->
<!-- feature: factory -->
- A read-only run that qory closes shows a line on its run page, such as “read-only run
  with no wall”, in place of its code. Its work item shows the fix, then the cause. On an
  installed pool, “Contact support.” replaces a fix in the machine's forager.yaml.
<!-- /feature -->
<!-- feature: workflow_model -->
- Explore starts on a work item of a software workspace made before the upgrade that
  added `workspaces.qory_stack`. This covers a work item taken in after this upgrade, and
  one shown as waiting for a workflow when you click **Check again**. Before, runs of such
  a workspace used the Qory harness at the stack `core`, which lists no workflow, so the
  work item stayed waiting for `explore-a-ticket`.
- A workspace made from a template runs Explore with no workflow saved on the Harness
  page. The Workflows page checks each workflow against the stack the workspace's runs use.
- Texts about a workflow the Qory harness does not list, and the quickstart guide, point
  to **Workspace settings › Workflows** and its **Details** tab. Before, they pointed to the
  Workflow page, which the settings menu does not list with this feature on.
- The stage's Runs list shows a run that an undo ended as undone, not as ended without a
  verdict.
- A run of Explore that pushes the verdict `escalate` escalates its stage with the
  verdict's points, as a run of any other workflow does, and the work item page shows no
  **Approve**. Before, such a run read as a run with no verdict, and the work item page
  showed **Approve** on the newest proposal, also one an earlier run wrote.
- Make `qory run verdict passed` the last step of each workflow entry outside a loop. A run
  of such an entry that ends with no verdict and no open question stops the stage with "The
  run stopped before its verdict.", **Run another round** and, where an output has a
  version or no output is required, **Accept as it is**. Before, the stage went on to the
  next entry, and after the last entry to its checks and its gate. **Accept as it is** goes
  on to the next entry. After the last entry the stage reaches its gate. At a gate `none`,
  it enters the next stage, or closes the work item at the last stage. `changes-requested`
  goes on. A test work item's run needs no verdict. Nor does a run of Explore whose take in
  has a proposal, or that left open questions.
- While the stage card at Explore shows **Waits for a person**, whatever the cause, the page
  shows no **Confirm**, and a confirmation from a page opened earlier writes nothing.
  **Confirm** shows again once the stage reaches its gate.
<!-- /feature -->
<!-- feature: factory -->
- **Take in again** on a Backlog row brings the work item back and opens its page, or
  shows why it cannot. Before, the button did nothing.
- Explore's tab of a work item that you undid, or closed before a run was queued, shows how
  the work item ended. Before, it showed that the run ended with an error.
- A Backlog row whose work item is in another workspace shows **Taken in** with no
  number, and **Take in again** has the title “Brings back the work item from another
  workspace”. Before, both showed “#” with no number.
<!-- /feature -->
- The keyboard shortcuts popover on a run's Timeline tab shows each description beside
  its key, inside the popover. Before, each description was outside the popover's right
  edge, one word per line, over the Timeline.
- The Policy page's Keys panel shows its keys and their descriptions as a plain list, as
  wide as the panel. Before, the list had a second box inside the panel, with the border,
  background, shadow and width of the Timeline's keyboard shortcuts popover.
<!-- feature: factory -->
- What enforce would deny leaves out a run's requests to the run API, which the gateway
  handles the same way in observe and enforce. Three places leave them out: the list when
  you pick enforce on a Policy page, the Policy page's count of attempts with no rule, and
  **Enforce would deny N destinations** on the Overview. Before, each of the three
  counted the run API's requests (the host `run-api.qory.invalid`) as a destination
  enforce would deny.
<!-- /feature -->

### Security

<!-- feature: workflow_model -->
- Where a stage lists approvers, only an approver settles the stage's escalation, or runs
  a stage after Explore again from its gate, with **Run another round**. The escalation
  records the approver who settled it, with a `gate.approve` entry in Activity. Anyone
  else sees “Ask an approver of <stage> to act on it.” and no run starts. Before, any
  member who could answer did both by sending answers, and the escalation recorded no
  one. While a stage's escalation is open, only an approver answers its questions; at
  any other time, every member answers them.
- Run another round on Explore's proposal starts no round of a later stage that waits for
  its inputs or its workflow.
<!-- /feature -->
- By default the release starts no Erlang distribution: before, every instance listened for
  other nodes with a cookie that every copy of the image holds, so anything that could reach
  the container's network could connect as a node and run code. With `DNS_CLUSTER_QUERY`,
  `RELEASE_COOKIE` must be set, the same secret on every node, or Qory Apiary stops at
  start. Without `RELEASE_COOKIE`, each start makes a new random cookie, so the cookie in
  the image is never used.
- The image build stops unless `ca-certificates` is 20250419+deb13u1 or later. That version
  removes the emSign ECC Root CA - G3 and Comodo AAA Services roots after eMudhra
  intermediate CA certificates were compromised (Debian DSA-6572-1).
- plug_crypto is updated to 2.2.1, which fixes CVE-2026-105963: a call to `Plug.Crypto` with
  an argument of the wrong type could write the secret key base to the logs.
- Bandit 1.14.1, Ecto 3.14.3, Phoenix.HTML 4.4.0, and JSV 0.26.2 close published
  advisories, among them a WebSocket message that made the server hold about 150 times the
  message size limit in memory.
- The log filter replaces an invitation link's token before it looks for `qak_` and an
  enrolment code's prefix. Before, a token that contained one of them could leave up to
  39 of its 43 characters in the log line.
- The log filter replaces a run key, `qrk_`, and its signature, and a diagnostics key's
  enrolment code, `qecd_`. The run page's header and the **Run** list in its Timeline
  show a pool's reason for releasing a machine through the same filter.
- A prebuild's image is accepted only at the place Qory Apiary sent the prebuild, so one
  organisation's build cannot make another organisation's runs start in its image.

### Upgrading

- Upgrade every Qory Gateway before you upgrade Qory Apiary, to a gateway built with
  qoryai/forager#52 or later. A gateway built before it returns an error for each batch
  that contains one of the three image codes `image_access_denied`, `image_rate_limited`
  and `image_registry_unreachable`.
<!-- feature: factory, secrets -->
- Upgrade every Qory Gateway first, to a gateway built with qoryai/forager#53 or later,
  then upgrade Qory Apiary. Each model key in a run configuration has `pause_for_s`, a
  member that the run configuration schema of an earlier gateway does not define. A run
  registered before the upgrade keeps its one key and goes on across the deploy; its run
  configuration gains `pause_for_s` (Migrations, below). Each key starts with no settings
  and no state, so it shows “Available” until a gateway reports it.
<!-- /feature -->

### Migrations

<!-- feature: factory, secrets -->
- `model_key_copies` (20261111220000): a row for each pending or running run and each of
  its model keys, with the key's `value_set_at`, so a run registered before the upgrade
  keeps its keys' reports. It takes no lock that blocks reads or writes. Rolling back
  changes nothing.
- `secret_values` and `model_key_copies` (20261111190000): a column
  `secret_values.value_set_at`, the time a key's value was last set, which a rename leaves
  as it is, filled from `updated_at`, which rewrites every row of `secret_values`; and a
  new table `model_key_copies`, with a row per run and model key: the `value_set_at` of
  the value last sealed for that run, deleted with the run and with the key.
- `runs` (20261111170000): a nullable column `resume`, the paused run whose transcript a
  continuation reads, with a check that it is an object of exactly `run_id`,
  `session_id` and `path`, each a string; the check scans `runs` under a lock that
  blocks reads and writes. It changes no row: a continuation registered before it starts
  a new session.
- `session_chunks` and `transcript_paths` (20261111143100): two new tables. The first
  has the chunks of a run's session transcript, with an index on the run, the path and
  the sequence. The second has a row per run and path: the chunks and bytes kept of the
  path, the sequence up to which they were checked for a gap, the offset at which the
  next chunk has to start, and `gap`, whether a checked chunk did not start there. It
  changes no row: the transcript events of a run stored before it become chunks only if
  that run is rebuilt from its events.
- `runs` and `dispatch_runs` (20261111143000): the checks on `runs.state` and
  `runs.exit_state` take `paused`; the first scans `runs` under a lock that blocks reads
  and writes, and the second stays not validated, as it was. Two nullable columns:
  `dispatch_runs.continues_id`, the paused run that a run continues, set to null when
  that run is deleted, with a unique index built inside the migration, so writes to
  `dispatch_runs` wait until the build ends; and `dispatch_runs.paused_until`, the
  earliest end of a cooldown among the keys of a paused run's provider, when every one of
  them was in cooldown as the run ended. It changes no row. Rolling back makes each
  paused run Cancelled.
- `runs` and `dispatch_runs` (20261111100000): `runs.model_keys`, a run's keys in the
  order of its run configuration, at most 6, in place of `runs.provider_value_id`, which
  is dropped; and `dispatch_runs.model_provider_ids`, the model providers a queued run
  waits for, with a constant default, an empty list, which rewrites no row. Each run with
  a key gets that key under the credential name its run configuration has, the
  provider's public id, with its Pause for (`pause_for_s`), written once: the key's
  setting, else 60 seconds for an API key and 1 hour for a subscription. A run that is
  live during the deploy keeps its key and goes on, and its run configuration gains
  `pause_for_s`. A run whose key was deleted after its claim gets a key id that no key
  has, so a secrets request for that key fails, as before. The migration rewrites each
  run with a key, and its two checks on `runs` scan `runs` under a lock that blocks reads
  and writes. Rolling back sets `provider_value_id` to the first key of the
  list where that key still exists, and clears the provider columns of a run whose first
  key is gone.
<!-- /feature -->

- `machine_types` and `runs` (20261111090000): drops `machine_types.image`, with its
  check, and `runs.configured_image_from_type` and
  `runs.configured_image_machine_type_id`, with their check and index. Each type's image
  and the mark of which runs started in a type's image are lost; `runs.configured_image`
  and each type's key, name and spec stay. A run claimed with a type's image before the
  upgrade starts in that image only where the image is in the organisation's place in
  the registry, else in the pool's default image. Rolling back adds the columns again,
  with no image on any type and no run marked.
<!-- feature: factory, secrets -->
- `model_key_settings` and `model_key_states` (20261110161700): two new tables, keyed by
  a key's row in `secret_values`: a key's Resets and Pause for, and its state in each
  limit window. A unique index on `secret_values` (`id`, `organisation_id`), built inside
  the migration, so writes to `secret_values` wait until the build ends. It changes no
  row.
- `model_choice_fallbacks` (20261110153000): a new table of the fallbacks of a model
  choice, each a model provider at a position, with an optional model and effort. A
  unique index on `model_choices` (`id`, `organisation_id`), built inside the migration,
  so writes to `model_choices` wait until the build ends. It changes no row.
<!-- /feature -->

- `runs` (20261110090000): a column `configured_image_from_type`, false by default, and
  a nullable column `configured_image_machine_type_id`, a foreign key to
  `machine_types`, with a partial index and a check. It changes no row, and
  20261111090000 drops both columns.
- `escalations` (20261109100001): the column `gaps` is dropped, and a column `points`, a
  JSON array that is empty by default, takes its place. Each line of an `escalate`
  escalation's gaps becomes one `run_again` point, up to 20. The gaps of other
  escalations are dropped, and the page shows the point of their cause in their place.
- `runs` (20261109100000): writes a run record for each run of the queue that waits, in
  the order the runs were queued, numbered after the workspace's highest number, and
  raises each workspace's count of runs to match. A run of the queue that ended or was
  taken gets none. It locks the waiting runs of the queue, then `run_counters`, until it
  ends, so no run is claimed or numbered meanwhile. Rolling back deletes these records;
  the counts stay. While a node of the previous release runs beside this one, its claim
  of a run that has a record raises and gets a 503 `unavailable` response; the run stays
  queued, and a claim of this release takes it. The previous release claims the oldest
  waiting run first, so while that run has a record, every claim of the previous release
  for that queue fails until the nodes run this release. The migration takes its locks in
  the order a claim does, with a 5-second `lock_timeout`: a migration that cannot take
  them fails, changes nothing, and can be run again.
- `machine_types` (20261109090000): the column `name` becomes `key`, with its index and
  its check. A column `name` gets each type's key with its first letter in upper case
  and its hyphens as spaces, such as Standard for `standard` and Large gpu for
  `large-gpu`; a nullable column `image` is added, which 20261111090000 drops. A unique
  index on the lower case of `name` follows, and a check of 1 to 100 characters with no
  control character and no line or paragraph separator (U+2028, U+2029). Unless a row
  has the key `browser`, the migration adds the type `browser`, 2 vCPUs, 4 GiB, 30 GiB
  of disk, amd64, named Browser tests, or Browser tests (browser) where another row has
  the name Browser tests in any case. It changes no other table.
- `run_configurations` and `audit_entries`: each workspace with no security policy gets
  version 1, observe with no rules, and its entry in the audit log, by Qory Apiary. No
  migration writes these rows. Qory Apiary writes them when it starts, after the
  migrations and the key check, one workspace per transaction, and `bin/migrate` writes
  them after the migrations. With `MIGRATE_ON_BOOT=false`, only `bin/migrate` writes them.
  A workspace whose version 1 fails is logged and has no version until the next start or
  `bin/migrate`. Going back to the previous release keeps the versions, so its machines
  keep the workspace's policy.
- `workspaces` (20261108140000): a nullable column `keep_process_latest`, the switch
  Keep the process at the latest. Empty means on for the Qory harness and off for a
  harness repository, and off where the first process version is a version of the
  workspace type that an instance admin saved. The migration sets it off for each
  workspace whose current process version a person saved, and for each workspace whose
  first process version an instance admin saved, and changes no other row.
- `dispatches` (20261108130000): a nullable column `late_machine_at`, the last time a
  machine showed up for a claim that takes none. It changes no row.
- `runs` (20261108120100): an index in the order of the run list, `GET /v1/runs`, built
  concurrently, so it does not block writes. It changes no row.
- `machine_types` (20261107110000): a new table of the instance's machine types, with
  the type `standard` as the default: 2 vCPUs, 4096 MiB, 30 GiB of disk, amd64, no
  virtualization.
- `dispatch_runs`, `dispatches` and `nodes` (20261107110100, 20261107110110 and
  20261107110120, one table each): nullable columns `dispatch_runs.machine_spec`,
  `dispatches.machine_type`, `dispatches.machine_spec` and `nodes.offers`. A run queued
  before them has no spec and runs on the default type. They change no row.
- `dispatch_runs` (20261107110200): a column `machine_type_was_default`, false by
  default, true for a run queued on the type that was the default then. It changes no
  row.
- `dispatch_runs` and `run_harnesses` (20261107090000): three nullable columns:
  `dispatch_runs.explore`, whether a queued run is a run of Explore;
  `run_harnesses.ref_kind`, whether the ref of the run's harness is a branch, a tag or a
  commit; and `run_harnesses.read_failed_at`, when a claim's read of the run's harness
  first timed out, found no address or connection, or got `429`, `500`, `502`, `503` or
  `504`. A check on `ref_kind` scans `run_harnesses` under a lock that blocks reads and
  writes. It changes no row.
- `runs` (20261107090010): two nullable columns, `peak_memory_bytes` and `cpu_time_ms`,
  which the projection fills from each run's session events. It changes no row.
- `dispatches` (20261107090050 and 20261107090100): a nullable column,
  `vendor_machine_type`, with a check on its characters. The first migration adds the
  check without a scan, and the second validates it with a scan that does not block
  writes. It changes no row.
- `organisations`: an organisation at the slug `work-items` moves to the first free one of
  `work-items-2`, `work-items-3`, …. A rollback changes no row.
- `source_item_comments` (20261106130000, 20261106130100 and 20261106130200): four
  nullable columns for a comment a member writes on a ticket in Qory Apiary: `author_id`,
  `comment_id` (unique), `post_state` and `post_failure`, with checks on their values and
  combinations. `external_ref` and `url` may be NULL, for a member's comment not posted at
  its source. The checks and the key to `users` are added without a scan, and a second
  migration then validates them with a scan that does not block writes. A third migration
  builds the two indexes concurrently, outside a transaction and without the migration
  lock: do not boot two instances at once for this upgrade (Upgrading guide). It changes
  no existing row. The `down` deletes the members' comments that were never posted at
  their source.
- `nodes` (20261106130300): a nullable column, `comments`, which is true when an
  adapter's source takes the comments members write in Qory Apiary, with a check that
  scans `nodes` under a lock that blocks reads and writes. It changes no row; each
  adapter's next start sets it.
- `adapter_feed` (20261106130400 and 20261106130500): the checks
  `adapter_feed_kind_check` and `adapter_feed_data_check` take a fifth kind, `comment`,
  with data up to 400,000 bytes; every other kind keeps the bound of 4,096 bytes. The
  first migration adds the new checks without a scan, and the second validates them with
  a scan that does not block writes. It changes no row. To roll back past
  20261106130400, delete the feed's `comment` entries first: its `down` fails while one
  exists.
- `run_steps` (20261106151500 and 20261106151600): the check on `kind` also allows
  `machine`. The first migration adds the check without a scan, and the second validates
  it with a scan that does not block writes. It changes no row. A rollback sets `kind` to
  NULL on each row of kind `machine`.
- `run_steps` (20261108090000 and 20261108090100): the check on `kind` also allows
  `copy`. The first migration adds the check without a scan, and the second validates it
  with a scan that does not block writes. It changes no row. A rollback sets `kind` to
  NULL on each row of kind `copy`.
- `run_steps` (20261108090200): a step with no `kind` and the name that qory sends for
  its copy step gets the kind `copy`, so a copy step recorded before the kind existed
  has no row on the run page. A rollback changes no row; the rollback of 20261108090000
  sets `kind` to NULL on each row of kind `copy`.
- `qory_harness_files` and `qory_harness_heads` (20261106190000): two new tables, with
  the files of the Qory harness by repository address, commit and path, and the commit
  each branch or tag was at when it was last read.
- `stacks` (20261106190100): the check `stacks_version_check` takes `branch`, `tag` and
  `commit` under both choices, and no longer takes `latest` or `named`. Each saved Qory
  harness choice at `latest` or `named`, or with no version, becomes the branch `main`,
  and the `ref` in its document becomes `main`. The document of a target's Qory harness
  row at `workspace` gets the same `ref`. The new check scans `stacks` under a lock that
  blocks reads and writes. A rollback turns each Qory harness row at a branch, `main` or
  another, into `latest`, and the documents keep their `ref`. It stops with an error
  while a Qory harness row is at a tag or a commit.
- `runs`: `number` becomes unique per workspace, from a new table `run_counters` with one
  row per workspace that has runs, and the sequence `runs_number_seq` goes. Existing runs
  get new numbers: each workspace's runs are numbered from 1 in the order they were
  created, and each counter also goes past the highest number of the runs of the work
  items now in its workspace. Runs of a work item moved before this migration may repeat a
  number. An old link to `/runs/<number>` may then show another run of the workspace or
  not found; a link with the `rn_` id keeps working. The migration updates every row of
  `runs` in one transaction. Until it ends, reads and writes of `runs` and writes to
  `workspaces` and `organisations` wait: 128 s on 1,000,000 runs with the 23 indexes of
  `runs`, on a machine that was not idle (Upgrading guide). A new trigger,
  `runs_number_from_counter`, takes a number from the counter for an insert with none, so
  the previous release keeps working on this schema. The `down` numbers the runs across
  the server again without restoring the numbers they had. This migration leaves the run
  numbers in stored `questions` and `review-comments` documents (`asked.run`,
  `reopened.run`, `by.run`) as they were, and so does `down`. An open question in such a
  document may then stop matching its run, so a member cannot answer it, or may count as a
  question of a later run. Upgrade before an instance stores these documents.
- `run_steps`: the check on `kind` also allows `build` and `push`. The check is added
  without a scan, and a second migration then validates it with a scan that does not
  block writes. It changes no existing row.
- `workspaces`: a nullable `shown_standard_types` column, `text[]`. It changes no existing
  row, and every workspace keeps every standard type.
- `dispatches`: two nullable columns, `machine_end_state` and `machine_end_at`, with a
  check that scans `dispatches` under a lock that blocks writes. It changes no existing
  row.
- `runs`: a `number` column, `bigint`, NOT NULL. The runs already there are numbered from
  1, and `20261105090000` numbers them per workspace (the `runs` entry on `number` at the
  top of this section).
- `type_template_versions`: three nullable columns, `name`, `summary` and `description`,
  with a check on their lengths (1 to 60, 200 and 1,200 characters) that scans the table
  under a lock that blocks writes. It changes no existing row.
- `stacks`: two nullable columns, `version_kind` and `version_name`, with a check on their
  combinations. Each saved Qory harness choice at the commit `fe3b3ab` becomes **Always
  the latest version**. Other rows keep their pin.
- `instance_settings`: four columns for Instance settings › Configuration,
  `audit_retention_days`, `audit_address_retention_days`, `deletion_grace_days` and
  `invitations_per_day`, all NULL, with checks on their ranges that hold in every edition:
  at least 30, at least 1, 1 to 90, and at least 1. It changes no existing row.
<!-- feature: secrets -->
- A stored secret can now belong to an organisation instead of a workspace, with a data
  key for each organisation.
<!-- /feature -->
- `instance_settings`: a nullable column, `used_setup_code_sha256`. It changes no existing
  row.
- `connections`: a column with a constant default, which rewrites no row, and a check. Its
  unique index is dropped and built again with that column inside the migration, so writes
  to `connections` wait until the build ends.
- `nodes`: nullable columns, checks, two indexes and a trigger. Three of the checks on
  the new columns scan `nodes` under a lock that blocks writes.
- The foreign keys from `dispatches`, `environments`, `dispatch_runs` and `runs` to `nodes`
  are replaced, with a trigger on each table. They are added `NOT VALID` and validated by a
  scan that blocks no write.
- The checks of the end causes on `dispatches` and `dispatch_runs` are replaced, with a
  scan of both tables that blocks writes to them.
- `invitations`: `workspace_id` becomes nullable. Its foreign key to `workspaces` is
  replaced with one on the same columns, still `ON DELETE CASCADE`, that lets a row
  without a workspace pass; adding it scans `invitations` under a lock that blocks writes.
  It changes no row.
- `instance_settings`: a nullable column, `connections_reviewed_at`. `nodes`: a nullable
  column, `source_guide`, with a check that scans `nodes` under a lock that blocks writes.
  They change no row.
- `work_items`, `model_choices` and `run_harnesses`: columns, checks and an index for test
  work items, a model choice's runtime and the built-in harness; `provider_models` is
  dropped. Each of the four tables comes with this release, so on an upgrade from 0.1.0
  all four are empty when these migrations run.
- `nodes`: a nullable column, `title`, with a check that scans `nodes` under a lock that
  blocks writes. It changes no row.
- `run_harnesses`: a nullable column, `failure_adapter_id`, with a foreign key to `nodes`
  and a partial index. It changes no row.
- `nodes`: a nullable column, `targets`, with a check that scans `nodes` under a lock
  that blocks writes. It changes no row.
- `workspaces`: a column `type`, the key of the type a workspace was made from, such as
  `qory.software`. The migration writes it into every row, `qory.software` for each
  workspace of 0.1.0, then sets the column NOT NULL, with a scan of `workspaces` under a
  lock that blocks writes.
- `stacks`: a nullable column, `choice`, the harness choice of a target, a workspace or
  the organisation, with a check on it; the check `stacks_harness_or_workflow` is
  replaced to take a row with a choice alone. `stacks` comes with this release, so on an
  upgrade from 0.1.0 it is empty when these migrations run. They change no row.
- `grant_rules`: a table, with its indexes built inside the migration, and a unique
  index on `adapter_grants` (`id`, `organisation_id`), built inside the migration too.
  `adapter_grants` comes with this release, so on an upgrade from 0.1.0 it is empty when
  this migration runs. It changes no row.
- `runs`: two nullable columns, `start_failure` and `start_failed_at`, with two checks
  on them, and a nullable column `dispatch_id`, with a foreign key to `dispatches`. The
  check `runs_run_settings_check` is replaced to accept run settings on a run whose start
  failed. The three checks scan `runs` under a lock that blocks writes. `dispatches`: a
  nullable column, `release_reason`, with a check of 1 to 200 characters that scans
  `dispatches` under a lock that blocks writes. An index on `runs.dispatch_id`, built
  concurrently. The migrations change no row.
- `instance_settings`: three nullable columns for the last test send of the mail settings,
  `mail_test_sent_at`, `mail_test_result` and `mail_test_reply_code`, with a check on the
  result and one on the reply code. The table has one row. It changes no row.
- `leaked_secrets`: a table, with its checks and indexes, where each secret a run printed
  is found, never the secret. `runs` and `dispatches`: integer columns with a constant
  default, 0, which rewrites no row: `leaked_secrets_omitted`,
  `machine_log_secrets_omitted` and `release_reason_secrets_omitted`.
- `nodes`: five checks replaced to take a diagnostics key, added `NOT VALID` and validated
  by a scan that blocks no write, and a unique index `nodes_diagnostics_index` for kind
  `diagnostics`, built inside the migration, so writes to `nodes` wait until the build
  ends. They change no row.
- `instance_settings`: a nullable column `support_address`, with a check on its length.
  It changes no row.
- `workspaces`: a nullable `qory_stack` column, `text`. An empty value means the stack
  `core`.
- `workspaces` and `stacks`: each workspace of the software domain made before
  `qory_stack` was added, with no `qory_stack`, gets `software`, unless its version 1
  came from a template of a harness repository. A Qory harness row at the stack `core`
  gets `software` too, if it belongs to such a workspace. A row the organisation shares
  gets it if every workspace that reads that row has `software` after the migration;
  otherwise it stays at `core`. A row chosen for a target stays. A rollback changes no
  row.
- `work_items`, `work_item_events` and `escalations`: the migration locks the three
  tables against reads and writes while it runs. It closes every declined work item,
  with the time and the person of the decline as `closed_at` and `closed_by_id`, then
  drops `declined_at`, `declined_by_id` and that column's index. A `declined` event
  becomes `closed`. A `taken_in` event whose earlier state is `declined` gets `closed`, so
  an undo of that take in again goes back to closed. An escalation resolved with
  `decline` becomes `close`. The audit log keeps its entries. A rollback brings back the
  columns and the checks with no declined row: each work item the migration closed stays
  closed.
- `source_items`: a nullable column, `last_closed_at`, with no default, which rewrites no
  row. It is empty on every existing row, a closed ticket's included; a later write that
  moves a ticket from open to closed sets it. The migration closes no work item: a live
  work item whose ticket closed before the upgrade stays open until a person closes it or
  the adapter sends that ticket again as closed.
- `work_item_confirmations`: the column `changes` is dropped, with the edits people made
  to a proposal before they confirmed it. A rollback brings it back, empty.
- `work_item_answers` comes with this release and is dropped by it: answers and review
  comments are kept in the artifacts `questions` and `review-comments`. On an upgrade from
  0.1.0 the table is empty when it is dropped. A rollback creates it again, empty.
- `dispatch_runs`: the check on `result_outcome` is replaced to allow the outcome
  `questions` on a run ended `lost`. It scans `dispatch_runs` under a lock that blocks
  reads and writes, and changes no row. A rollback stops with an error while a run ended
  `lost` has an outcome.
- `work_items`: a partial index on the work items that explore with their stage running,
  built inside the migration, so writes to `work_items` wait until the build ends.

## [0.1.0] - 2026-10-13

The first release of the open core of Qory Apiary: Qory Apiary Community, complete for
one team, as `EDITIONS.md` at the root of the repository describes it.

### Requirements

- Every machine runs qory 0.13.0 and connects with `qory access-key enrol`: Qory Apiary
  takes only requests signed with a node's access key. On a machine that holds an access
  key, qory runs each run behind a wall, which needs Docker.
- `PUBLIC_URL`, `DATABASE_URL`, `SECRET_KEY_BASE`, `APIARY_ENCRYPTION_SECRET` and
  `APIARY_SIGNING_SECRET` are required. With the `compose.yaml` and `env.example` this
  release attaches, the bundled Postgres gives `DATABASE_URL`, and the service `keys`
  generates the three keys at first start into the volume `keys`: keep a copy apart from
  the database backups.
- Behind a reverse proxy, set `TRUSTED_PROXIES` to the address its connections come from,
  and let the proxy pass the `Content-Security-Policy` header on unchanged. The AWS
  template, `apiary.yaml`, sets `TRUSTED_PROXIES` itself and takes no mail settings: set
  mail in Instance settings › Mail.

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
  with mail, whose address a link confirms first; the sign-up the instance
  makes itself (`actor: :instance`) needs none and keeps one given.
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
  to ask for a new one; Account settings do not call the password optional beside
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
- An edition may use different words to say who may take an action
  (`c:ApiaryWeb.Edition.who_may_sentence/2`, asked with the action and the scope, through
  `ApiaryWeb.Access.who_may/3`), where the core's sentence names the levels, such as
  "Only owners and admins add nodes.", and the core's sentence stands where it has none,
  as it does in the core. It is asked for the refusals, and the notices to whoever may not
  act, of the nodes' pages and a node's Access key tab, the workspace overview's Get the
  command, the organisation's and the workspace's settings, People, and the
  pages that say "Only owners and admins change this."; for People's line of what each
  level does; for the refusal to cancel an organisation's deletion on Your organisations;
  for the security policy's refusals (`Apiary.Policy`); and for the policy pages'
  refusals of a click on the mode or a lock. The policy pages' mode row and the workspace
  overview's hint on the mode keep the core's words.
- The record of every run, reported by Forager over the server contract (version 1,
  revision 1: discovery, a run's registration, attach, reload and outcome, events and
  enrolment): the
  session as a timeline, the terminal, every connection with its decision and rule, and
  how the run ended.
- A run's registration. A run opens with a signed `POST /v1/runs`, whose body holds its
  id, its labels, what it is about, the heartbeat interval it uses and when it was sent,
  read strictly, a body it refuses being `400` `invalid_request` with the member at fault
  in `names`; the answer is its run configuration, `{"version":1}` where the workspace
  serves no policy, always with `X-Qory-Run-Configuration`, an `ETag` and
  `X-Qory-Configuration`. The same bytes
  sent again under any active key of the node that registered the run get the same answer;
  the run id from another node, or with other bytes, is `409` `run_id_used`; a run whose events retention pruned is
  `410`; a run configuration that cannot be read is `503`, never no policy. No run is
  stored on any refusal. `GET /v1/runs/<run_id>` reloads a run's configuration for the
  active keys of the node that registered it, by its registration's labels, and is `404`
  for a key of any other node, for a run its batches created, and where the workspace
  serves no policy. Discovery's `run` section is always there, `…/v1/runs`. A batch that
  holds `dev.qory.ping` or `dev.qory.run.registered` is `400` `invalid_request`: a
  Forager that opens its runs with a ping starts none: its machines run Forager 0.7.0,
  which qory 0.13.0 builds on.
- A run's outcome, from its starter. `POST /v1/runs/<run_id>/outcome`, signed by any
  active key of the run's node, says how the run went:
  `{"version":1, "state":"succeeded", "reason":"all_checks_passed", "time":"…"}`. The state
  is `succeeded`, `failed` or `cancelled`, and none is `cancelled` with the reason
  `stopped`; a reason that is not a code, or is one of Forager's reserved codes, is dropped and the
  outcome kept; a `time` more than 300 seconds from the server's clock is `401`. The
  outcome sets the run's state and reason whenever it arrives, before the run's exit or
  after it, and the exit's code, signal and reason stay on record beside it. Each run gets
  one: the same state and reason again, whatever the bytes or the `time`, get the same
  answer, `200` `{"version":1}`, and change nothing; another state or reason is `409`
  `outcome_given`. A run of another node, one the workspace does not hold, and one whose
  events retention pruned are `404` `not_found`. Where the outcome's state differs from
  what the run's exit said, the run page says both, for example "Succeeded, as its starter
  said; the runtime exited 1". A run refused at its start says the outcome's state alone:
  "Succeeded, as its starter said". A run whose starter sent its outcome with no state says no such sentence: it
  reads as any cancelled run, "Cancelled", with "the starter gave no outcome" after it.
- The end of a run, in the answers to its batches. Once a run's starter has given its
  outcome, until the run's `dev.qory.run.exited` arrives, each signed `2xx` to its batches
  carries `end` with the outcome's state and reason, as `application/json`,
  `{"end":{"state":"succeeded","reason":"all_checks_passed"}}`, under the answer's
  signature. Every other `2xx` to a batch has an empty body, as does the `410` of a
  pruned run.
- A run through a gateway. A run's registration resolves its node's choice of gateway as
  the records are then. A node that goes directly registers as above; a node whose
  choice leads to a gateway registers without `forager_version`, `contract_version`,
  `interval_seconds` and `events`, and may ask for an attach window, `attach_seconds`
  (600 seconds unless asked, at most 3600: `config :apiary, Apiary.Runs.Registration`,
  `attach_seconds` and `max_attach_seconds`). Its answer is no run configuration but the
  run's id and a run key, `{"version":1,"run_id":"…","run_key":"qrk_…"}`, with neither
  `X-Qory-Run-Configuration` nor `ETag`. A run key (`Apiary.Runs.RunKey`) is `qrk_`, a
  payload and its Ed25519 signature under the instance's signing key, at most 2048
  characters; the payload names the run, its workspace, the node that registered it, the
  gateway with its `https` address and active public keys, the instance, when it was made
  and the end of its attach window. Before the instance limit, a registration is a signed
  `409`: `gateway_key` from a gateway's key, `node_is_direct` and `node_uses_gateway`
  for a body whose shape does not match the node's choice, `no_default_gateway`,
  `gateway_not_serving` and `gateway_without_key` for a choice that leads nowhere. A
  gateway attaches the run with a signed `POST /v1/runs/<run_id>/attach` under the gateway's
  key, with the run key and what a direct registration announces
  (`Apiary.Runs.Attach`); the answer is the run's run configuration, read under the run's
  workspace, with the registration's `labels` and `about`. Its refusals, in order:
  `409` `not_a_gateway`, `400` `run_key_invalid`, the same gateway node and the same
  instance id attaching the live run again, under any of the node's active keys, is given
  the same answer, `410` for a run that has ended, then `409` `run_key_expired`,
  `wrong_gateway`, `workspace_not_served` and `run_attached`, which another gateway node,
  or another instance of the same one, is given for a live run. The run keeps the instance
  id the attach was signed with (`X-Qory-Instance-Id`), so one instance of the gateway
  takes the run on; a gateway that restarts keeps its instance id, and its run. Once
  attached, the run's batches, heartbeats and reloads are the gateway's alone, under any
  of its active keys, from the instance that attached it, and a batch from any other key,
  or from another instance, is a signed `409` `wrong_gateway`, a reload `404`; a
  gateway's batch never opens a run. Once the run's exit has arrived, it was lost after
  its attach, or its events were pruned, a batch or heartbeat from any instance of the
  gateway is answered as the attaching instance's would be, a resend deduplicated and a
  pruned run `410`; an outcome alone leaves the run to its attaching instance until its
  exit arrives, and reloads stay that instance's. After a loss, only the attaching
  instance's heartbeat makes the run live again: another instance's heartbeat is stored
  and answered, and the run stays lost. A run whose attaching instance is not known yet
  is made live again by any instance's heartbeat. Its outcome stays its node's. The run is held to
  the interval its attach announced, from its attach, and a run its gateway never
  attaches is lost at the end of its window. The console does not show a run's gateway or its attach.
- A run through a gateway belongs to the node that registered it and its instance, never
  to the gateway, and its Host is the machine the runtime ran on.
- Qory Apiary records what a run reports and never ends a run it did not start; it starts
  none today. No run offers Close, on its page or as a lost run on the Overview, and a run
  has no Closed state. The events endpoint answers `410` to a run whose events retention
  has pruned, and `410` `workspace_not_served` to a run whose gateway may no longer serve
  its workspace.
- Six states of a run, in four families: alive (Pending, Running), ended well (Completed),
  cancelled (Cancelled) and ended badly (Failed, Lost). A cancelled run was stopped
  before it said how it went, and counts neither as ended well nor as ended badly: the
  runs list's Ended badly view and the Overview's Ended badly count Failed and Lost, the
  share that ended well leaves cancelled runs out, the Filter menu's State section has a
  Cancelled heading, and the Overview's chart table a Cancelled column. Completed is a
  green check, Cancelled a grey stop, Failed a red x-mark and Lost an amber
  signal-slash.
- How a run ended, by one rule, from its exit's `state` (`succeeded`, `failed` or `cancelled`) and its open `reason`:
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
- Signed requests and signed answers. Every request the gateway makes names a node's
  access key and its instance and is signed with that key, Ed25519
  (`X-Qory-Access-Key-Id`, `X-Qory-Instance-Id`, `X-Qory-Signature-Ed25519`), within 300
  seconds of the server's clock for a GET and a registration's `time`; every answer to a
  verified request is signed with the server's Ed25519 key, which every machine pins
  as `apiary_public_key`, and sent with `Cache-Control: no-store, no-transform`, while
  every `401` goes out unsigned. The refusals come in the contract's order, coded: a
  header sent twice or an instance id absent or malformed is `400` `bad_request` on every
  endpoint. Discovery names the key's node (`node_id`), its workspace (`workspaces`) and
  the server's keys (`apiary_public_key`), so its digest differs by node and workspace.
  The tests replay the contract's fixtures at the commit `.forager-contract-ref` pins,
  4d036d1, Forager's release v0.7.0.
- A workspace's id in the server contract: every workspace has one, `ws_` and 16
  characters, made when it is created. Discovery lists it as `workspaces`, the one
  workspace an access key may name, that of its node or node pool. Only the contract
  names a workspace by it: the console neither shows nor uses it.
- Gateways, a third kind of node beside the node and the node pool: `ng_` and 16
  characters, with an address (`url`: `https://`, a host
  and an optional port, nothing more, at most 2048 characters) and no instance limit. A
  gateway belongs to a workspace and may serve that workspace; it enrols with a code as a
  node does, and the enrolment answer's `node_kind` is `gateway`. Discovery for a
  gateway's key names it (`node_id`, `ng_…`) and lists no workspaces: which workspaces a
  gateway serves follows from the nodes that use it, and Qory Apiary decides at each
  registration and attach whether it may serve the run's workspace. Each node and node
  pool records a choice of gateway: direct, its workspace's default gateway, or a gateway
  it names, one that may serve its workspace, checked when the choice is saved, and
  resolved again at each run's registration (a run through a gateway, above). The choice
  can be changed. A new one given no choice starts on the default when a default
  gateway resolves for its workspace, and on direct otherwise. A workspace's first
  gateway becomes its default, and only a gateway made when no default resolves does so
  by itself, so adding a second one moves no node; a person moves the mark
  (`Apiary.Nodes.make_default_gateway/2`). A gateway is deleted only when no node names
  it, no node on the default resolves to it, and no run through it is
  live (attached and not ended) or waiting for its attach (registered for it, not
  attached, not lost or ended, and within its attach window); the refusal names those
  nodes and runs. A run's registration or attach that meets the gateway's deletion
  waits for it, and is then refused as for a deleted gateway. After a deletion no node
  moves, and when no default resolves for the workspace any more, the oldest gateway left
  becomes the default. Making, changing and deleting a gateway, and moving the mark, are
  `node.create`, `node.edit` and `node.delete` entries, as for any node. `Apiary.Gateways`
  answers whether a gateway may serve a workspace, the workspace's default gateway, where
  a node's choice leads, the workspaces a gateway may serve and the gateways a node may
  name, and `Apiary.Gateways.chosen/1` the gateway a node's choice names now, with a key
  or not. On the console, Nodes lists gateways, with their kind, Gateway, the default's
  mark, Default, and Kind's Gateway in the Filter menu.
  New gateway (`/nodes/new-gateway`) asks a name and a URL, with the URL's errors under
  its field, and opens the gateway's Access key tab as a new node's does. A gateway's
  Overview shows its URL and whether it is the default, with Make default; its Settings
  change its name and URL; its deletion is confirmed in place, and refused while nodes
  point to it or runs go through it: "Nodes use this gateway: …", the first five of the
  workspace by name, then "and N more", which counts the rest and any of other
  workspaces, and "Runs are going through this gateway: …", the first five to
  register, named by run id, then "and N more"; when both hold, one message names both,
  the runs as "Runs are going through it: …".
  New node, New node pool and a node's Settings choose its Gateway once the workspace has
  one: Default gateway, offered only while a default resolves, Direct, or a gateway by
  name; a new one starts on Default gateway when one resolves. A node's About says where
  its choice leads, and its Access key tab, command page, Key for a node and Forager file
  name the gateway its runs go through, with its URL. The command and the Forager file
  point at Qory Apiary through that gateway: the command, on its page and in the
  overview's first-run box, carries `--via` and the gateway's URL, with a line under it
  that a gateway whose certificate a private certificate authority signed needs
  `--via-ca-file`, and the Forager file's lines carry `via` and its `url`
  (`Apiary.AccessKeys.via_lines/1`), each step that points the node or node pool at Qory
  Apiary naming the gateway. A gateway relays the enrolment unchanged, from its address,
  which the enrolment's per-address limit counts for every machine behind it.
  A gateway's key enrols the gateway and registers no
  run, and its Access key tab says so. The audit log calls a
  gateway's creation Gateway. `Apiary.Nodes.count_nodes/1` counts gateways too.
- A gateway's URL has a host that is a DNS name, an IPv4 address or an IPv6 address in
  brackets, and a port of 1 to 65535 written without a leading zero. A DNS name is labels
  of letters, digits and `-`, 1 to 63 characters each, neither starting nor ending with
  `-`, the last not all digits, 253 characters at most, with an optional trailing dot.
  Any other URL is refused with the URL's error, "must be a scheme and a host, with a port
  if needed, and nothing more", or "must start with https://" for another scheme, by
  `Apiary.Nodes.Node.validate_url/1` and by the database (`nodes_url_check`).
- `gateways` is a reserved workspace slug, refused as the names of the organisation's
  pages are; a new workspace named Gateways gets the slug `gateways-2`.
- The organisation slugs `admin`, `api`, `new` and `settings`, and the workspace slugs
  `api` and `new`, are reserved as well: a slug made from a name skips them, to the first
  free one of `-2`, `-3`, …, and a workspace given one is refused.
- A gateway may live at an organisation as well as at a workspace: its row has no
  workspace, and nor have its access keys, enrolment codes and instances. It may serve
  every workspace of its organisation, and those an edition names
  (`c:Apiary.Edition.serving_organisations/1`, `c:Apiary.Edition.served_organisations/1`;
  the core's edition names none). An organisation's gateways have names unique among
  them, and at most one default. A workspace's default gateway is the one it marks;
  without one, its organisation's; without that, one of an organisation that
  serves it. `Apiary.Nodes.create_organisation_gateway/2`,
  `list_organisation_gateways/1` and `list_serving_gateways/1` make and list them, asked
  of the organisation (`node.create`, `node.read`); a gateway's changes, keys and codes
  are asked at its place. A change of an organisation's gateways takes turns with every
  change of a node's choice in a workspace it may serve, on the organisations' rows
  (`Apiary.Gateways.lock/1`, `docs/access.md`). An organisation's gateway's key is checked while its
  organisation is out of use, not marked for deletion, and acts for a run only while the
  run's workspace is in use, the gateway may serve it, and either the gateway's
  organisation is in use or the run is another organisation's. A gateway acts for a run
  only while it may serve the run's workspace, asked again at each batch, heartbeat,
  reload and repeated attach: once it may not, a batch or heartbeat, one accepted before
  and sent again included, is a signed `410` `workspace_not_served` with no digest and
  nothing of it stored, before deduplication and before a pruned run's answer, a reload the same `410` with no
  policy, and a repeated attach a signed `409` `workspace_not_served`; the run goes lost
  by liveness. A workspace's gateway's key is held to its organisation's use as any
  node's is. The console offers an
  organisation's gateways only where an organisation may have more than one workspace
  (`c:Apiary.Edition.limits/0`): with one workspace, as here, Organisation › Gateways, its
  sidebar entry and New gateway in New are not offered, and their paths are not found.
  Where they are offered, Gateways lists them, with their URL, Default and whether each is
  connected; New gateway is a form page; a gateway's page has the tabs a workspace's
  gateway has, says whose nodes can use it and which workspaces' nodes use it now,
  naming only the workspaces the reader reaches and counting the rest, and its deletion
  is confirmed in place. A workspace's Nodes lists its organisation's gateways beside the
  workspace's, each "Set for" the organisation; a node's choice groups the gateways by level; a
  gateway of another organisation is named with its organisation and linked only where
  the reader may open it. `c:ApiaryWeb.Edition.gateway_reach_sentence/2` and
  `c:ApiaryWeb.Edition.nodes_managed_by_sentence/1` let an edition word whose nodes can
  use an organisation's gateways and who manages the nodes.
- A rate limit per access key on each node, `429` `rate_limited` with `Retry-After` past
  it: the events endpoint, and a run's registration and reload, each spend a separate bucket, 50 requests a second and 100 at once, so a gateway flushing a backlog of
  events still registers a new run. Discovery is not limited.
- Limits on signing in, on each node: a log-in with a password, 5 per email address from
  one network a request comes from (an IPv4 /24 or an IPv6 /48) and then 1 a minute, 50
  per email address from all networks and then 10 a minute, and 20 per address a request
  comes from and then 1 every 3 seconds; a log-in link asked for, 3 per email address from
  one network and then 1 every 5 minutes, and 30 from all networks and then 10 every 5
  minutes, so a stranger's network does not lock an address's owner out of theirs; an
  invitation's pages and the set-up page, 20 per address a request comes from and then 1
  every 3 seconds. Every attempt counts before the address is looked up, so past a limit
  an address with an account and one without get the same answer, "Too many attempts.
  Try again in a few minutes." The address a request comes from is the one the audit
  trail records, behind the proxies `TRUSTED_PROXIES` names; an IPv6 one counts with the
  rest of its /64.
- The security policy of a workspace: a baseline and rules per repository, observe or
  enforce, locked rules, a history with a diff, and an export for a machine without a
  server. Its rules are hosts and paths; credentials are not part of it, and the run
  configuration selects none of a machine's. An edition may keep a level above it (`c:Apiary.Edition.above_workspace/1`,
  an `Apiary.Policy.Above`; the core keeps none): its denies hold everywhere, its allows
  reach every workspace and can be narrowed, never widened, it may require enforce
  (then `Apiary.Policy.set_mode/3` refuses with `:fixed`) and may allow only the hosts
  on its list; the pages list its rules first and link to where it is changed
  (`c:ApiaryWeb.Edition.above_policy_link/1`), and a change of it renders every
  workspace again (`Apiary.Policy.rerender_in/3`, an `above_changed` change in each
  workspace's history).
- Nodes and node pools, the places a workspace's runs run: a node is one permanent
  machine that runs one instance at a time, a node pool a fleet of short-lived instances
  up to its instance limit, or any number without one; the kind is fixed when one is
  made. Owners and admins add them, rename them, change a pool's limit and delete them
  (`node.create`, `node.edit`, `node.delete`, each in the audit trail). Setting a pool's
  limit, as it is made or after, is a separate action, `node.set_limit`, held as
  `node.edit` is, so an edition may keep it from some who change the rest: the node's
  Settings then show the limit disabled, and New node pool leaves it out and makes the
  pool with a limit of 1; the entry of the creation or the edit records it. Everyone in the
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
  set `QORY_APIARY_PUBLIC_KEY`; point the node at Qory Apiary, the Forager file's
  `gateway.server.url`. Opened again, it says the secret is gone, and offers nothing of it to
  copy. A key's card shows its
  Key ID with Copy, how it was added ("Connected with a command by …", "Generated in a
  browser by …") and where its secret is. An active key's card opens the page Forager
  file for the key: for a key connected with a command, the Forager file's `server`
  lines under `gateway:` (`url`, `access_key_id`, `apiary_public_key`), each marked as
  Qory Apiary's or this key's; for a generated key, four numbered steps: where its secret belongs, then
  `QORY_ACCESS_KEY_ID`, `QORY_APIARY_PUBLIC_KEY` and `gateway.server.url`. The server's address
  and public key are set once for the instance, the same for every organisation,
  workspace and node. A public key pasted into a node is no way to give it a key.
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
  `qory-enrol-answer-ed25519-v1`, `429` over the code's limit, `409` `key_invalid`
  for a public key used before, `409` `key_limit` and `201`. Every public key received
  passes the contract's key checks, and a public key serves one access key, ever, on the
  instance. Each key's row carries an integrity code, checked before the key is trusted.
- `Apiary.AccessKeys.active_keys/1` lists a node's active keys, oldest first, and
  `active_key?/1` says whether a node holds one. `Apiary.AccessKeys.place_in_use?/2` asks
  whether a workspace and its organisation are in use, as a key's verification does.
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
  organisation's People. An edition may refuse a level in an organisation, with a reason
  (`c:Apiary.Edition.level_refusal/4`, `Apiary.Access.level_refusal/4`): an invitation,
  its acceptance, a change of level and the release commands that grant and revoke an
  instance admin each refuse it, asked in the lock order inside their transaction, and
  People offers only the levels it refuses none of (`Apiary.Access.grantable_levels/1`)
  and says a refusal in the edition's words
  (`c:ApiaryWeb.Edition.level_refusal_sentence/2`). An edition locks its rows for a change
  at one point, right after the organisation rows and before any membership
  (`c:Apiary.Edition.lock_rows/1`), in every change of people and every write that must
  stay allowed. Several organisations are locked in one order,
  `Apiary.Organisations.lock_order/1`, which an edition must use whenever it locks the
  rows of more than one, and `Apiary.Organisations.lock_organisations/2`, through which
  every change that locks more than one organisation row takes them, in any mode, so
  what it holds in the end was taken in one statement, and which reads the order again
  and locks once more when Postgres refuses its lock as a deadlock.
  A test may have a stub answer some of the edition's callbacks in the test's
  processes (`Apiary.Edition.put_test_stub/1`).
- The audit trail of every change, Audit log in the organisation's sidebar
  (`/:org/audit-log`); retention of a run's events and log output, set per workspace in
  its settings under Runs (`/settings/retention` sends on there); deletion of a
  workspace or an organisation, marked first and purged after a grace period.
- An edition may add to an audit entry's details as it is written, such as how the actor
  reached the organisation (`c:Apiary.Edition.audit_details/3`), and say who made an entry
  in the Audit log's Who column (`c:ApiaryWeb.Edition.activity_actor/2`); the core adds
  nothing, and its Who column keeps the core's words.
- Retention prunes nothing of a lost run until 7 days after it was lost, however short the
  workspace's settings, so a gateway's record sent after a shorter outage is stored.
- A heartbeat counts by the time it carries, corrected by its run's clock offset, which
  the run's heartbeats alone set, within 300
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
  organisation's and yours each have a separate place with separate sections, and
  deleting a workspace, an organisation or your account is the danger
  zone at the end of its General page or Profile.
  Pages start at one left edge and use the width of the screen: lists up to 1680 px, a
  run's page all of it, forms 720 px.
  Each name in the top bar's path is cut short with an ellipsis where it does not fit; on
  a phone the page's name is cut first and its parent keeps up to 8rem, so no name
  runs over a separator or the buttons after it.
- Signing in, and a workspace's link on the organisation's Overview, lead to the first
  page of the workspace the person is shown.
- The workspace Overview's "more" link under To review goes to the page for the first
  item it leaves out: Network access for a denial, the runs for a lost or quiet run, or
  one behind the policy in force, the Policy page for a policy item and the nodes page for
  an idle key, each where the reader may read it.
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
  and a tab of each run; a repository's Overview links to it narrowed to the
  repository): every destination the runs reached, what
  decided it, and Allow or Deny from its row, narrowed the same way as the runs. Its
  rows are one line each, the denied number the one red, with Allow and Deny as icons on
  hover, a copy icon by the host, and host suggestions in its query field. The policy's
  host rules are its Network access section, which links back to it. The paths
  `/:org/:workspace/connections` and a run's `…/connections` send on to it.
- A connection the wall refused says so in words on the run page and on Network access:
  "Forager refuses a host that is neither a name nor an address in canonical form, in
  either mode." and "The wall refuses link-local addresses and the machine's addresses,
  in either mode."; in a table, its tooltip says what refused it. The rule form's error
  for an address written with a port, a path or brackets says the wall refuses link-local
  addresses whatever the policy says, and the machine's addresses unless the policy
  allows that host by name.
- A connection whose host is longer than 255 bytes keeps the host's first 252 bytes, cut
  on a character boundary, followed by "…", and no rule can be made from it. It shows so
  on the connection's row, in the run's timeline, on the Overview and in the list of what
  enforce would deny. The Overview and the Policy pages offer no Allow for a destination
  no rule can change, the wall's refusals and a host no rule can name; the row still
  shows, and still counts.
- A connection's host is isolated where a page shows it, so a right-to-left character in
  it reorders nothing around it; a tooltip or a label holds it as plain text.
- The policy's rules on the same list pattern, however long the list grows: views (All,
  Allowed, Denied, Locked) with their counts, "Find a host" with `seen:`, `paths:` and
  `by:` as tokens, one Filter menu and Sort, and pages of 50, every choice in the address;
  Add rule is the one primary button of the Network access section's header. A repository's Policy tab is its effective
  policy on that list, each rule with its source: the repository's rules first, changed there; the
  workspace's read there and changed on the workspace's page, which their menu leads to;
  what is not in force struck through, saying why. Its mode is a card above the tabs:
  the mode in force, a badge that says whose it is, and Change mode, which offers Follow
  with the workspace's name, Observe or Enforce.
- The rules on the Policy pages, and the rule form's words of a rule, name who made each
  rule by their account, as History does, whether or not that person is a member of the
  organisation; "Former member" is for a deleted account.
- A policy page asked to edit the paths of an id that is no rule's stays on its list, with
  "This workspace has no such rule." for an id that could be a rule's.
- A host rule is added and changed on a page, New rule
  (`/:org/:workspace/policy/rules/new`, a repository's `…/-/policy/rules/new`) and Edit
  rule (`…/policy/rules/:id/edit`), from Add rule, a row's Edit and the top bar's New
  (Network access rule). The page asks what runs should do first, Allow or Deny, each
  saying what it does; then Host and Paths, each with its help; and reads the rule back
  under "What this rule does" as it is typed. An error is said under its field with its
  repair as a link, and Add rule, never off, moves to the first field at fault. A pasted
  list of hosts is added one at a time. A save goes back to the list as it was left, the
  new rule marked. A declared host's Allow with paths… opens the page with the host
  filled in. `ApiaryWeb.PolicyComponents.rule_form/1` draws the form; `rule_list/1` takes
  the section's header (`title`, `count`, `add_path`, `edit_path`), and
  `rule_composer/1` and `rule_list/1`'s `composer` slot stay for callers that have not
  moved. On a page with the form, a Remove that `ApiaryWeb.PolicyLive.Common` answers gives
  the focus to Add rule, never to a composer the page does not draw.
- The rule form and its reading also serve a level above the workspace, for an edition
  that keeps one: `rule_form/1` and `ApiaryWeb.PolicyLive.Reading.host_rule/2` take the
  scope `:organisation`, whose button reads Add rule and whose sentences say "for every
  workspace", and `ApiaryWeb.PolicyLive.Common.mount/3` takes `scope` and `may_change`,
  who may change the page's rules. Where only that level allows a host, Network access and
  To review lead to its New rule page with the host filled in (`new_rule_path` of
  `c:ApiaryWeb.Edition.above_policy_link/1`).
- An edition's sentence of who may lock, unlock or change a locked rule
  (`c:ApiaryWeb.Edition.who_may_sentence/2` with `:"security_policy.lock"`) shows after
  the sentence that says what is locked, at each place that says it: a locked rule's lock,
  the rule form, a target's path refusal, the lock's tip in a target's list of what
  enforce would deny, the refusal to change or remove a locked rule, a connection's Allow
  or Deny panel and the workspace overview. The Lock confirm keeps the core's words, and
  the core's edition gives no such sentence.
- Every form answers a field that is wrong under it, in the page's words, and never with
  the browser's built-in bubble: the log-in form says an address cannot be one before it
  sends a link, and still says the same of an address with an account and one without.
- The features an instance has, switched at launch (`QORY_FEATURES`), and the
  documentation every instance serves at `/docs`: the guides and the release notes, and
  the module reference on an instance with every feature. An opt-in feature is on only when
  the list names it: `all`, `all-…`, and a value that is not set or empty leave it off.
- `APIARY_ENCRYPTION_SECRET`, required, 32 bytes: the integrity codes of stored rows are
  keyed from it.
- `APIARY_SIGNING_SECRET`, required, a separate 32 bytes, never derived from
  `APIARY_ENCRYPTION_SECRET`: the seed of the Ed25519 key the server signs its answers
  to gateways with. The boot refuses it when it is missing, of another length, the same
  as `APIARY_ENCRYPTION_SECRET`, one of the contract's published fixture seeds, or the
  development or test seed this repository publishes. Every machine pins its public key, so changing
  or losing it means pinning every machine again.
- The two 32-byte keys, `APIARY_ENCRYPTION_SECRET` and `APIARY_SIGNING_SECRET`, in hex
  too (64 characters, either case), beside base64 (44 characters): both decode to the same
  bytes, and the boot compares the bytes.
- A key variable left blank counts as not set: a blank `SECRET_KEY_BASE` or
  `APIARY_ENCRYPTION_SECRET` stops the boot as missing, unless the keys file holds it.
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
  secrets included, on the container's disk. Its base is Debian: the release and CI build
  it on qoryai's digest-pinned copies in `ghcr.io/qoryai/ci-images` of
  `public.ecr.aws/docker/library` (Amazon's public copy of Docker's official images) and
  of the Elixir build image, and CI pulls the Postgres, nginx and Docker images it runs
  from the same copies; the end to end job's SMTP sink, Mailpit, comes from `ghcr.io`.
- Pre-release images: `.github/workflows/prerelease.yml`, run by hand only, from the
  Actions tab or by pushing a commit to the branch `prerelease`, never on a push to any
  other branch or a schedule, builds a branch, tag or commit as a release's image is
  built and publishes it to `ghcr.io/qoryai/apiary-prerelease` alone, a private package, as
  `sha-<7>` and, for `next`, as `next`; the Test image field, under For testing only in
  the AWS template's test copy, runs such an image in place of the image the Edition and
  Version pick.
- `compose.yaml`: the published image, as `.env` names it
  in `APIARY_VERSION` (and `APIARY_IMAGE`), Postgres 18 in the profile `postgres`, which
  `.env.example` turns on, and the server, published on `127.0.0.1:4100` alone.
  `.env.example` holds no secret, and no `POSTGRES_PASSWORD`. CI runs it as a person
  does: the install, a restart, the upgrade from the base commit's image, the path from a
  checkout, and an external Postgres over TLS.
- The AWS template, `deploy/aws/apiary.yaml`: Qory Apiary on ECS Fargate behind an
  Application Load Balancer, with RDS for PostgreSQL 18 and its keys in Secrets Manager,
  installed from the AWS console's form and upgraded with its Update, with no command. A
  release attaches its release copy as `apiary.yaml`, with the test parts left out and the
  template's version written in (`scripts/aws-template-release.py --copy release --version
  X.Y.Z`). The stack finds the version to install when it is created or updated: with
  `VersionOverride` empty, the newest release of the edition, the highest `X.Y.Z` tag of
  its image (`ghcr.io/qoryai/apiary` for Qory Apiary Community), never `latest`; with a
  version typed, exactly that one. The task runs that image pinned by its digest, so
  only a stack create or update changes what runs. An update with
  `VersionOverride` empty looks up the newest release again, except one that changes only
  the download key, which is not among the lookup's values; when nothing else changes,
  something new under "Look for a newer release" (`LookForNewerRelease`) makes it look. A
  version older than the one the stack runs is refused, typed or found: within the edition
  by its `X.Y.Z`, and on a change of edition by its `X.Y` alone. So is a release of a
  newer minor than the template: a new minor needs that minor's `apiary.yaml`. The test
  copy, the repository's template or one written with `--copy test`, keeps the Test image
  field, which skips the lookup, and is never published. The form asks for the edition;
  a download key, for an edition that needs one, which the stack keeps as a separate
  secret, deleted with the stack; and the domain, with a Route 53 hosted zone, or without
  one, the stack then making the certificate and waiting for its validation record. Rules
  refuse an edition that needs a download key without one, and an edition built for
  X86_64 alone on ARM64, and, in the test copy, a test image without the download key.
  Under Recovery, `AcceptSigningKey` is passed as `APIARY_ACCEPT_SIGNING_FINGERPRINT`, and
  `DatabaseDeletionProtection` sets the database's deletion protection: a function of the
  stack turns it on once the service is first healthy, so a create that fails
  before then rolls back whole, and an Update with No turns it off before a delete. Under
  Advanced, `ErlangOptions`, empty by default, is passed as `ELIXIR_ERL_OPTIONS` only when
  set: extra options for the Erlang runtime when Qory Apiary starts. The
  stack sets its stack policy itself, refusing any update that would replace or delete the
  database or a key's secret: an EventBridge rule sends this stack's status changes to a
  function of the stack's, which sets the policy once the create completes, and again
  once each update completes or rolls back, as CloudFormation refuses a stack policy while
  the stack is in progress. The four secrets are kept when the stack is
  deleted, each named after the stack and the whole UUID of its stack ID, so they do not
  block a new stack of the same name, which has a different stack ID, and the database leaves
  a final snapshot. The log groups, the task's and those of the stack's three functions,
  are kept too, when the stack is deleted and when a create rolls back, their events for
  30 days, under names made from the stack ID in the same way. The outputs are the
  address, the load balancer's DNS name, the edition, the version the stack runs and its
  image, by its digest, the key secrets' ARNs (their names, on a stack given the keys of a
  deleted one), and links into the console: the logs, the set-up link's line in
  them, the service, the key secrets and the database snapshots. CI lints the template
  with cfn-lint, and the two copies the release script writes, the release copy and the
  test copy; runs the script's tests, and the version lookup's against a stubbed registry;
  checks that the release copy holds no test part and no test wording, comments included,
  and is the test copy without the test parts; checks that the version lookup's role may
  read the download key's secret, describe the stack and write its log group, nothing else,
  and that the task runs the image the lookup found; and checks the stack
  policy and the rule, function, permission and role that set it, and that nothing sets
  it from inside the stack's create or update, that no output is a command, which
  secrets and log groups the stack keeps and that their names use the stack ID's UUID,
  the mappings' keys, that every value compared with the edition is one the form allows,
  and that the template and every copy are ASCII alone, as the AWS console shows any
  other character as "?".
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
  documentation: only the console's scripts run, and a script injected into a page,
  inline, in an `on…=` attribute or as a `javascript:` address, is refused by the
  browser. A reverse proxy must pass the header on, neither stripping nor replacing it.
- A feature can have parts, which an edition may hide from a person apart from the rest
  of the feature (`Apiary.Features.parts/0`, `c:Apiary.Edition.hidden/1`), and an action
  may belong to one (`part:`). The first is the run's Terminal (`:"observability.terminal"`),
  which `run.read_log` belongs to: hidden from a person, it hides the run's whole log from
  them, the Terminal tab, `/runs/:run_id/terminal`, the log's address with every stream and
  the download, the ⋯ menu's Raw log and Download log and the runs list's preview of the
  last lines, and the sentences on session events name no terminal. The terminal's size on
  the run's Details asks whether the person may read the log (`run.read_log`), as the
  Terminal tab does.
- Workspace settings leave out the size of the log a retention pass deleted for a reader
  the run's Terminal is hidden from.
- The runs list's preview shows a run's last log lines, and its Full log link, only to a
  reader who may read the log (`run.read_log`), as the run page's Terminal tab does.
- A feature part can belong to no feature; the nodes, node pools, access keys and gateways
  are the part `nodes`, which an edition may hide from a person while nodes keep working.
- What a node is served follows the instance's features alone (`QORY_FEATURES`): a run's
  registration, events, attach, outcome and reload, and its run configuration, whatever a
  level above the workspace shows. Below the instance a feature is shown or hidden, never
  switched off: an edition says what a person is not shown in an organisation
  (`c:Apiary.Edition.hidden/1`, the core's answer: nothing), and a feature is hidden from
  a person when a feature it needs is hidden. A hidden feature's pages, menu entries and
  actions are not found for that person, and still work in full for nodes, rendering and
  the instance's jobs. `Apiary.Features.on?/1` says what is on, and
  `Apiary.Features.visible?/2` what a person is shown.
- An edition may give other words for the invitation's description, a level's hint on
  People (`c:ApiaryWeb.Edition.people_sentence/3`) and the empty Gateways page
  (`c:ApiaryWeb.Edition.gateway_reach_sentence/2`, `:empty`); the core edition keeps
  today's.

[Unreleased]: https://github.com/qoryai/apiary/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/qoryai/apiary/releases/tag/v0.1.0
