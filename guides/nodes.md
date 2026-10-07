# Nodes and their keys

A machine posts its runs to a workspace with an access key of its own, and every access key
belongs to a node of the workspace. This page says what a node is, the three ways a node
gets its key, and what to do when a key has to go. The owners and admins of the
organisation do all of it; everyone in the workspace reads the nodes and their keys.

## Nodes and node pools

**Nodes**, in the workspace's sidebar, lists them, with **New node** and **New node
pool**.

- A **node** is one permanent machine, `build-01` say. It runs one instance at a time.
- A **node pool** is a fleet of short-lived instances that share one key, such as the
  runners of a CI, `spot-runners` say. Its **Instance limit** is how many may run at
  once, up to 10,000; empty means no limit.

The kind is fixed when one is made. A new node opens on its **Access key** tab, where its
machine gets its key. Its **Overview** shows its instance, or a pool's running instances,
and its recent runs; its **Settings** change its name and a pool's limit, and delete it.

## The access key

A machine signs every request with its own key, an Ed25519 key. Made by `qory` on the
machine, its secret stays there, in `~/.config/qory/access-key-secret`; made in a browser,
it goes into a CI's secret store. Qory keeps only the public half, so nothing the server
holds can sign for the machine. Every answer of the
server is signed too, with the server's own key, which the machine pins as
`apiary_public_key` and checks every answer under.

A key is active from the moment it arrives until it is revoked. A node holds two keys at a
time, so that a machine can move to a new key before the old one is revoked. Each key's
**Stored secrets** is fixed when it is made. A key is never rotated: a new one is made, and
the old one revoked.

There are three ways to give a node its key, each a button on the node's **Access key**
tab, for owners and admins:

- **New enrolment code**: `qory` makes the key on the machine with
  `qory access-key enrol`, and its secret never leaves the machine.
- **Generate a key**: your browser makes the key, and shows you its secret once, for a
  CI's secret store.
- **Add a public key**: paste the public key that `qory access-key create` printed.

While the node holds no active key, the tab leads with the way that suits its kind. A node
leads with **Enrol this machine with qory**, and **New enrolment code** first; a pool with
**Generate a key for this pool**, and **Generate a key** first. Once it holds an active key,
the three buttons stay, in the same order. A member sees the keys, and none of the
buttons.

### Enrol with a code

1. On the node's **Access key** tab, select **New enrolment code**. Choose **Stored
   secrets** for the key it brings, and, if you like, a **Label hint**, the label the key
   starts from. Select **Make code**.
2. The page shows the code once, and the command to run on the machine, with this server
   and the code filled in:

   ```sh
   qory access-key enrol https://apiary.example qec_…
   ```

   The code works once, for 15 minutes. Only a hash of it is kept, so it cannot be shown
   again; **Revoke…** under **Enrolment codes** cancels one that is still outstanding.
3. On the machine, the command makes the key, keeps its secret and prints its fingerprint.
   The code carries the fingerprint of the server's key, so `qory` checks the server's
   signed answer against it and pins that key, and it writes the `server` section of
   `~/.config/qory/runner.yaml` itself: `url`, `access_key_id` and `apiary_public_key`.
4. The key arrives on the node's **Access key** tab, **Active**, under the code's label
   hint, else the machine's name (`-2`, `-3` and on when the node has a key of that label
   already); reload the tab if it is not there yet. The code is the approval: the key
   needs nothing more. Its **Fingerprint** is the one `qory` printed; if it is not,
   select **Revoke…**.

A code works only while the person who made it is still an owner or an admin of the
workspace: once they are not, the machine's enrolment is refused, and an owner or an admin
makes a new code.

### Paste the public key

1. On the machine, `qory access-key create` makes the key, keeps its secret, and prints
   the public key and its fingerprint. It does not write `runner.yaml`.
2. On the node's **Access key** tab, select **Add a public key**, give it a **Label**,
   paste the **Public key**, and check that the **Fingerprint** under it is the one the
   machine printed. Select **Add key**: the key is active as soon as you add it.
3. The page **Runner file for build-01** shows what the machine needs, none of it secret:
   the lines to put in `~/.config/qory/runner.yaml` (`url`, `access_key_id` and
   `apiary_public_key`), with **Copy lines**, and for a CI the same id and pin as two
   variables, with **Copy variables**. **Runner file lines**, on an active key's card,
   opens the page again whenever it is needed.

### For a CI

A CI keeps the key in its own settings rather than in a machine's files. A pool's
**Access key** tab leads with **Generate a key** for this. Both commands take `--print`
too: they keep nothing on the machine and print the settings, one `NAME=value` line each.

- `qory access-key enrol --print <server> <code>` prints `QORY_ACCESS_KEY_ID`,
  `QORY_ACCESS_KEY_SECRET` and `QORY_APIARY_PUBLIC_KEY`. The key is active at once.
- `qory access-key create --print` prints `QORY_ACCESS_KEY_SECRET`, and the public key
  for pasting. After **Add key**, the id and the pin come from **Runner file for …**,
  under "For CI".

Only `QORY_ACCESS_KEY_SECRET` belongs in the CI's secret store; the id and the pin are
plain settings, and the CI's `runner.yaml` then needs `server.url` alone.
`QORY_APIARY_PUBLIC_KEY` is JSON: in a shell, put its value in single quotes
([The runner file's `server` section](runner-file.md#the-id-and-the-pin-in-the-environment)).
A fleet of short-lived CI runners is a node pool with one key.

#### Generate a key in the browser

1. On the node's **Access key** tab, select **Generate a key**. Give the key a **Label**,
   `spot-runners` say, choose **Stored secrets**, and select **Generate key**.
2. Your browser makes the Ed25519 key and sends Qory only its label, its **Stored
   secrets** and its public half. The key is active as soon as it arrives.
3. The page **Variables for spot-runners** shows the three variables, each with a copy
   button: `QORY_ACCESS_KEY_ID`, `QORY_ACCESS_KEY_SECRET`, which is `qak_` and the key's
   secret, and `QORY_APIARY_PUBLIC_KEY`. The secret is shown once: it was made in your
   browser, Qory never received it, and it can't be shown again. Copy it into the CI's
   secret store before you select **Done**.

Opened again, the page still shows the id and the pin, and says the secret is not shown:
only the page that made the key held it. If you didn't copy it, revoke the key and
generate another. The key's card says **Made in a browser by** you, and when.

The browser makes keys only on a page served over HTTPS (a browser counts
`http://localhost` as one too) and only if it can make an Ed25519 key: a current Chrome,
Edge, Firefox or Safari. Where it can't, the page says why, and **Generate key** stays
off; enrol the machine with `qory` instead. For a machine of your own, enrolling it with
`qory` keeps the secret off every screen.

## Instances and the instance limit

Each running copy of `qory` with a node's key is an **instance** of that node. `qory` keeps
its id in the file `instance-id` beside `runner.yaml`, and its name is `instance.name` in
`runner.yaml`, else the host name. The instance is a claim, for display, the audit and the
instance limit: what a request is allowed rests on the key alone.

An instance counts as running while one of its runs is alive. A node runs one at a time,
and a pool up to its limit: the ping that starts a run, from an instance beyond the limit,
is refused, `instance_limit`, the run does not start, and the node's **Overview** counts
the starts refused. Lowering a limit stops nothing that runs; new instances wait
until fewer run.

An instance that stopped without saying so keeps its place until its runs are found lost.
**Clear instance…** on the node's **Overview** marks its open runs lost at once, so another
instance can start.

Every run records its node and its instance. A run's page names both, beside its access
key; the node's **Overview** lists its recent runs; and on **Runs**, `node:build-01` in the
filter, or **Node** in the Filter menu, keeps a node's runs alone.

## Revoking a key

**Revoke…** on an active key's card revokes it at once: the machine's next request is
refused, `401`, and it starts no new run. Its public key can never be used again. To move a
machine to a new key without a gap, give it the new key first, and revoke the old one once
the machine uses the new one.

Deleting a node revokes its keys and its outstanding codes. Suspending a member revokes
nothing: a key belongs to its node, not to the person who added it, so revoke the keys
that should stop too.

The workspace's overview lists, under **To review**, an active key nobody has used for
30 days, with **Revoke** leading to its card. A key nobody uses is a key to revoke.
