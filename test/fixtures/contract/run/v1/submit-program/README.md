# The submit program

A submit program opens the draft of a run's submission on a forge, and prints
the forge's address of each commit. A draft is a pull request or a merge request that
people can still change before it is ready. qory runs the program only on a run that has
no run code: a person starts `qory run`, and the program uses the login of the forge's
command line, such as `gh`, that the person made. A run that qory starts from a run code
runs no program: the forge's adapter puts the submission on the forge from the change
feed (`contracts/integration/v1/changes.schema.json`, the `submission` entry).

The contract has plain inputs and plain lines back. The program needs no JSON tool.

## Finding the program

The program is the `submit_program` key of the manifest of the forge's harness module,
`{command: [<path>, <argument>, ...]}`. The module is one that the person's `qory.yaml`
composes. `<path>` is relative to the module's directory, and the arguments that follow
it are the program's arguments. This is the harness module contract's key, not a member
of the run documents or of the adapter's start-up: neither document mentions the module.

## Inputs

qory runs the program once for each repository of the submission, with the arguments of
`submit_program` and no other, and sets these environment variables. Each value is on one
line, except where the table shows another form. Only a write run gets a draft.

| Variable | Value |
|---|---|
| `QORY_SUBMIT_SYSTEM` | the host name of the repository's system, such as `code.example.com` |
| `QORY_SUBMIT_PATH` | the repository's path on the system, such as `acme/shop` |
| `QORY_SUBMIT_BRANCH` | the branch that qory makes for the run: `qory/run-<run id>`, or `qory/run-<run id>-2`, `-3` and so on when that name is taken, or `qory-run-<run id>` when a branch named `qory` exists. The head of the draft, already pushed when the program starts; the program reads it and assumes no name |
| `QORY_SUBMIT_BASE_BRANCH` | the branch that the draft is based on. Unset when qory did not read it; a program that has `QORY_SUBMIT_DRAFT` `open` and no base branch exits with status 2 |
| `QORY_SUBMIT_BASE_COMMIT` | the commit that the run started at, 40 or 64 lower-case hexadecimal digits |
| `QORY_SUBMIT_COMMITS` | the run's commits from the base to the head, oldest first: full commit ids joined by single spaces, 1 to 100 |
| `QORY_SUBMIT_DRAFT` | `open` or `none`. `none` when the run has no hand-off text |
| `QORY_SUBMIT_TITLE` | the title of the draft, from the run's hand-off text, 1 to 256 characters on one line. Unset when `QORY_SUBMIT_DRAFT` is `none` |
| `QORY_SUBMIT_DESCRIPTION_FILE` | the path of a UTF-8 file with the description text from the run's hand-off text, at most 20000 characters, over several lines, with no marker line: the program adds the markers. Unset when `QORY_SUBMIT_DRAFT` is `none` |

A run with no run code has no work item and no earlier submission. qory pushes the run's
branch with the person's git login before it runs the program, and the program pushes
nothing. The branch is `qory/run-<run id>`, `qory/run-<run id>-2`, `-3` and so on when
that name is taken, or `qory-run-<run id>` when a branch named `qory` exists, so a program
reads the name from `QORY_SUBMIT_BRANCH`. Before each push qory checks the run's commits
as it does for a run that it starts from a run code: for a key or a value of the run's
secrets, and for a change to a file that the session may not change
(`outcome.schema.json`, the end codes `push_key_found` and `push_scope_refused`). If a
check refuses, qory pushes nothing and runs no program. After a push that succeeded, the
program only opens or edits the draft, so exit status 1 means that a call to the forge
failed, and the program never exits with a push failure.

The description is a file because it has several lines. Standard input is an empty file
such as `/dev/null`: a command that reads it gets end of file at once. A program that
starts `gh` or `git` passes its standard input on, so no command waits for input or takes
the text from it. `gh pr create` and `gh pr edit` read a body from a file with
`--body-file`.

With `QORY_SUBMIT_DRAFT` `none`, as after a session that did not pass, the program makes no
draft and prints only the address of each commit. qory leaves out each draft line that a
program prints then. With `open`, the program first looks for the drafts from `QORY_SUBMIT_BRANCH` and the
repository, in any state, so a draft that exists is not opened a second time. With
several drafts, it takes the not-closed, not-merged draft with the highest number; with
none, the closed or merged one with the highest number, which it reports with
`draft_action` `kept` and leaves as it is. Any other draft is edited: its description
follows the rules below, and its title stays, because the program never changes the
title of a draft that it finds and a run with no run code has no previous title. The
program edits a draft only while it is `draft` or `open`. There is no input for the
number of a draft or for a previous title, because a run with no run code has no earlier
submission.

## Credentials

The program uses the forge command line's login of the person who runs qory. qory gives
the program no credential, no access token and no proxy address, and no input in the
table of inputs is a secret. The program reads no credential from qory. If the person is
not logged in to the forge's command line, the program exits with status 3 and prints, as
the first line on standard error, the command that logs in. For a forge whose command
line is `gh`, that line is:

```text
Run `gh auth login`, then `qory run` again.
```

A program for another forge prints the login command of that forge's command line in the
same form.

## The result lines

The program prints its result on standard output, one line for each fact, each ending in
a line feed. The line is a key, a space and the value; the value is the rest of the
line.

| Key | Value |
|---|---|
| `draft_number` | the draft's number: 1 to 9 digits, no leading zero |
| `draft_url` | the draft's address |
| `draft_title` | the draft's title after the call, 1 to 256 characters |
| `draft_state` | `draft` while the forge shows the draft as not ready for review, `open` once it shows it as ready, `closed` when a person closed it without merging, `merged` once it is merged |
| `draft_action` | `opened`, `updated`, or `kept` when the program changed nothing; a draft that is `closed` or `merged` always has `kept` |
| `commit_url` | a commit id from `QORY_SUBMIT_BASE_COMMIT` or `QORY_SUBMIT_COMMITS`, a space, and the forge's address of that commit |

An address is an `https` address of at most 2048 characters, on the host in
`QORY_SUBMIT_SYSTEM`, with no user information, port, query or fragment, and with a path.
qory checks no more of its form, so the same program contract serves a forge whose
addresses end in `/pull/<number>` and one whose addresses end in
`/-/merge_requests/<number>`.

An address passes the pattern of `$defs.url` in `contracts/integration/v1/definitions.schema.json`,
the one that the adapter's reply has: the scheme is `https` in lower case, and the
address has no double quote, no `<`, `>`, `{`, `}`, `|`, `^`, backtick or backslash, no space and
no character outside ASCII. `draft_title` has the rule of `$defs.draft_title` in the same
file: UTF-8, no control character, no bidirectional control, no line or paragraph
separator, no invisible format character, and at least one character that is not a space.

Each line ends in a line feed, or in a carriage return and a line feed: qory strips one
carriage return at the end of each line before it reads the line.

qory records the draft only when all five `draft_` lines are there and valid, and
`draft_action` is `kept` for a draft that is `closed` or `merged`. It records a
`commit_url` line for each commit that it gave the program, once. qory leaves out each line
that is not valid and reads the lines around it. These lines are not valid:

- a key that the table does not list, or a key with no value;
- a line with a control character, or a last line with no line feed;
- a second valid line with a `draft_` key, or a second valid line for a commit: the first
  valid line stays, and an earlier line that is not valid does not count;
- a `commit_url` for a commit that qory did not give the program;
- a value that breaks its rule in the table;
- a `draft_` line when `QORY_SUBMIT_DRAFT` is `none`;
- each `draft_` line of a draft that lacks one of the five lines: qory records no draft,
  and lists the lines that it left out;
- the `draft_action` line of a draft whose `draft_state` is `closed` or `merged`, when it is not
  `kept`: qory records no draft.

A blank line is left out and is not an error. Diagnostics go to standard error.

## Exit status

For a draft that it asked for and the program did not make, qory records a reason in its
record of the run, for the repository that the program ran for. It records nothing for
`QORY_SUBMIT_DRAFT` `none`.

| Reason | When |
|---|---|
| `program-failed` | the program ended with status 0, 1 or 2 and printed no whole draft, or it did not start, or it ended with a signal or a status that the table does not list; it has `exit`: the exit status, or 1 when the program did not start or ended with a signal or an unlisted status |
| `program-timeout` | the program ran past the time limit; it has no exit status |
| `login-needed` | the program ended with status 3; it has `exit` 3 |

| Exit | What qory records |
|---|---|
| 0 | the program finished: the draft and the addresses from the valid lines; `program-failed` with `exit` 0 when the lines make no draft |
| 1 | a call to the forge failed: the valid lines, and for a draft that they do not make, `program-failed` with `exit` 1 |
| 2 | the program could not use its inputs: the valid lines, and `program-failed` with `exit` 2 for a draft that they do not make |
| 3 | the person has no login of the forge's command line: no line is read, and the reason is `login-needed` |
| another status, or the program did not start | no line is read, and the reason is `program-failed` with `exit` 1 |

The time limit is 120 seconds. qory stops a program that runs longer, so a local
`qory run` never waits on the program for more. The record is `program-timeout` with no
exit status, and qory reads no line, whatever the program printed and whatever status
the stopped program ended with. A program that a signal ended for another reason is in the
last row of the table.

A reader of qory's record cannot tell a program that did not start, or ended with another
status or a signal, from a program that exited with status 1 and printed no draft: all are
`program-failed` with `exit` 1. qory prints a different message on standard error for
each.

A program that exits with status 1 or 2 and has printed a whole draft is recorded as a
success: the draft is recorded as for exit 0, and the record keeps no exit status. qory
does not flag a commit that has no `commit_url` line.

`contracts.ReadSubmitRun` is the same rule in Go.

## What qory prints

qory prints at most 20 lines of the program's standard error, with secrets masked and
prefixed `qory run: submit program: `. It does not print the result lines, so a
repository of 100 commits does not take the 20 lines.

## The description's block

The run's text sits in the description of the draft between two marker lines, each alone
on its line:

```text
<!-- qory:start -->
The page lists open orders.
<!-- qory:end -->
```

The program writes the draft's description as follows. It reads the draft's description
from the forge first. A line is a marker line when it is the marker followed by nothing
but spaces, tabs or a carriage return.

1. For an `open` where no draft exists, the description is the block: the start marker
   line, the text of `QORY_SUBMIT_DESCRIPTION_FILE`, the end marker line.
2. For a draft that exists, the program takes the first end marker line that has a start marker
   line before it, and the last start marker line before that end line. It replaces the
   text from the start of the start line to the end marker with the new block, and keeps
   every other byte, the spaces, tabs and carriage return after the end marker included.
   A start marker line that a person left alone, with no end marker line after it,
   stays; the block that qory wrote comes after it and is the pair the next edit
   replaces.
3. For a draft that exists, if no such pair exists, as when a person removed a marker, the
   program keeps the description whole and adds a blank line and the new block at the end.
   When the description is empty, the block alone is the new description, with no blank
   line before it.
4. The new block uses the line ending of the description: CRLF when the first line ending
   of the description is CRLF, otherwise LF. Only the line endings that the program adds
   use it: the ones next to the two marker lines, and the blank line before a block added
   at the end. The line endings inside the text of `QORY_SUBMIT_DESCRIPTION_FILE` stay as
   given.

`contracts.MarkedDescription` is the same rule in Go, and `fixtures/description/` contains
plain-text cases: for each case, the draft's description before (`existing.md`), the text
(`text.md`) and the description after (`result.md`).

## The draft's title

A new draft has `QORY_SUBMIT_TITLE`. The program does not change the title of a draft
that it finds, because a run with no run code has no previous title to compare it with.

## Examples

A repository on a forge whose draft is a pull request, with the program given
`QORY_SUBMIT_DRAFT=open`, prints
[`fixtures/output/github-like.txt`](fixtures/output/github-like.txt):

```text
draft_number 34
draft_url https://code.example.com/acme/shop/pull/34
draft_title Show delivery dates at checkout
draft_state draft
draft_action opened
commit_url 3e2d1c0b9a8f7e6d5c4b3a291807f6e5d4c3b2a1 https://code.example.com/acme/shop/commit/3e2d1c0b9a8f7e6d5c4b3a291807f6e5d4c3b2a1
commit_url 9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c https://code.example.com/acme/shop/commit/9f8e7d6c5b4a39281706f5e4d3c2b1a09f8e7d6c
```

A repository on a forge whose draft is a merge request prints
[`fixtures/output/gitlab-like.txt`](fixtures/output/gitlab-like.txt), with `-/` in its
addresses. A draft that a person closed or merged is in
[`fixtures/output/closed-kept.txt`](fixtures/output/closed-kept.txt) and
[`fixtures/output/merged-kept.txt`](fixtures/output/merged-kept.txt): `draft_state` is `closed`
or `merged`, and `draft_action` is `kept`. The directory `fixtures/output/` also contains
`invalid-` files, each with a line that qory leaves out, and the test checks the reason
for each.

## Fixtures

| Path | Contains | Checked by |
|---|---|---|
| `fixtures/output/*.txt` | result lines that qory records whole | `contracts.ParseSubmitLines` |
| `fixtures/output/invalid-*.txt` | result lines with a line that qory leaves out | `contracts.ParseSubmitLines` |
| `fixtures/description/<case>/` | a draft's description before and after an update | `contracts.MarkedDescription` |
