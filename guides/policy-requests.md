# Policy requests

This guide covers policy requests, with the `managed_organisations` and `security`
features: how an operator asks its clients for the changes of the security policy its
harness needs, and how a client answers. [Operators and their clients](operators.md) says
what an operator and a client are, and the guide to the security policy says how a policy
is changed.

<!-- feature: managed_organisations, security -->
## Asking

A client's security policy is the client's, and its operator asks for what its harness
needs. An owner or an admin of the operator writes a **policy request** on its **Policy
requests** page, in the Operator group of its sidebar: the rules to add, change or remove,
and the mode if it is to change, each checked as the policy checks a change, with a note
saying why the harness needs them. It goes to the clients chosen, every client that has the
security policy and is not suspended by default.

## Answering

Each client answers separately, on its **Policy requests** page, in its organisation's
sidebar, which its policy page points to while a request waits. Each request has a separate
page, where whoever may change the client's policy accepts it in the workspaces they
choose: the changes are made there as changes they make to the policy, all of them or none,
a locked rule still an owner's and the mode an owner's or an admin's. Or they decline it,
with a reason or none, from its row of the list, after a question in place. A request that
no longer fits the policy as it is, a rule already there or one that is gone, is refused
with the reason, and nothing changes.
<!-- /feature -->
<!-- feature: managed_organisations, security, organisation_policy -->
Where the client's organisation requires enforce in every workspace
([The organisation's policy](organisation-policy.md)), a requested mode of enforce is what
holds already, and observe refuses the acceptance; a requested rule the organisation's
policy denies is made, and listed as not in force.
<!-- /feature -->
<!-- feature: managed_organisations, security -->

## Following a request

The operator's page lists its requests, and a request's page lists each client's answer.
Its owners and admins withdraw a request from the clients that have not answered it, from
its row, after a question in place. The operator's people read a client's requests and
answer none. A client that is dropped has its pending requests withdrawn. Each step is in
the audit log of the operator and of the client (Audit log, in the organisation sidebar's
first group).
<!-- /feature -->
