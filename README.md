# 🐝 Qory Apiary

The control plane for coding agent runs.

Every agent session runs behind a wall, reaches only what your policy allows, never holds
your keys, and leaves a full record. Qory Apiary is the server your machines report to and
the console you read. Open source, so you can check all of that.

- **The record.** Every run in one place: the session as a timeline, the terminal output,
  and every connection with the decision and the rule behind it.
- **The wall.** A session's only way out is a proxy on its machine. Credentials stay
  outside the container; the record names them and never holds them.
- **The policy.** What runs may reach, versioned and edited in one place. A change reaches
  the runs in flight within about 30 seconds.

## Try it

You need Docker with `docker compose`, `git` and `openssl`.

```sh
git clone https://github.com/qoryai/apiary.git && cd apiary
cp .env.example .env         # fill in the values it marks as required
docker compose up --build    # Postgres, then the server on port 4100
```

Sign up at `http://localhost:4100/users/register`; the trial writes the log-in link to
`docker compose logs apiary`. The first person to sign up creates the organisation and runs
the instance, and everyone else joins by invitation.

Then add a node under **Nodes**, select **Get the command** on its **Access key** tab, run
the command it gives, `qory access-key enrol <server> <code>`, on the machine, which needs
the [`qory`](https://github.com/qoryai/qory) command, and start a run. The key the machine
makes is active as soon as it arrives. For a CI or a node pool, **Generate a key** on the
same tab makes the key in your browser and shows its secret once, for the CI's secret
store. A run shows up under **Runs** while it runs. [The quickstart](guides/quickstart.md)
walks through each step.

## Guides

- [Quickstart](guides/quickstart.md): the trial, step by step.
- [Install](guides/install.md) and the [hosting checklist](guides/hosting-checklist.md): an
  instance other people sign in to, and every setting.
- [Nodes and their keys](guides/nodes.md): how a machine gets its access key, and what a
  node pool is.
- [Security policy](guides/security-policy.md): read it before your first change.
- [Upgrading](guides/upgrading.md) and [backup](guides/backup.md).

Every instance also serves its guides and module reference at `/docs`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md); contributions are made under [CLA.md](CLA.md).
Report a vulnerability as [SECURITY.md](SECURITY.md) says, not as an issue.

## Licence

Apache License 2.0, see [LICENSE](LICENSE). Qory™ is a trademark of 8wonders GmbH;
[TRADEMARKS.md](TRADEMARKS.md) says what you may do with the name, and
[EDITIONS.md](EDITIONS.md) what each edition contains.
