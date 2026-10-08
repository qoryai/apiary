# The runner file's `server` section

The runner file says what `qory run` does on one machine. It is `runner.yaml` in the
command's configuration directory: `~/.config/qory/runner.yaml`, or
`$XDG_CONFIG_HOME/qory/runner.yaml` when that variable is set. It lives there and nowhere
else, so a repository cannot set the policy a run is under or where its events go.

Its `server` section names the Qory Apiary every run on the machine reports to, and the
access key the machine signs with. The section needs a `qory` command that has
`qory access-key`, the command that makes the machine's key.

## The section

```yaml
server:
  url: https://apiary.example
  access_key_id: ak_0123456789abcdef
  apiary_public_key:
    - {alg: ed25519, public_key: mptNqtgGKgLhLZxmOGfpBQkdeBNH7QN3Qs9ETNumy8Q}
```

You rarely write it by hand. `qory access-key enrol <server> <code>` writes it when a
machine enrols with a code, and an active key's **Runner file lines** opens the page
**Runner file for build-01**, which shows these lines with the values filled in
([Nodes and their keys](nodes.md)). When the file exists already, add the `server`
section to it. The file is read strictly: a key it does not know, or a key written twice,
is refused with a message that names the file.

| Key | Holds |
|---|---|
| `url` | The server's scheme and host, with a port when it has one, and nothing after: no path, no query. It is the server's `PUBLIC_URL`. `https`, or `http` to an address of this machine, `localhost` or a loopback address; `http` to any other host is refused. The runner finds every endpoint through the configuration document under this URL. |
| `access_key_id` | The id the server gave the machine's access key: `ak_` and 16 characters. It names the key to the server and travels in clear with every request. |
| `apiary_public_key` | The pin: the server's public keys, a list of `alg` and `public_key`. Every answer of the server is signed, and the runner verifies it under these keys before it reads it. A runner with a server and no pin does not start, `apiary_public_key_missing`. |

Nothing in the section is secret. The access key's secret is never in `runner.yaml`:
`qory access-key` keeps it in the file `access-key-secret` beside it,
`~/.config/qory/access-key-secret`, readable by its owner alone. The server holds only the
key's public half, so nothing the server stores, shows or logs can sign for the machine.

### The id and the pin in the environment

`access_key_id` and `apiary_public_key` may be left out of the file. The command then
takes them from `QORY_ACCESS_KEY_ID` and `QORY_APIARY_PUBLIC_KEY`, in the environment
`qory run` starts in; a value set in both places is refused. `QORY_APIARY_PUBLIC_KEY` is
the same list written as JSON, on one line:

```text
QORY_ACCESS_KEY_ID=ak_0123456789abcdef
QORY_APIARY_PUBLIC_KEY=[{"alg":"ed25519","public_key":"mptNqtgGKgLhLZxmOGfpBQkdeBNH7QN3Qs9ETNumy8Q"}]
```

Those are the lines **Runner file for build-01** shows under "For CI", for a CI's
variables or an env file, where a value is taken as written. In a shell the JSON has
brackets and double quotes the shell would read, so put the value in single quotes:

```sh
export QORY_ACCESS_KEY_ID=ak_0123456789abcdef
export QORY_APIARY_PUBLIC_KEY='[{"alg":"ed25519","public_key":"mptNqtgGKgLhLZxmOGfpBQkdeBNH7QN3Qs9ETNumy8Q"}]'
```

The secret is then `QORY_ACCESS_KEY_SECRET`, the one of the three that belongs in a CI's
secret store; `qory access-key enrol --print` prints it instead of keeping it on the
machine, and **Generate a key** on the node's **Access key** tab shows it once, with the
other two, on the page **Variables for …**. With the three variables set, the CI's
`runner.yaml` needs `server.url` alone.

The three stay the runner's. `qory` reads them when it starts and takes them out of its
environment before it starts anything, so no session inherits them, and naming one in
`wall.env` or with `--env` is refused. `qory config` lists `runner.server.url`,
`runner.server.access_key_id` and the pin by its fingerprint, and never the secret.

### A new key, and revoking one

A key is never rotated. To change a machine's key, enrol or generate a new one on the same
node, and once the machine uses it, **Revoke…** the old one on the node's **Access key**
tab. A node holds two keys at a time for this. A revoked key stops verifying at once: a
machine still using it fails its next request, `401`, and starts no new run.

## What the runner does with it

With a `server` section, every `qory run` on the machine:

1. fetches the server's configuration document, a signed `GET` of
   `/.well-known/qory-configuration` under `url`;
2. sends a ping, a batch of one event, to the events URL the document names, which on this
   server is `/v1/events`;
   <!-- feature: security -->
3. when the document names a `run` section, fetches the run configuration for the checkout,
   a signed `GET` of `/v1/run-configuration` with the run's labels as the query. That
   document is the run's security policy;
   <!-- /feature -->
4. starts the runtime, and posts the run's events in signed batches while it runs.

Each request names the machine's instance, its id kept in the file `instance-id` beside
`runner.yaml`, and is signed with the access key. Each answer is signed with the server's
key, and the runner verifies it under the pin before it reads anything of it.

The run fails closed. A configuration fetch that fails or is refused, an answer that does
not verify under the pin, or a ping the server does not accept: no run, and the error
names the URL and the status. An instance beyond its node pool's instance limit is refused
`instance_limit`.
<!-- feature: security -->
A named run configuration that does not answer `200` is no run either.
<!-- /feature -->
A redirect is not followed.

Once the run is under way the server never delays the session. Events are posted behind a
queue. At the end of a run qory prints where the run's record is, once, after the line
that says how the run ended, which names no path:
`qory run: the record is in <folder>/<id>`. That is
`~/.local/state/qory/runs/<checkout folder name>-<hash>/<id>/` on Linux and macOS alike,
or the same under `$XDG_STATE_HOME/qory` when `XDG_STATE_HOME` is set to an absolute path,
and not in the checkout. `<hash>` is the first 12 hex digits of the SHA-256 of the
checkout's full path, links resolved. qory's state directory, its `runs` directory and the
checkout's folder are mode 0700. The record itself, `events.jsonl` and `output.log`, is
written there whatever the server does. What is undelivered when the run ends is kept
beside it under `undelivered/`, and `qory run resend <run-id>` sends a finished run's
record to the server again.

[The server contract](contract.md) says how requests are signed and what the server answers.

## There is no `webhook` section any more

The `server` section replaced the `webhook` section in version 0.10.0 of the command. A
runner file that still has a `webhook` section is refused with a message that says so, and
`QORY_WEBHOOK_SECRET` is not read any more. A receiver of your own that is not a Qory Apiary
is configured with the same `server` section, and implements the same contract: the
configuration document and the events endpoint are enough.

<!-- feature: security -->
## The `egress` section and the workspace's policy

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
- while the workspace of the access key's node has no policy yet. The server then names
  no run configuration, and the machine's own policy stands, enforcement included.

From the first change of the workspace's policy in the console, the server's run
configuration is the policy of every run under the keys of the workspace's nodes, and the
file's `egress` section is not merged with it. [The security policy](security-policy.md)
says what to do before that first change.

With a server configured, `qory run --policy <file>` is refused unless `--local` is given
too: the server's run configuration is the policy.

One section of the runner file still matters under a workspace's policy: `wall` starts the
runtime in a container, and a policy with paths needs one. The workspace's policy selects
none of the machine's `credentials`, so a run under it uses none.
<!-- /feature -->

## The `forge` and `repository` labels

The server reads a run's repository from two of its labels, `forge` and `repository`.
<!-- feature: security -->
It keeps a policy per repository, and the runner asks for the run configuration with the
run's labels.
<!-- /feature -->
Both come from the checkout's origin remote:

- `forge` is the remote's host;
- `repository` is its path without the leading slash and without `.git`.

So the origin `git@git.example:acme/shop.git` gives `forge` `git.example` and `repository`
`acme/shop`. Nothing else is read from the remote. A checkout with no origin remote, or one
whose remote is on this machine, carries neither label: its runs are listed under
**Unassigned** on the runs page.
<!-- feature: security -->
They are served the workspace baseline.
<!-- /feature -->

To override, name them, and the caller's labels win over the remote's:

```sh
qory run --label forge=git.example --label repository=acme/shop
```

The labels go into the run's first event with every other `--label`, and the console
files runs under the repository these two name.
<!-- feature: security -->
It keeps repository rules by them too.
<!-- /feature -->
The server compares them to the stored labels byte for byte, so one repository reached
through two remotes that spell it differently is two repositories unless the labels are
named.

<!-- feature: security -->
The runner sends every label of the run on the run configuration request. The server
reads the repository from `forge` and `repository`; any other label names no repository.
<!-- /feature -->
