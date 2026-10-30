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
- While an organisation has no workspace, its owners and admins invite people from
  **People** into the organisation. The invitation page and the sign-up show the
  organisation's name, and **People** lists the invitation with **None** as its workspace.
  Accepting it opens **Set up your workspace** while the organisation has no workspace,
  else the organisation's overview. Once the organisation has a workspace, an invitation
  needs a workspace again.
- Each page of the set-up with more than one step shows a list of the steps of its part,
  with the part's count. The instance set-up, which an instance admin goes through once,
  has **Your account** and the steps under **Connect Qory Apiary**. The workspace set-up
  lists its steps with no heading, after **Your account** for a person who is not an
  instance admin. Above the list, “Step 1 of 2” and a bar, and in the workspace set-up
  a title such as “Set up Main · Software factory”; below 1280 px the list is a bar with
  **All steps**. A step done or skipped is a link to it where it has a page, once you
  are signed in; **Your account** is not. **Back** at the foot of a form opens the step
  before in the same part, and each step has an address, such as
  `/instance/set-up?step=mail` and `/<organisation>/set-up?step=name&type=software`. A
  person who waits for another to create the first workspace sees no list.
- The workspace set-up at `/<organisation>/set-up` moves on without a reload when
  another person creates the organisation's first workspace while the page shows the
  type cards, the line for a person who waits, or the step **Name**.
- An edition can change the set-up's steps and their notes, and, for a person who waits
  for the first workspace, the page's title, **Set up your workspace** in the core, and
  a line under **About this step**, through the callbacks `set_up_steps/2`,
  `set_up_title/2` and `set_up_context/2` of `Apiary.Edition`. The core keeps its steps
  and the title, and adds no line.
- **What will this workspace do?** shows a card for each workspace type, with what you do
  in that kind of workspace, what you connect, and **Choose**. This release has one type,
  **Software factory**: “Agents change code in your repositories. You connect: where work
  comes from, where changes go, a model.” The cards show on `/<organisation>/set-up` while
  the organisation has no workspace, and on `/<organisation>/workspaces/new`, where an
  owner adds a workspace where the edition allows another. Where the organisation has as
  many workspaces as the edition allows, that page shows “Acme may have no more
  workspaces.” in place of the cards. Only owners see the cards: anyone else reads who
  sets up the first workspace, and `/<organisation>/workspaces/new` is not found for
  them. **Choose** opens the set-up of a workspace of that type, “Set up a new Software
  factory”. Its step **Name** has the field **Name**, filled in with Main for the
  organisation's first workspace and empty for any other, and **Create workspace**,
  which creates the workspace and opens the next step, or the workspace where there is
  none. Each workspace stores the type it was made from.
<!-- feature: factory -->
- **Connect Qory Apiary** has a step for each adapter that **Instance settings ›
  Adapters** lists, before **Mail** where the page has that step. Where an adapter's
  description has steps for setting it up or connecting it, that step and the workspace
  set-up's **Work sources** and **Destinations** list them in the column **About this
  step**, under **In the new tab** or **On** and the adapter's name. Qory Apiary stores
  those steps at each start of the adapter.
- After a type's card, the workspace set-up has 7 steps: **Name**, **Work sources**,
  **Destinations**, **Model**, **Harness**, **Machines** and **Test run**, counted
  “Step 4 of 7”, or “Step 5 of 8” after **Your account**. **Name** creates the workspace,
  and each later step sets up that workspace: before it exists, the page opens **Name**.
  Without a step in its address, the page opens the first step that is not done. **Work
  sources**, **Destinations**, **Model** and **Harness** each show where you change them
  later, such as “You can change this later in Workspace settings › Workflow.” Where the
  edition allows more than one workspace, a workspace added later goes through the same
  7 steps.
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
  **Connected**. **Connect another source**, or **Connect another destination** in
  **Destinations**, lists the adapters the instance has set up for the workspace's type
  that the organisation has not connected, each with **Not connected**, or
  **Connecting…** while the connection is pending. That list is open while the step
  shows no card and no **Connected** line. Owners and admins have **Connect**, which returns to the step after the
  adapter's steps; anyone else reads who may connect. A connection to an adapter is the
  organisation's and serves every workspace, so its **Connect** has no setting of where
  it applies: one connection to GitHub serves both steps of every workspace. With no
  adapter to list, the step shows “No work source for this type is set up on this
  instance. An instance admin sets one up in Instance settings › Adapters.”, or the same
  for a work destination. The step updates without a reload.
- **Choose** opens “Choose repositories · GitHub · acme”, at
  `/acme/set-up/choose?step=sources&grant=<id>&workspace=main`, with two choices, in the
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
  as the set-up's steps, with **Connect another source** or **Connect another
  destination**. **Choose** opens the same chooser in the workspace's settings, at
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
  Claude subscription, **About this step** shows `claude setup-token` on a separate
  line, with **Copy command**.
- **Harness**, “Which harness do runs in Main use?”, sets the harness of the
  workspace's runs. **About this step** explains what a harness is, which harness a run
  uses, and the versions. The choices are two: **Qory harness**, with **Version**
  **Always the latest version**, the newest version this Qory Apiary release ships, which
  moves on when Qory Apiary is upgraded, and **A fixed version**, disabled with “Named
  versions come with the first release of the Qory harness.”; or **A harness
  repository**: a **Repository** from a searchable list of the connected repositories, a
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
  of an error in Qory Apiary. Try again. If it repeats, tell an instance admin.” Each run
  on a branch reads the branch's newest commit when it starts and records it. A
  workspace with no saved choice uses the Qory harness. Owners and admins choose. The
  test run keeps its built-in harness.
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

  Under a pool that is not ready, an instance admin has **Check the nodes** for the
  instance's pool. For a pool of the workspace, owners and admins have its name as a
  link to its page. Anyone else reads who acts, such as “Only an instance admin checks
  the Qory Pool and the Qory Gateway.” While the workspace has no pool, anyone who may not
  add one sees the Qory Pool, read only. The step is done once a pool is ready. **About
  this step** explains what a pool does, which pool takes the workspace's runs, what
  makes a pool ready, and that every run gets an isolated environment.
- **Test run**, “Run a test”, makes a test work item of the line in **Say hi to your
  agent** with **Run the test**, with no work source; owners, admins and members run it
  once a pool that serves the workspace is ready. Before that, the step shows “Runs need
  a ready pool. See Machines.”, and **See Machines** opens that step. **About this step**
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
- While a workspace's test run has not passed, opening the workspace opens its set-up at
  the first step that is not done, such as
  `/<organisation>/set-up?step=harness&workspace=main`: from its address, the sidebar,
  the breadcrumb, the organisation's list of workspaces and a sign-in. A person who may
  not act on that step reads who may. Once the test run has passed, the workspace opens
  at its Overview, which has no set-up list. Its other pages, such as **Backlog** and
  **Runs**, open whatever the state of its set-up.
- **Organisation settings › Model providers** lists the organisation's model providers,
  and **New model provider** adds one with its key, and an address for a provider that
  needs one, such as LiteLLM; no page shows a key once it is saved. Under **Key**: “Qory
  Apiary stores the key encrypted, and nobody can view it again.” The provider is added
  for one workspace, the one in the help beside the form: “After you save, choose the
  model for Main in Workspace settings › Model.” Its key is a secret of that workspace,
  and it reaches that workspace alone. While the organisation has no workspace, the
  page shows “Set up a workspace first, then add a model provider in its Model step.” in
  place of the form, and adds nothing. For a Claude subscription, **About this step** shows
  `claude setup-token` on a separate line, with **Copy command**. **Workspace settings ›
  Model** sets the model of the workspace's runs. Its field suggests each provider's
  models from the models.dev list in the release, which the Mix task
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
- **Workspace settings › Workflow**, for owners and admins, shows the workspace's
  **Harness** on two lines, such as “Qory harness” over “Always the latest version”, or
  the harness the organisation shares where the workspace has no saved choice.
  **Change** opens the two choices of the set-up's **Harness** step, with **Save** and
  **Cancel**. Under the harness, **Repositories** shows the same rows as the Harness
  step, with the same **Stack** field. **About this step** also has the Harness step's
  five paragraphs.
  Under it, the page sets the workflow of the workspace's runs, from a harness
  repository: **Source** lists the repositories connected to the organisation, and the
  harness sources an instance admin assigned to it;
  **Enter an address** takes a **Public address**. **Save** sets the workflow the runs
  use; no run reads that source's stack as its harness. When an adapter's result
  marks a repository as public, a run reads it through that adapter with no link to the
  organisation and no credential.
- The documentation at `/docs` describes the `factory` feature: its steps in the guides,
  the variables of the instance's node pool and gateway, and its modules in the module
  reference. An instance without `factory` serves none of that text.
<!-- /feature -->
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

### Changed

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
- The organisation slug `integrations` is reserved as well: a slug made from a name skips
  it, to the first free one of `-2`, `-3`, …; a new organisation named Integrations gets
  the slug `integrations-2`.
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
  `dev.qory.runtime.*` names, and a run's runtime is that of its last session. A run
  recorded before the upgrade keeps its runtime, cost and log, and its Timeline shows no
  prompts, turns or results. Do not run `Apiary.Release.rebuild()` after this upgrade: it
  clears the runtime and cost of those runs, and the command, arguments, folder, image and
  terminal size.
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
  workspace set-up, at `/<organisation>/set-up`, which starts with **What will this
  workspace do?**. Until the organisation has a workspace, each sign-in of a member of
  the organisation opens that page.
  On a new instance, `Apiary.Release.grant_instance_admin/2`, the release command an
  instance admin runs, still creates Main, of the type Software factory. Where an edition
  offers a sign-up without an invitation, that sign-up creates no workspace either.
  Create Main before you load the demo: `Apiary.Release.demo()` writes nothing while Acme
  has no workspace Main.
- Where a step of the set-up needs context, its page has a column **About this step**
  beside the form, or under it below 1024 px, that shows what the step does.
<!-- feature: factory -->
- **Organisation settings › Model providers**, **Workspace settings › Model** and
  **Workspace settings › Workflow** have a column **About this step** beside the form.
  **Provider**, **Model** and **Source** are choice fields.
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
- Account settings, **Connect Qory Apiary**, and Instance settings › Mail and ›
  Configuration accept a sign-in from the last 15 minutes, up from 10: the time a set-up
  pass of the GitHub adapter lasts.
- A run whose machine never started it stays as a failed run, with its page and id. The
  cause is one of: the pool made no machine, the claim lapsed before the handover, or the
  machine stopped before it started the run. The run page, its preview and the runs list
  show the cause, the pool's name and the pool's reason. A run whose machine stops before
  it starts the run ends failed at once, not 15 minutes later.

### Fixed

- The built-in harness uses qory's hello example at a commit that allows extending it.
  With the earlier commit, composing the built-in harness failed, so every test run
  failed.

### Security

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
- The log filter replaces an invitation link's token before it looks for `qak_` and an
  enrolment code's prefix. Before, a token that contained one of them could leave up to
  39 of its 43 characters in the log line.

### Migrations

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
