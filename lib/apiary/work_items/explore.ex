defmodule Apiary.WorkItems.Explore do
  # Explore says where Explore stands for a work item, from the runs of its take ins
  # (`Apiary.Dispatches.DispatchRun`, with the run registered for each, `Apiary.Runs.Run`),
  # each run's result (`Apiary.Explore.Result`), and what members gave it: the answers
  # (`Apiary.WorkItems.Answer`) and the confirmation (`Apiary.WorkItems.Confirmation`). It
  # writes nothing. `Apiary.WorkItems.Moves` asks it under the work item's lock, and
  # `Apiary.WorkItems` reads the pages' maps from it.
  #
  # ## A run
  #
  # `step/4` is where one run of a take in stands:
  #
  #   * waiting or claimed: `:queued`; handed over: `:running`;
  #   * ended lost: `:lost`; ended released: `:cancelled`; ended with its work item closed
  #     or undone, before its handover: `:cancelled`;
  #   * ended at its claim because the claim could not form what the run is made from
  #     (`variables_invalid`, `ticket_gone`, `inputs_invalid`), while it waited for its
  #     environment image's build, which failed (`build_failed`), or because its harness
  #     walk failed (`harness_unresolved`): `:no_result` with the outcome `:error`, and
  #     no registered run;
  #   * ended by its exit, or by an outcome stored on it before a run of the queue was
  #     refused one (`run_ended`): what the run gave decides. Once
  #     Qory reads it as decided it is kept on the run of the queue
  #     (`Apiary.Dispatches.Settle`: `result_outcome`, and the run's result for a proposal
  #     or questions), and read from there; until then it is read from the run's
  #     `dev.qory.runtime.result` with the highest sequence (`Apiary.Explore.Result.given/3`).
  #     A result whose verdict is `understood` is `:proposal`, one whose verdict is
  #     `not_understood` is `:questions`. Without a result the run is `:cancelled` when the
  #     registered run reads as cancelled, `:lost` when it reads as lost, and otherwise
  #     `:no_result`, with the outcome `:none` for no result event, or one whose `is_error`
  #     is `false` and that carries no result, `:error` for a result event whose `is_error`
  #     is anything else, and `:refused` for a result that fails the check of
  #     `Apiary.Explore.Result`. A proposal or questions whose kept result retention
  #     cleared (`Apiary.Retention`) reads as a run whose events were pruned: no result
  #     event.
  #
  # **A stated limit: the window before a run's result.** A run of the queue takes no
  # outcome (`Apiary.Runs.Outcome`). An outcome stored on one before that rule ended the
  # run, possibly before the gateway had delivered the run's events, its result among
  # them. So a run ended by such an outcome, with no result yet, reads as `:running`
  # until it is settled (`Apiary.Explore.Result.settled?/2`): its exit is
  # folded (every event before the exit is then stored, as the projector folds them in
  # order), it is lost, its events are pruned, or 10 minutes have passed since its
  # outcome arrived; only then does it read as a run without a result, which a member
  # may run again. What it gave is stored on the run of the queue when it settles, or
  # when its result comes. A result that arrives after those 10 minutes still counts: it
  # replaces what was stored, and the run then reads as its result says.
  #
  # ## A take in
  #
  # `status/2` is where Explore stands for a live work item, from the runs of its current
  # take in and whether that take in was confirmed: `:shape` once confirmed; else its
  # latest run's place, `:proposal` read as `:confirm`; and `:used_up` for a latest run at
  # `:questions`, `:no_result`, `:lost` or `:cancelled` whose attempt is its `of`, the run
  # limit, where no run is left. A take in with no run yet is `:queued`.
  # `with_status/1` derives the same status in SQL, for a list of work items, from what
  # the runs of the queue keep: a run whose outcome is not stored yet reads as running
  # there until it is.
  #
  # `stage/1` is the stage a status is at, as a decline or a close records it: `:shape`
  # once confirmed, `:confirm` while the proposal waits, `:explore` otherwise.
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Explore.Result
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Repo
  alias Apiary.Runs.{Event, Run}
  alias Apiary.WorkItems.{Answer, Confirmation, WorkItem, WorkItemEvent}

  @statuses [
    :queued,
    :running,
    :confirm,
    :questions,
    :no_result,
    :lost,
    :cancelled,
    :used_up,
    :shape
  ]
  @run_states %{
    "pending" => :pending,
    "running" => :running,
    "completed" => :completed,
    "failed" => :failed,
    "cancelled" => :cancelled,
    "lost" => :lost
  }

  @typedoc "Where one run of a take in stands."
  @type place :: :queued | :running | :proposal | :questions | :no_result | :lost | :cancelled

  @typedoc "Where Explore stands for a live work item."
  @type status ::
          :queued
          | :running
          | :confirm
          | :questions
          | :no_result
          | :lost
          | :cancelled
          | :used_up
          | :shape

  @typedoc "What a run gave: its result's verdict, or why it has none."
  @type outcome :: Result.outcome() | nil

  @typedoc """
  One run of a take in: the run of the queue, the run its claim registered (nil while it
  has none: waiting, or ended before its handover), its place, what it gave and its
  result.
  """
  @type step :: %{
          dispatch_run: DispatchRun.t(),
          run: Run.t() | nil,
          take_in: pos_integer,
          attempt: pos_integer,
          of: pos_integer,
          place: place,
          outcome: outcome,
          result: map | nil
        }

  # settle_seconds/0 is how long after its outcome arrived a run with no result yet reads
  # as running.
  @doc false
  @spec settle_seconds() :: pos_integer
  def settle_seconds, do: Result.settle_seconds()

  ## A run

  # step/4 is where the run of the queue `dispatch_run` stands, with `run`, the run
  # registered for it or nil, and `event`, its result event with the highest sequence or
  # nil, at `now` (the moduledoc).
  @doc false
  @spec step(DispatchRun.t(), Run.t() | nil, Event.t() | nil, DateTime.t()) :: step
  def step(%DispatchRun{} = dispatch_run, run, event, %DateTime{} = now) do
    {place, outcome, result} = place(dispatch_run, run, event, now)

    %{
      dispatch_run: dispatch_run,
      run: run,
      take_in: dispatch_run.take_in,
      attempt: dispatch_run.attempt,
      of: dispatch_run.of,
      place: place,
      outcome: outcome,
      result: result
    }
  end

  defp place(%DispatchRun{state: state}, _run, _event, _now) when state in [:waiting, :claimed],
    do: {:queued, nil, nil}

  defp place(%DispatchRun{state: :handed_over}, _run, _event, _now), do: {:running, nil, nil}

  defp place(%DispatchRun{state: :ended, end_cause: :lost}, _run, _event, _now),
    do: {:lost, nil, nil}

  defp place(%DispatchRun{state: :ended, end_cause: cause}, _run, _event, _now)
       when cause in [:released, :closed, :undone],
       do: {:cancelled, nil, nil}

  defp place(%DispatchRun{state: :ended, end_cause: :run_ended} = dispatch_run, run, event, now) do
    case given(dispatch_run, run, event, now) do
      {:proposal, result} ->
        {:proposal, :proposal, result}

      {:questions, result} ->
        {:questions, :questions, result}

      :unsettled ->
        {:running, nil, nil}

      outcome ->
        cond do
          match?(%Run{state: "cancelled"}, run) ->
            {:cancelled, nil, nil}

          match?(%Run{state: "lost"}, run) ->
            {:lost, nil, nil}

          true ->
            {:no_result, outcome, nil}
        end
    end
  end

  defp place(%DispatchRun{state: :ended}, _run, _event, _now), do: {:no_result, :error, nil}

  # What a run ended by its exit, or by an outcome stored before a run of the queue was
  # refused one, gave: what the run of the queue keeps once
  # stored, a proposal or questions whose result was cleared as no result event, else
  # what its result event gives (`Apiary.Explore.Result.given/3`).
  defp given(%DispatchRun{result_outcome: nil}, run, event, now),
    do: Result.given(run, event, now)

  defp given(%DispatchRun{result_outcome: outcome, result: %{} = result}, _run, _event, _now)
       when outcome in [:proposal, :questions],
       do: {outcome, result}

  defp given(%DispatchRun{result_outcome: outcome}, _run, _event, _now)
       when outcome in [:proposal, :questions],
       do: :none

  defp given(%DispatchRun{result_outcome: outcome}, _run, _event, _now), do: outcome

  ## A take in

  # status/2 is where Explore stands for a live work item whose current take in has
  # `steps`, oldest first, confirmed or not (the moduledoc).
  @doc false
  @spec status([step], boolean) :: status
  def status(_steps, true), do: :shape
  def status([], false), do: :queued

  def status(steps, false) do
    latest = List.last(steps)

    case latest.place do
      :proposal ->
        :confirm

      place when place in [:questions, :no_result, :lost, :cancelled] ->
        if latest.attempt >= latest.of, do: :used_up, else: place

      place ->
        place
    end
  end

  # stage/1 is the stage `status` is at.
  @doc false
  @spec stage(status) :: :explore | :confirm | :shape
  def stage(:shape), do: :shape
  def stage(:confirm), do: :confirm
  def stage(_status), do: :explore

  ## The status in SQL

  # with_status/1 is `query`, whose work items are bound as `:work_item`, with each work
  # item's status as `status/2` gives it, derived in SQL: bound as `:explore_status`, its
  # one column `status`, the status's name as text (`status_name/1`). One `LEFT JOIN
  # LATERAL` per work item: the latest run of the queue of its current take in, its
  # highest `attempt`, read backwards through the unique index on (`work_item_id`,
  # `take_in`, `attempt`), with its registered run, and whether that take in is confirmed.
  # A run ended by its exit, or by an outcome stored before a run of the queue was refused
  # one, reads from what the run of the queue keeps
  # (`Apiary.Dispatches.Settle`): one whose outcome is not stored yet reads as running
  # until it is, where `status/2`, which reads its result event, reads a result that
  # came, or a run settled since, at once. The status of an ended work item is that of
  # its last take in, which `status/2` does not give. For example, the live work items
  # of a workspace that wait for a member, with their status:
  #
  #     from(w in WorkItem, as: :work_item, where: w.workspace_id == ^workspace_id)
  #     |> Explore.with_status()
  #     |> where([work_item: w], w.state == :exploring)
  #     |> where([explore_status: s], s.status in ^Explore.status_names([:confirm, :questions]))
  #     |> select([work_item: w, explore_status: s], {w.public_id, s.status})
  #
  # and `status_of/1` reads a `status` back.
  @doc false
  @spec with_status(Ecto.Queryable.t()) :: Ecto.Query.t()
  def with_status(query) do
    from [work_item: w] in query,
      left_lateral_join:
        s in fragment(
          """
          SELECT CASE
            WHEN EXISTS (
              SELECT 1 FROM work_item_confirmations AS c
              WHERE c.work_item_id = ? AND c.take_in = ?
            ) THEN 'shape'
            WHEN l.place IS NULL THEN 'queued'
            WHEN l.place = 'proposal' THEN 'confirm'
            WHEN l.place IN ('questions', 'no_result', 'lost', 'cancelled') AND l.attempt >= l.of
              THEN 'used_up'
            ELSE l.place
          END AS status
          FROM (SELECT 1) AS one
          LEFT JOIN LATERAL (
            SELECT d.attempt, d.of, CASE
              WHEN d.state IN ('waiting', 'claimed') THEN 'queued'
              WHEN d.state = 'handed_over' THEN 'running'
              WHEN d.end_cause = 'lost' THEN 'lost'
              WHEN d.end_cause IN ('released', 'closed', 'undone') THEN 'cancelled'
              WHEN d.end_cause <> 'run_ended' THEN 'no_result'
              WHEN d.result_outcome IS NULL THEN 'running'
              WHEN d.result_outcome IN ('proposal', 'questions') AND d.result IS NOT NULL
                THEN d.result_outcome
              WHEN r.state = 'cancelled' THEN 'cancelled'
              WHEN r.state = 'lost' THEN 'lost'
              ELSE 'no_result'
            END AS place
            FROM dispatch_runs AS d
            LEFT JOIN runs AS r ON r.dispatch_run_id = d.id
            WHERE d.work_item_id = ? AND d.take_in = ?
            ORDER BY d.attempt DESC
            LIMIT 1
          ) AS l ON true
          """,
          w.id,
          w.take_in,
          w.id,
          w.take_in
        ),
      on: true,
      as: :explore_status
  end

  # statuses/1 is the status of each of the work items `ids`, by id, as `with_status/1`
  # derives it: `%{id => status}`, with no entry for an id that names no work item.
  @doc false
  @spec statuses([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => status}
  def statuses(ids) when is_list(ids) do
    from(w in WorkItem, as: :work_item, where: w.id in ^ids)
    |> with_status()
    |> select([work_item: w, explore_status: s], {w.id, s.status})
    |> Repo.all()
    |> Map.new(fn {id, name} -> {id, status_of(name)} end)
  end

  # status_name/1 is the text `with_status/1` gives for `status`, and status_names/1 the
  # texts of `statuses`, for a query's filter.
  @doc false
  @spec status_name(status) :: String.t()
  def status_name(status) when status in @statuses, do: Atom.to_string(status)

  @doc false
  @spec status_names([status]) :: [String.t()]
  def status_names(statuses) when is_list(statuses), do: Enum.map(statuses, &status_name/1)

  # status_of/1 is the status whose text `with_status/1` gives as `name`.
  @doc false
  @spec status_of(String.t()) :: status
  for status <- @statuses do
    def status_of(unquote(Atom.to_string(status))), do: unquote(status)
  end

  ## Reading

  # steps/3 is the runs of the take ins `take_ins` of the work item `work_item_id`, or of
  # every take in for `:all`, each where it stands at `now`, by take in, then attempt.
  # Two queries: the runs with their registered runs, then the result event with the
  # highest sequence of each registered run whose outcome is not stored yet; and the
  # adapters of the runs that stopped at a call to one, and the walks of the runs whose
  # harness walk failed.
  @doc false
  @spec steps(Ecto.UUID.t(), [pos_integer] | :all, DateTime.t()) :: [step]
  def steps(work_item_id, take_ins, %DateTime{} = now) when is_binary(work_item_id) do
    query =
      from d in DispatchRun,
        left_join: r in Run,
        on: r.dispatch_run_id == d.id,
        where: d.work_item_id == ^work_item_id,
        order_by: [asc: d.take_in, asc: d.attempt],
        select: {d, r}

    query = if take_ins == :all, do: query, else: where(query, [d], d.take_in in ^take_ins)
    rows = Repo.all(query)

    # The adapter of each run that stopped at a call to one, a third query only when one
    # did, and the walk of each run whose harness walk failed, a fourth only when one did.
    dispatch_runs =
      rows |> Enum.map(&elem(&1, 0)) |> Repo.preload(:failed_adapter) |> failed_walks()

    rows = Enum.zip_with(dispatch_runs, rows, fn d, {_d, r} -> {d, r} end)

    events =
      result_events(for {%DispatchRun{result_outcome: nil}, %Run{id: id}} <- rows, do: id)

    for {dispatch_run, run} <- rows,
        do: step(dispatch_run, run, run && Map.get(events, run.id), now)
  end

  # The runs ended `harness_unresolved` with their walk (`harness_walk`), read in one
  # query; the others as they are.
  defp failed_walks(dispatch_runs) do
    case for(%DispatchRun{end_cause: :harness_unresolved, id: id} <- dispatch_runs, do: id) do
      [] ->
        dispatch_runs

      ids ->
        walks =
          Repo.all(from h in RunHarness, where: h.dispatch_run_id in ^ids)
          |> Map.new(&{&1.dispatch_run_id, &1})

        for dispatch_run <- dispatch_runs do
          case Map.fetch(walks, dispatch_run.id) do
            {:ok, walk} -> %{dispatch_run | harness_walk: walk}
            :error -> dispatch_run
          end
        end
    end
  end

  defp result_events([]), do: %{}

  defp result_events(run_ids) do
    from(e in Event,
      where: e.run_id in ^run_ids and e.type == ^Result.event_type(),
      distinct: e.run_id,
      order_by: [asc: e.run_id, desc: e.sequence]
    )
    |> Repo.all()
    |> Map.new(&{&1.run_id, &1})
  end

  # current/2 is where Explore stands for `work_item`'s current take in at `now`: its
  # `status`, its runs (`steps`, oldest first), its latest run (`step`, nil for none) and
  # its confirmation, or nil.
  @doc false
  @spec current(WorkItem.t(), DateTime.t()) :: %{
          status: status,
          steps: [step],
          step: step | nil,
          confirmation: Confirmation.t() | nil
        }
  def current(%WorkItem{id: id, take_in: take_in}, %DateTime{} = now) do
    steps = steps(id, [take_in], now)
    confirmation = confirmation(id, take_in)

    %{
      status: status(steps, not is_nil(confirmation)),
      steps: steps,
      step: List.last(steps),
      confirmation: confirmation
    }
  end

  # confirmation/2 is the confirmation of take in `take_in` of the work item `id`, or nil.
  @doc false
  @spec confirmation(Ecto.UUID.t(), pos_integer) :: Confirmation.t() | nil
  def confirmation(id, take_in),
    do: Repo.one(from c in Confirmation, where: c.work_item_id == ^id and c.take_in == ^take_in)

  # answers/1 is every answer given for the work item `id`, by take in, attempt and
  # position.
  @doc false
  @spec answers(Ecto.UUID.t()) :: [Answer.t()]
  def answers(id) do
    Repo.all(
      from a in Answer,
        where: a.work_item_id == ^id,
        order_by: [asc: a.take_in, asc: a.attempt, asc: a.position]
    )
  end

  # events/1 is the events of the work item `id`, in the order they happened.
  @doc false
  @spec events(Ecto.UUID.t()) :: [WorkItemEvent.t()]
  def events(id) do
    Repo.all(
      from e in WorkItemEvent, where: e.work_item_id == ^id, order_by: [asc: e.at, asc: e.id]
    )
  end

  # run_state/1 is the state of a step's run as the run pages name it: the registered
  # run's, nil for a run waiting for its claim, and for a run that ended before its handover,
  # `:cancelled` when it was released, closed or undone and `:failed` otherwise.
  @doc false
  @spec run_state(step) :: atom | nil
  def run_state(%{run: %Run{state: state}}), do: Map.get(@run_states, state)

  def run_state(%{dispatch_run: %DispatchRun{state: :ended, end_cause: cause}})
      when cause in [:released, :closed, :undone],
      do: :cancelled

  def run_state(%{dispatch_run: %DispatchRun{state: :ended}}), do: :failed
  def run_state(_step), do: nil

  # started_at/1 is when a step's run started, as its registered run says: nil before.
  @doc false
  @spec started_at(step) :: DateTime.t() | nil
  def started_at(%{run: %Run{} = run}), do: run.started_at || run.attached_at || run.registered_at
  def started_at(_step), do: nil

  # ended_at/1 is when a step's run ended: nil while it has not, or reads as running.
  @doc false
  @spec ended_at(step) :: DateTime.t() | nil
  def ended_at(%{place: place}) when place in [:queued, :running], do: nil

  def ended_at(%{run: run, dispatch_run: dispatch_run}) do
    case run do
      %Run{} -> run.exited_at || run.lost_at || run.outcome_received_at || dispatch_run.updated_at
      nil -> dispatch_run.updated_at
    end
  end
end
