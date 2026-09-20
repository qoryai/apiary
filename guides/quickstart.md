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
address, `ada@qory.example` say, and select **Create account**. No password is asked for:
the server sends a link, and the page says where it went and that the link works for 15
minutes.

With `MAIL_TO_LOG=true` the email is in the log of the `apiary` service. This prints the
newest link:

```sh
docker compose logs apiary | grep -o 'http://localhost:4100/users/log-in/[A-Za-z0-9_-]*' | tail -n 1
```

Open the link in the browser. The page reads **Welcome to Qory Apiary**; select **Confirm my
account**. You land on the overview of your hive.

Signing up created an organisation, which the console calls an *apiary* and names after the
part of your email before the `@`, one hive in it named *Main*, and your membership as its
owner. Both can be renamed under **Settings**.

## 5. Create an access key

An access key lets the machines of a hive post their runs.

1. Select **Access keys** in the sidebar, `/hive/keys`.
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

Open `http://localhost:4100/hive/runs`, **Runs** in the sidebar. The run is there with its
state, runtime, host, start and duration; select it for its timeline, terminal, connections
and details. The `hello` directory has no origin remote, so the run names no repository and
is listed under **Unassigned**. A run started in a checkout with an origin remote is grouped
under that repository.

On **Access keys**, the key's row now shows when it was last used, its last heartbeat and
the runner's version.

## Next

- Until somebody changes the hive's policy, runs use each machine's own policy. Read
  [The security policy](security-policy.md) before the first rule: the first change takes
  over for every machine of the hive.
- `qory run --local` records to files only and does not contact the server.
- To stop the trial: `docker compose down`. The database stays in the `postgres-data`
  volume; `docker compose down --volumes` deletes it.
