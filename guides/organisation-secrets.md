# The organisation's secrets

This guide covers the organisation's secrets, with the `organisation_variables` feature,
which holds the organisation's secrets and variables: secrets that belong to an
organisation, not to one of its workspaces, beside each workspace's secrets. The quick
start says where a workspace's secrets are kept and what a secret holds; this guide says
what the organisation adds beside them.

<!-- feature: organisation_variables -->
## The feature

`organisation_variables` is a feature and needs `security` and `secrets`. It is on by
default, and support can turn it off for an organisation. It holds the organisation's
secrets and its variables, granted together as Organisation secrets and variables. Where
an organisation does not have it, its people can't open or change the organisation's
secrets, and its **Secrets and variables** has no Variables tab and lists no secret of
the organisation, only the keys of its model providers, where the features `factory` and
`secrets` are on; secrets it already has, and the links to them, still work.

The organisation's secrets are in its settings, under Organisation settings › Secrets and
variables, on the **Secrets** tab.

**A value is never shown again.** Qory Apiary keeps the secrets, each value
encrypted, and never shows a value again once it is saved, to anyone. The page lists
names, notes and value IDs, and who changed each and when.

## Two levels

A secret belongs to one workspace, under Workspace settings › Secrets and variables, or
to the organisation, under Organisation settings › Secrets and variables. The two levels
sit side by side, and neither is above the other:

- **Nothing is inherited, and nothing is locked.** A workspace gets no secret of the
  organisation's by its name, and its Secrets page lists only the workspace's secrets.
- **The same name is another secret.** A workspace's secret named as one of the
  organisation's is a different secret, with other values: neither replaces the other,
  and neither is refused for the other's name.
- **Names are compared without case, at each level.** `FORGE_TOKEN` and `forge_token`
  are one name among the organisation's secrets, as among a workspace's.

## Links and runs

A secret reaches a run only through a link from what uses it, and links come with the
integration's page. Nothing links a secret yet, so the page's **Used by** reads
**Not used** on every secret, and no run is given an organisation's secret.

A secret, or one of its values, that something uses is not deleted: the refusal names
what uses it, to unlink it there first.

## What a name and a value may be

The organisation's secrets keep the rules of a workspace's secrets:

- A name starts with a letter or `_` and holds only letters, digits and `_`, at most 128
  of them.
- A secret holds one value, or several, at most 32, each named by a value ID: lowercase
  letters, digits, `.`, `_` and `-`, starting with a letter or digit, at most 64 of them.
- A value is UTF-8 text, at most 16 384 bytes, and may run over several lines; it may
  not be empty or hold a NUL byte.
- The note, **What it is for**, is optional: at most 500 characters, with no control
  characters.

## Who

Owners and admins of the organisation change its secrets: they create one, change its name
and note, add a value, change, rename or delete one, and delete the secret. Owners and
admins read them, and so does support, who changes nothing: names, notes and value IDs,
never a value. A member does not read them; a member reads the secrets of the workspaces
they reach. A suspended organisation is read-only.
<!-- /feature -->
<!-- feature: organisation_variables, managed_organisations -->

In a client, the people of its operator read its secrets and variables as support does,
and change nothing.
<!-- /feature -->
<!-- feature: organisation_variables -->

Each change is in the organisation's audit log (Audit log, in the organisation sidebar's
first group), as a stored secret's, by its name and value IDs and never a value: who
created it, changed its name or note, replaced, added, renamed or deleted a value, or
deleted it.
<!-- /feature -->
