defmodule Apiary.Runs.Preparation do
  @moduledoc """
  How a run went from its queue to the removal of its machine, as the **Run** list in the
  run's Timeline and the run's diagnostics show it: how its machine was prepared, from
  the machine request to the start of its session, how the session ended, what the run
  pushed, and the removal of the machine. Read from records Qory Apiary keeps for every
  run: the run's dispatch and its run of the queue, its steps (`Apiary.Runs.Step`) with
  their log lines, its `dev.qory.session.started` events and the events that end its
  sessions, and the artifact versions it pushed.

  An agent session is a session that runs an agent: every session but a bare one, whose
  `dev.qory.session.started` has `bare: true`, and one whose wall failed, which never ran
  its agent. A bare session is a helper that `qory run` starts with no runtime, such as
  the one that copies the run's work back from the wall.
  A helper step is a step of the kind `copy`, or a `join` or a `wall` of a bare session:
  one whose start lies inside a `copy` step by sequence, a join followed by a bare
  session's start, or a wall that follows one with no join of an agent session between
  them. The run page shows no helper step.

  `read/2` returns a map with twelve members:

    * `machine`: the dispatch whose claim registered the run, nil for a run no node
      pool claimed. `queued_at` is when the run of the queue began to wait for this
      claim, `requested_at` the claim, and `requested_ms` the time from the claim to the
      starter's `dispatched`; `started_as` is the vendor's type of the machine that
      `dispatched` reported, for an instance admin alone; `started` spans from that
      `dispatched` to the redemption of the run's code, or to the failure that ended the
      attempt; `end` is what the pool's starter last reported about the removal of the
      machine, nil while it has reported nothing; `removal_cause` is why the machine was
      removed (`t:machine/0`).
    * `steps`: the run's steps of every kind but `push` and `copy`, by number, each with
      its output:
      its last log lines as plain text (`Apiary.Runs.Record.plain_line/1`), at most 64 KiB
      and 2,500 lines, each with its number in the step and its time, and whether that is
      cut (`t:output/0`). The output is nil for a reader who may not read the run's log
      (`run.read_log`), and empty once retention deleted the run's log lines.
    * `after_session`: the run's `push` and `copy` steps by number, in the same shape.
      Both run after the last agent session, so they are no part of the preparation:
      `machine` and `stopped` are read from `steps` alone, and a failed push or copy is no
      failed preparation.
    * `log_pruned_at`: when retention deleted the run's log lines (`runs.log_pruned_at`),
      nil while they are kept.
    * `sessions`: the run's agent sessions in the order they started, each with how it
      ended (`t:session/0`); none before the first starts and once retention deleted the
      run's events.
    * `unrun`: the sessions whose wall failed after their start, which never ran their
      agent, each with its number and the sequence of its start (`t:unrun/0`).
    * `session_started_at`: when the first agent session started; nil before it starts
      and once retention deleted the run's events.
    * `session_end`: how the last agent session ended (`t:session_end/0`); for a run with
      no `dev.qory.session.started` at all, how its session ended, from the run's last
      `dev.qory.runtime.result` and `dev.qory.session.exited`; nil while it has neither.
    * `outputs`: the artifact versions the run pushed, in the order they were pushed
      (`t:output_version/0`).
    * `stopped`: why the preparation failed, nil while it has not (`t:stopped/0`).
    * `prebuild`: whether the run is a prebuild, a run of the queue for the step
      `prebuild` that builds a collection's environment (`dispatch_runs.step`); false for
      a run no queue started. A prebuild builds its image in one session that `qory`
      starts with no agent, which Forager may mark bare: the session of a prebuild is
      read as an agent session, bare or not, so its join and wall are no helper steps.
    * `built`: for a prebuild, how it saved its image (`t:built/0`): its first
      `dev.qory.run.built` by sequence, `at` its time, `image` the image it reports, nil
      when that is no text, and `refused` why the report fails the check that stores it,
      as Apiary.Dispatches.Built returns it, nil when it passes; else, once the prebuild
      failed after its build session exited with success, `at` the run's exit, no image,
      and `refused` `:not_sent`, as `qory` sends no report when its check of the build's
      result fails; or once it was lost or cancelled after that build, `at` when it was
      found lost or its exit, and `refused` `:lost` or `:cancelled`. `fix` is what the
      reader of `scope` does about an image not saved (`t:built_fix/0`). Nil otherwise,
      and for any other run.

  Every read is scoped as `Apiary.Runs.Record` scopes it: the scope's organisation and
  workspace, and the run's row id.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, only: [from: 2]

  alias Apiary.{Access, ExternalText, Repo, SecretLogFilter}
  alias Apiary.Accounts.Scope
  alias Apiary.Artifacts.Version
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.{Record, Run, Step, Waiting}

  # The most of a step's output that is kept, in bytes of UTF-8, and in lines: the page
  # draws about 330 bytes of markup for each line, so 2,500 lines and their 64 KiB stay
  # under 1 MB.
  @output_bytes 65_536
  @output_lines 2_500

  # The kinds of step whose failure lies on the pool's machine. A failure of any other step
  # lies in the workspace: its targets, harness, build and set-up, and a kind outside the
  # contract's list counts as the workspace's.
  @pool_kinds ~w(image join wall machine)

  # The kinds of step that run after the last agent session: the push of the run's work,
  # and the copy of it back from the wall.
  @after_kinds ~w(push copy)

  @typedoc "Where the cause of a failure lies, by who can fix it."
  @type fixer :: :support | :operator_admin | :workspace_admin

  @typedoc "Why a preparation failed."
  @type cause ::
          :machine_not_made | :lease_lapsed | :code_not_redeemed | :machine_stopped | :step_failed

  @typedoc """
  The pool that claimed the run: its public id, its name, and where it lives:
  `:instance` for the instance's pool, `:workspace` for a pool of the run's workspace,
  `:operator` for a pool of another organisation, whose name is `operator`.
  """
  @type pool :: %{
          id: String.t(),
          name: String.t(),
          place: :instance | :workspace | :operator,
          operator: String.t() | nil
        }

  @typedoc """
  What the pool's starter last reported about the removal of the machine, at
  `POST /v1/dispatches/<dispatch_id>/machine-end`: `deleting`, the removal was requested
  and the machine may still exist; `gone`, the starter confirmed that the machine no
  longer exists; `delete_failed`, the removal failed and the machine still exists. `at`
  is when Qory Apiary accepted the report.
  """
  @type machine_end :: %{state: :deleting | :gone | :delete_failed, at: DateTime.t()}

  @typedoc """
  Why the machine was removed: `:keep_alive_lost` for a run that was lost
  (`runs.lost_at`), `:run_ended` for a run that exited (`runs.exited_at`), nil for any
  other run.
  """
  @type removal_cause :: :keep_alive_lost | :run_ended | nil

  @typedoc """
  The machine part. `dispatch_id` is the dispatch's public id, `dp_…`. `queued_at` is when
  the dispatch's run of the queue began to wait for this claim: its `queued_at`, or when
  an earlier dispatch of it that put it back in the queue was released or lapsed;
  nil for a dispatch with no run of the queue. `machine_type` is the machine type the
  claim answer had: its key, the name of the type that has the key today (nil where no
  type has it), and its spec as the provisioner contract writes it; nil for an answer to
  a claim with no offers, which has none. `requested_ms` is nil while the
  dispatch has no `dispatched`. `started_as` is the vendor's type of the machine the
  starter created, as its first `dispatched` reported it, for a reader who is an instance
  admin (`Apiary.Access.instance_admin?/1`); nil for anyone else, and while the starter
  reported none. `release_reason` is the starter's reason of a release, nil for any
  other dispatch. `started.state` is `running`, `succeeded`, `failed` or `cancelled`, as
  a step's. `handed_over_at` is when the dispatch was handed over, so a machine existed
  for it, nil for a dispatch never handed over. `ended_at` is when the dispatch ended
  with its run; for a run that ended before its dispatch did, the run's exit, loss or
  failed start, or else its last change; nil while both go on. `end` is the starter's
  last report about the removal of the machine, nil before the first
  (`t:machine_end/0`), and `removal_cause` why the machine was removed
  (`t:removal_cause/0`).
  """
  @type machine :: %{
          dispatch_id: String.t(),
          pool: pool,
          queued_at: DateTime.t() | nil,
          machine_type: %{key: String.t(), name: String.t() | nil, spec: map} | nil,
          requested_at: DateTime.t(),
          requested_ms: non_neg_integer | nil,
          started_as: String.t() | nil,
          release_reason: String.t() | nil,
          handed_over_at: DateTime.t() | nil,
          ended_at: DateTime.t() | nil,
          end: machine_end | nil,
          removal_cause: removal_cause,
          started: %{
            state: String.t(),
            started_at: DateTime.t() | nil,
            ended_at: DateTime.t() | nil,
            duration_ms: non_neg_integer | nil
          }
        }

  @typedoc """
  One line of a step's output: its number in the step, from 1; its time, the time of the
  `dev.qory.run.log` event the line began in, nil once retention deleted the run's events;
  and its text.
  """
  @type line :: %{number: pos_integer, at: DateTime.t() | nil, text: String.t()}

  @typedoc """
  A step's output: `lines`, the last lines with their numbers and times, at most 64 KiB
  joined by line feeds and at most 2,500 lines; `truncated`, whether the start of the
  output is cut; and `lines_cut`, whether the cut is the one of 2,500 lines.
  """
  @type output :: %{lines: [line], truncated: boolean, lines_cut: boolean}

  @typedoc """
  One step. `name` is qory's name with its first letter in upper case, nil when only the
  step's exit is recorded, as `started_at` and `started_sequence` are; `sent_name` is the
  name as qory or Forager sent it, for `step_detail/1`. `helper` is whether the step is
  a helper step (the moduledoc). A join of a prebuild also has `prebuild: true`.
  """
  @type step :: %{
          optional(:prebuild) => true,
          number: pos_integer,
          name: String.t() | nil,
          sent_name: String.t() | nil,
          kind: String.t() | nil,
          state: String.t(),
          exit_code: integer | nil,
          started_at: DateTime.t() | nil,
          exited_at: DateTime.t() | nil,
          started_sequence: integer | nil,
          exited_sequence: integer | nil,
          duration_ms: non_neg_integer | nil,
          helper: boolean,
          output: output | nil
        }

  @typedoc """
  Why the preparation failed: the cause, the number of the failed step for `:step_failed`
  (nil for any other cause), who can fix it, and the cause line: `text`, what happened
  and who fixes it, `what`, its first sentence alone, and `fix`, its second. `detail` is
  the part of qory's step name that the step's label leaves out (`step_detail/1`), in
  parentheses at the end of `what`; nil when there is none.
  """
  @type stopped :: %{
          cause: cause,
          step: pos_integer | nil,
          fixer: fixer,
          text: String.t(),
          what: String.t(),
          fix: String.t(),
          detail: String.t() | nil
        }

  @typedoc """
  How a session ended. `result_at` is the time of the session's last
  `dev.qory.runtime.result`, and `outcome`, `turns`, `duration_ms` and `cost_usd` are
  from it, nil without one. `exited_at` is the time of the session's last
  `dev.qory.session.exited`, and `state` and `exit_code` are from it, nil without one.
  `model` is the model of the session's last `dev.qory.runtime.started`, nil without
  one. An event belongs to the session whose number its `session` has; an event with no
  `session`, as in a record written before Forager sent it on every runtime event, to
  the last agent session that started before it. An event of a bare session belongs to
  none.
  """
  @type session_end :: %{
          result_at: DateTime.t() | nil,
          outcome: String.t() | nil,
          turns: integer | nil,
          duration_ms: integer | nil,
          cost_usd: number | nil,
          exited_at: DateTime.t() | nil,
          state: String.t() | nil,
          exit_code: integer | nil,
          model: String.t() | nil
        }

  @typedoc """
  An artifact version the run pushed: its artifact's type and name, its number, when it
  was pushed, and the version's public id.
  """
  @type output_version :: %{
          type: String.t(),
          name: String.t(),
          number: pos_integer,
          at: DateTime.t(),
          public_id: String.t()
        }

  @typedoc """
  An agent session: its number (`session` of its `dev.qory.session.started`, nil
  without one), the sequence and the time of that start, its runtime (`runtime` of that
  start, nil when it has none that is text), and how it ended, nil while it has neither a
  result nor an exit (`t:session_end/0`).
  """
  @type session :: %{
          session: pos_integer | nil,
          sequence: integer,
          started_at: DateTime.t(),
          runtime: String.t() | nil,
          end: session_end | nil
        }

  @type unrun :: %{session: pos_integer | nil, sequence: integer}

  @type t :: %{
          machine: machine | nil,
          steps: [step],
          after_session: [step],
          log_pruned_at: DateTime.t() | nil,
          sessions: [session],
          unrun: [unrun],
          session_started_at: DateTime.t() | nil,
          session_end: session_end | nil,
          outputs: [output_version],
          stopped: stopped | nil,
          prebuild: boolean,
          built: built | nil
        }

  @type built :: %{
          at: DateTime.t() | nil,
          image: String.t() | nil,
          refused: atom | tuple | nil,
          fix: built_fix | nil
        }

  @typedoc """
  What the reader does about a prebuild's image that was not saved, by why it was not
  and who reads it:

    * `:machine_log`: for an instance admin, the cause of a build whose image never
      arrived is in the machine log, under Start the machine.
    * `{:pool_log, pool}`: for anyone else, on a pool of the run's workspace, it is in
      the log of the pool named `pool` on its host.
    * `{:operator_log, operator, pool}`: on a pool of another organisation, named
      `operator`, an admin of it reads that log.
    * `{:support, run}`: on the instance's pool, and for a report whose form or run does
      not pass the check, support, given the run's public id `run`.
    * `{:rebuild, target}`: for a run whose documents have no destination, a reader who
      may rebuild the environment of the run's target, `target`
      (`target.rebuild_environment`), rebuilds it.
    * `{:ask_rebuild, workspace, target}`: a reader who may not asks an admin of the
      workspace, named `workspace`.

  Nil where the reader has nothing to do: the line shows the values that differ.
  """
  @type built_fix ::
          :machine_log
          | {:pool_log, String.t()}
          | {:operator_log, String.t(), String.t()}
          | {:support, String.t()}
          | {:rebuild, String.t()}
          | {:ask_rebuild, String.t(), String.t()}

  @doc """
  The preparation of `run` for the reader of `scope`: the moduledoc. `opts`:

    * `log`, whether the steps' output is read, by default whether `scope` may read the
      run's log (`run.read_log`). `Apiary.Runs.Diagnostics` sets it for a diagnostics
      key, which reads every run's log and has no scope in the run's workspace.
    * `release_reason`, how `stopped`'s text has the pool's release reason: `:filtered`,
      by default, through the secret filter (`Apiary.SecretLogFilter.filter_text/1`), as
      the run page's header has it; `:as_stored` for the diagnostics document, which
      keeps every text as stored.
  """
  @spec read(Scope.t(), Run.t(), keyword) :: t
  def read(%Scope{} = scope, %Run{} = run, opts \\ []) do
    attempt = attempt(scope, run)
    log? = Keyword.get_lazy(opts, :log, fn -> Access.can?(scope, :"run.read_log", run) end)
    kept? = is_nil(run.log_pruned_at)
    prebuild = prebuild?(scope, run)
    starts = Record.session_starts(scope, run)
    starts = if prebuild, do: Enum.map(starts, &%{&1 | bare: false}), else: starts
    every = for step <- Record.steps(scope, run), do: step(scope, run, step, log?, kept?)
    every = helpers(every, starts)
    every = if prebuild, do: Enum.map(every, &prebuild_step/1), else: every
    {after_session, steps} = Enum.split_with(every, &(&1.kind in @after_kinds))
    starts = unrun(starts, steps)
    ends = Record.session_end_events(scope, run)
    sessions = sessions(starts, ends)
    session_started_at = sessions |> List.first() |> then(&(&1 && &1.started_at))
    machine = machine(scope, run, attempt, steps, session_started_at)
    session_end = last_end(starts, sessions, ends)

    %{
      machine: machine,
      steps: steps,
      after_session: after_session,
      log_pruned_at: run.log_pruned_at,
      sessions: sessions,
      unrun:
        for(
          %{unrun: true, bare: false} = start <- starts,
          do: Map.take(start, [:session, :sequence])
        ),
      session_started_at: session_started_at,
      session_end: session_end,
      outputs: outputs(scope, run),
      stopped:
        stopped(
          scope,
          run,
          attempt,
          machine,
          Enum.reject(steps, & &1.helper),
          Keyword.get(opts, :release_reason, :filtered)
        ),
      prebuild: prebuild,
      built: if(prebuild, do: built(scope, run, session_end, machine)),
      queued: if(is_nil(machine), do: queued(scope, run))
    }
  end

  # A queued run (`Apiary.Runs.Run.queued?/1`): when it began to wait, its record's
  # `inserted_at` (`Apiary.Dispatches.Queued`), the machine type it was queued on, and why
  # it waits (`Apiary.Runs.Waiting`); the run's public id, and whether the reader is an
  # instance admin, for who fixes why it waits. Nil for any other run.
  defp queued(scope, %Run{dispatch_run_id: id, workspace_id: workspace_id} = run)
       when is_binary(id) do
    with true <- Run.queued?(run),
         %DispatchRun{state: :waiting} = queued <-
           Repo.one(from d in DispatchRun, where: d.id == ^id and d.workspace_id == ^workspace_id) do
      %{
        queued_at: run.inserted_at,
        machine_type:
          if(queued.machine_type,
            do: %{
              key: queued.machine_type,
              name: type_name(queued.machine_type),
              spec: queued.machine_spec
            }
          ),
        reason: Waiting.reason(queued),
        run: run.public_id,
        instance_admin: Access.instance_admin?(scope)
      }
    else
      _other -> nil
    end
  end

  defp queued(_scope, _run), do: nil

  @doc "The most of a step's output a preparation keeps, in bytes: #{@output_bytes}."
  def output_bytes, do: @output_bytes

  @doc "The most of a step's output a preparation keeps, in lines: #{@output_lines}."
  def output_lines, do: @output_lines

  ## The dispatch

  # The run's dispatch, with its pool, and how the attempt failed, if it did. This
  # function alone finds the dispatch.
  #
  # The dispatch is the one whose claim registered the run (`dispatch_id`) for a run whose
  # start failed, else the last one claimed of the run's run of the queue; a run no node
  # pool claimed has none, and neither has a run whose dispatch was deleted since. The
  # failure is the run's `start_failure` (`Apiary.Runs.Run.start_failures/0`) at
  # `start_failed_at`, or `code_not_redeemed` for a run lost with its code never redeemed.
  defp attempt(scope, %Run{} = run) do
    case dispatch(scope, run) do
      %Dispatch{} = dispatch ->
        %{dispatch: dispatch, failure: failure(run), queued_at: queued_at(scope, dispatch)}

      nil ->
        %{dispatch: nil, failure: nil, queued_at: nil}
    end
  end

  # When the run of the queue began to wait for this dispatch's claim. A lapsed lease
  # makes a dispatch stale (`stale_at`) and a release ends it (`ended_at`), and either puts
  # its run of the queue back in the queue with the same `queued_at`. So after an earlier
  # dispatch of it lapsed or ended before this claim, it is the latest of those times;
  # else the run of the queue's `queued_at`. A stale dispatch gets `ended_at` too, when
  # its run of the queue ends, after this claim, so `stale_at` comes first.
  defp queued_at(_scope, %Dispatch{dispatch_run: nil}), do: nil

  defp queued_at(
         %Scope{organisation: organisation, workspace: workspace},
         %Dispatch{dispatch_run: %{queued_at: queued_at}} = dispatch
       ) do
    requeued =
      Repo.one(
        from d in Dispatch,
          where: d.organisation_id == ^organisation.id and d.workspace_id == ^workspace.id,
          where: d.dispatch_run_id == ^dispatch.dispatch_run_id and d.id != ^dispatch.id,
          where: coalesce(d.stale_at, d.ended_at) <= ^dispatch.claimed_at,
          select: type(max(coalesce(d.stale_at, d.ended_at)), :utc_datetime_usec)
      )

    case requeued do
      %DateTime{} = at -> if DateTime.after?(at, queued_at), do: at, else: queued_at
      nil -> queued_at
    end
  end

  defp dispatch(scope, %Run{dispatch_id: id}) when is_binary(id),
    do: Repo.one(from d in dispatches(scope), where: d.id == ^id)

  defp dispatch(scope, %Run{dispatch_run_id: id}) when is_binary(id) do
    Repo.one(
      from d in dispatches(scope),
        where: d.dispatch_run_id == ^id,
        order_by: [desc: d.claimed_at, desc: d.id],
        limit: 1
    )
  end

  defp dispatch(_scope, %Run{}), do: nil

  defp dispatches(%Scope{organisation: organisation, workspace: workspace}) do
    from d in Dispatch,
      where: d.organisation_id == ^organisation.id and d.workspace_id == ^workspace.id,
      preload: [:dispatch_run, pool: :organisation]
  end

  defp failure(%Run{start_failure: "machine_not_made", start_failed_at: at}),
    do: {:machine_not_made, at}

  defp failure(%Run{start_failure: "lease_lapsed", start_failed_at: at}),
    do: {:lease_lapsed, at}

  defp failure(%Run{start_failure: "machine_stopped", start_failed_at: at}),
    do: {:machine_stopped, at}

  defp failure(%Run{} = run) do
    if code_lost?(run), do: {:code_not_redeemed, run.lost_at || run.run_code_expires_at}
  end

  # Lost with no attach, no exit and no outcome, its code never redeemed: the code's 15
  # minutes ran out.
  defp code_lost?(
         %Run{state: "lost", attached_at: nil, exited_at: nil, outcome_state: nil} = run
       ),
       do: not is_nil(run.run_code_expires_at) and is_nil(run.run_code_public_key)

  defp code_lost?(%Run{}), do: false

  ## The machine

  defp machine(_scope, _run, %{dispatch: nil}, _steps, _session_started_at), do: nil

  defp machine(
         scope,
         run,
         %{dispatch: dispatch, failure: failure, queued_at: queued_at},
         steps,
         session_started_at
       ) do
    started_at = dispatch.dispatched_at

    {state, ended_at} =
      case failure do
        {_cause, at} ->
          {"failed", at}

        nil ->
          cond do
            ended = started_by(run, dispatch) -> {"succeeded", ended}
            steps != [] or session_started_at != nil -> {"succeeded", nil}
            run.state in Run.alive_states() -> {"running", nil}
            true -> {"cancelled", nil}
          end
      end

    %{
      dispatch_id: dispatch.public_id,
      pool: pool(dispatch.pool, run),
      queued_at: queued_at,
      machine_type:
        if(dispatch.machine_type,
          do: %{
            key: dispatch.machine_type,
            name: type_name(dispatch.machine_type),
            spec: dispatch.machine_spec
          }
        ),
      requested_at: dispatch.claimed_at,
      requested_ms: between(dispatch.claimed_at, started_at),
      started_as:
        if(dispatch.vendor_machine_type && Access.instance_admin?(scope),
          do: dispatch.vendor_machine_type
        ),
      release_reason: dispatch.release_reason,
      handed_over_at: dispatch.handed_over_at,
      ended_at: dispatch.ended_at || run_ended_at(run),
      end: machine_end(dispatch),
      removal_cause: removal_cause(run),
      started: %{
        state: state,
        started_at: started_at,
        ended_at: ended_at,
        duration_ms: between(started_at, ended_at)
      }
    }
  end

  # When a run that ended did so, for a dispatch that has not ended yet: its exit, its
  # loss or its failed start, else its last change. Nil while the run is alive.
  defp run_ended_at(%Run{state: state} = run) do
    if state not in Run.alive_states(),
      do: run.exited_at || run.lost_at || run.start_failed_at || run.updated_at
  end

  defp removal_cause(%Run{lost_at: %DateTime{}}), do: :keep_alive_lost
  defp removal_cause(%Run{exited_at: %DateTime{}}), do: :run_ended
  defp removal_cause(%Run{}), do: nil

  defp type_name(key) do
    case Apiary.MachineTypes.get(key) do
      %Apiary.MachineTypes.MachineType{name: name} -> name
      nil -> nil
    end
  end

  defp machine_end(%Dispatch{machine_end_state: nil}), do: nil

  defp machine_end(%Dispatch{machine_end_state: state, machine_end_at: at}),
    do: %{state: state, at: at}

  # When the machine started the run: the redemption of the run's code, which sets the
  # run key's issue time; for a run without a code, the dispatch's handover.
  defp started_by(%Run{run_code_public_key: key, run_key_issued_at: at}, _dispatch)
       when is_binary(key) and not is_nil(at),
       do: at

  defp started_by(%Run{run_code_expires_at: nil}, %Dispatch{handed_over_at: at}), do: at
  defp started_by(_run, _dispatch), do: nil

  defp pool(%Node{organisation_id: nil} = pool, _run),
    do: %{id: pool.public_id, name: pool.name, place: :instance, operator: nil}

  defp pool(%Node{organisation_id: id} = pool, %Run{organisation_id: id}),
    do: %{id: pool.public_id, name: pool.name, place: :workspace, operator: nil}

  defp pool(%Node{organisation: %Organisation{name: operator}} = pool, _run),
    do: %{id: pool.public_id, name: pool.name, place: :operator, operator: operator}

  defp between(%DateTime{} = from, %DateTime{} = to),
    do: max(DateTime.diff(to, from, :millisecond), 0)

  defp between(_from, _to), do: nil

  ## The sessions

  # One session per agent session's start, in sequence order, each with the end events
  # that belong to it (`t:session_end/0`).
  defp sessions(starts, ends) do
    agents = Enum.reject(starts, &(&1.bare or &1.unrun))
    by_start = Enum.group_by(ends, &owner(&1, starts, agents))

    for start <- agents do
      %{
        session: start.session,
        sequence: start.sequence,
        started_at: start.time,
        runtime: start.runtime,
        end: session_end(Map.get(by_start, start.sequence, []))
      }
    end
  end

  # Marks each session's start `unrun` when the session's wall failed: the wall starts
  # after the session's start (the Forager contract's `dev.qory.run.step_started`), and
  # the agent runs only behind it, so the session never ran its agent. A wall's session is
  # the last to start before it, unless the join of an agent session lies between that
  # start and the wall: then the wall failed before its session started, as
  # `bare_session?/4` reads it.
  defp unrun(starts, steps) do
    joins =
      for %{kind: "join", helper: false, started_sequence: at} <- steps,
          is_integer(at),
          do: at

    unrun =
      for %{kind: "wall", state: "failed", helper: false, started_sequence: at} <- steps,
          is_integer(at),
          %{bare: false} = start <- [starts |> Enum.filter(&(&1.sequence < at)) |> List.last()],
          not Enum.any?(joins, &(&1 > start.sequence and &1 < at)),
          into: MapSet.new(),
          do: start.sequence

    Enum.map(starts, &Map.put(&1, :unrun, MapSet.member?(unrun, &1.sequence)))
  end

  # The sequence of the start of the agent session an end event belongs to: the last
  # session, bare or not, with the event's `session` that started before it, else the
  # first with that number; nil when that session is bare or did not run its agent, so a
  # bare session that reuses an agent session's number does not end it. For an event
  # with no `session`, or one that no session's start has, the last agent session that
  # started before it, else the first.
  defp owner(%{session: n} = event, starts, agents) do
    numbered = if n, do: Enum.filter(starts, &(&1.session == n)), else: []

    cond do
      numbered != [] ->
        case started_before(numbered, event.sequence) do
          %{bare: true} -> nil
          %{unrun: true} -> nil
          start -> start.sequence
        end

      agents != [] ->
        started_before(agents, event.sequence).sequence

      true ->
        nil
    end
  end

  defp started_before(starts, sequence) do
    starts |> Enum.filter(&(&1.sequence < sequence)) |> List.last() || hd(starts)
  end

  # How the last agent session ended. For a run with no session's start at all, as one
  # whose session no event announced, it is read from the run's last end events.
  defp last_end([], [], ends), do: session_end(ends)
  defp last_end(_starts, sessions, _ends), do: sessions |> List.last() |> then(&(&1 && &1.end))

  # How a session ended, from its last result, exit and runtime start; nil with neither a
  # result nor an exit.
  defp session_end(events) do
    last = fn type -> events |> Enum.filter(&(&1.type == type)) |> List.last() end
    result = last.("dev.qory.runtime.result")
    exited = last.("dev.qory.session.exited")

    if result || exited do
      result_data = (result && result.data) || %{}
      exited_data = (exited && exited.data) || %{}
      started_data = (last.("dev.qory.runtime.started") || %{data: %{}}).data

      %{
        result_at: result && result.time,
        outcome: text(result_data["outcome"]),
        turns: integer(result_data["turns"]),
        duration_ms: integer(result_data["duration_ms"]),
        cost_usd: if(is_number(result_data["cost_usd"]), do: result_data["cost_usd"]),
        exited_at: exited && exited.time,
        state: text(exited_data["state"]),
        exit_code: integer(exited_data["exit_code"]),
        model: text(started_data["model"])
      }
    end
  end

  @doc """
  The session of the run page's Timeline that `item` belongs to: the `sequence` of its
  agent session's start (`t:session/0`); nil for no session. The rule is the one that
  places a session's end events: an item whose `session` is an agent session's number
  belongs to the last session with that number that started before it, else to the first
  with that number. An item with no `session`, or with a bare session's number, belongs
  to the last agent session that started before it. Both go by the item's `sequence`, or,
  for a row with no sequence, as Pushed, by its `time`; an item before every candidate
  belongs to the first.
  """
  @spec session_of([session], map) :: integer | nil
  def session_of([], _item), do: nil

  def session_of(sessions, item) do
    n = item[:session]
    numbered = if n, do: Enum.filter(sessions, &(&1.session == n)), else: []
    session_by(if(numbered == [], do: sessions, else: numbered), item).sequence
  end

  @doc """
  The session of the run page's Timeline that `item` belongs to, as `session_of/2` has
  it, and nil for an item of a session that never ran its agent (`unrun`): the rule is
  the same, among the agent sessions and those sessions, by the item's `session` and
  `sequence`. Such an item is in the Timeline after the list.
  """
  @spec session_of([session], [unrun], map) :: integer | nil
  def session_of(sessions, [], item), do: session_of(sessions, item)

  def session_of(sessions, unrun, item) do
    if unrun_item?(sessions, unrun, item), do: nil, else: session_of(sessions, item)
  end

  defp unrun_item?(sessions, unrun, %{session: n, sequence: seq})
       when is_integer(n) and is_integer(seq) do
    marked = Enum.map(unrun, &Map.put(&1, :unrun, true))

    case sessions |> Enum.concat(marked) |> Enum.filter(&(&1.session == n)) do
      [] ->
        false

      numbered ->
        match?(%{unrun: true}, numbered |> Enum.sort_by(& &1.sequence) |> started_before(seq))
    end
  end

  defp unrun_item?(_sessions, _unrun, _item), do: false

  defp session_by(sessions, %{sequence: sequence}) when is_integer(sequence),
    do: started_before(sessions, sequence)

  defp session_by(sessions, %{time: %DateTime{} = time}) do
    sessions
    |> Enum.filter(&(DateTime.compare(&1.started_at, time) != :gt))
    |> List.last() || hd(sessions)
  end

  defp session_by(sessions, _item), do: hd(sessions)

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: nil

  defp integer(value) when is_integer(value), do: value
  defp integer(_value), do: nil

  ## What the run pushed

  # The versions a run of the queue wrote, through the run's `dispatch_run_id`; none for a
  # run no queue started.
  defp outputs(%Scope{organisation: organisation, workspace: workspace}, %Run{
         dispatch_run_id: id
       })
       when is_binary(id) do
    Repo.all(
      from v in Version,
        join: a in assoc(v, :artifact),
        where: v.organisation_id == ^organisation.id and v.workspace_id == ^workspace.id,
        where: v.writer == :run and v.run_id == ^id,
        order_by: [asc: v.inserted_at, asc: v.number],
        select: %{
          type: a.type,
          name: a.name,
          number: v.number,
          at: v.inserted_at,
          public_id: v.public_id
        }
    )
  end

  defp outputs(_scope, _run), do: []

  # Whether the run's run of the queue is for the step `prebuild`; false for a run no
  # queue started.
  defp prebuild?(%Scope{organisation: organisation, workspace: workspace}, %Run{
         dispatch_run_id: id
       })
       when is_binary(id) do
    Repo.exists?(
      from d in Apiary.Dispatches.DispatchRun,
        where: d.id == ^id and d.step == ^Apiary.Dispatches.DispatchRun.prebuild(),
        where: d.organisation_id == ^organisation.id and d.workspace_id == ^workspace.id
    )
  end

  defp prebuild?(_scope, _run), do: false

  # A step of a prebuild, marked so its join reads Start the build (`step_label/1`).
  defp prebuild_step(%{kind: "join"} = step), do: Map.put(step, :prebuild, true)
  defp prebuild_step(step), do: step

  # A prebuild with no report whose build session exited with success: failed, lost or
  # cancelled after its build, at its exit, or when it was found lost; nil while it goes
  # on, and once it completed.
  defp unsent(%Run{state: "failed", exited_at: at}), do: %{at: at, image: nil, refused: :not_sent}

  defp unsent(%Run{state: "lost"} = run),
    do: %{at: run.lost_at || run.exited_at, image: nil, refused: :lost}

  defp unsent(%Run{state: "cancelled", exited_at: at}),
    do: %{at: at, image: nil, refused: :cancelled}

  defp unsent(%Run{}), do: nil

  # How a prebuild saved its image (`t:built/0`): its first `dev.qory.run.built` by
  # sequence, with the result of its check; else, for a prebuild that failed after its
  # build session exited with success, no report; else nil.
  defp built(scope, run, session_end, machine) do
    built =
      case Record.built(scope, run) do
        %{time: at, image: image, data: data} ->
          refused =
            case Apiary.Dispatches.Built.check(run, data) do
              :ok -> nil
              {:refused, why} -> why
            end

          %{at: at, image: text(image), refused: refused}

        nil ->
          if session_end[:state] == "succeeded", do: unsent(run)
      end

    built && Map.put(built, :fix, built_fix(scope, run, machine, built.refused))
  end

  # What the reader of `scope` does about an image not saved (`t:built_fix/0`).
  defp built_fix(_scope, _run, _machine, nil), do: nil

  defp built_fix(scope, run, machine, :not_sent) do
    if Access.instance_admin?(scope) do
      :machine_log
    else
      case machine && machine.pool do
        %{place: :workspace, name: pool} -> {:pool_log, pool}
        %{place: :operator, operator: operator, name: pool} -> {:operator_log, operator, pool}
        _instance -> {:support, run.public_id}
      end
    end
  end

  defp built_fix(
         %Scope{workspace: %Workspace{} = workspace} = scope,
         run,
         _machine,
         :no_destination
       ) do
    cond do
      is_nil(run.target_path) -> nil
      Access.can?(scope, :"target.rebuild_environment", workspace) -> {:rebuild, run.target_path}
      true -> {:ask_rebuild, workspace.name, run.target_path}
    end
  end

  defp built_fix(_scope, run, _machine, :not_prebuild), do: {:support, run.public_id}
  defp built_fix(_scope, run, _machine, {:form, _member}), do: {:support, run.public_id}

  defp built_fix(_scope, _run, _machine, _why), do: nil

  # work_item/2 is the work item of the run's run of the queue, whose artifacts the run
  # pushes: nil for a run no queue started, or a run of the queue with no work item.
  # Scoped to the scope's organisation and workspace. `Apiary.WorkItems.WorkItem` is
  # hidden from the docs, so this function is too.
  @doc false
  @spec work_item(Scope.t(), Run.t()) :: Apiary.WorkItems.WorkItem.t() | nil
  def work_item(%Scope{organisation: organisation, workspace: workspace}, %Run{
        dispatch_run_id: id
      })
      when is_binary(id) do
    Repo.one(
      from w in Apiary.WorkItems.WorkItem,
        join: d in Apiary.Dispatches.DispatchRun,
        on: d.work_item_id == w.id,
        where: d.id == ^id,
        where: d.organisation_id == ^organisation.id and d.workspace_id == ^workspace.id
    )
  end

  def work_item(_scope, _run), do: nil

  ## The steps

  # A step's output is read while the run's log lines are kept (`kept?`), and is empty
  # once retention deleted them.
  defp step(scope, run, %Step{} = step, log?, kept?) do
    %{
      number: step.step,
      name: name(step.name),
      sent_name: step.name,
      kind: step.kind,
      state: step.state,
      exit_code: step.exit_code,
      started_at: step.started_at,
      exited_at: step.exited_at,
      started_sequence: step.started_sequence,
      exited_sequence: step.exited_sequence,
      duration_ms: step.duration_ms,
      helper: false,
      output: if(log?, do: output(scope, run, step.step, kept?))
    }
  end

  # Marks the helper steps (the moduledoc). A step whose start is not recorded is none:
  # its place among the events is not known.
  defp helpers(steps, starts) do
    copies =
      for %{kind: "copy", started_sequence: from} = copy <- steps,
          is_integer(from),
          do: {from, copy.exited_sequence}

    # The joins of agent sessions, which end a bare session's part of the run.
    joins =
      for %{kind: "join", started_sequence: at} <- steps,
          is_integer(at),
          not in_copy?(at, copies),
          not bare_session?("join", at, starts, []),
          do: at

    Enum.map(steps, &%{&1 | helper: helper?(&1, copies, starts, joins)})
  end

  defp helper?(%{kind: "copy"}, _copies, _starts, _joins), do: true

  defp helper?(%{kind: kind, started_sequence: at}, copies, starts, joins)
       when kind in ["join", "wall"] and is_integer(at),
       do: in_copy?(at, copies) or bare_session?(kind, at, starts, joins)

  defp helper?(_step, _copies, _starts, _joins), do: false

  defp in_copy?(at, copies),
    do: Enum.any?(copies, fn {from, to} -> at > from and (is_nil(to) or at < to) end)

  # A join ends before its session's start, and a wall starts after it (the Forager
  # contract's `dev.qory.run.step_started`): a join's session is the first to start after
  # it, a wall's the last to start before it, unless the join of an agent session lies
  # between that start and the wall, as for a wall that fails before its session starts.
  defp bare_session?("join", at, starts, _joins),
    do: match?(%{bare: true}, Enum.find(starts, &(&1.sequence > at)))

  defp bare_session?("wall", at, starts, joins) do
    case starts |> Enum.filter(&(&1.sequence < at)) |> List.last() do
      %{bare: true, sequence: start} -> not Enum.any?(joins, &(&1 > start and &1 < at))
      _ -> false
    end
  end

  # qory's name as it gave it, with its first letter in upper case.
  defp name(nil), do: nil

  defp name(name) do
    case String.next_grapheme(name) do
      {first, rest} -> String.upcase(first) <> rest
      nil -> nil
    end
  end

  @doc "The text of a step's `output`: its lines joined by line feeds."
  @spec output_text(output) :: String.t()
  def output_text(%{lines: lines}), do: Enum.map_join(lines, "\n", & &1.text)

  # The step's output as plain lines, at most #{@output_bytes} bytes and #{@output_lines}
  # lines: the end of it when it is longer, without the line the cut fell in, unless that
  # line is all there is. Each line has its number in the whole output and the time of the
  # chunk it began in.
  defp output(_scope, _run, _number, false), do: %{lines: [], truncated: false, lines_cut: false}

  defp output(scope, run, number, true) do
    %{chunks: chunks, total: total, line_feeds: feeds} =
      Record.step_tail(scope, run, number, @output_bytes)

    raw = raw_lines(chunks)
    cut? = total > Enum.sum_by(chunks, &byte_size(&1.bytes))
    # The first raw line is the one after all but `length(raw) - 1` of the output's line
    # feeds.
    first = max(feeds - length(raw) + 2, 1)

    lines =
      raw
      |> Enum.with_index(first)
      |> Enum.map(fn {{bytes, at}, n} -> %{number: n, at: at, text: Record.plain_line(bytes)} end)
      |> Enum.reverse()
      |> Enum.drop_while(&(&1.text == ""))
      |> Enum.reverse()

    lines = if cut? and length(lines) > 1, do: tl(lines), else: lines
    {lines, budget_cut?} = within_bytes(lines, @output_bytes)
    lines_cut? = length(lines) > @output_lines
    lines = if lines_cut?, do: Enum.take(lines, -@output_lines), else: lines
    %{lines: lines, truncated: cut? or budget_cut? or lines_cut?, lines_cut: lines_cut?}
  end

  # The chunks' bytes as raw lines split at each line feed, in order, each with the time of
  # the chunk it began in. A line begins after a line feed, or, after one that ends its
  # chunk, in the next chunk. The last line is what follows the last line feed: empty, with
  # no time, when the output ends with one.
  defp raw_lines(chunks) do
    {done, part, at} =
      Enum.reduce(chunks, {[], [], :none}, fn %{bytes: bytes, time: time}, {done, part, at} ->
        [first | rest] = :binary.split(bytes, "\n", [:global])
        at = if at == :none and (first != "" or rest != []), do: time, else: at
        line_ends(rest, time, {done, [part | first], at})
      end)

    Enum.reverse([{IO.iodata_to_binary(part), begun(at)} | done])
  end

  defp line_ends([], _time, acc), do: acc

  defp line_ends([piece | rest], time, {done, part, at}) do
    done = [{IO.iodata_to_binary(part), begun(at)} | done]
    at = if piece == "" and rest == [], do: :none, else: time
    line_ends(rest, time, {done, piece, at})
  end

  defp begun(:none), do: nil
  defp begun(at), do: at

  # The last lines whose texts, joined by line feeds, take at most `limit` bytes, and
  # whether a line was left out. Replaced bytes that were not UTF-8 can make the text
  # longer than the bytes it came from.
  defp within_bytes(lines, limit) do
    {kept, _size} =
      lines
      |> Enum.reverse()
      |> Enum.reduce_while({[], -1}, fn line, {kept, size} ->
        size = size + 1 + byte_size(line.text)
        if size > limit, do: {:halt, {kept, size}}, else: {:cont, {[line | kept], size}}
      end)

    {kept, length(kept) < length(lines)}
  end

  ## Why it stopped

  defp stopped(scope, run, %{failure: {cause, _at}}, machine, _steps, release_reason) do
    {fixer, who} = pool_fixer(scope, machine.pool, run)
    machine = %{machine | release_reason: reason(machine.release_reason, release_reason)}
    {what, fix} = machine_line(cause, machine, who, log_place(machine.pool))

    %{
      cause: cause,
      step: nil,
      fixer: fixer,
      text: what <> " " <> fix,
      what: what,
      fix: fix,
      detail: nil
    }
  end

  defp stopped(scope, run, _attempt, machine, steps, _release_reason) do
    case Enum.find(steps, &(&1.state == "failed")) do
      nil ->
        nil

      step ->
        step_stopped(scope, run, machine, step)
    end
  end

  defp step_stopped(scope, run, machine, step) do
    {fixer, who} =
      if step.kind in @pool_kinds,
        do: pool_fixer(scope, machine && machine.pool, run),
        else: workspace_fixer(scope)

    {what, fix} = step_line(step, who, run.log_pruned_at)

    %{
      cause: :step_failed,
      step: step.number,
      fixer: fixer,
      text: what <> " " <> fix,
      what: what,
      fix: fix,
      detail: step_detail(step)
    }
  end

  # Each cause line is two sentences: what happened, then who fixes it. The first sentence
  # of a machine's cause is the one the run's header shows as the run's reason
  # (`ApiaryWeb.RunComponents.reason_words/1`), but for a lapsed lease, which names the
  # pool here.
  defp machine_line(:machine_not_made, machine, who, place) do
    {gettext("No machine was made: %{reason}.", reason: machine.release_reason),
     reads_why(who, place)}
  end

  defp machine_line(:lease_lapsed, machine, who, _place) do
    pool = pool_name(machine.pool)

    {gettext("%{pool} did not start a machine within 10 minutes.", pool: pool),
     checks_running(who, pool)}
  end

  defp machine_line(:code_not_redeemed, _machine, who, place) do
    {gettext("The machine did not start the run within 15 minutes of the request."),
     reads_why(who, place)}
  end

  defp machine_line(:machine_stopped, _machine, who, place) do
    {gettext("The machine stopped before it started the run."), reads_why(who, place)}
  end

  # Only support reaches the cause in the Qory Pool, so the line names the run to give them.
  defp checks_running({:support, line}, _pool), do: line

  defp checks_running(who, pool),
    do: gettext("%{who} checks that %{pool} is running.", who: who, pool: pool)

  defp reads_why({:support, line}, _place), do: line

  defp reads_why(who, place),
    do: gettext("%{who} reads why in %{place}.", who: who, place: place)

  # The step by its row's name (`row_name/1`), with qory's detail in parentheses when the
  # label leaves it out (`step_detail/1`). An exit code of -1 is no exit status (the
  # Forager contract's `dev.qory.run.step_exited`), so the line shows none.
  defp step_line(step, who, pruned_at), do: {step_what(step), reads_cause(who, pruned_at)}

  @doc """
  The cause line of a prebuild's session that failed, as the step Build the image:
  "Build the image failed with exit code 1." for the session's `exit_code`, or "Build the
  image failed." with none, or with -1 (`t:session_end/0`).
  """
  @spec build_what(map) :: String.t()
  def build_what(session_end),
    do: step_what(%{kind: "build", exit_code: session_end[:exit_code], sent_name: nil, name: nil})

  defp step_what(%{exit_code: code} = step) when is_integer(code) and code != -1 do
    case step_detail(step) do
      nil ->
        gettext("%{step} failed with exit code %{code}.", step: row_name(step), code: code)

      detail ->
        gettext("%{step} failed with exit code %{code} (%{detail}).",
          step: row_name(step),
          code: code,
          detail: detail
        )
    end
  end

  defp step_what(step) do
    case step_detail(step) do
      nil -> gettext("%{step} failed.", step: row_name(step))
      detail -> gettext("%{step} failed (%{detail}).", step: row_name(step), detail: detail)
    end
  end

  # Once retention deleted the run's log lines, the step's output is gone.
  defp reads_cause({:support, line}, nil), do: line

  defp reads_cause(who, nil),
    do: gettext("%{who} reads the cause in the step's output.", who: who)

  defp reads_cause(_who, _pruned_at) do
    gettext(
      "The step's output was deleted under the workspace's log retention, so the cause is no longer shown."
    )
  end

  @doc """
  What the run page calls a step: its name (`t:step/0`), or "Step" and its number when
  only its exit is recorded.
  """
  @spec step_name(map) :: String.t()
  def step_name(%{name: name}) when is_binary(name), do: name
  def step_name(%{number: number}), do: gettext("Step %{number}", number: number)

  @doc """
  What a row of the preparation calls a step of `kind`: Clone the repository for
  `fetch`, Compose the harness for `compose`, Pull the images for `image`, Build the
  image for `build`, Set up the dev container for `setup`, Start the agent for `join`,
  or Start the build for the join of a prebuild, whose step has `prebuild: true`, Start
  the wall for `wall` and Start the machine for `machine`; nil for any other kind, whose
  row has the step's name (`step_name/1`).
  """
  @spec step_label(map) :: String.t() | nil
  # A fetch clones a repository in a workspace of any domain, so the label is the same in
  # every domain: the plain context (docs/lingo.md).
  def step_label(%{kind: "fetch"}), do: pgettext("plain", "Clone the repository")
  def step_label(%{kind: "compose"}), do: gettext("Compose the harness")
  def step_label(%{kind: "image"}), do: gettext("Pull the images")
  def step_label(%{kind: "build"}), do: gettext("Build the image")
  def step_label(%{kind: "setup"}), do: gettext("Set up the dev container")
  def step_label(%{kind: "join", prebuild: true}), do: gettext("Start the build")
  def step_label(%{kind: "join"}), do: gettext("Start the agent")
  def step_label(%{kind: "wall"}), do: gettext("Start the wall")
  def step_label(%{kind: "machine"}), do: gettext("Start the machine")
  def step_label(_step), do: nil

  @doc "The name of a step's row: its label (`step_label/1`), else its name (`step_name/1`)."
  @spec row_name(map) :: String.t()
  def row_name(step), do: step_label(step) || step_name(step)

  @doc """
  The part of a step's name that its label leaves out, nil when there is none. It reads
  the name as qory or Forager sent it (`sent_name`): without its first word when that
  word is the step's kind, as in "postCreateCommand: npm ci" for
  "setup postCreateCommand: npm ci", else the whole name. Nil for a step with no label,
  with no name, with a name of one word (qory's "prepare"), or whose words are all words
  of its label, as "compose harness" for Compose the harness, and for a `join`, whose
  name has the session's number alone. An `image` step whose name is one word, its image
  reference, has that name, unless the word is the kind.
  """
  @spec step_detail(map) :: String.t() | nil
  def step_detail(%{kind: "join"}), do: nil

  def step_detail(%{kind: kind, sent_name: sent_name} = step) when is_binary(sent_name) do
    label = step_label(step)
    name = String.trim(sent_name)

    detail =
      case String.split(name, " ", parts: 2) do
        [first, rest] -> if String.downcase(first) == kind, do: String.trim(rest), else: name
        [one] -> if kind == "image" and String.downcase(one) != kind, do: one
      end

    if label != nil and detail not in [nil, ""] and
         not MapSet.subset?(words(detail), words(label)),
       do: detail
  end

  def step_detail(_step), do: nil

  defp words(text), do: text |> String.downcase() |> String.split() |> MapSet.new()

  @doc """
  The step a preparation stopped at, as the run page shows it: Start the machine for a
  cause of the machine, else the failed step's row name (`row_name/1`); nil while it has
  not stopped.
  """
  @spec stopped_step(t) :: String.t() | nil
  def stopped_step(%{stopped: %{step: nil}}), do: gettext("Start the machine")

  def stopped_step(%{stopped: %{step: number}, steps: steps}),
    do: steps |> Enum.find(&(&1.number == number)) |> row_name()

  def stopped_step(_preparation), do: nil

  @doc """
  How a run that a failed step of its preparation stopped ended, as the run page's header
  shows it: the first sentence of the cause line (`stopped`'s `what`), which states what
  happened, with no advice. Nil for any other preparation: the header's reason states a
  machine's cause.
  """
  @spec stop_line(t) :: String.t() | nil
  def stop_line(%{stopped: %{step: n, what: what}}) when is_integer(n), do: what
  def stop_line(_preparation), do: nil

  @doc """
  How a run whose push or copy failed ended, as the run page's header shows it, for the
  first failed one: for a push, what happened, the first sentence of its cause line, with
  no advice; for the copy of the run's work back from the wall, that the work did not
  come back from the machine. Nil when neither failed.
  """
  @spec push_line(t) :: String.t() | nil
  def push_line(%{after_session: steps}) do
    case Enum.find(steps, &(&1.state == "failed")) do
      nil -> nil
      %{kind: "copy"} -> gettext("The run's work did not come back from the machine.")
      push -> step_what(push)
    end
  end

  @doc "Whether a step after the last agent session, a push or a copy, failed."
  @spec push_failed?(t) :: boolean
  def push_failed?(%{after_session: steps}), do: Enum.any?(steps, &(&1.state == "failed"))

  # The starter's reason as a line an external system sent, with its one closing full
  # stop left out for the sentence's, through the secret filter unless kept as stored.
  defp reason(nil, _how), do: gettext("n/a")

  defp reason(reason, :filtered),
    do: reason |> SecretLogFilter.filter_text() |> reason(:as_stored)

  defp reason(reason, :as_stored),
    do: reason |> ExternalText.line() |> String.replace_suffix(".", "")

  defp pool_name(%{name: name}), do: name

  # Who fixes a cause in the pool: support for the instance's pool, an admin of the
  # operator for an operator's, an admin of the workspace for the workspace's and for a
  # pool that is not known.
  defp pool_fixer(_scope, %{place: :instance}, %Run{public_id: run}),
    do: {:support, {:support, gettext("Contact support with run %{run}.", run: run)}}

  defp pool_fixer(_scope, %{place: :operator, operator: operator}, _run),
    do: {:operator_admin, gettext("An admin of %{operator}", operator: operator)}

  defp pool_fixer(scope, _pool, _run), do: workspace_fixer(scope)

  defp workspace_fixer(%Scope{workspace: workspace}),
    do: {:workspace_admin, gettext("An admin of %{workspace}", workspace: workspace.name)}

  # Where the machine log of a pool outside Qory Apiary is read: on the pool's host. The
  # line for the instance's pool has no place (`pool_fixer/3`).
  defp log_place(pool),
    do: gettext("the log of %{pool} on its host", pool: pool_name(pool))
end
