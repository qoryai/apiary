# The security policy

The security policy says what the runs of a hive may reach through the runner's proxy. It
is edited in the console under **Policy**, `/hive/policy`, rendered into a run configuration
for every repository, and served to the hive's machines, which apply it to the runs they
start and to the runs already in flight. In the code it is `Apiary.Policy`.

> #### A hive is served a policy only after its first change {: .warning}
>
> Installing or upgrading the server changes no machine's policy. Until somebody makes the
> hive's policy, by the first rule or the first change of mode, the server offers the hive's
> machines no run configuration, and every machine keeps the `egress` section of its own
> runner file, enforcement included. The first change takes over for every machine of the
> hive at once. Read [The first change](#the-first-change) before you make it.

## Rules

A rule allows or denies one thing:

- **A host**: a name in lower case, `api.example`, or `*.` and a suffix, `*.internal.example`,
  for every host below it. A suffix rule does not cover the suffix itself:
  `*.internal.example` does not allow `internal.example`. A rule names a host and nothing
  else: no scheme, no port.
- **Paths**, on an allowed host: every path, or the paths listed. A path starts with `/` and
  may end in one `*`, such as `/v1/*`; there is no other wildcard and no query. A host held
  to paths is one the proxy reads requests to, which it can do only behind a wall.
- **A credential**, by name, with an argument when the machine's adapter takes one: a name
  such as `forge-token` and an argument such as `acme/shop`. The policy names a credential
  and never holds one. Each machine defines its credentials in its own runner file, and a
  run whose policy names a credential its machine does not define does not start.

Paths and credentials need a wall. Without one the runner refuses to start a run whose
policy has either.

The policy document the runner reads can only allow. A deny is the server's own notion: it
takes entries out of the document that is rendered. That is how a repository disables a
host the hive allows, and why a deny rule is never found in the document itself.

## The hive's baseline and a repository's rules

The hive has a baseline of rules, on `/hive/policy`. A repository has rules of its own on
top, on `/hive/policy/repositories/:repository_id`; the list of repositories is
`/hive/policy/repositories`. A repository appears there once a run names it, by the `forge`
and `repository` labels the runner takes from the checkout's origin remote
([The runner file's `server` section](runner-file.md)).

A repository without rules of its own is served the hive baseline, and so is a run that
names no repository.

A repository's page shows its effective policy as one list, every rule with where it came
from: **Hive**, **This repository**, or **Hive, locked**. A rule that lost is struck
through under the rule that beat it. The row actions are **Disable here**, **Allow here**,
**Remove** and **Restore**.

## How rules resolve

Rules meet on the same host string, or the same credential name, and the one that wins
decides the host whole, its action and its paths.

1. A **locked** rule of the hive wins over everything.
2. Then the repository's rule.
3. Then an unlocked rule of the hive.

So where the two meet on a host, the repository wins, unless the hive's rule is locked.

A deny of a `*.` suffix also removes every allow entry it covers, `*.example` covers
`api.example` and `*.eu.example`, unless the allow has the higher precedence.

A host held to paths is rendered both in the document's `allow` and in its `paths`, because
the runner's proxy decides the connection by `allow` first and the request by `paths` after.

### What is refused

What the document cannot say is refused when it is written, with a sentence that says what
to do instead. Nothing is ever rendered that allows more than the page shows.

- **A deny of a host below an allowed `*.` suffix**, when the deny does not lose to that
  allow by precedence. The document has no way to allow every host below a suffix except
  one. Remove the suffix rule and allow the hosts you want by name, or deny the suffix whole.
- **A `*.` suffix held to paths above another allowed entry.** The runner holds a host to
  the path list of whichever entry it finds first, and the order is not fixed. A name held
  to paths under a suffix that is free of paths is fine.
- **A rule outside the grammar**: a URL, a port, capitals, a `*` anywhere but the lead. The
  composer checks a rule as it is typed and reads it back in words before it can be saved.
- **A change whose rendered document the contract's schema refuses.** Nothing is changed,
  and the version in force stays in force.
- **A change over a limit**, see [Limits](#limits).

## Locks

A locked rule of the hive holds against every repository: a locked deny cannot be allowed by
a repository, and a locked allow cannot be disabled by one. A repository's rule that a lock
holds against is kept and shown as held; it is not in force.

Members edit rules. Only an owner locks, unlocks, changes or removes a locked rule.

## Observe and enforce

The hive has a mode, shown as two cards at the top of `/hive/policy`.

- **Observe** records every connection and denies none. A host no rule names is let through,
  and the record says so. Locked rules do not hold in observe mode either: the document then
  only says what enforce would allow.
- **Enforce** denies a connection no rule allows, and records the denial. With no allow
  rule, a run reaches nothing.

A hive starts in observe. Only an owner changes the mode, in either direction, and each
change is confirmed. A wall's own refusals, the machine's own address say, hold in either
mode.

The hive's mode is a default. A repository follows it until an owner gives the repository a
mode of its own, on the repository's page under `/hive/policy/repositories`: **Follow the
hive**, **Observe** or **Enforce**, with what is in effect and where it comes from. A change
of the hive's mode reaches the repositories that follow it and leaves the others as they
are. The mode and the rules are apart: a repository in enforce under a hive in observe is
held to its effective rules, the hive's locked rules included, and a repository in observe
is denied nothing. That is the way to enforce one repository first and the rest later.

The confirmation of a switch to enforce lists what enforce **would start denying**: the
destinations that were let through in the last seven days and that today's rules still do
not cover, counted from the recorded connections, each with **Allow** for the hive beside
it. A destination no run has reached yet is not in that list. Under observe, the page says
the same as a fact: how many attempts to how many destinations had no rule.

## Versions

Every change renders the baseline and every repository with rules of its own, in the same
transaction, as canonical JSON: members in a fixed order, no whitespace, `allow` sorted with
names before `*.` suffixes. Each render is validated against the contract's schemas before
it is stored.

- A version is kept as the **exact bytes served**, under its digest: `sha256=` and the
  SHA-256 of those bytes in lower-case hex. Two runs with the same digest had the same
  policy.
- A change that renders the **same bytes** as the version in force makes **no new
  version**. The change is still in the history. A lock often does this: it holds against
  repositories and leaves the hive's document as it was.
- **History**, `/hive/policy/history` and
  `/hive/policy/repositories/:repository_id/history`, has every change with who made it,
  when, the rules before and after, the version it made or that it made none, and its diff
  in rules and in document lines. Changes to a repository's own rules are in that
  repository's history.
- **A version's page**, `/hive/policy/versions/:n` and
  `/hive/policy/repositories/:repository_id/versions/:n`, has the changes from any earlier
  version, the document indented for reading, and the bytes as served.
  `/hive/policy/document` is the document in force.

A run's page names the policy version the run last reported, as a link to that exact
version, and says when an alive run is behind the version in force.

## Live reload

Every answer of the server to a batch of events carries the digest of the run configuration
in force for the run's repository. A runner that holds another digest fetches the run
configuration again and applies it. A run sends a heartbeat every thirty seconds, so a change
reaches the runs in flight within a heartbeat, about 30 s.

On a reload the new policy holds for new connections at once, the record gets a second
policy applied event, which the run's timeline shows as "Policy applied again" with the
hosts added and removed, and a tunnel open to a host the new policy denies is closed and
recorded as refused.

The record is not rewritten. A rule added from a connection's row, **Allow** or **Deny** on
a run's Connections tab or on `/hive/connections`, changes what happens next; what the
record already says stays as it was.

## Export for a node without a server

A machine that reports to no server can be given the same policy as files. **Export**, on the
policy page and on a version's page, `/hive/policy/versions/:n/export` and
`/hive/policy/repositories/:repository_id/versions/:n/export`, gives the effective policy of
that version as text, with **Download**:

- the `egress` section for the machine's runner file, which says a mode and the hosts
  allowed and nothing else;
- when the policy has paths or credentials, a policy file in the contract's own format,
  given to one run with `qory run --policy <file>`. It narrows the runner file's section and
  never widens it, so the two are exported together and agree.

```yaml
# ~/.config/qory/runner.yaml
egress:
  mode: enforce
  allow:
    - "api.example"
```

The export is a copy: it does not follow later changes. Keep a policy file outside the
checkout. Deny rules and locks are already applied: the files list what remains allowed.
With a server configured, `qory run` refuses `--policy` unless `--local` is given too.

## Limits

| Limit | Value |
|---|---|
| Rules in a list, the hive's baseline or one repository's | 500 |
| Paths in a rule | 100 |
| A rendered run configuration | 1 MiB, the most a runner reads of a document |

A change that would pass a limit is refused, and nothing is changed.

## The first change

Until somebody has made the hive's policy:

- the server's discovery document names no `run` section for the hive's machines;
- the run configuration endpoint answers `404` for the hive's keys;
- every machine runs under the `egress` section of its own runner file, in its own mode,
  enforcement included;
- the policy page says: "Runs use each machine's own policy until the first change here."

The first rule or the first change of mode, the hive's or a repository's, is the moment the hive
takes over:

- for every machine under the hive's access keys, and for the runs in flight, which reload
  within a heartbeat;
- entirely: from then on the hive's policy is the policy, and a machine's own `egress`
  section is not merged with it;
- in the mode the hive is in, which is observe until an owner sets it. A machine that
  enforced a list of its own is, after the first change, under a hive that observes and
  denies nothing, until an owner switches the hive to enforce.

So before the first change:

1. Collect what the machines' own lists say, the `egress.allow` of every runner file.
2. Say all of it in the hive. The first rule you add already takes over, so add
   the rest straight after it; while the hive is in observe nothing is denied in between.
3. When the rules are complete, an owner switches to enforce. The confirmation lists what
   would start being denied, from the record.

To keep one machine on its own policy, start its runs with `qory run --local`: the run is
recorded to files only, under the machine's policy, and the server is not contacted, so
that run does not appear in the console.

It does not go back by removing the rules. A hive that was given a policy keeps serving it:
with every rule removed it serves an empty policy, under which a run in enforce mode
reaches nothing.
