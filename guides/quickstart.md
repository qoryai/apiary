# From nothing to a first run

This page takes a machine with Docker and nothing else to a running Qory Apiary with one run on its
runs page. It is a trial on one machine: the server is reached at `http://localhost:4100`,
and emails are written to the log instead of being sent. For an installation other people
sign in to, read [Install and configure](install.md) and the
[hosting checklist](hosting-checklist.md).

You need Docker with the `docker compose` command, `git` and `openssl`. For the last two
steps you need the `qory` command, version 0.10.0 or later, on the same machine.

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

Generate three values:

```sh
openssl rand -hex 24       # the database password
openssl rand -base64 48    # SECRET_KEY_BASE: 64 characters, the least the server accepts
openssl rand -base64 32    # CLOAK_KEY: 32 bytes in base64, 44 characters
```

Open `.env` and set these lines. The database password appears twice, and the two must
match; a password in hexadecimal needs no escaping inside the URL.

```text
POSTGRES_PASSWORD=<the database password>
DATABASE_URL=ecto://apiary:<the database password>@postgres/apiary
SECRET_KEY_BASE=<the second value>
CLOAK_KEY=<the third value>
PUBLIC_URL=http://localhost:4100
MAIL_TO_LOG=true
```

Leave `SMTP_RELAY` empty and every other line as it is.

> #### MAIL_TO_LOG is for a trial on one machine only {: .warning}
>
> With `MAIL_TO_LOG=true` every email is written to the log in full. Log-in links and
> invitation links are credentials, and with this setting they reach the log and everyone
> and everything that reads it. Never set it on an installation other people sign in to.

Keep `CLOAK_KEY` and `SECRET_KEY_BASE` somewhere safe if you mean to keep this installation;
[Backup and restore](backup.md) says what is lost without them.

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
account**. You land on the overview of your workspace.

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
at one of three levels, and every one of them reaches the workspace. An invitation is an
email address and nothing else: the person joins as a member, and an owner changes their
level afterwards. An **owner** and an **admin** manage the organisation's members and
settings; only an owner changes a person's level or locks a rule of the security policy,
and an admin manages members only, not owners or other admins. A **member** works in the
workspace and manages neither the members nor the settings. `http://localhost:4100/` and
the log-in take you to the workspace.

Your own preferences are under **Your settings › Preferences**, in the menu of your account: the
time zone the pages show times in (UTC until you choose one; every time is stored in UTC)
and, once the instance has more than one, the language. They are yours, not the
organisation's. Mail to you, such as a log-in link, is written in your language. The words
of the workspace's pages are its domain's, chosen when it was created: software, the one
domain there is, which says repository, forge and pull request.

## 5. Create an access key

An access key lets the machines of a workspace post their runs.

1. Select **Settings** at the foot of the sidebar, then **Access keys**,
   `/:org/:workspace/settings/keys`.
2. Select **New access key**.
3. Give it a **Label**, the machine or environment it is for, `build-01` say, and select
   **Create key**.
4. The dialog **Your new access key** shows the **Key id**, the **Secret**, and the block
   for the runner file with both filled in. The secret is shown once: Qory Apiary keeps only an
   encrypted copy and cannot show it again. Copy the block, then select **I have copied the
   secret**.

## 6. Put the `server` section in the runner file

The runner file is `~/.config/qory/runner.yaml`, or `$XDG_CONFIG_HOME/qory/runner.yaml`
when that variable is set. It belongs to the machine and to no repository.

```sh
mkdir -p ~/.config/qory
```

Paste the block from the console into `~/.config/qory/runner.yaml`. It begins with an
`apiVersion` line and holds this section:

```yaml
server:
  url: http://localhost:4100
  access_key: ak_0123456789abcdef
  secret: <the secret from the console>
```

When the file exists already, keep its own `apiVersion` line and add the `server` section
alone: the file is read strictly, and a key written twice is refused. The file now holds a
secret, so make it readable by you alone:

```sh
chmod 600 ~/.config/qory/runner.yaml
```

A `server.url` over plain `http` is accepted only for an address of this machine, such as
`localhost`. A server elsewhere is reached over `https`.
[The runner file's `server` section](runner-file.md) has the rest.

## 7. First run

Check the command's version; the `server` section needs 0.10.0 or later, and an earlier
`qory` refuses a runner file that has one:

```sh
qory version
```

Then write the command's hello example into an empty directory, compose its harness and
start one headless turn:

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
access key and the secret, and sends a ping. If the server does not answer, or refuses the
key, there is no run, and the error names the URL and the status. The record of the run is
also written to `.qory/runs/<id>/` in the directory, whatever the server does.

## 8. See it

Open **Runs** in the sidebar, `http://localhost:4100/<organisation>/main/runs`. The run is
there with its state, runtime, host, start and duration; select it for its timeline,
terminal, connections and details. The `hello` directory has no origin remote, so the run
names no repository: the repositories beside the list count it under **Unassigned**. A
run started in a checkout with an origin remote names that repository, and choosing the
repository there, or typing `repo:` and its path in the filter, lists its runs alone.

On **Access keys**, the key's row now shows when it was last used, its last heartbeat and
the runner's version.

## Next

<!-- feature: security -->
- Until somebody changes the workspace's policy, runs use each machine's own policy. Read
  [The security policy](security-policy.md) before the first rule: the first change takes
  over for every machine of the workspace.
<!-- /feature -->
- `qory run --local` records to files only and does not contact the server.
- To stop the trial: `docker compose down`. The database stays in the `postgres-data`
  volume; `docker compose down --volumes` deletes it.
