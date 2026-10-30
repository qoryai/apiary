# From nothing to a first run

This page takes a machine with Docker to a running Qory Apiary with one run on its runs
page. It is a trial on one machine, from the image a release publishes, with nothing
cloned or built: Qory Apiary is reached at `http://localhost:4100`, and needs no mail: you
sign in with a password. For an installation other people sign in to, read
[Install and configure](install.md) and the [hosting checklist](hosting-checklist.md).

You need Docker with the `docker compose` command, and `curl`. From step 5 on you need the
`qory` command, version 0.13.0, and `git`, on the same machine.

## Run it

### 1. Download the release's files

Every release attaches `compose.yaml` and `env.example`. In an empty directory, download the
latest release's, and rename `env.example` to `.env`:

```sh
mkdir qory-apiary && cd qory-apiary
curl -fLO https://github.com/qoryai/apiary/releases/latest/download/compose.yaml
curl -fLO https://github.com/qoryai/apiary/releases/latest/download/env.example
mv env.example .env
```

`.env` names its release in `APIARY_VERSION`, and `compose.yaml` runs the image
`ghcr.io/qoryai/apiary` at that version. `PUBLIC_URL` is `http://localhost:4100` already.
The mail lines are optional and stay empty for this trial: without mail Qory Apiary sends
no email, you sign in with a password, and an invitation is a link you copy
([Mail](install.md#mail) says how to set it). The keys are not in `.env`: they are
generated at first start.

### 2. Start it

```sh
docker compose up -d
```

Compose pulls the image, then runs the service `keys`, which generates `SECRET_KEY_BASE`,
`APIARY_ENCRYPTION_SECRET`, `APIARY_SIGNING_SECRET` and the database password into the
volume `keys` and exits. It then starts Postgres 18 with a volume, waits until it is
healthy, and starts the `apiary` service, which runs the database migrations and listens
on port 4100 of `127.0.0.1`. A required variable that is missing or malformed stops the
boot with a message that names it, in `docker compose logs apiary`.

### 3. Check that it serves

Once the migrations have run, a few seconds after the start:

```sh
curl http://localhost:4100/health
```

```text
{"status":"ok","database":"ok","version":"0.1.0","revision":"4f2a9c1e0b…"}
```

The members of the object may come in another order. `version` is the release's, the one
`.env` names, and `revision` the commit the release's image was built from.

Keep a copy of the keys if you mean to keep this installation:
[Backup and restore](backup.md) says how, and what is lost without them.

## 4. Set it up

Until it is set up, Qory Apiary writes its set-up link to its log at every start, the
same link each time. An install that sets `QORY_SETUP_CODE_SHA256` prints the link itself,
and the log does not show it ([Install](install.md)). Find it:

```sh
docker compose logs apiary | grep 'Set up Qory Apiary'
```

The log is one JSON object per line, and the line's `message` reads:

```text
Set up Qory Apiary at http://localhost:4100/setup/<code>.
```

Open that link. The page reads **Set up Qory Apiary**.
Enter an email address, `ada@example.com` say, a password of 12 to 72 characters, the
same password again, and the **Organisation name**, usually your company's, `Acme` say.
Then select **Set up**. It creates your account and the organisation, with no workspace
yet, and signs you in. **Connect Qory Apiary** lists its steps, with the current one
marked, counted from step 1. With the `factory` feature, the group **Set up** at the top
of the workspace's sidebar lists the workspace's steps, with a check mark on each one
done. **Back**, at the foot of a step's form, opens the step before it. Two pages
follow:

1. **Connect Qory Apiary**, at `http://localhost:4100/instance/set-up`. At its **Mail**
   step, select **Skip**. You can set mail up later in **Instance settings › Mail**. With
   mail set in `.env`, the page has no **Mail** step, and you see the page only when the
   instance has an adapter.
2. The overview of your organisation, at `http://localhost:4100/acme`. Under **Choose
   what your first workspace does**, it shows the card **Software factory**, whose words
   this guide uses: select **Choose**. It creates the workspace *Software factory*, at
   `http://localhost:4100/acme/software-factory`, and opens its step **Name**. Type the
   name `Main`, which this guide uses, and select **Save and next**. The workspace's
   address follows its name, so it moves to `http://localhost:4100/acme/main`.

You land on the overview of your workspace Main, `http://localhost:4100/acme/main`.
Until a run reaches it, the overview is one box, **Send your first run**: Add a node,
Connect it, See runs here. Steps 5 to 7 below are those steps.

<!-- feature: factory -->
With the `factory` feature, **Connect Qory Apiary** has one step for each adapter that
**Instance settings › Adapters** lists, before **Mail** where the page has that step:
select **Skip**, or **Continue** where the step is set up already, or set the adapter up
as [Set up a new instance](install.md#set-up-a-new-instance) shows.

**Save and next** on **Name** then opens **Work sources**, the next step of Main's
set-up, and [step 8](#8-set-up-main-and-run-the-test) has the steps from there
to a test run. Steps 5 to 7 still connect a node and post a run, from **Nodes** in the
sidebar, but Main's overview has no box for them, and their node does not count for the
step **Machines**, which counts node pools only.
<!-- /feature -->

The link works once: after it, its page shows "This Qory Apiary is already set up.", and
you log in at `http://localhost:4100/users/log-in` with your email address and password.
Until it is used nobody can sign up, and anyone who reads the log can use it, so open it
as soon as the instance is up ([Set up a new instance](install.md#set-up-a-new-instance)).

Setting it up created an organisation with the name you gave and your membership as its
owner, and **Choose** created one workspace in it, which you named *Main*. Both can be
renamed in their **Settings**, at the foot of the sidebar: the workspace's on any page of
the workspace, the organisation's on its overview, which its name in the top bar opens. As
the person who set the instance up you are also its **instance admin**: your organisation
is the instance owner, and its owners are the instance's admins. Nobody else can sign up
without an invitation ([Install and configure](install.md#sign-up-and-invitations)), so
invite your colleagues from **People** in the organisation's settings. Without mail the
page shows the invitation's link once, for you to copy and send yourself. Someone who signs
up through an invitation joins the organisation as a member, chooses a password, and is not
asked for a name.

Every page of a workspace is under `/<organisation>/<workspace>/…`, both parts slugs made
from the names given at set-up: an organisation named `Acme` gives `/acme/main`, and the runs
are at `/acme/main/runs`. A slug follows the name: renaming the organisation or the
workspace changes its slug, and links to the old address stop working. A link to a page
names its workspace, so a colleague in the organisation opens the same page, and anyone
else gets *Not Found*.

The people of the organisation are under **Organisation settings › People**, `/<organisation>/settings/people`, each
at one of three levels, and every one of them reaches the workspace; the workspace's **Workspace
settings › People**, `/<organisation>/<workspace>/settings/people`, lists who reaches it,
and leads owners and admins to the organisation's. An invitation is an
email address and nothing else: the person joins as a member, and an owner changes their
level afterwards. An **owner** and an **admin** manage the organisation's members and
settings; only an owner changes a person's level or locks a rule of the security policy,
and an admin manages members only, not owners or other admins. A **member** works in the
workspace and manages neither the members nor the settings. `http://localhost:4100/` and
the log-in take you to the workspace.

<!-- feature: secrets -->
Secrets and variables are under **Workspace settings › Secrets and variables**,
`/<organisation>/<workspace>/settings/secrets`, in two views; a run receives only its
security policy. A **secret**, such as a token for a forge, holds one value or several,
each named by a **value ID**; once saved, a value is never shown again, to anyone, and the
page lists only names, value IDs and who changed each value and when. A **variable** is a
plain value of the workspace, such as the address of a package registry. A **locked**
variable sets aside every repository override of it; no page sets a repository override. Every member reads both views; owners and admins change them. A
name beginning `QORY_` is reserved for Forager and is refused.
<!-- /feature -->

Your preferences are under **Your settings › Preferences**, in the menu of your account: the
time zone the pages show times in (UTC until you choose one; every time is stored in UTC)
and, once the instance has more than one, the language. They are yours, not the
organisation's. Mail to you, once the instance sends mail, is written in your language. The words
of the workspace's pages are its type's, chosen when it was created and fixed after: in
a Software factory they are repository, forge and pull request.

## 5. Add a node, then connect it

A machine posts its runs with an access key, on a **node** of the workspace: a
node is one permanent machine, a **node pool** a fleet of short-lived instances that share
one key. These are the overview's first two steps, **Add a node** and **Connect it**.
Here you connect the machine with a command: `qory` makes the key on the machine, and Qory
Apiary keeps only its public half.

1. Select **Nodes** in the sidebar, then **New node**. Name it after the machine,
   `build-01` say, and select **Add node**. The node's **Access key** tab opens and asks
   "How do you want to connect build-01?", with two ways: **Connect with a command**
   first, and **Generate a key in the browser**. (Back on the overview, step 2 asks the
   same, and **Get the command** there shows the command in place.)
2. Under **Connect with a command**, select **Get the command**. The page **Connect
   build-01 with a command** shows the command to run on the machine, with Qory Apiary's
   address and a one-time code in it. Select **Copy command**. Since `PUBLIC_URL` is a
   `localhost` address, the page also says machines can't reach it; that holds for other
   machines, and this trial's machine is the one Qory Apiary runs on, so the command works here.
3. On the machine, run the command:

   ```sh
   qory access-key enrol http://localhost:4100 qecn_…
   ```

   `qory` makes the key, keeps its secret in `~/.config/qory/access-key-secret`, readable
   by you alone, and prints the key's fingerprint. It writes the `gateway.server` section into
   `~/.config/qory/forager.yaml`, `$XDG_CONFIG_HOME/qory/forager.yaml` when that variable is
   set: Qory Apiary's `url`, the key's `access_key_id`, and `apiary_public_key`, Qory
   Apiary's key, which the code named and Qory Apiary's signed answer confirmed. The
   address and Qory Apiary's key are the same for every machine connected to this Qory
   Apiary; only `access_key_id` is the machine's key's. The command works once, for 15
   minutes.
4. The page, which read "Waiting for build-01 to run it.", now says "build-01 is
   connected." with the key and its **Fingerprint**. It is the one `qory` printed; if it
   is not, revoke the key on the **Access key** tab. Select **Done**.

The command is the approval: the key is active as soon as it arrives, and the machine can
use it at once. On the **Access key** tab, the key's card says where its secret is.

The Forager file belongs to the machine and to no repository.
[The Forager file's `server` section](forager-file.md) has the rest of it.

For a CI or a node pool, **Generate a key in the browser** on the same tab makes the key
in your browser and shows its secret once, with the other values the CI sets; [Nodes and
their keys](nodes.md) says more about both ways, node pools and revoking a key.

## 6. First run

The machine holds an access key now, so every run there needs a wall: the agent runs in a
container whose one way out is the gateway's proxy. Without a wall, `qory run` refuses
the run, `key_needs_wall`, as [An access key needs a
wall](https://github.com/qoryai/qory/blob/v0.13.0/docs/run.md#an-access-key-needs-a-wall)
says. A wall needs Docker and an image that holds the agent.

Qory publishes no such image: build it from a checkout of `qory` at its release's tag
([Qory's images](https://github.com/qoryai/qory/blob/v0.13.0/docs/run.md#qorys-images)):

```sh
git clone https://github.com/qoryai/qory && git -C qory checkout v0.13.0
docker build -t qory-agent qory/images/agent
```

Add the wall to `~/.config/qory/forager.yaml`, the file step 5 wrote:

```yaml
wall:
  adapter: docker
  image: qory-agent
  helper: /path/to/linux/qory   # on a Mac only
```

On a Mac, `wall.helper` is the Linux `qory` of the same release, from its archive
`qory_0.13.0_linux_arm64.tar.gz` or `qory_0.13.0_linux_amd64.tar.gz`, matching Docker's
architecture; on Linux, leave the line out ([The
wall](https://github.com/qoryai/qory/blob/v0.13.0/docs/run.md#the-wall)).
`qory image check` checks the image against what the wall needs of it.

Write the command's hello example into an empty directory, compose its harness and start
one headless turn:

```sh
mkdir hello && cd hello
qory setup example
qory harness compose
qory run --env CLAUDE_CODE_OAUTH_TOKEN -- -p "/hello"
```

The example is composed for the `claude` runtime, which the image holds. It needs a model
credential, here `CLAUDE_CODE_OAUTH_TOKEN` from `claude setup-token`, set in this shell;
[The wall](https://github.com/qoryai/qory/blob/v0.13.0/docs/run.md#the-wall) has the
other ways. `--env` passes that one variable into the container, and nothing else of your
environment goes in. Arguments after `--` go to the runtime. The agent greets you, and
`qory` prints `✓ claude exited 0`.

Before the runtime starts, the gateway fetches Qory Apiary's configuration, signed with the
machine's access key, checks the answer under Qory Apiary's key it pinned, and registers
the run. If Qory Apiary does not answer, or refuses the key, there is no run, and the error
names the URL and the status. At the end of the run qory prints where its record is,
`qory run: the record is in <folder>/<id>`. The record is written whatever Qory Apiary
does, under `~/.local/state/qory/runs/`, or `$XDG_STATE_HOME/qory/runs/` when
`XDG_STATE_HOME` is set to an absolute path, not in the directory.

## 7. See it

Open **Runs** in the sidebar, `http://localhost:4100/<organisation>/main/runs`. The run is
there with its state, runtime, host, start and duration; select it for its timeline,
terminal, network access and details, among them its node and its instance. The `hello`
directory has no origin remote, so the run names no repository: the repositories beside
the list count it under **Unassigned**. A run started in a checkout with an origin remote
names that repository, and choosing the repository there, or typing `repo:` and its path
in the filter, lists its runs alone.

On the node's **Overview**, the machine is now its instance, with its run. On its **Access
key** tab, the key's card shows when it was last used, its last heartbeat and Forager's
version.

<!-- feature: factory -->
## 8. Set up Main and run the test

With the `factory` feature, the workspace set-up goes on after **Name**, at
`http://localhost:4100/acme/main/set-up/<step>`, a page of Main. Until a test run passes,
the group **Set up** at the top of Main's sidebar lists the steps, and Main's overview,
`http://localhost:4100/acme/main`, lists them too, with **Continue** to the next step.
Each list shows a check mark on each step once it is done:

| Step | Done when |
|---|---|
| **Name** | Main exists. |
| **Work sources** | Main takes tickets from at least one collection: the collection is Main's, with its Backlog on. |
| **Destinations** | At least one repository is Main's. |
| **Model** | Main has a default model, with a model provider that applies to Main and has a key. |
| **Harness** | Main has a saved harness choice. |
| **Machines** | A node pool that serves Main's runs has a key in use, and so does the gateway the pool's runs go through. While Main has no node pool, the instance's pool and gateway serve its runs, on an install that has them. |
| **Test run** | The step shows **Test run passed**. |

**Run the test** shows once **Machines** is done, so you can leave the other steps for
later.

1. **Work sources.** **Where does work for Main come from?** shows a card for each
   account that Acme's connections reach. With nothing connected, **Connect another
   source** is open and lists the adapters that the instance has set up. Select
   **Connect** beside one, and follow the steps that **About this step** lists under its
   name: the adapter sends you back to this step, which shows a card such as “GitHub ·
   acme” with **Choose**. Select **Choose**. On “Choose repositories · GitHub · acme”,
   choose **All repositories, including new ones**, in the adapter's word for its
   collections, or **Only selected** and tick the collections whose tickets Main takes
   in. **Only selected** shows 50 to a page, with **Find a repository** and a count such
   as “3 selected”. Select **Save**: each collection chosen is assigned to Main, with
   its Backlog on, and the card shows how many, such as “3 of 14 repositories”, or “All
   repositories”. All also assigns to Main each collection that the adapter lists for
   the account later; with **Only selected**, a collection listed later joins no
   workspace until you tick it. If a collection is missing and the adapter sent a line
   on its access, **Not listed?** shows that line, with **Change access**. Select
   **Continue**, or **Skip** to leave the step for later. You can change the list later
   in **Workspace settings › Work sources**, with the same cards and chooser, and
   connect an adapter in **Organisation settings › Integrations**. One connection to an
   adapter serves every workspace of Acme. Only owners and admins connect and choose.
2. **Destinations.** **Which repositories may runs in Main change?** shows a card for
   each account of the adapters with repositories, and **Connect another destination**
   for an adapter not connected yet. Select **Choose**, choose **All repositories,
   including new ones** or **Only selected** and tick the repositories Main's runs may
   change, then **Save** and **Continue**. Where **Work sources** has All for the
   account, the chooser shows All alone: “Work sources is set to All for acme. Change it
   there first.” You can change the list later in **Workspace settings › Destinations**,
   which shows the same cards and chooser. Unticking a repository there also stops its
   tickets.
3. **Model.** **Which model do runs in Main use?** has three fields. In **Key**, keep
   **Add a key**, the one option while Main has no model provider to reuse. In
   **Provider**, choose the provider of your key, such as **Anthropic API key**; **About
   this step**, beside the form, shows where to get a key for the provider you choose.
   Paste the key in **Key**. For LiteLLM, also enter the proxy's https address in
   **Address**, such as `https://litellm.example.com`. **Runtime** shows **Claude
   Code**. In **Default model**, keep the first model or choose another, and select
   **Continue**. The key is a secret of Main: **Workspace settings › Secrets and
   variables** lists it, masked, and you replace it there. Only owners and admins add a
   model key.
4. **Harness.** **Which harness do runs in Main use?** has two choices:
   - **Qory harness**, `github.com/qoryai/harness` at the commit it is pinned to, the
     choice when you have made none. A run reads its repository's `harness.yaml` or
     `qory.yaml` first, where the repository has one.
   - **A harness repository**: choose a repository linked to Acme and, in **Branch or
     tag**, a branch or tag. **Continue** reads the repository and pins the commit that
     the branch or tag points to; the step shows why the read failed. A run then reads
     no harness file of its repository.

   Under **Repositories**, each of Main's repositories from **Destinations** shows
   **Workspace default**, or the stack chosen for it. **Change** beside a repository chooses a
   harness for that repository alone: the **Qory harness**, or **A harness repository**
   with a **Source**, a **Stack** of it and a **Branch or tag**, then **Save**. A run in
   that repository then uses that stack, and reads no harness file of the repository.
   Keep **Qory harness** and select **Continue**. The test run uses a built-in harness
   whatever you choose. **Workspace settings › Workflow** shows the choice with its pin,
   and **Change** there opens the same two choices. Only owners and admins save a
   harness choice.
5. **Machines.** **Which machines run the runs in Main?** shows the node pools that
   serve Main's runs: Main's pools, or the instance's pool while Main has none. Each
   shows **Ready** with its gateway, or **Not ready** with the reason. While Main has no
   node pool, you choose between **Qory Pool** and **A pool for
   Main**. The test run passes only through the instance's gateway, set with
   `QORY_INSTALLED_GATEWAY`, whose key allows stored secrets, and this trial's
   `compose.yaml` runs neither the instance's pool nor its gateway ([The instance's node
   pool and gateway](install.md#the-instance-s-node-pool-and-gateway)). A gateway added
   on **Nodes** gets a key without stored secrets, so a test run through it ends before
   a machine starts it. On an install with the instance's pool and gateway, keep
   **Qory Pool**; an instance admin selects **Check the nodes**, which
   opens **Instance settings › Nodes**: each is ready when **State** shows **Running**
   or **Last seen**. Under **A pool for Main**, the step shows "Runs in Main then wait
   for this pool, and the Qory Pool stops taking them." Its **Add pool** adds a
   node pool with the name Main. **Get the command** then shows "On the machine for the
   pool Main, run:" and the enrol command, with **Copy command**. Under it, the step
   shows the command that installs qory. Run it first on the Linux machine with Docker
   that runs Main's runs:

   ```sh
   curl -fsSL https://raw.githubusercontent.com/qoryai/qory/main/install.sh | sh
   ```

   Then run the enrol command on that machine. Once Main has its one pool, owners and
   admins can go back to the instance's pool: choose **Qory Pool**,
   then **Remove pool**. The step deletes Main's pool, and that pool's machines stop
   taking runs. Once Main has its pool and the instance has none, **Qory Pool** shows
   "Not ready: no pool" and cannot be chosen. **Skip** opens **Test run**.
6. **Test run.** In **Say hi to your agent**, keep `Hi! Where are you running?`, or write
   another greeting, and select **Run the test**. The step shows "The test run is queued
   for a machine.", then "The test run is running.", with **See the run** once a machine
   has registered the run. While no pool is ready, the step shows "Runs need a ready
   pool. See Machines." in place of **Run the test**.

A pass shows "Test run passed: the agent answered on a machine of the Qory Pool.",
with Main's node pool by name in place of the instance's pool, or "…on a machine." for a
run with no node, and **See the run**: the agent's output is in the run's log. Owners,
admins and members run the test. If the step shows another line, follow its first
sentence, then select **Run the test** again. When no machine takes the test run within 5
minutes, for example, the step shows "Check the pool in Instance settings › Nodes. No
machine has taken the test run yet." After a pass, **Go to Main** opens Main's overview,
and opening Main opens the overview from then on.

The test run needs no workflow. Before later runs, open **Workspace settings › Workflow**,
`/acme/main/settings/workflow`, which opens for owners and admins. In **Source**, choose
the harness repository, such as `example-org/harness`: the list has the repositories
linked to Acme that have a `qory-stack.yaml` file, and the harness sources an instance
admin assigned to Acme. For a public repository that is not in the list, choose **Enter an
address**, and enter its address in **Public address**, such as
`https://github.com/example-org/harness`, without a password or token in it. In
**Workflow**, choose one of the workflows that the repository's stack lists, and select
**Save**. **Save** sets only which workflow Main's runs use, not their harness.
<!-- /feature -->

## Next

<!-- feature: security -->
- Until somebody changes the workspace's policy, runs use each machine's local policy. Read
  [The security policy](security-policy.md) before the first rule: from the first change,
  each machine's runs take the workspace's policy, narrowed by the `egress` section of
  the machine's Forager file.
<!-- /feature -->
- `qory run --local` records to files only and does not contact Qory Apiary.
- To stop the trial: `docker compose down`. The database stays in the volume
  `postgres-data`, and the keys in the volume `keys`; `docker compose down --volumes`
  deletes both.
