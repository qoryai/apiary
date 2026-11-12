# The organisation's variables

This guide covers the organisation's variables, with the `organisation_variables` feature,
which holds the organisation's secrets and variables: names and values every workspace of
an organisation inherits, above each workspace's variables. The quick start says where a
workspace's variables are kept and what a lock does; this guide says what the organisation
adds above them.

<!-- feature: organisation_variables -->
## The feature

`organisation_variables` is a feature and needs `security` and `secrets`. It is on by
default, and support can turn it off for an organisation. It holds the organisation's
secrets and its variables, granted together as Organisation secrets and variables. Where
an organisation does not have it, its **Secrets and variables** has no Variables tab, or
is not there at all where the features `factory` and `secrets` are off too, and its
people can't open or change the organisation's variables; variables it already has still
reach every workspace. They do not need the organisation's policy
(`organisation_policy`): they reach every workspace whether or not the organisation has a
policy, and with none they add nothing to the workspaces' security policy.

The organisation's variables are in its settings, under Organisation settings › Secrets
and variables, on the **Variables** tab.

**A run receives only its security policy.** Qory Apiary keeps the variables, checks them
and resolves them at every level, for each workspace and repository, and the configuration
Qory Apiary returns when a run registers does not contain them.

## Three levels

A workspace's variables reach each of its repositories, and a repository may hold an
override, which no page sets.
The organisation's sit above both: they reach every workspace of the organisation, and
each of their repositories.

- **A lower value overrides the organisation's, unless the organisation locks the name.**
  A workspace that sets a name the organisation sets and does not lock resolves to its
  override, for itself and its repositories, and a repository's override replaces its
  workspace's value, as without the organisation.
- **A name the organisation locks** is set at no level below it. A workspace or a
  repository that set it before the lock keeps its value, set aside: the organisation's
  is the one in force, and unlocking the name puts the lower values back in force.
- **Names are compared without case.** `LOG_LEVEL` and `log_level` are one name: an
  organisation sets a name once, and a workspace or a repository that spells a name the
  organisation sets otherwise is refused, as the organisation is when a workspace or a
  repository already spells it otherwise. The refusal names the workspace.

## What a name and a value may be

The organisation's variables keep the rules of a workspace's variables, with the same
sentences:

- A name starts with a letter or `_` and holds only letters, digits and `_`, at most 128
  of them.
- A name beginning `QORY_`, whatever its case, is reserved for Forager, and refused.
- A value is one line of text, at most 4096 bytes; it may be empty.
- A write at any level that would raise one workspace's or one repository's variables
  above 128, or above 64 KiB of names and values, counting every level that reaches it,
  is refused. A change
  of the organisation's that would take
  the organisation's variables alone, a workspace or a repository over either limit is
  refused, and the refusal names the workspace. A value a lock sets aside does not count,
  so unlocking a name, or deleting a locked one, is refused where the values it puts back
  would be over. A workspace deleted but still in its grace period counts as one in use,
  so restoring it never takes it over a limit or brings back another spelling.

The limits and the one spelling are checked on every write, the organisation's and its
workspaces', and on nothing else.

## Who

Owners and admins of the organisation change its variables: they create one, change its
value, lock it, unlock it and delete it. Owners and admins read them, and so does support,
who changes nothing. A member does not read the organisation's variables, only the
workspace's they reach. A suspended organisation is read-only.
<!-- /feature -->
<!-- feature: organisation_variables, managed_organisations -->

In a client, the people of its operator read its secrets and variables as support does,
and change nothing.
<!-- /feature -->
<!-- feature: organisation_variables -->

Each change is in the organisation's audit log (Audit log, in the organisation sidebar's
first group), by the variable's name and never its value: who set, changed, locked,
unlocked or removed it.
<!-- /feature -->
