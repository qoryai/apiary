# 🐝 Qory Apiary

Can you trust your agents? With Qory you don't have to. Every session runs behind a security
wall, reaches only what you allow, never holds your keys, and leaves a full record. Open
source, so you can check all of that.

Qory Apiary is the control plane: the server the machines that run your agents report to,
and the console you read. It keeps the record of every run, serves the policy every run is
held to, and shows you both. One container image, Postgres beside it, and the `qory`
command on each machine.

## The problem

You let a coding agent work on its own: a branch, a task, an hour with nobody watching. It
can open a connection to any host it likes. It holds the token for the model, and often the
one for your code host too. When it is done you have a diff, and a diff does not say what
the agent read, where it sent it, or what it tried that did not work. You cannot trust what
you cannot see, and the one remedy on offer is to watch every session, which is the thing
autonomy was meant to end. Autonomy should not mean blindness.

## What Qory Apiary gives you

- **The record.** Every run of every machine of a workplace, in one place: the session as
  a timeline, the terminal as it was written, every connection with the decision and the
  rule behind it, and how the run ended. It is written by the runner as the run happens
  and kept here after the machine is gone.
- **The wall.** Every connection a session makes goes through a proxy on the machine, and
  behind a container wall that proxy is the only way out. A credential stays outside the
  container; the proxy sets it on the requests it is for, and the record names the
  credential and never holds it.
- **The policy.** What the runs of a workplace may reach, edited in one place, versioned,
  and served to every machine of the workplace. A change reaches the runs in flight within
  a heartbeat.
- **Open source.** Apache 2.0, the contract between runner and server published, the
  fixtures replayed in the tests. You can read what the record is made of.

## Three steps

### 1. Run it

Docker with `docker compose`, `git` and `openssl` are enough for a trial on one machine.

```sh
git clone https://github.com/qoryai/apiary.git qory-server && cd qory-server
cp .env.example .env
openssl rand -hex 24         # the database password, twice in .env
openssl rand -base64 48      # SECRET_KEY_BASE
openssl rand -base64 32      # CLOAK_KEY
docker compose up --build    # Postgres 18, then the server on port 4100
curl http://localhost:4100/health
```

For the trial, `.env` sets `PUBLIC_URL=http://localhost:4100` and `MAIL_TO_LOG=true`,
which writes the log-in link to the log instead of sending it. Open
`http://localhost:4100/users/register`, enter an email address, and take the link from
`docker compose logs apiary`. You land on the overview of your workplace. Every value, and
what each one is for: [guides/quickstart.md](guides/quickstart.md).

### 2. Connect a machine

The `qory` command, 0.10.0 or later, runs the agent and reports to the server. Under
**Access keys** in the console, create a key for the machine; the dialog shows the secret
once, inside the block for the runner file.

```sh
brew install qoryai/tap/qory        # or the install script; see the command's README
qory version                        # 0.10.0 or later
mkdir -p ~/.config/qory
# paste the block from the console into ~/.config/qory/runner.yaml
chmod 600 ~/.config/qory/runner.yaml
```

```yaml
server:
  url: http://localhost:4100        # https for a server on another machine
  access_key: ak_0123456789abcdef
  secret: <the secret from the console>
```

Then a first run, with the command's own hello example:

```sh
mkdir hello && cd hello
qory setup example
qory harness compose
qory run -- -p "/hello"
```

The runner fetches the server's configuration, signed with the key, sends a ping and starts
the runtime. If the server does not answer, there is no run. The run is on **Runs** before
it ends, with its timeline, terminal and connections.
[guides/runner-file.md](guides/runner-file.md) has the section's rules.

### 3. Set the policy

Under **Policy**, add the hosts your agents may reach: a name, `api.example`, or a suffix,
`*.internal.example`; a host held to paths, `/acme/*`; a credential of the machine, by
name. A workplace starts in observe, which records every connection and denies only what a
deny rule names. When the rules are complete, an owner switches to enforce; the
confirmation lists what enforce would start denying, from the record. A repository can
have rules and a mode of its own, so one repository is enforced first and the rest when
the record says they are ready.

The first change is the moment the workplace takes over from each machine's own list, so
read [guides/security-policy.md](guides/security-policy.md) before you make it.

## Without it

Without a record, the first sign that an agent sent your source to a host it found in a
README is nothing at all. Without a wall, a token in the container belongs to the agent and
to every program it starts. Without one policy, each machine keeps a list of its own, and
the lists drift. None of that is a reason to stop letting agents run. It is a reason to know
what they did.

## With it

You see and bound what your agents do. A run is a page: what it worked on, what it reached,
what was refused and why, what it wrote, what it cost. A policy is a document with a
version, a history and a digest every run reports back, so two runs with the same digest ran
under the same rules, and a run behind the version in force says so. The overview opens on
what needs you: a destination the rules do not cover, a run that went quiet, a workplace
still in observe with rules ready to enforce.

## What it holds

- **Runs**, `/hive/runs`: every run of the workplace with its state, what it worked on,
  runtime, host, start, duration and denials; grouped by repository or by task, filtered,
  and live.
- **Timeline**: the session in sequence, a tool call and its response as one item, one lane
  per agent, a connection inside the call it was made during.
- **Terminal**: the bytes the run wrote, tailing while it runs, with search and download.
- **Connections**: one row per destination, on the run and across the workplace, with
  attempts, the decision, the rule and the outcome of the last attempt, and **Allow** or
  **Deny** in the row.
- **The security policy**: a baseline for the workplace and rules per repository, observe
  or enforce per repository, locked rules that hold everywhere, a history with a diff, an
  export for a machine without a server. A change reaches the runs in flight within a
  heartbeat, about 30 seconds.
- **Retention**: how long a workplace keeps a run's events and its log output, set by an
  owner, pruned nightly, and unlimited until somebody says otherwise
  ([guides/retention.md](guides/retention.md)).
- **Docs**: the guides and the module reference, built into the image and served by every
  instance at `/docs`, so what you read is the version you run.

## How it fits

The `qory` command composes the agent's harness and starts the session; the runner inside
it puts the proxy and the wall around the session and writes the record. This server is
where the record goes and where the policy comes from. What the two say to each other is
the [runner contract](https://github.com/qoryai/runner/tree/main/contracts/runner/v1):
signed requests, a configuration document, an events endpoint and a run configuration. The
server implements version 1, revision 2, and replays the contract's fixtures in its tests;
its reading of the contract is in
[docs/contract-assumptions.md](docs/contract-assumptions.md) and
[guides/contract.md](guides/contract.md). The command is
[qoryai/qory](https://github.com/qoryai/qory), and its README says how a session runs.

## Ways to run it

Self-hosting is one way to run it, and the one this page describes: the compose file in the
repository, or the image on infrastructure of your own. A hosted instance and a managed
installation are the other options; it is the same code either way.

For an installation other people sign in to, read
[guides/install.md](guides/install.md) and then the
[hosting checklist](guides/hosting-checklist.md): an `https` address behind a reverse proxy,
real mail, the two keys kept with the backups, the port published to the proxy alone.

## Configuration

Configuration is by environment variables, read once at boot. A required variable that is
missing or malformed stops the boot with a message naming it. Every variable, its default
and its accepted values are in [guides/install.md](guides/install.md).

| Group | Variables |
|---|---|
| Database | `DATABASE_URL` (required), `POOL_SIZE`, `ECTO_IPV6`, `MIGRATE_ON_BOOT`; `POSTGRES_PASSWORD` for the bundled Postgres |
| Secrets | `SECRET_KEY_BASE` (required), `CLOAK_KEY` (required; never changes once a key exists) |
| Public address | `PUBLIC_URL` (required: scheme and host, a port when it has one, nothing after), `PORT` |
| Mail | `SMTP_RELAY` (required), `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_TLS`, `MAIL_FROM`; `MAIL_TO_LOG` for a trial on one machine only |
| Clustering | `DNS_CLUSTER_QUERY` |

`GET /health` answers `200` when the database does and `503` when it does not, and needs no
credentials. In production the release writes one JSON object per line to stdout, never a
header, a body or a secret. Postgres is the only state: a `pg_dump` plus `CLOAK_KEY` and
`SECRET_KEY_BASE` is a complete backup ([guides/backup.md](guides/backup.md)).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for where contributions go and how the checkout is
run: Erlang and Elixir from `mise.toml`, Postgres on `localhost:5432`, `mix setup`,
`mix phx.server`, and `mix precommit` before a pull request. Contributions are made under
the agreement in [CLA.md](CLA.md).

## Versioning and upgrading

Releases follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html) and are tags
`vX.Y.Z`; the image is built from the `Dockerfile` at the tag, and the version is what
`GET /health` and `bin/apiary version` report. Before 1.0 a minor release may change what an
existing installation does, and says so under **Upgrading** in [CHANGELOG.md](CHANGELOG.md);
every section names the migrations the release runs on boot.

An upgrade is a restart: the new release migrates the database before it serves. Back up
first, read the release's section of the changelog, and go one minor version at a time
before 1.0.

```sh
git fetch --tags && git checkout vX.Y.Z
docker compose up --build -d
```

Every migration reverses, and [guides/upgrading.md](guides/upgrading.md) says how to roll
back and how migrations are written so that the previous release keeps running on the
schema the next one migrated.

## Support

A question or a bug is an issue on this repository. A vulnerability is not: report it the
way [SECURITY.md](SECURITY.md) says, and you get an answer within three working days.

## Licence

Apache License 2.0. See `LICENSE`. Qory™ is a trademark of 8wonders GmbH;
`TRADEMARKS.md` says what you may do with the name.
