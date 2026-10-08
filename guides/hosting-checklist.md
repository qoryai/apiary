# Hosting checklist

Notes for whoever puts an instance in front of other people. The
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
- **The three keys, kept.** `SECRET_KEY_BASE`, `APIARY_ENCRYPTION_SECRET` and
  `APIARY_SIGNING_SECRET` are generated once, each on its own, and stored where the
  database backups are stored, not only in the `.env` of the machine.
  `APIARY_ENCRYPTION_SECRET` never changes once an access key or a stored secret exists,
  and losing it loses every stored secret value. Every machine pins the key of
  `APIARY_SIGNING_SECRET`, so changing or losing it means pinning every machine again.
  [Backup and restore](backup.md) says what each loss costs.
- **The features.** `QORY_FEATURES` says which features the instance has; not set, it has
  all of them. A feature that is off is absent for everybody on the instance, so decide
  before they arrive: [Install and configure](install.md#features).
- **Postgres that is backed up.** The database is the only state. Schedule the dump, and
  restore one into an empty database once, before it is needed.
- **Claim the instance.** The first person to sign up creates its organisation and becomes
  its admin. Before the address is public, run `Apiary.Release.grant_instance_admin/2` on
  the release with your address and your organisation's name: it is the instance's first
  sign-up, and emails you your log-in link.
  [Install and configure](install.md#the-instance-admins) has the command.
<!-- feature: security -->
- **Where integrations come from.** A workspace adds an integration from a release on
  `github.com`, `gitlab.com` or `codeberg.org`, or from an https address of its
  `description.json`, which may be on any host; Qory Apiary fetches it from public addresses
  only. On an instance open to people you do not know, set
  `INTEGRATION_URL_SOURCES=false` so that they are added from forges' releases alone; a
  release's download links, which its author chooses on GitLab and Codeberg, are still
  followed to any public https host: [Install and configure](install.md#integrations).
<!-- /feature -->
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
- **Sign-up.** Once the instance is claimed, nobody signs up without an invitation: people
  join by invitation from an owner or an admin on the organisation's **Members** page, as
  members. `INVITATIONS_PER_DAY` bounds how many invitations the organisation sends a day.
  [Install and configure](install.md#sign-up-and-invitations) has the details.
- **Stopping someone.** An owner suspends an admin or a member on the organisation's
  **Members** page, and an admin a member, and activates them again; nothing is removed.
  A suspended person acts in the organisation no more, but the access keys they added
  keep working, since they belong to their nodes: revoke those too if they should stop.
  [Install and configure](install.md#the-instance-admins) says more.
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
- **The security headers.** Every page carries a `Content-Security-Policy` that lets only
  the console's own scripts run. The proxy must pass it on as it is: not strip it, not
  replace it with one of its own, and not add a second.

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
