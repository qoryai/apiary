# Retention

A workspace keeps everything its runs sent until an owner says otherwise. Retention is two
settings of the workspace, each a number of days or empty for unlimited, and a nightly job
that deletes what is older and says what it deleted.

## The two settings

On **Settings**, `/workspace/settings`, under **Retention**. Only owners change them;
members read them.

| Setting | What it limits | Default |
|---|---|---|
| Keep a run's events for | the events of a run: its timeline, the policy it applied, the record behind its connections, and its log output, which the events carry | empty: for ever |
| Keep a run's log output for | the bytes the run wrote to its terminal, which are most of what a run stores | empty: for ever |

Each is a whole number of days from 1 to 3650. The log output is carried by a run's events,
so it cannot be kept longer than they are: a log setting above the events setting is
refused. The usual shape is a short time for the log output and a long one, or none, for the
events.

A self-hosted instance starts with both empty, and an upgrade never sets them: nothing is
pruned until an owner asks for it.

## What is pruned, and what stays

Retention works on whole runs, so a timeline is never half there.

A run is due when it is not alive (it succeeded, failed, timed out, was lost or was closed) and
the server last received an event of it before the cut-off. Only the server's clock is
compared, never the time a runner wrote into an event. A run that is still running is never
pruned, however long it has run.

- **Past the days for log output** the run loses its log: the terminal tab says *Log output
  pruned* and the date. The timeline, the connections and the details are whole.
- **Past the days for events** the run loses all its events, its log output and the
  receiver's record of the batches that delivered them. The timeline says *Events pruned*
  and the date; it is never an empty timeline without a sentence.

What stays, in both cases, is the run itself: its row in the runs list with its state, what
it worked on, its runtime, host, start, duration and exit, the number of events it sent and
the number of connections it was denied, and its connections, one row per destination with
the attempts, the decision, the rule and the outcome of the last attempt. The workspace's
connections page reads those rows and is unchanged.
<!-- feature: security -->
So are the counts on the policy pages.
<!-- /feature -->

A pruned run takes nothing more. A runner that delivers a batch of it again, from a spool
that outlived the retention, is answered `410` once the events are pruned, as for a run
the workspace closed, and nothing is stored. A run that lost only its log output still
takes its other events, without storing one twice, and no log event.

A run whose events are pruned cannot be projected again, because a projection is rebuilt
from events. `mix apiary.rebuild` and `Apiary.Release.rebuild/1` never select such a run,
and leave alone a run that is due to be pruned, so a rebuild never wipes what is left of it.
A run that lost only its log output is rebuilt from the events it still has.

> #### Pruned data comes back only from a backup {: .warning}
>
> The job deletes rows. Nothing is archived first. If the events may be needed later, take
> the [backup](backup.md) before shortening a setting, and keep it for as long as they may
> be needed.

## The nightly job

`Apiary.Retention.Scheduler` runs in every instance. It wakes at three o'clock UTC plus a
random part of an hour, and prunes every workspace that has a setting.

- With several nodes, one prunes: the job takes a Postgres advisory lock, and a workspace
  pruned in the last twelve hours is left alone by the node that wakes second.
- Every delete is one statement over at most 2,000 rows of one run, found through an index,
  in its own short transaction. No statement scans `events`, and none holds a lock for longer
  than its batch, so the receiver keeps writing while the job runs.
- One night prunes at most 10,000 runs of a workspace, oldest first, and the next night
  goes on. The first night after a setting is shortened is the long one.
- Postgres reuses the space of deleted rows; it does not give it back to the operating
  system. The database's files stop growing, they do not shrink. `VACUUM FULL` or
  `pg_repack` gives the space back, and neither is needed for the instance to work.

## What it says

Every run of the job writes one row per workspace, and the settings page lists the last
five under **Pruned**: when, how many runs, how many events, how much log output in how
many chunks, and the dates before which it pruned. A row is marked *By hand* when it came
from the task below, and *Not finished* when the job stopped at its bound or a run failed;
the next night goes on from there.

The same is one line in the server's log per workspace:

```text
retention pruned workspace=6f1c… trigger=schedule runs=12 events=48210 log_chunks=9120 log_bytes=73400320 deliveries=640 events_cutoff=2026-06-01T03:12:44Z log_cutoff=2026-08-02T03:12:44Z complete=true duration_ms=8450
```

A run that could not be pruned is `retention failed run=<id> error=<kind>`, without any of
the run's data, and a night when another node held the lock is `retention skipped
reason=locked`.

## By hand

In a checkout, `mix apiary.prune` runs the job now; `mix apiary.prune --dry-run` deletes
nothing, records nothing and prints the same counts. In a release, where there is no Mix:

```sh
docker compose exec apiary bin/apiary eval "Apiary.Release.prune(dry_run: true)"
docker compose exec apiary bin/apiary eval "Apiary.Release.prune()"
```

A dry run is the way to see what a new setting will do before the night does it. Both are
safe beside the running server, and refuse to start while the nightly job is at work.

## The hosted instance

The hosted instance's defaults are decided at its launch and are not the self-hosted
defaults. A self-hosted instance keeps everything unless told otherwise.
