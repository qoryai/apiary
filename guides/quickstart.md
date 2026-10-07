# From nothing to a first run

This page takes a machine with Docker and nothing else to a running Qory Apiary with one run on its
runs page. It is a trial on one machine: the server is reached at `http://localhost:4100`,
and emails are written to the log instead of being sent. For an installation other people
sign in to, read [Install and configure](install.md) and the
[hosting checklist](hosting-checklist.md).

You need Docker with the `docker compose` command, `git` and `openssl`. From step 5 on you
need the `qory` command, one that has `qory access-key`, on the same machine.

## 1. Get the source

Clone the repository of Qory Apiary and enter the checkout:

```sh
git clone https://github.com/qoryai/apiary.git qory-server
cd qory-server
```

## 2. Write `.env`

```sh
cp .env.example .env
```

Generate four values:

```sh
openssl rand -hex 24       # the database password
openssl rand -base64 48    # SECRET_KEY_BASE: 64 characters, the least the server accepts
openssl rand -base64 32    # APIARY_ENCRYPTION_SECRET: 32 bytes in base64, 44 characters
openssl rand -base64 32    # APIARY_SIGNING_SECRET: another 32 bytes, never the same value
```

Open `.env` and set these lines. The database password appears twice, and the two must
match; a password in hexadecimal needs no escaping inside the URL.

```text
POSTGRES_PASSWORD=<the database password>
DATABASE_URL=ecto://apiary:<the database password>@postgres/apiary
SECRET_KEY_BASE=<the second value>
APIARY_ENCRYPTION_SECRET=<the third value>
APIARY_SIGNING_SECRET=<the fourth value>
PUBLIC_URL=http://localhost:4100
MAIL_TO_LOG=true
```

Leave `SMTP_RELAY` empty and every other line as it is.

> #### MAIL_TO_LOG is for a trial on one machine only {: .warning}
>
> With `MAIL_TO_LOG=true` every email is written to the log in full. Log-in links and
> invitation links are credentials, and with this setting they reach the log and everyone
> and everything that reads it. Never set it on an installation other people sign in to.

Keep `APIARY_ENCRYPTION_SECRET`, `APIARY_SIGNING_SECRET` and `SECRET_KEY_BASE` somewhere safe
if you mean to keep this installation; [Backup and restore](backup.md) says what is lost
without them.

## 3. Start it

```sh
docker compose up --build
```

The first start builds the image, which takes a few minutes. Compose starts Postgres 18
with a volume, waits until it is healthy, then starts the `apiary` service, which runs the
database migrations and listens on port 4100. A required variable that is missing or
malformed stops the boot with a message that names it.

From a second terminal, check that it serves:

```sh
curl http://localhost:4100/health
```

```text
{"status":"ok","database":"ok","version":"0.1.0"}
```

The members of the object may come in another order, and the version is the release's.

## 4. Sign up

Open `http://localhost:4100/users/register`. Under **Create your account**, enter an email
address, `ada@qory.example` say, and the **Organisation name**, usually your company's,
`Acme` say, and select **Create account**. No password is asked for:
the server sends a link, and the page says where it went and that the link works for 15
minutes.

With `MAIL_TO_LOG=true` the email is in the log of the `apiary` service. This prints the
newest link:

```sh
docker compose logs apiary | grep -o 'http://localhost:4100/users/log-in/[A-Za-z0-9_-]*' | tail -n 1
```

Open the link in the browser. The page reads **Welcome to Qory Apiary**; select **Confirm my
account**. You land on the overview of your workspace. Until a run reaches it, the
overview is one box, **Send your first run**: Add a node, Enrol the machine, See runs here.
Steps 5 to 8 below are those steps.

Signing up created an organisation with the name you gave, one workspace in it named
*Main*, and your membership as its owner. Both can be renamed in their **Settings**, at the
foot of the sidebar: the workspace's on any page of the workspace, the organisation's on its
overview, which its name in the top bar opens. As the first person to sign up on this instance you are also its **instance
admin**: your organisation is the instance's own, and its owners are the instance's
admins. Nobody else can sign up without an invitation
([Install and configure](install.md#sign-up-and-invitations)), so invite your colleagues
from **People** in the organisation's settings. Someone who signs up through an invitation joins the
organisation as a member and is not asked for a name.

Every page of a workspace is under `/<organisation>/<workspace>/…`, both parts slugs made
from the names at sign-up: an organisation named `Acme` gives `/acme/main`, and the runs
are at `/acme/main/runs`. Renaming keeps a slug. A link to a page names its workspace, so
a colleague in the organisation opens the same page, and anyone else gets *Not Found*.

The people of the organisation are under **Settings › People**, `/<organisation>/settings/people`, each
at one of three levels, and every one of them reaches the workspace; the workspace's own
**Settings › People**, `/<organisation>/<workspace>/settings/people`, lists who reaches it,
and leads owners and admins to the organisation's. An invitation is an
email address and nothing else: the person joins as a member, and an owner changes their
level afterwards. An **owner** and an **admin** manage the organisation's members and
settings; only an owner changes a person's level or locks a rule of the security policy,
and an admin manages members only, not owners or other admins. A **member** works in the
workspace and manages neither the members nor the settings. `http://localhost:4100/` and
the log-in take you to the workspace.

<!-- feature: security -->
The values runs are given are under the workspace's **Settings › Secrets and variables**,
`/<organisation>/<workspace>/settings/secrets`, in two views. A **secret**, such as a
token for a forge, holds one value or several, each named by a **value ID**; once saved, a
value is never shown again, to anyone, and the page lists only names, value IDs, who
changed each value and when, and what uses it. A **variable** is a plain value, such as
the address of a package registry, which a repository may set its own value of unless the
variable is **locked**. Every member reads both views; owners and admins change them. A
name beginning `QORY_` is the runner's own and is refused.
<!-- /feature -->

Your own preferences are under **Your settings › Preferences**, in the menu of your account: the
time zone the pages show times in (UTC until you choose one; every time is stored in UTC)
and, once the instance has more than one, the language. They are yours, not the
organisation's. Mail to you, such as a log-in link, is written in your language. The words
of the workspace's pages are its domain's, chosen when it was created: software, the one
domain there is, which says repository, forge and pull request.

## 5. Add a node, then enrol the machine

A machine posts its runs with an access key of its own, on a **node** of the workspace: a
node is one permanent machine, a **node pool** a fleet of short-lived instances that share
one key. The machine makes the key, and Qory Apiary keeps only its public half.

1. Select **Nodes** in the sidebar, then **New node**. Name it after the machine,
   `build-01` say, and select **Add node**. The node's **Access key** tab opens.
2. Select **New enrolment code**, leave **Stored secrets** at **Not allowed**, and select
   **Make code**. The page shows the code once, and under "On the machine, run:" the
   command with this server and the code filled in. Select **Copy command**.
3. On the machine, run the command:

   ```sh
   qory access-key enrol http://localhost:4100 qec_…
   ```

   `qory` makes the key, keeps its secret in `~/.config/qory/access-key-secret`, readable
   by you alone, and prints the key's fingerprint. It writes the `server` section into
   `~/.config/qory/runner.yaml`, `$XDG_CONFIG_HOME/qory/runner.yaml` when that variable is
   set: the server's `url`, the key's `access_key_id`, and `apiary_public_key`, the
   server's key, which the code named and the server's signed answer confirmed. The code
   works once, for 15 minutes.
4. Select **Done**. Once the command has run, the node's **Access key** tab shows the key,
   **Awaiting approval**, under the machine's name; reload the tab if it is not there yet.
   Compare its **Fingerprint** with the one `qory` printed, then select **Approve…** and
   **Yes, approve**.

Until the key is approved, every request of the machine is refused `key_pending`, and no
run starts.

The runner file belongs to the machine and to no repository.
[The runner file's `server` section](runner-file.md) has the rest of it.

## 6. Or paste the key

Instead of a code, the machine can make its key on its own, and you paste the public key
into the node:

1. On the machine, `qory access-key create` makes the key, keeps its secret in
   `~/.config/qory/access-key-secret`, and prints the public key and its fingerprint.
2. On the node's **Access key** tab, select **Add a public key**, give it a **Label**,
   paste the **Public key**, check that the **Fingerprint** under it is the one the
   machine printed, and select **Add key**. A key you add here is approved as you add it.
3. The page **Runner file for build-01** shows the lines to put in
   `~/.config/qory/runner.yaml`, with **Copy lines**, and for a CI the same id and pin as
   variables. Nothing on it is secret, and an approved key's **Runner file lines** opens it
   again.

[Nodes and their keys](nodes.md) says more about both ways, node pools and revoking a key.

## 7. First run

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

Before the runtime starts, the runner fetches the server's configuration, signed with the
machine's access key, checks the answer under the server's key it pinned, and sends a
ping. If the server does not answer, or refuses the key, there is no run, and the error
names the URL and the status. The record of the run is also written to `.qory/runs/<id>/`
in the directory, whatever the server does.

## 8. See it

Open **Runs** in the sidebar, `http://localhost:4100/<organisation>/main/runs`. The run is
there with its state, runtime, host, start and duration; select it for its timeline,
terminal, network access and details, among them its node and its instance. The `hello`
directory has no origin remote, so the run names no repository: the repositories beside
the list count it under **Unassigned**. A run started in a checkout with an origin remote
names that repository, and choosing the repository there, or typing `repo:` and its path
in the filter, lists its runs alone.

On the node's **Overview**, the machine is now its instance, with its run. On its **Access
key** tab, the key's card shows when it was last used, its last heartbeat and the runner's
version.

## Next

<!-- feature: security -->
- Until somebody changes the workspace's policy, runs use each machine's own policy. Read
  [The security policy](security-policy.md) before the first rule: the first change takes
  over for every machine of the workspace.
<!-- /feature -->
- `qory run --local` records to files only and does not contact the server.
- To stop the trial: `docker compose down`. The database stays in the `postgres-data`
  volume; `docker compose down --volumes` deletes it.
