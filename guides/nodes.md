# Nodes and their keys

A machine posts its runs to a workspace with an access key of its own, and every access key
belongs to a node of the workspace. This page says what a node is, the two ways a node
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
it goes into a CI's secret store. Qory Apiary keeps only the public half, so nothing Qory
Apiary holds can sign for the machine. Every answer of Qory Apiary is signed too, with
Qory Apiary's own key, which the machine pins as `apiary_public_key` and checks every
answer under. Qory Apiary's key and its address are the instance's own, the same for every
organisation, workspace and node: the address is its `PUBLIC_URL`, and the key is made
from its `APIARY_SIGNING_SECRET`. Only a key's ID and its secret belong to the node's key.

A key is active from the moment it arrives until it is revoked. A node holds two keys at a
time, so that a machine can move to a new key before the old one is revoked.
<!-- feature: secrets -->
Each key's **Stored secrets** is fixed when it is made, and every new key, either way,
gets **Not allowed**.
<!-- /feature -->
A key is never rotated: a new one is made, and the old one revoked.

There are two ways to connect a node's machine, both on the node's **Access key** tab, for
owners and admins. While the node holds no active key, the tab asks "How do you want to
connect build-01?": "build-01 connects to Qory with a key. Choose one of two ways to give
it one." The two ways are two options side by side, each saying when to choose it, what
happens, and the same four facts, with one button:

- **Connect with a command**: "Choose it when you can open a terminal on build-01: a
  laptop, or a server of your own." You get one command to run on build-01. It carries a
  one-time code, not a key, which works once within 15 minutes. `qory` makes the key on
  build-01, sends Qory Apiary only its public half, and saves everything else there
  itself. Key made: on build-01, by `qory`. Secret: stays on build-01; it is never shown.
  By hand: nothing. Needs: a terminal on build-01. The button is **Get the command**.
- **Generate a key in the browser**: "Choose it when build-01 runs in a CI job, or on a
  machine you can't open a terminal on." This browser makes the key, and Qory Apiary
  receives only its public half. The next page shows the secret once, with everything
  else the machine needs, for you to set where build-01 runs. Key made: in this browser.
  Secret: shown to you once, for the machine's or the CI's secret store. By hand: the
  key's ID, its secret, Qory Apiary's public key and address. Needs: this page open over
  HTTPS. The button is **Generate a key**.

A node lists **Connect with a command** first, its button primary; a pool lists **Generate
a key in the browser** first. A member reads "build-01 has no key yet, so it can't start
runs. An owner or admin connects it."

Once the node holds a key, the tab lists it under **Keys**, one card per key, headed by
its label and **Active**: its **Key ID**, with **Copy**, which can always be seen again;
how it was added ("Connected with a command by …" or "Generated in a browser by …");
where its secret is; when it was last used ("Not yet" while unused); its **Fingerprint**;
<!-- feature: secrets -->
its **Stored secrets**;
<!-- /feature -->
with **Runner file** and **Revoke…**. Under the keys, **Add a
key** offers the same two ways, in the same order, to move the node to a new key: add it
either way, then revoke the old one. At two keys it offers neither, and says "build-01
holds two keys, the most a node can. Revoke the one it no longer uses to add another." A
member sees the keys and none of the buttons.

At the foot, **Configure a machine**, for everyone, at two keys too: "A machine connected
with the command needs nothing more: qory saved all of this on it. Don't set these again
there; qory refuses a key ID or a public key set twice. With a generated key, set these
where the machine runs qory." Then four numbered steps:

1. **Point qory at Qory Apiary.** In the runner file, with **Copy lines**. It is required:
   without it, `qory` ignores the three variables below.
2. **Set Qory Apiary's public key.** `QORY_APIARY_PUBLIC_KEY`, a plain setting, with
   **Copy**. The same for every machine connected to this Qory Apiary.
3. **Set the key's ID.** `QORY_ACCESS_KEY_ID`, a plain setting: with one active key, its
   ID, with **Copy**; with two, the ID of the key the machine uses, on its card above.
4. **Keep the key's secret in a secret store.** `QORY_ACCESS_KEY_SECRET`. It was shown
   once, when the key was generated, and is never shown here. If it is lost, generate a
   new key and revoke the old one.

### Connect with a command

1. On the node's **Access key** tab, select **Get the command**. There is nothing to fill
   in.
   <!-- feature: secrets -->
   The key the command brings gets **Stored secrets** **Not allowed**.
   <!-- /feature -->
2. The page **Connect build-01 with a command** shows the whole command to run on the
   machine, with Qory Apiary's address and a one-time code in it, and **Copy command**:

   ```sh
   qory access-key enrol https://apiary.example.com qec_…
   ```

   It works once, for 15 minutes, and the page gives the time it stops working. This is
   the only time it is shown: only a hash of the code is kept.
3. On the machine, the command makes the key, keeps its secret and prints its fingerprint.
   The code carries the fingerprint of Qory Apiary's key, so `qory` checks Qory Apiary's
   signed answer against it and pins that key, and it writes the `server` section of
   `~/.config/qory/runner.yaml` itself: `url`, `access_key_id` and `apiary_public_key`.
4. The page reads "Waiting for build-01 to run it." until the key arrives, then "build-01
   is connected. Its key arrived at 14:20 and is active.", with the key and its
   **Fingerprint**. The code is the approval: the key needs nothing more. Its fingerprint
   is the one `qory` printed on the machine; if it is not, revoke the key on the **Access
   key** tab. The key is named after the machine's host name (`-2`, `-3` and on when the
   node has a key of that name already).

A command not yet run shows on the tab, in the **Connect with a command** card's first step
or row: "A
command is waiting to be run on build-01.", who got it and when, and until when it works.
**Cancel the command…** cancels it, confirmed in place, and the button then reads **Get a
new command**. A lost command can't be shown again: cancel it and get a new one.

A command works only while the person who got it is still an owner or an admin of the
workspace: once they are not, a machine that runs it is refused, and an owner or an admin
gets a new command.

The command carries Qory Apiary's address, its `PUBLIC_URL`. When that is an address only
Qory Apiary's own computer reaches, such as `http://localhost:4100`, the page says
"Machines can't reach this address." and asks you to set `PUBLIC_URL` to the address
machines use.

### The runner file

**Runner file**, on an active key's card, opens the page **Runner file for build-01**:
"The runner file's lines for this key. Nothing here is secret." (for a generated key, the
description below). What it shows depends on how the key came:

- A key connected with a command: the `server` lines the command wrote to
  `~/.config/qory/runner.yaml`, each marked whose it is: `url` (`# Qory Apiary`),
  `access_key_id` (`# this key`) and `apiary_public_key` (`# Qory Apiary's public key`).
  Only the key ID is the key's; the address and the public key are Qory Apiary's, the
  same for every machine connected to it. The page says the key's secret is on the
  machine, in `~/.config/qory/access-key-secret`, where the command saved it. It has
  never been on a screen.
- A generated key: "What build-01 needs, besides the secret. Nothing here is secret." Four
  numbered steps. **Keep the secret in a secret store**: it was shown once, when the key
  was generated, and belongs in `QORY_ACCESS_KEY_SECRET` in the secret store of the
  system that runs `qory`; if it is lost, generate a new key and revoke this one. **Set
  the key's ID**, `QORY_ACCESS_KEY_ID`, as a plain setting. **Set Qory Apiary's public
  key**, `QORY_APIARY_PUBLIC_KEY`, as a plain setting: the same for every machine
  connected to this Qory Apiary. **Point qory at Qory Apiary**: the lines the runner
  file needs, `server.url`.

### For a CI

A CI keeps the key in its own settings rather than in a machine's files. **Generate a key
in the browser** is the way for it, and a pool's **Access key** tab lists it first.
`qory access-key enrol` takes `--print` too: it keeps nothing on the machine and prints
the settings, one `NAME=value` line each.

- `qory access-key enrol --print <server> <code>` prints `QORY_ACCESS_KEY_ID`,
  `QORY_ACCESS_KEY_SECRET` and `QORY_APIARY_PUBLIC_KEY`. The key is active at once.

Only `QORY_ACCESS_KEY_SECRET` belongs in the CI's secret store; the id and the pin are
plain settings, and the CI's `runner.yaml` then needs `server.url` alone.
`QORY_APIARY_PUBLIC_KEY` is JSON: in a shell, put its value in single quotes
([The runner file's `server` section](runner-file.md#the-id-and-the-pin-in-the-environment)).
A fleet of short-lived CI runners is a node pool with one key.

#### Generate a key in the browser

1. On the node's **Access key** tab, select **Generate a key**. The page **Generate a key
   for spot-runners** has one field, **Name of the key**, filled in with the node's name
   (`spot-runners-2` when a key has that name already). Select **Generate key**.
2. Your browser makes the Ed25519 key and sends Qory Apiary only its name and its public
   half. The key
   <!-- feature: secrets -->
   gets **Stored secrets** **Not allowed**, and
   <!-- /feature -->
   is active as soon as it arrives.
3. The page **Key for spot-runners** says "Do these where spot-runners runs. Only the
   secret can't be seen again." Under the notice "The secret is shown once.", four
   numbered steps, each value with **Copy**:
   1. **Store the secret.** In the secret store of the system that runs spot-runners,
      such as your CI's: `QORY_ACCESS_KEY_SECRET`, which is `qak_` and the key's secret,
      tagged "secret · shown once".
   2. **Set the key's ID.** As a plain setting: `QORY_ACCESS_KEY_ID`. It stays on the
      **Access key** tab.
   3. **Set Qory Apiary's public key.** As a plain setting: `QORY_APIARY_PUBLIC_KEY`. The
      same for every machine connected to this Qory Apiary. It stays on the **Access
      key** tab.
   4. **Point qory at Qory Apiary.** In the runner file. It is required: without it,
      `qory` ignores the three variables. With **Copy lines**:

      ```yaml
      server:
        url: https://apiary.example.com
      ```

   Only the secret is shown once: it was made in your browser, Qory Apiary never received
   it, and it can't be shown again. Copy it into the secret store before you select
   **Done**.

Opened again, the page has no notice and nothing to copy for the secret: where it was, it
says "Not shown: only the page that made the key held its secret, and this one was opened
again. If you didn't copy it, revoke spot-runners and generate another key." The other
steps stay. The key's card says **Generated in a browser by** you, and when.

The browser makes keys only on a page served over HTTPS (a browser counts
`http://localhost` as one too) and only if it can make an Ed25519 key: a current Chrome,
Edge, Firefox or Safari. Where it can't, the page says why, and **Generate key** stays
off; connect the machine with a command instead.

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
machine to a new key without a gap, give it the new key first, under **Add a key**, and
revoke the old one once the machine uses the new one. For a node that has or had a key,
the command page adds `--replace` by itself, so a machine that already has a key moves to
the new one; you add it only when you type the command yourself:
`qory access-key enrol --replace <server> <code>`. The old key stays in use until the new
one is active; then revoke the old key on the node's page.

Deleting a node revokes its keys and cancels a command not yet run. Suspending a member
revokes nothing: a key belongs to its node, not to the person who added it, so revoke the
keys that should stop too.

The workspace's overview lists, under **To review**, an active key nobody has used for
30 days, with **Revoke** leading to its card. A key nobody uses is a key to revoke.
