# The runner file's `server` section

The runner file says what `qory run` does on one machine. It is `runner.yaml` in the
command's configuration directory: `~/.config/qory/runner.yaml`, or
`$XDG_CONFIG_HOME/qory/runner.yaml` when that variable is set. It lives there and nowhere
else, so a repository cannot set the policy a run is under or where its events go.

Its `server` section names the Qory Apiary every run on the machine reports to. The section
is read by the `qory` command from version 0.10.0. An earlier command reads the file
strictly and refuses a file that has the section, so install 0.10.0 or later before adding
it; `qory version` prints the version.

## The section

```yaml
server:
  url: https://qory.example
  access_key: ak_0123456789abcdef
  secret: <the secret the console showed once>
```

The console writes this block for you, with the values filled in, when an access key is
created or rotated under **Access keys**, `/hive/keys`. The block begins with an
`apiVersion` line; a runner file has one such line, so when the file exists already, add
the `server` section alone. The file is read strictly: a key it does not know, or a key
written twice, is refused with a message that names the file.

| Key | Holds |
|---|---|
| `url` | The server's scheme and host, with a port when it has one, and nothing after: no path, no query. It is the server's `PUBLIC_URL`. `https`, or `http` to an address of this machine, `localhost` or a loopback address; `http` to any other host is refused. The runner finds every endpoint through the configuration document under this URL. |
| `access_key` | The key id the console shows: `ak_` and 16 characters. It names the machine's key to the server and travels in clear with every request. |
| `secret` | The secret of that key, at least 16 characters. It signs every request and never travels. |

### The secret in the environment

`secret` may be left out of the file. The command then takes it from the environment
variable `QORY_SERVER_SECRET`, in the environment `qory run` starts in. The file's value
wins when both are there, and with neither the file is refused:

```text
server.secret is missing; set it there or in QORY_SERVER_SECRET
```

The secret stays the runner's. `QORY_SERVER_SECRET` is taken out of the session's
environment, and naming it in `wall.env` or with `--env` is refused. `qory config` lists
`runner.server.url` and `runner.server.access_key`, and never the secret.

When the secret is in the file, make the file readable by its owner alone:

```sh
chmod 600 ~/.config/qory/runner.yaml
```

### Rotating

**Rotate** on the key's row issues a new secret and shows it once, with the block to paste.
The previous secret keeps working until **Retire previous secret**, so machines move over
one at a time without a gap. **Revoke** stops the key verifying at once: machines still
using it fail their next request and start no new runs.

## What the runner does with it

With a `server` section, every `qory run` on the machine:

1. fetches the server's configuration document, a signed `GET` of
   `/.well-known/qory-configuration` under `url`;
2. sends a ping, a batch of one event, to the events URL the document names, which on this
   server is `/v1/events`;
3. when the document names a `run` section, fetches the run configuration for the checkout,
   a signed `GET` of `/v1/run-configuration` with the run's labels as the query. That
   document is the run's security policy;
4. starts the runtime, and posts the run's events in signed batches while it runs.

The run fails closed. A configuration fetch that fails or is refused, a ping the server
does not accept, or a named run configuration that does not answer `200`: no run, and the
error names the URL and the status. A redirect is not followed.

Once the run is under way the server never delays the session. Events are posted behind a
queue, what is undelivered when the run ends is kept under `.qory/runs/<id>/undelivered/`
in the checkout, and `qory run resend <run-id>` sends a finished run's record to the server
again. The record itself, `.qory/runs/<id>/events.jsonl` and `output.log`, is written
whatever the server does.

[The server contract](contract.md) says how requests are signed and what the server answers.

## There is no `webhook` section any more

The `server` section replaced the `webhook` section in version 0.10.0 of the command. A
runner file that still has a `webhook` section is refused with a message that says so, and
`QORY_WEBHOOK_SECRET` is not read any more. A receiver of your own that is not a Qory Apiary
is configured with the same `server` section, and implements the same contract: the
configuration document and the events endpoint are enough.

## The `egress` section and the workplace's policy

The runner file's `egress` section is the machine's own policy: a mode, `observe` or
`enforce`, the hosts allowed and the hosts denied. A host in `deny` is denied in either
mode, before `allow` is consulted; under `observe` it is the only thing denied.

```yaml
egress:
  mode: enforce
  allow: [api.example, "*.internal.example"]
  deny: [tracker.internal.example]
```

It applies:

- on a machine with no `server` section;
- with `qory run --local`, which records to files only and does not contact the server;
- while the workplace the access key belongs to has no policy yet. The server then names
  no run configuration, and the machine's own policy stands, enforcement included.

From the first change of the workplace's policy in the console, the server's run
configuration is the policy of every run under the workplace's keys, and the file's
`egress` section is not merged with it. [The security policy](security-policy.md) says
what to do before that first change.

With a server configured, `qory run --policy <file>` is refused unless `--local` is given
too: the server's run configuration is the policy.

Two sections of the runner file still matter under a workplace's policy. `credentials`
defines what the machine has; the workplace's policy selects credentials by name and
defines none, and a name the machine does not define is no run. `wall` starts the runtime
in a container; a policy with paths or credentials needs one.

## The `forge` and `repository` labels

The server keeps a policy per repository. The runner asks for the run configuration with
the run's labels, and the server reads the repository from two of them, `forge` and
`repository`. Both come from the checkout's origin remote:

- `forge` is the remote's host;
- `repository` is its path without the leading slash and without `.git`.

So the origin `git@git.example:acme/shop.git` gives `forge` `git.example` and `repository`
`acme/shop`. Nothing else is read from the remote. A checkout with no origin remote, or one
whose remote is on this machine, carries neither label: its runs are listed under
**Unassigned** on the runs page and are served the workplace baseline.

To override, name them, and the caller's labels win over the remote's:

```sh
qory run --label forge=git.example --label repository=acme/shop
```

The labels go into the run's first event with every other `--label`, and the console
groups runs and keeps repository rules by these two. The server compares them to the
stored labels byte for byte, so one repository reached through two remotes that spell it
differently is two repositories unless the labels are named.

Runner 0.5.0 and later sends every label of the run on the run configuration request; an earlier one sends `forge` and `repository` alone.
The server reads the repository from these two either way. Any other label names no
repository.
