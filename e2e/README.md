# Live reload, end to end

One job that shows the thing the console promises: a session behind a wall is refused a
host, a person allows the host from the connection's row, and the same session reaches it
without being restarted, within thirty-five seconds.

    e2e/run.sh        # one run
    e2e/run.sh 3      # three, each on a fresh database and a fresh node

It leaves with status 0 only when every assertion held, and prints the timings:

    allow -> second policy applied, seen stored here     4.17 s
    allow -> allowed connection, seen stored here        6.17 s   (budget 35 s)
    E2E PASS  allow_to_applied_ms=4173 allow_to_allowed_ms=6167

## What runs where

| Piece | What it is |
|---|---|
| The test instance | This application with production's settings (`MIX_ENV=prod`, migrations on boot, JSON logs), on a database of its own, `apiary_e2e`, and a port of its own, 4180. `run.sh` starts it with `mix run e2e/scenario.exs`, so the scenario runs in the virtual machine that answers the runner. The database is dropped before and after; a `DATABASE_URL` that does not end in `_e2e` is refused. |
| The node | `compose.yaml`'s `node`: a Linux machine with a container engine of its own (Docker in Docker). `qory run` runs here, built from the pinned source for Linux, and builds its wall with the node's engine: an internal network, the agent's container on it and on nothing else, the relay's container beside it. The node has its own `XDG_CONFIG_HOME`; nobody's `~/.config/qory` is read or written. |
| The session | `checkout/bin/fake-runtime`, started by `qory run` as the runtime, in the wall's container (`curlimages/curl`). Not a model: a loop that asks for one page of the target every few seconds. It first tries to go around the proxy and leaves with 3 if that works, so a pass also says there was a wall. |
| The target | `compose.yaml`'s `target`: nginx with a certificate made for the run, on the node's network under the name `files.e2e.test`. No site outside the job is asked for anything. |

The server contract lets a runner speak plain http to a loopback address only. So the node
reaches the test instance as `http://127.0.0.1:4180`, which is also the instance's
`PUBLIC_URL`: a forwarder in the node (`socat`) carries that port to the host, as a tunnel
would. Everything after that is the contract as it is: signed discovery, the ping, the run
configuration for the checkout's forge and repository, signed batches, the digests in the
answers.

## The scenario

`scenario.exs`, in order:

1. Signs an owner up (`Apiary.Organisations.sign_up_user/2`), sets the hive to `enforce`
   with nothing allowed (`Apiary.Policy.set_mode/2`, which is also what makes the hive a
   managed one that serves a run configuration), and creates an access key. The key's
   `server` block and the wall section become the node's `runner.yaml`, mode 0600. The
   secret goes there and nowhere else; nothing prints it.
2. Makes the node ready (`node/prepare.sh`: the checkout with an origin remote, which is
   where the run's `forge` and `repository` come from, and its harness composed) and starts
   the session (`node/session.sh`: `qory run --headless`).
3. Waits for a connection row of the hive for `files.e2e.test` with a denial, and checks
   that the run has one policy applied event, in `enforce`, under the digest in force.
4. Allows the host with the two calls the row's popover makes
   (`ApiaryWeb.RunLive.Show`, `ApiaryWeb.ConnectionLive.Index`):
   `Apiary.Runs.fetch_connection/2`, then `Apiary.Policy.rule_from_connection/4` with
   `:allow` and the level, `:repository` unless `E2E_LEVEL=hive`. The clock starts before
   the first of them.
5. Polls the run's stored events, every 50 ms, for a second `ai.qory.run.policy_applied`
   whose `run_configuration` is the new digest, then for an `ai.qory.run.egress` to the
   host after it in sequence with `decision: allowed` and `outcome: connected`.
6. Waits for the session to leave and for the exit to be projected.

## What it asserts

- a second policy applied event in the run's record, naming the new digest and allowing
  the host;
- an allowed, connected egress event to the host, later in sequence;
- the time from the allow to that event being stored here, under `E2E_BUDGET_SECONDS` (35);
- the run was behind the docker wall (`wall` of `ai.qory.run.started`), and the session
  found no way around the proxy;
- no connection to the host was denied after the reload;
- the session left with 0, and the run ends on the digest in force with no drift
  (`Apiary.Policy.digests/2`).

## What the number is, and is not

The time is measured on one clock, the test instance's, from before the allow is written
to the moment a poll finds the event stored. It therefore includes the runner's batching
(a batch is cut a second after its first event), the post, and up to 50 ms of polling: it
is an upper bound on when the connection was let through. The same intervals by the
node's clock are printed beside it for comparison; the two machines' clocks may differ.

A runner learns of a change from the answer to any batch it posts, and a session that is
being refused posts a batch with every refusal. So with the default retry of three seconds
the reload is carried by the next refusal's own batch, not by a heartbeat: about four
seconds to the second policy applied event, about six to the allowed connection.

A quiet session learns of it at its next heartbeat, thirty seconds at most, and reaches
the host at its next try after that. The job can show that shape, and then it fails on the
budget, rightly: with `E2E_RETRY_SECONDS=40` the reload came with the heartbeat, 27.6 s
after the allow, and the allowed connection at the session's next try, 40.0 s after it;
with `E2E_RETRY_SECONDS=20` the reload came with the second refusal at 21.2 s and the
connection at 40.2 s. What the runner bounds is the reload, by the heartbeat's interval.
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
| `RUNNER_SRC` | a runner checkout to build it against, for when the module version qory's `go.mod` names cannot be fetched; the module file is copied and the copy edited, the checkout is not touched |
| `E2E_QORY` | a static Linux build of qory to use instead of building one |
| `E2E_DATABASE_URL` | default `ecto://postgres:postgres@localhost:5432/apiary_e2e` |
| `E2E_WORK` | where the job writes, `tmp/e2e` by default (ignored by git) |

In CI it is the workflow `.github/workflows/e2e.yml`, on a Linux runner, with qory at the
commit in `.qory-e2e-ref` and the runner at the one in `.runner-contract-ref`.

## Not covered

- The click itself. The scenario makes the domain calls the row's popover makes; it does
  not drive the LiveView over a socket.
- A real runtime. The events of a session inside a runtime (hooks, tool calls) play no part
  in a reload and are not produced here.
- A tunnel that is open when a host is denied (the contract's second reload rule), and TLS
  termination (the third). The job allows; it does not deny.
