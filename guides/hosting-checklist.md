# Hosting checklist

Notes for an operator who puts an instance in front of other people. The
[quickstart](quickstart.md) is a trial on one machine; this is what changes when it stops
being one. Every variable named here is described in [Install and configure](install.md).

## Before anybody signs up

- **An `https` address.** `PUBLIC_URL` is the address people and runners use, with its
  scheme, for example `https://qory.example`. Terminate TLS at a reverse proxy in front of
  the release's port and have it send `X-Forwarded-Proto: https`; without the header every
  request is redirected to the `https` address again. A runner refuses a `server.url` over
  plain `http` unless it is an address of its own machine, and one with a path, so serve
  the instance at the root of its host name.
- **Real mail.** Set `SMTP_RELAY` and the variables beside it, and make sure `MAIL_TO_LOG`
  is not set: with it, log-in links and invitation links, which are credentials, are
  written to the log. Send yourself a log-in link before inviting anybody, and check that
  `MAIL_FROM` is an address your relay may send from.
- **The two keys, kept.** `SECRET_KEY_BASE` and `CLOAK_KEY` are generated once and stored
  where the database backups are stored, not only in the `.env` of the machine.
  `CLOAK_KEY` never changes once an access key exists. [Backup and restore](backup.md)
  says what each loss costs.
- **The features.** `QORY_FEATURES` says which features the instance has; not set, it has
  all of them. A feature that is off is absent for everybody on the instance, so decide
  before they arrive: [Install and configure](install.md#features).
- **Postgres that is backed up.** The database is the only state. Schedule the dump, and
  restore one into an empty database once, before it is needed.
- **The port is not public.** Publish the release's port to the reverse proxy only. In the
  compose file that is `127.0.0.1:4100:4100` in place of `4100:4100` when the proxy runs
  on the same machine.

## When it is up

- **Health.** Point the load balancer or the monitor at `GET /health`: `200` with
  `"status":"ok"` when the database answers, `503` when it does not. It needs no
  credentials and says nothing about any workspace.
- **Logs.** The release writes one JSON object per line on stdout. Ship them as they are.
  A line never holds a request's headers or body, and the paths that carry a credential
  are rewritten before they are logged.
- **Sign-up is open.** Anybody who reaches the instance can sign up and gets an
  organisation of their own; they see nothing of any other. Until sign-up can be closed by
  configuration, restrict who reaches `/users/register` at the reverse proxy if the
  instance is for one company.
- **Retention.** Decide it per workspace before the database decides it for you:
  [Retention](retention.md). Log output is most of what a run stores.
- **The size of a request.** The receiver takes batches of up to 2 MiB; a proxy with a
  smaller limit on request bodies turns them into errors the runner retries for ever.
  Allow at least 2 MiB on `/v1/events`.
  <!-- feature: security -->
  The runner sends every label of a run in the query of `/v1/run-configuration`, which makes a request line of up to about 13 KB; the release
  takes 16 KiB, and a proxy has to take as much.
  <!-- /feature -->
- **WebSockets.** The console is LiveView: the proxy has to pass the `Upgrade` header on
  `/live`, and should not cut idle connections before 60 seconds.

## Upgrades

An upgrade is a restart of the new image, which migrates before it serves:
[Upgrading](upgrading.md). First read the release's section of the changelog,
`CHANGELOG.md` at the root of the repository, then back up, and upgrade one minor version
at a time before 1.0. Two instances must not boot the same release at the same moment when
its changelog says a migration builds an index `CONCURRENTLY`: start one, wait for
`/health`, then the others.

## Several nodes

One node is enough for a workspace of any size this release was tested with. With more
than one, set `DNS_CLUSTER_QUERY` so the nodes find each other and a page on one node
hears of a run received on another. The lost-run check and the retention job are safe on
several nodes: each change is one statement or under a lock, and one node does the work.
