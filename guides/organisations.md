# Workspaces and deleting an organisation

This guide is for the owners of an organisation: how they add a workspace, who reaches a
workspace, and what happens when they delete the organisation.

## Adding a workspace

An owner adds a workspace to the organisation.
<!-- feature: managed_organisations -->
In a client of an operator, the client's admins add one too, with or without
`operator_infrastructure`; while operators run their clients, the operator's owners may as
well.
<!-- /feature -->
An organisation with no workspace shows the kind cards on its overview, `/:org`, under
**What will your first workspace do?**. Once it has one, an owner adds another with **New
workspace** on **Workspaces** in the organisation's settings, `/:org/settings/workspaces`,
on the organisation's overview, from **New** in the top bar on any of the organisation's
pages, or from the workspace menu (the chevron beside the workspace) on any of its
workspaces' pages. Each leads to the same cards, `/:org/workspaces/new`, which ask what
the workspace will do.

Click a card to open its type's page. Click **Create workspace** there to create the
workspace and open its **Name** step. The workspace is named after the card, such as
*Software factory*, or *Software factory 2* when the organisation has one of that name
already. The type is chosen at creation only. Type another name and select **Save and
next** to rename it. The workspace's address, under the organisation's, such as
`/acme/software-factory`, is made from its name and follows it at all times: a new name,
on the Name step or in the workspace's settings, changes the address, and links to the
old address stop working. There is no field for an address. A name whose address another
workspace of the organisation has is refused: "Choose another name. Another workspace
already has the address /acme/payments."

The workspace starts empty, with no machine and no run, and its policy in observe, or in
enforce where the organisation's policy requires it, with the organisation's rules it
follows from the start. With the `factory` feature, **Save and next** goes on to the
workspace's next set-up step, **Work sources**; until a test run passes, the group **Set
up** at the top of the workspace's sidebar and the workspace's overview list the steps.
Without it you land on its overview, which leads you to add a machine, and the switcher lists
it from then on. Its owners and admins reach it as they reach every workspace; a member
reaches it once added ([Who reaches a workspace](#who-reaches-a-workspace)).

## Who reaches a workspace

An owner and an admin reach every workspace of their organisation. A **member** reaches
the workspaces they were added to, and no other: an invitation, sent from a workspace,
adds the person to that workspace, and an owner or an admin adds a member to a workspace,
or removes them from one, with **Workspaces…** in their row's menu on Organisation
settings › People. A member who has not been added to any workspace signs in to the
organisation and is told so.

## Deleting an organisation

An owner deletes the organisation on **Organisation settings**, `/:org/settings`, typing
its slug to confirm. That only marks it: it disappears for every member at once, its
access keys stop working, and nothing is removed. During the grace period, an owner can
cancel the deletion on their organisations page, and everything comes back; retention does
not prune its workspace meanwhile. An organisation's only workspace is not deleted by
itself: the organisation is.
<!-- feature: managed_organisations -->
An operator with clients is not deleted until each client is purged or dropped ([Operators
and their clients](operators.md)).
<!-- /feature -->

Once a day, at 03:20 UTC, a job purges what is past its grace period: every row the
organisation holds, its runs and access keys, its members and its audit trail. Of a purged
organisation Qory Apiary keeps one row in `purged_organisations`: its id, when it was
marked and by whom, and when it was purged, with no name.
