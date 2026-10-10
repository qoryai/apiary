# 🐝 Qory Apiary

The control plane for coding agent runs.

Every run of a connected machine reports to Qory Apiary: its session, terminal and every
connection, with the decision and rule behind it. Qory Apiary is the server your machines report to and the
console you read. Open source, so you can check all of that.

- **The record.** Every run in one place: the session as a timeline, the terminal output,
  and every connection with the decision and the rule behind it.
- **The wall.** Behind Forager's wall a session's only way out is the gateway; each run's
  record says whether it had a wall.
- **The policy.** What runs may reach, versioned and edited in one place. A change reaches
  the runs in flight within about 30 seconds.

## Run it

You need Docker with `docker compose`, and `curl`. Nothing is cloned or built: Qory Apiary
runs from the image a release publishes, `ghcr.io/qoryai/apiary`, with its own Postgres,
on port 4100 of `127.0.0.1`.

In a directory of its own, download the latest release's `compose.yaml` and `env.example`,
rename `env.example` to `.env`, and start it:

```sh
mkdir qory-apiary && cd qory-apiary
curl -fLO https://github.com/qoryai/apiary/releases/latest/download/compose.yaml
curl -fLO https://github.com/qoryai/apiary/releases/latest/download/env.example
mv env.example .env
docker compose up -d
curl http://localhost:4100/health
```

`.env` names its release in `APIARY_VERSION`, runs the bundled Postgres
(`COMPOSE_PROFILES=postgres`) and sets `PUBLIC_URL` to `http://localhost:4100`, for a trial
on this machine. The keys are generated at first start, into the volume `keys`. `/health`
answers once the migrations have run, a few seconds after the start.

Then set it up with the link its log gives, the same at every start until it is used:

```sh
docker compose logs apiary | grep 'Set up Qory Apiary'
```

Open the link, `http://localhost:4100/setup/<code>`, and enter your email address, a
password and your organisation's name. That creates the instance's organisation, its
workspace Main and your account as its owner, the instance's admin; everyone else joins by
invitation.

Mail is optional: with the mail lines of `.env` empty, Qory Apiary sends no email, you sign
in with your password, and an invitation is a link you copy and send. To send mail, set
`SMTP_RELAY` in `.env`, and the variables beside it, then run `docker compose up -d` again,
or set it under **Instance settings › Mail** and follow the test link it sends you.

Then add a node under **Nodes**, select **Get the command** on its **Access key** tab, and
run the command it gives, `qory access-key enrol <server> <code>`, on the machine, which
needs the [`qory`](https://github.com/qoryai/qory) command. Start a run there, and it shows
up under **Runs**. With `PUBLIC_URL` on `localhost`, that machine is this one; for other
machines Qory Apiary needs an `https` address, as
[Install](https://github.com/qoryai/apiary/blob/main/guides/install.md) says.
[The quickstart](https://github.com/qoryai/apiary/blob/main/guides/quickstart.md) walks
through set-up, the node and the first run step by step.

To upgrade, set the new release's version in `APIARY_VERSION` in `.env`, then run
`docker compose pull` and `docker compose up -d`. Back up first, and read
[Upgrading](https://github.com/qoryai/apiary/blob/main/guides/upgrading.md).

On AWS, no command is needed: the release attaches `apiary.yaml`, a CloudFormation
template; create a stack from it in the AWS console.

## Guides

- [Quickstart](https://github.com/qoryai/apiary/blob/main/guides/quickstart.md): a trial
  on one machine, step by step.
- [Install](https://github.com/qoryai/apiary/blob/main/guides/install.md) and the
  [hosting checklist](https://github.com/qoryai/apiary/blob/main/guides/hosting-checklist.md):
  an instance other people sign in to, and every setting.
- [Nodes and their keys](https://github.com/qoryai/apiary/blob/main/guides/nodes.md): how a
  machine gets its access key, and what a node pool is.
- [Security policy](https://github.com/qoryai/apiary/blob/main/guides/security-policy.md):
  read it before your first change.
- [Upgrading](https://github.com/qoryai/apiary/blob/main/guides/upgrading.md) and
  [backup](https://github.com/qoryai/apiary/blob/main/guides/backup.md).

Every instance also serves its guides and release notes at `/docs`.

## Changelog

What each release changed is in
[CHANGELOG.md](https://github.com/qoryai/apiary/blob/main/CHANGELOG.md), and every release
with its files is on the [releases page](https://github.com/qoryai/apiary/releases).

## Contributing

Running it from a checkout, development and the architecture are in
[CONTRIBUTING.md](https://github.com/qoryai/apiary/blob/main/CONTRIBUTING.md); contributions
are made under [CLA.md](https://github.com/qoryai/apiary/blob/main/CLA.md). Report a
vulnerability as [SECURITY.md](https://github.com/qoryai/apiary/blob/main/SECURITY.md)
says, not as an issue.

## Licence

Apache License 2.0, see [LICENSE](https://github.com/qoryai/apiary/blob/main/LICENSE).
Qory™ is a trademark of 8wonders GmbH;
[TRADEMARKS.md](https://github.com/qoryai/apiary/blob/main/TRADEMARKS.md) says what you may
do with the name, and [EDITIONS.md](https://github.com/qoryai/apiary/blob/main/EDITIONS.md)
what each edition contains.
