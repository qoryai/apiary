# The security policy

The security policy says what the runs of a workspace may reach through the runner's
proxy. It is edited in the console under **Policy**, `/:org/:workspace/policy`, rendered
into a run configuration for every repository, and served to the workspace's machines,
which apply it to the runs they start and to the runs already in flight. In the code it is
`Apiary.Policy`.

> #### A workspace is served a policy only after its first change {: .warning}
>
> Installing or upgrading the server changes no machine's policy. Until somebody makes the
> workspace's policy, by the first rule or the first change of mode, the server offers the
> workspace's machines no run configuration, and every machine keeps the `egress` section
> of its own runner file, enforcement included. The first change takes over for every
> machine of the workspace at once. Read [The first change](#the-first-change) before you
> make it.

## Rules

A rule allows or denies one thing:

- **A host**: a name in lower case, `api.example`, or `*.` and a suffix, `*.internal.example`,
  for every host below it. A suffix rule does not cover the suffix itself:
  `*.internal.example` does not allow `internal.example`. A rule names a host and nothing
  else: no scheme, no port.
- **Paths**, on an allowed host: every path, or the paths listed. A path starts with `/` and
  may end in one `*`, such as `/v1/*`; there is no other wildcard and no query. A host held
  to paths is one the proxy reads requests to, which it can do only behind a wall.

Paths need a wall. Without one the runner refuses to start a run whose policy has them.

Credentials are not part of the policy: the run configuration this server renders selects
none, and a run uses no credential of its machine's. Secrets are coming as a feature of
their own.

The policy document the runner reads has a deny list and an allow list. The runner decides
the deny list first, in either mode: a host a deny rule names is denied under observe as
under enforce, and the denial is recorded with the rule. A deny rule is written to that
list and takes the allowed hosts it covers out of the allow list, which is how a repository
disables a host the workspace allows.

## The workspace's baseline and a repository's rules

The workspace has a baseline of rules, on `/:org/:workspace/policy`: the hosts and paths
in its **Network access** section. What the runs
reached, and what decided it, is the **Network access** page beside **Policy** in the
sidebar, `/:org/:workspace/network`, where each row can allow or deny its host; the
section links to it, and its rules link back. A repository has rules of its own on top,
on the **Policy** tab of the repository's page,
`/:org/:workspace/targets/:forge/:path/-/policy` (the old address,
`/:org/:workspace/policy/targets/:id` and what followed it, sends on there); the list of
repositories and their policy is `/:org/:workspace/policy/targets`. A repository appears
there once a run names it, by the `forge` and `repository` labels the runner takes from the
checkout's origin remote ([The runner file's `server` section](runner-file.md)).

A repository without rules of its own is served the workspace baseline, and so is a run
that names no repository.

Every list of rules is read the same way, however long it grows: views **All**,
**Allowed**, **Denied** and **Locked** with their counts; a field that finds a host and
holds the chosen filters as words (`seen:no`, `paths:held`, `by:dana`; on a repository's
tab `source:repo` or the workspace's slug); one **Filter** menu (Source where there is more
than one, Paths, Seen in 14 days, Added by); **Sort** (the list's own order, Host, Most
used, Recently added); **Add rule**, which opens the composer line over the list; and
pages of 50. Every choice is in the address, so a filtered view can be linked. A rule is
one line: allow or deny, the host, its paths, its use in the last 14 days, who added it
and when, a lock when it is locked, and a ⋯ menu (Edit paths, Change to deny or allow,
Lock or Unlock for an owner, Remove).

A repository's Policy tab is its effective policy on the same list, every rule with its
**Source**: **This repository** or the workspace, by its name. Its own rules come first
and are changed there; the workspace's are read there and changed on the workspace's
policy page, which their menu leads to (**View in Main's policy**). A rule that is not in
force, the repository's own under a locked rule of the workspace, or the workspace's that
the repository's own decides, stays in the list, struck through, and says why. A
repository overrides the workspace's rule for a host by adding its own rule for it, the
other way round; removing that rule gives the workspace's back.

## How rules resolve

Rules meet on the same host string, and the one that wins decides the host whole, its
action and its paths.

0. A rule of the level above the workspace, where the edition keeps one (the core keeps
   none): its denies hold everywhere, so no rule of the workspace or of a repository
   allows the host; its allows reach every workspace and can be narrowed by a deny below
   them, never widened. Against a lower allow on the same host, its allow holds, paths
   included.
1. A **locked** rule of the workspace wins over everything else.
2. Then the repository's rule.
3. Then an unlocked rule of the workspace.

So where the two meet on a host, the repository wins, unless the workspace's rule is
locked. Where the level above the workspace allows only its own hosts, an allow of the
workspace or of a repository is listed, struck, and not in force; denies still apply.

A deny of a `*.` suffix also removes every allow entry it covers, `*.example` covers
`api.example` and `*.eu.example`, unless the allow has the higher precedence. A deny below
an allowed `*.` suffix stands beside it: `*.example` allowed and `tracker.example` denied
reaches `api.example` and denies `tracker.example`, since the runner decides deny first.

One shape has no form on the wire: a `*.` deny of the workspace with a repository's own
allow below it, where the repository wins by precedence. The allow is rendered, the deny
still takes out the workspace's allow entries below it, but it is not written to the
document's deny list, since that would deny the repository's host too. Under enforce the
other hosts below the suffix are denied by having no allow; under observe they are let
through in that repository, and the record says no rule matched.

A host held to paths is rendered both in the document's `allow` and in its `paths`, because
the runner's proxy decides the connection by `deny` and then `allow` first, and the request
by `paths` after. A denied host is never reached, so its paths never apply.

### What is refused

What the document cannot say is refused when it is written, with a sentence that says what
to do instead. Nothing is ever rendered that allows more than the page shows.

- **A `*.` suffix held to paths above another allowed entry.** The runner holds a host to
  the path list of whichever entry it finds first, and the order is not fixed. A name held
  to paths under a suffix that is free of paths is fine.
- **A rule outside the grammar**: a URL, a port, capitals, a `*` anywhere but the lead. The
  composer checks a rule as it is typed and reads it back in words before it can be saved.
- **A change whose rendered document the contract's schema refuses.** Nothing is changed,
  and the version in force stays in force.
- **A change over a limit**, see [Limits](#limits).

## Locks

A locked rule of the workspace holds against every repository: a locked deny cannot be
allowed by a repository, and a locked allow cannot be disabled by one. A repository's rule
that a lock holds against is kept and shown as held; it is not in force.

Members edit rules. Only an owner locks, unlocks, changes or removes a locked rule.

## Observe and enforce

The workspace has a mode, one line at the top of `/:org/:workspace/policy`: Observe or
Enforce, then a sentence of what it does and how many repositories follow it.

- **Observe** records every connection and denies only what a deny rule names. A host no
  rule names is let through, and the record says so. A deny holds in observe as in enforce,
  a locked one included; the allow list then only says what enforce would reach.
- **Enforce** denies a connection no rule allows, and records the denial. With no allow
  rule, a run reaches nothing.

A workspace starts in observe. Only an owner or an admin changes the mode, in either
direction, and each change is confirmed. A wall's own refusals, the machine's own address
say, hold in either mode. Where the level above the workspace requires enforce, the mode
is enforce in the workspace and in every repository, the workspace's and the
repositories' choices are fixed and say who requires it, and a repository's own observe is kept but not
in force.

The workspace's mode is a default. A repository follows it until an owner or an admin
gives the repository a mode of its own, on the repository's Policy tab: **Follow** the workspace, by its name, **Observe** or **Enforce**,
with what is in effect and where it comes from. A change of the workspace's mode reaches
the repositories that follow it and leaves the others as they are. The mode and the rules
are apart: a repository in enforce under a workspace in observe is held to its effective
rules, the workspace's locked rules included, and a repository in observe is denied only
what a deny rule names. That is the way to enforce one repository first and the rest
later.

The confirmation of a switch to enforce lists what enforce **would start denying**: the
destinations that were let through in the last seven days and that today's rules still do
not cover, counted from the recorded connections, each with **Allow** for the workspace
beside it. A destination no run has reached yet is not in that list. Under observe, the
page says the same as a fact: how many attempts to how many destinations had no rule.

## Versions

Every change renders the baseline and every repository with rules of its own, in the same
transaction, as canonical JSON: members in a fixed order, no whitespace, `allow` and `deny`
sorted with names before `*.` suffixes. Each render is validated against the contract's schemas before
it is stored.

- A version is kept as the **exact bytes served**, under its digest: `sha256=` and the
  SHA-256 of those bytes in lower-case hex. Two runs with the same digest had the same
  policy.
- A change that renders the **same bytes** as the version in force makes **no new
  version**. The change is still in the history. A lock often does this: it holds against
  repositories and leaves the workspace's document as it was.
- **History**, `/:org/:workspace/policy/history` and
  `/:org/:workspace/targets/:forge/:path/-/policy/history`, has every change with who made it,
  when, the rules before and after, the version it made or that it made none, and its diff
  in rules and in document lines. Changes to a repository's own rules are in that
  repository's history. The history is the policy's part of the organisation's audit
  trail, and is kept as long as the trail: 90 days unless the instance says otherwise
  (`AUDIT_RETENTION_DAYS`, [Install and configure](install.md)). The versions are kept
  whatever their age.
- **A version's page**, `/:org/:workspace/policy/versions/:n` and
  `/:org/:workspace/targets/:forge/:path/-/policy/versions/:n`, has the changes from any
  earlier version, the document indented for reading, and the bytes as served.
  `/:org/:workspace/policy/document` is the document in force.

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

The record is not rewritten. A rule added from a destination's row, **Allow** or **Deny**
on a run's **Network access** tab or on the workspace's Network access page,
`/:org/:workspace/network`, changes what happens next; what the record already says stays
as it was.

## Tool invocations

A runner can give a run **tools**: programs on the runner's machine that serve hosts. The
machine defines them; the run's policy selects among them by name. A run configuration
could carry that selection, but this server never sends one: the workspace's policy has no
tools. So a run has tools only when it runs under its
machine's own policy, the one in its [runner file](runner-file.md), and only such runs
report tool invocations.

The runner's proxy hands a request to a host a tool serves to that tool when the rules let
it through; the host may be a name that exists only on the machine, such as
`files.tools.internal`. Each request to such a host is decided on its path, recorded like
any connection, decided by the same rules and counted on the same pages, and the record
adds the tool's name, the proxy's id of the request and, when the tool answered, its
status. A **tool invocation** is a request that names a tool and was allowed, and nothing
else. A request a path rule refused names the tool too, the tool whose host it was for,
but it never reached the tool: it is no tool invocation. A connection refused on its host,
by a deny rule, the wall's guard or the allow list, never reaches the point where requests
are read: it names no tool and reads as a plain connection to the host.

Wherever a connection is shown, a tool invocation reads as a call to its tool:

- The row leads with the tool's name, then the request line (method and path), then the
  host, faint.
- The reason says the request was **handed to** the tool, by the host's rule and the path
  rule that let it through. A request the rules let through that did not reach the tool,
  because the tool was not running or a reload closed the connection, says **for** the
  tool instead.
- A request refused on its path reads as any denial: the host leads, the reason is that
  of the denial, and it adds that the request was refused before reaching the tool.
- The outcome is **Answered** with the status the tool gave, or **Handed over** when no
  answer is recorded. A tool that is not running is a **Dial failed**, and a refusal is
  **Refused**, as for any host. A host whose requests the proxy reads shows the status it
  answered beside **Connected**.
- On the run's timeline, allowed requests to one tool in a row fold into one line that
  names the tool, "2 allowed requests"; a refused one is never folded away, and the row of
  one request carries the proxy's id of it on hover.
- The run's policy applied item and the policy in force on its Details tab list the tools,
  each with its argument beside its name when the policy passed one, and the hosts each
  serves.
- On Network access, `/:org/:workspace/network`, **Tool invocations** keeps only the
  destinations where a run's last attempt was a tool invocation, each whole: its counts
  are the same as without the filter. A destination where every run's last attempt was
  refused is not among them.
- The list of what enforce would start denying and the overview's denied destinations
  name a destination's tool, first, whenever a request to it named one, handed to the
  tool or refused by a path rule: a refused request to a tool is a denied request to
  that tool, and shows its refusal as any destination does.

**Allow** and **Deny** on a tool invocation's row act on its host and path, like on any
row: the rules decide what reaches a tool, and the tool decides what the request does.

## Export for a node without a server

A machine that reports to no server can be given the same policy as files. **Export**, on
the policy page and on a version's page, `/:org/:workspace/policy/versions/:n/export` and
`/:org/:workspace/targets/:forge/:path/-/policy/versions/:n/export`, gives the effective
policy of that version as text, with **Download**:

- the `egress` section for the machine's runner file, which says a mode, the hosts
  allowed, the hosts denied and nothing else;
- when the policy has paths, a policy file in the contract's own format,
  given to one run with `qory run --policy <file>`. It narrows the runner file's section and
  never widens it, so the two are exported together and agree.

```yaml
# ~/.config/qory/runner.yaml
egress:
  mode: enforce
  allow:
    - "api.example"
  deny:
    - "tracker.example"
```

The export is a copy: it does not follow later changes. Keep a policy file outside the
checkout. Deny rules and locks are already applied: the files list what is denied and
what remains allowed.
With a server configured, `qory run` refuses `--policy` unless `--local` is given too.

## Limits

| Limit | Value |
|---|---|
| Rules in a list, the workspace's baseline or one repository's | 500 |
| Paths in a rule | 100 |
| A rendered run configuration | 1 MiB, the most a runner reads of a document |

A change that would pass a limit is refused, and nothing is changed.

## The first change

Until somebody has made the workspace's policy:

- the server's discovery document names no `run` section for the workspace's machines;
- the run configuration endpoint answers `404` for the workspace's keys;
- every machine runs under the `egress` section of its own runner file, in its own mode,
  enforcement included;
- the policy page says: "Runs use each machine's own policy until the first change here."

The first rule or the first change of mode, the workspace's or a repository's, is the
moment the workspace takes over:

- for every machine under the workspace's access keys, and for the runs in flight, which
  reload within a heartbeat;
- entirely: from then on the workspace's policy is the policy, and a machine's own
  `egress` section is not merged with it;
- in the mode the workspace is in, which is observe until an owner or an admin sets it. A
  machine that enforced a list of its own is, after the first change, under a workspace
  that observes and denies only what a deny rule names, until an owner or an admin
  switches the workspace to enforce.

So before the first change:

1. Collect what the machines' own lists say, the `egress.allow` of every runner file.
2. Say all of it in the workspace. The first rule you add already takes over, so add the
   rest straight after it; while the workspace is in observe only what a deny rule names
   is denied in between.
3. When the rules are complete, an owner or an admin switches to enforce. The confirmation lists what
   would start being denied, from the record.

To keep one machine on its own policy, start its runs with `qory run --local`: the run is
recorded to files only, under the machine's policy, and the server is not contacted, so
that run does not appear in the console.

It does not go back by removing the rules. A workspace that was given a policy keeps
serving it: with every rule removed it serves an empty policy, under which a run in
enforce mode reaches nothing.
