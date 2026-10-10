# Live reload, end to end

One job that shows two things the console promises. A session behind a wall is refused a
host, a person allows the host from the connection's row, and the same session reaches it
without being restarted, within thirty-five seconds. A member of the workspace asks for
observe, which is an owner's or an admin's, and is refused: the session is still let
through to the host on its next connections, and the run's record shows no policy applied
event after the refusal. Then the workspace goes to observe, the person denies the host
from the same row, and the same session is refused it by name, under observe, within the
same budget: a deny holds in either mode.

Each instance is set up as a person sets one up, with the set-up link its start logged,
read from its log. The live reload runs on an instance without mail, as a new install has
none. Then, on Linux, a second instance sends its mail over SMTP to a sink, and the job
checks the mailed way in: the owner's log-in link and a member's invitation, each read from
the sink.

    e2e/run.sh        # one run
    e2e/run.sh 3      # three, each on a fresh database and a fresh node

It leaves with status 0 only when every assertion held, and prints the timings:

    allow -> second policy applied, seen stored here     6.11 s
    allow -> allowed connection, seen stored here        6.11 s   (budget 35 s)
    deny  -> third policy applied, seen stored here      4.97 s
    deny  -> denied connection, seen stored here         4.98 s   (budget 35 s)
    E2E PASS  allow_to_applied_ms=6108 allow_to_allowed_ms=6109 deny_to_applied_ms=4975 deny_to_denied_ms=4976
    E2E PASS  mail=sink set_up=logged_link log_in_link=mailed invitation=mailed

## What runs where

| Piece | What it is |
|---|---|
| The test instance | This application with production's settings (`MIX_ENV=prod`, migrations on boot, JSON logs), on a database of its own, `apiary_e2e`, and a port of its own, 4180. `run.sh` starts it with `mix run e2e/scenario.exs`, so the scenario runs in the virtual machine that answers the gateway, and writes its output, the instance's log, to `run-<n>.log`, where the scenario reads the set-up link. It has no mail: `run.sh` unsets `SMTP_RELAY` and the variables beside it. The database is dropped before and after; a `DATABASE_URL` that does not end in `_e2e` is refused. |
| The mailed instance | The same, on Linux, after the first, on the database made anew, with `E2E_MAIL=sink`, `SMTP_RELAY` the sink's address on the job's network, `SMTP_PORT=1025` and `SMTP_TLS=never`; its log is `run-<n>-mail.log`. No node and no session: it checks the mailed way in alone. |
| The node | `compose.yaml`'s `node`: a Linux machine with a container engine of its own (Docker in Docker). `qory run` runs here, built from the pinned source for Linux, and builds its wall with the node's engine: an internal network, the agent's container on it and on nothing else, the relay's container beside it. The node has its own `XDG_CONFIG_HOME`, a copy of what the job writes for it; nobody's `~/.config/qory` is read or written. qory keeps the run's record on the node, in its state directory, root's `~/.local/state/qory/runs/checkout-<hash>/<id>/`, outside the checkout, and names that folder in the session's output when the run ends; what the job checks is the record the test instance stored. |
| The session | `checkout/bin/fake-runtime`, started by `qory run` as the runtime, in the wall's container (`curlimages/curl`). Not a model: a loop that asks for one page of the upstream every few seconds, and keeps asking after it got through, so the deny can refuse it. It first tries to go around the proxy and leaves with 3 if that works, so a pass also says there was a wall. |
| The upstream | `compose.yaml`'s `upstream`: nginx with a certificate made for the run, on the node's network under the name `files.e2e.test`. No site outside the job is asked for anything. |
| The sink | `compose.yaml`'s `sink`: Mailpit, `ghcr.io/axllent/mailpit`, pinned by version and pulled from `ghcr.io`, not Docker Hub. It takes every message on port 1025 and sends none on; the scenario reads what it holds from its API on port 8025, asked inside its container (`docker compose exec sink wget …`). It publishes no port: the mailed instance reaches it at its address on the job's network, which a Linux host routes to. A Mac's engine does not, so on a Mac `run.sh` leaves the mailed instance out and says so. |

The server contract lets the gateway speak plain http to a loopback address only. So the node
reaches the test instance as `http://127.0.0.1:4180`, which is also the instance's
`PUBLIC_URL`: a forwarder in the node (`socat`) carries that port to the host, as a tunnel
would. Everything after that is the contract as it is: every request signed with the
node's Ed25519 access key and every answer signed with the instance's own key
(`APIARY_SIGNING_SECRET`, a fresh random value for each job), which the node pins;
discovery, the ping, the run configuration for the checkout's forge and repository,
batches, the digests in the answers.

## The scenario

`scenario.exs`, in order:

1. Sets the instance up with an owner, as a person does: it waits for the line "Set up
   Qory Apiary at http://127.0.0.1:4180/setup/<code>." in the instance's log, the
   `message` of a JSON line, checks that the instance's start also said that no mail is
   set, opens the link, whose page offers the set-up form, sets the instance up with the
   link's code as the form's submit does (`Apiary.Setup.set_up/3`, with an email address,
   a fresh password and the organisation's name), and opens the link again, which now
   says the instance is set up. That is the instance's first sign-up, on its fresh
   database, which makes the instance's own organisation. The owner then signs in with the
   password, as the log-in form's post does
   (`Apiary.Accounts.get_user_by_email_and_password/2`). It sets the workspace to
   `enforce` with nothing allowed (`Apiary.Policy.set_mode/2`, which is also what makes
   the workspace a managed one that serves a run configuration), and makes a node,
   `build-01` (`Apiary.Nodes.create_node/2`). It generates a fresh Ed25519 key and adds
   its public key to the node the way the node's Generate a key adds one made in a
   browser (`Apiary.AccessKeys.add_access_key/3`), active as it is added, without stored
   secrets. The key's `server` lines, the server's `url` and `apiary_public_key` pin
   (`Apiary.AccessKeys.server_lines/2`) and the key's `access_key_id`
   (`Apiary.AccessKeys.key_line/1`), under `gateway:`, and the wall section become the
   node's `forager.yaml`. The key's secret, `qak_` and its seed, goes into `access-key-secret`
   beside it, mode 0600, in a directory of mode 0700; nothing prints it. `node/prepare.sh` copies the three files into a
   directory of the node's own, root's, mode 0700, each file mode 0600, since qory
   reads the secret only from a file its user owns, and keeps its instance id and locks
   beside it.
2. Makes the node ready (`node/prepare.sh`: the checkout with an origin remote, which is
   where the run's `forge` and `repository` come from, and its harness composed) and starts
   the session (`node/session.sh`: `qory run --headless`).
3. Waits for a connection row of the workspace for `files.e2e.test` with a denial, and
   checks that the run has one policy applied event, in `enforce`, under the digest in
   force.
4. Allows the host with the two calls the row's popover makes
   (`ApiaryWeb.RunLive.Show`, `ApiaryWeb.ConnectionLive.Index`):
   `Apiary.Runs.fetch_connection/2`, then `Apiary.Policy.rule_from_connection/4` with
   `:allow` and the level, `:target` unless `E2E_LEVEL=workspace`. The clock starts before
   the first of them.
5. Polls the run's stored events, every 50 ms, for a second `dev.qory.run.policy_applied`
   whose `run_configuration` is the new digest, then for an `dev.qory.run.egress` to the
   host after it in sequence with `decision: allowed` and `outcome: connected`.
6. Makes a member of the workspace the way a person joins without mail
   (`Apiary.Organisations.invite_member/3` from the owner's workspace, which hands back
   the invitation's link to copy, then `Apiary.Organisations.sign_up_user/2` with its
   token and a password of the member's own), and has them ask
   for observe (`Apiary.Policy.set_mode/2`), which is an owner's or an admin's: a member
   changes the rules, not the mode. Then it notes the run's last sequence and waits for
   the second allowed, connected egress event to the host after it, and for twice this
   run's own allow to second policy applied time from the refusal, whichever is later. The
   first allowed connection after the refusal may have been on its way before it, and the
   second can come sooner than a change takes to come back as a policy applied event: the
   session tries every three seconds by default, and one propagation took about six.
7. Puts the workspace in observe as the owner, denies the host from the same row, and
   polls for a third policy applied event with the deny's digest and a denied egress
   event to the host after it.
8. Waits for the session to leave and for the exit to be projected.

The mailed instance, `E2E_MAIL=sink`, then:

1. Checks that its mail is the environment's and that its start did not say no mail is
   set, and sets it up with its logged link, as above.
2. Sends the owner a log-in link (`Apiary.Accounts.deliver_login_instructions/2`), waits
   for the message to the owner's address in the sink, and logs in with the link in it
   (`Apiary.Accounts.login_user_by_magic_link/1`), which confirms the owner's address and
   removes the password set at the set-up, as a first link log-in does.
3. Invites a member by email (`Apiary.Organisations.invite_member/3`, which answers
   `{:ok, invitation}` when it mailed it), waits for the message to the member's address
   in the sink, and signs the member up with the link in it; the member is in the owner's
   workspace.

## What it asserts

- each instance was set up with the link its start logged, whose page offered the form
  and then said the instance is set up; the instance without mail said so at its start,
  and the mailed one did not;
- without mail, the owner signs in with the password given at the set-up, and the
  invitation is a link to copy; with the sink, the log-in link and the invitation arrive
  there, the log-in link confirms the owner and removes the password, and the member joins
  with the mailed link;
- a second policy applied event in the run's record, naming the new digest and allowing
  the host;
- an allowed, connected egress event to the host, later in sequence;
- the time from the allow to that event being stored here, under `E2E_BUDGET_SECONDS` (35);
- the member's observe refused as forbidden (`{:error, %Apiary.Policy.Error{reason:
  :forbidden}}`), with no policy applied event in the run's record after the last sequence
  noted at the refusal, over that wait, which also shows the session let through to the
  host on its next two connections; the version and digest in force and the workspace's
  mode as they were, and no audit entry by the member since they joined;
- the run was behind the docker wall (`wall` of `dev.qory.run.started`), and the session
  found no way around the proxy;
- no connection to the host was denied after the reload;
- the session left with 0, and the run ends on the digest in force with no drift
  (`Apiary.Policy.digests/2`).

## What the number is, and is not

The time is measured on one clock, the test instance's, from before the allow is written
to the moment a poll finds the event stored. It therefore includes the gateway's batching
(a batch is cut a second after its first event), the post, and up to 50 ms of polling: it
is an upper bound on when the connection was let through. The same intervals by the
node's clock are printed beside it for comparison; the two machines' clocks may differ.

The gateway learns of a change from the answer to any batch it posts, and while a session
is being refused the gateway posts a batch with every refusal. So with the default retry of
three seconds the reload is carried by the next refusal's own batch, not by a heartbeat:
about six seconds to the second policy applied event, and the allowed connection with it,
since the gateway numbers a reload's connections after its policy applied event.

A quiet session learns of it at its next heartbeat, thirty seconds at most, and reaches
the host at its next try after that. The job can show that shape, and then it fails on the
budget, rightly: with `E2E_RETRY_SECONDS=40` the reload came with the heartbeat, 27.6 s
after the allow, and the allowed connection at the session's next try, 40.0 s after it;
with `E2E_RETRY_SECONDS=20` the reload came with the second refusal at 21.2 s and the
connection at 40.2 s. What the gateway bounds is the reload, by the heartbeat's interval.
When the host is reached is the session's: the budget holds for one that tries again
within a few seconds, and nothing can make a session try.

One job at a time on a machine: two would share the database and the compose project.

## What it needs

Docker with compose, `openssl`, the toolchain of `mise.toml`, Go for building qory (its
own `mise.toml` names the version), a Postgres that lets `postgres` create and drop
`apiary_e2e`, and the source of `qoryai/qory`. Variables, all optional, are listed at the
top of `run.sh`; the ones that matter:

| Variable | |
|---|---|
| `QORY_SRC` | the qory checkout to build, `../../qory/main` by default |
| `FORAGER_SRC` | a Forager checkout to build it against, for when the module version qory's `go.mod` names cannot be fetched; the module file is copied and the copy edited, the checkout is not touched |
| `E2E_QORY` | a static Linux build of qory to use instead of building one |
| `E2E_DATABASE_URL` | default `ecto://postgres:postgres@localhost:5432/apiary_e2e` |
| `E2E_WORK` | where the job writes, `tmp/e2e` by default (ignored by git) |

In CI it is the workflow `.github/workflows/e2e.yml`, on a Linux runner, with qory at the
commit in `.qory-e2e-ref` and Forager at the one in `.forager-e2e-ref`.

## Not covered

- The click itself. The scenario makes the domain calls the row's popover makes; it does
  not drive the LiveView over a socket. So too the set-up form's submit, the log-in, the
  invitation and the sign-up: the set-up page is opened over HTTP, and its form is not
  posted.
- The mailed way in on a Mac, whose engine does not route the host to the sink.
- A real runtime. The events of a session inside a runtime (hooks, tool calls) play no part
  in a reload and are not produced here.
- A tunnel that is open when a host is denied (the contract's second reload rule), and TLS
  termination (the third). The session opens a fresh connection for every try, so the deny
  refuses a new tunnel, never closes an open one.
