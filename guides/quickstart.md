# From nothing to a first run

This page takes a machine with Docker to a running Qory Apiary with one run on its runs
page. It is a trial on one machine, from the image a release publishes, with nothing
cloned or built: Qory Apiary is reached at `http://localhost:4100`, and needs no mail: you
sign in with a password. For an installation other people sign in to, read
[Install and configure](install.md) and the [hosting checklist](hosting-checklist.md).

You need Docker with the `docker compose` command, and `curl`. From step 5 on you need the
`qory` command, one that has `qory access-key`, on the same machine.

## Run it

### 1. Download the release's files

Every release attaches `compose.yaml` and `env.example`. In a directory of its own,
download the latest release's, and rename `env.example` to `.env`:

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
same link each time. Find it:

```sh
docker compose logs apiary | grep 'Set up Qory Apiary'
```

The log is one JSON object per line, and the line's `message` reads:

```text
Set up Qory Apiary at http://localhost:4100/setup/<code>.
```

Open that link. The page reads **Set up Qory Apiary**.
Enter an email address, `ada@example.com` say, a password of 12 to 72 characters, the
same password again, and the **Organisation name**, usually your company's, `Acme` say,
and select **Set up**. You are signed in, and land on the overview of your workspace.
Until a run reaches it, the overview is one box, **Send your first run**: Add a node,
Connect it, See runs here. Steps 5 to 7 below are those steps.

The link works once: after it, it says "This Qory Apiary is already set up.", and you log
in at `http://localhost:4100/users/log-in` with your email address and password. Until it
is used nobody can sign up, and anyone who reads the log can use it, so open it as soon as
the instance is up ([Set up a new instance](install.md#set-up-a-new-instance)).

Setting it up created an organisation with the name you gave, one workspace in it named
*Main*, and your membership as its owner. Both can be renamed in their **Settings**, at the
foot of the sidebar: the workspace's on any page of the workspace, the organisation's on its
overview, which its name in the top bar opens. As the person who set the instance up you
are also its **instance admin**: your organisation is the instance's own, and its owners
are the instance's admins. Nobody else can sign up without an invitation
([Install and configure](install.md#sign-up-and-invitations)), so invite your colleagues
from **People** in the organisation's settings. Without mail the page shows the
invitation's link once, for you to copy and send yourself. Someone who signs up through an
invitation joins the organisation as a member, chooses a password, and is not asked for a
name.

Every page of a workspace is under `/<organisation>/<workspace>/…`, both parts slugs made
from the names given at set-up: an organisation named `Acme` gives `/acme/main`, and the runs
are at `/acme/main/runs`. Renaming keeps a slug. A link to a page names its workspace, so
a colleague in the organisation opens the same page, and anyone else gets *Not Found*.

The people of the organisation are under **Organisation settings › People**, `/<organisation>/settings/people`, each
at one of three levels, and every one of them reaches the workspace; the workspace's own
**Workspace settings › People**, `/<organisation>/<workspace>/settings/people`, lists who reaches it,
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
variable sets aside any value of its own a repository has for the name; no page sets a
repository's own value. Every member reads both views; owners and admins change them. A
name beginning `QORY_` is Forager's own and is refused.
<!-- /feature -->

Your own preferences are under **Your settings › Preferences**, in the menu of your account: the
time zone the pages show times in (UTC until you choose one; every time is stored in UTC)
and, once the instance has more than one, the language. They are yours, not the
organisation's. Mail to you, once the instance sends mail, is written in your language. The words
of the workspace's pages are its domain's, chosen when it was created: software, the one
domain there is, which says repository, forge and pull request.

## 5. Add a node, then connect it

A machine posts its runs with an access key of its own, on a **node** of the workspace: a
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
   machines, and this trial's machine is Qory Apiary's own, so the command works here.
3. On the machine, run the command:

   ```sh
   qory access-key enrol http://localhost:4100 qec_…
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

Write the command's hello example into an empty directory, compose its harness and start
one headless turn:

```sh
mkdir hello && cd hello
qory setup example
qory harness compose
qory run -- -p "/hello"
```

The example is composed for the `claude` runtime, so that runtime's command has to be
installed on this machine and able to start a session. Arguments after `--` go to the
runtime.

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

## Next

<!-- feature: security -->
- Until somebody changes the workspace's policy, runs use each machine's own policy. Read
  [The security policy](security-policy.md) before the first rule: from the first change,
  each machine's runs take the workspace's policy, narrowed by the machine's own `egress`
  section.
<!-- /feature -->
- `qory run --local` records to files only and does not contact Qory Apiary.
- To stop the trial: `docker compose down`. The database stays in the volume
  `postgres-data`, and the keys in the volume `keys`; `docker compose down --volumes`
  deletes both.
