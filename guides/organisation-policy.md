# The organisation's policy

This guide covers the organisation's policy, with the `organisation_policy` feature: the
rules every workspace of an organisation follows, above each workspace's security policy.
The guide to the security policy says how a workspace's policy and a repository's rules
work; this one says what the organisation adds above them.

<!-- feature: organisation_policy -->
## The feature

`organisation_policy` is a feature and needs `security`. Support turns it on for an
organisation. Where an organisation does not have it, its sidebar has no **Policy** in its
first group, and its people can't open or change the organisation's policy; a policy it
already has still holds above every workspace, and its runs are served it. Where its
people have `security`, each workspace's **Policy** page still lists the organisation's
rules.

## Three levels

A workspace's policy has workspace rules, and each repository has repository rules under
them. The organisation's policy sits above both: its rules reach every workspace of the
organisation, and a workspace or a repository may narrow them, never widen them.

- **An organisation deny holds everywhere.** No workspace or repository rule allows the
  host; a `*.` suffix denied covers every host below it.
- **An organisation allow reaches every workspace.** A workspace or a repository may
  still deny it, by the host or by a `*.` suffix that covers it. Against an allow of a
  workspace or a repository for the same host, the organisation's holds, paths included.
- **Precedence** is the organisation's rule, then a locked rule of the workspace, then
  the repository's, then the workspace's.

The gateway still receives one document per workspace or repository, with the
organisation's rules rendered into it; the wire contract is unchanged. A change of the
organisation's policy renders every workspace's documents again, each a new version where
its bytes change, and a workspace with no version yet, such as one an earlier release
created during an upgrade, gets its version 1, so a deny of the organisation's holds there
too ([Version 1](security-policy.md#version-1)).

## The page

An owner or an admin of the organisation opens **Policy**, in the organisation sidebar's
first group, `/:org/policy`; owners change it, admins read it, and so do the people of the
organisation's operator and support.

The mode card, above the page's tabs, says whether the organisation requires enforce:
**Mode: Set per workspace**, the default, or **Mode: Enforce required**. Required, no
workspace or repository may observe: a connection no rule allows is denied everywhere,
each workspace's and repository's mode reads Enforce, required by the organisation, and a
repository's override to observe is kept but not in force. An owner changes it with **Change
mode**, which opens two choices in the card, **Each workspace chooses** and **Enforce in
every workspace**; picking one only selects it, and the button that names it saves it.

**Rules** holds **Workspaces may allow more hosts**, on by default. Off, only the
organisation's allows grant a host: a workspace's or a repository's allow rules are
listed, struck, "not in force", and may still be removed; their denies still apply. Then
comes Network access on the list pattern of the workspace's page: All, Allowed and Denied,
a search with the same qualifiers, each rule's use counted over every workspace in the
last 14 days, and Add rule, which opens New rule. A rule's menu offers Edit, Change to
deny or allow, and Remove.

Changing the mode or turning the switch gives each workspace it changes a new version of
its policy, so the page asks first, in place, and says what changes: for the mode, each
workspace, and each one's repositories, that enforce from now on or observe again; for
the switch, the allows it leaves out of force or puts back, by workspace. An admin reads
the mode with no Change mode, and the switch dimmed, and is told that only owners change
the policy.

**Workspaces** lists each workspace in use: its mode in force, how many workspace rules
it has, how many of its allows are not in force, and the way to its policy page.

**History** lists each change of the organisation's policy, who made it and when, with
the workspaces it rendered again and the version each was left at, or that no bytes
changed.

## What the workspace's pages show

Where the organisation has a policy, the workspace's Policy page says so under its
title: "Acme's policy applies here: 14 rules, enforce required", with a link to it.
Its Network access list has the organisation's rules first, their source the
organisation's name with its tile, a lock glyph, and no action but **View in Acme's
policy** in the row's menu; the Filter menu's Source section narrows the list to one
source. A rule of the workspace's the organisation's deny strikes says whose deny; one
the switch strikes says only the hosts on the organisation's list are allowed. While the
organisation requires enforce, the mode card reads Enforce, **Required by Acme**, and
offers no Change mode. A repository's Policy tab shows the same rows after the repository
rules.

On the Network access page, a destination the organisation decides shows its rule as
"Acme · denied" or "Acme · allowed", a link to the organisation's policy with the
rule marked. A denied one offers no Allow: its lock says that Acme's policy denies
the host and that no workspace or repository rule can allow it. Where only the
organisation's allows grant, a denied destination's Allow names Acme's policy and
opens a panel under the row that says so and leads to the organisation's policy, on New
rule, with the host filled in, and **Back to Main › Network access** beside the list to
return; the rule you add there is marked in the list.

Each change of the organisation's policy is in every workspace's History too, as
"changed Acme's policy", with the version it rendered, and in the organisation's
audit log (Audit log, in the organisation sidebar's first group).
<!-- /feature -->
