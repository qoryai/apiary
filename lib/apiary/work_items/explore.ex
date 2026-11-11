defmodule Apiary.WorkItems.Explore do
  # Explore says where Explore stands for a work item, from the runs of its take ins
  # (`Apiary.Dispatches.DispatchRun`, with the run registered for each, `Apiary.Runs.Run`),
  # what each run gave, which the run of the queue keeps (`result_outcome`, written by
  # `Apiary.Dispatches.Settle` from the run's artifacts, `Apiary.Explore.Outcome`), and the
  # confirmation (`Apiary.WorkItems.Confirmation`). It writes nothing.
  # `Apiary.WorkItems.Moves` asks it under the work item's lock, and `Apiary.WorkItems`
  # reads the pages' maps from it.
  #
  # ## A run
  #
  # `step/2` is where one run of a take in stands:
  #
  #   * waiting or claimed: `:queued`; handed over: `:running`;
  #   * ended lost: `:lost`, or `:questions` when it left questions that wait for an
  #     answer; ended released: `:cancelled`; ended with its work item closed or undone,
  #     before its handover: `:cancelled`;
  #   * ended at its claim because the claim could not form what the run is made from
  #     (`variables_invalid`, `ticket_gone`, `inputs_invalid`), while it waited for its
  #     environment image's build, which failed (`build_failed`), or because its harness
  #     walk failed (`harness_unresolved`): `:no_result` with the outcome `:error`, and
  #     no registered run;
  #   * ended by its exit (`run_ended`): what the run gave decides, `:questions` or
  #     `:proposal`. Without either the run is `:cancelled` when the registered run reads as
  #     cancelled, `:lost` when it reads as lost, and otherwise `:no_result`, with its
  #     outcome. A run whose outcome is not stored yet reads as `:running`.
  #
  # ## A take in
  #
  # `status/2` is where Explore stands for a live work item, from the runs of its current
  # take in and whether that take in was confirmed: `:shape` once confirmed; else its
  # latest run's place, `:proposal` read as `:confirm`; and `:used_up` for a latest run at
  # `:no_result`, `:lost` or `:cancelled` whose attempt is its `of`, the run limit, where
  # no run is left. Questions wait for answers at any count of runs, as each answer adds
  # a run. A take in with no run yet is `:queued`. `with_status/1` derives the same status
  # in SQL, for a list of work items.
  #
  # `stage/1` is the stage a status is at, as a close records it: `:shape`
  # once confirmed, `:confirm` while the proposal waits, `:explore` otherwise.
  #
  # `status/3` is `status/2` with where the work item stands in its stage: a stage that
  # waits for answers is `:questions`, also after a confirmation, once the latest run has
  # ended. `with_status/1` and a close keep `status/2`. `member_view/2` is what a member's
  # answer, reply, send or Run another round reads (`Apiary.WorkItems.Moves`): that
  # status, a latest run that has not ended as itself, and `:gate` at the gate of any
  # stage but Explore's.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.Artifacts.{Artifact, ArtifactFile, Version}
  alias Apiary.Dispatches.DispatchRun
  alias Apiary.Harnesses.{RunHarness, WorkflowGap}
  alias Apiary.Repo
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.{Confirmation, WorkItem, WorkItemEvent}

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
    "lost" => :lost,
    "paused" => :paused
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

  @typedoc "Where a live work item stands for a member's answer, reply, send or round."
  @type member_status :: status | :gate

  @typedoc "What a run gave, or why it gave nothing."
  @type outcome :: :proposal | :questions | :error | :none | :refused | nil

  @typedoc """
  One run of a take in: the run of the queue, the run its claim registered (nil while it
  has none: waiting, or ended before its handover), its place and what it gave.
  """
  @type step :: %{
          dispatch_run: DispatchRun.t(),
          run: Run.t() | nil,
          take_in: pos_integer,
          attempt: pos_integer,
          of: pos_integer,
          place: place,
          outcome: outcome
        }

  ## A run

  # step/2 is where the run of the queue `dispatch_run` stands, with `run`, the run
  # registered for it or nil (the moduledoc).
  @doc false
  @spec step(DispatchRun.t(), Run.t() | nil) :: step
  def step(%DispatchRun{} = dispatch_run, run) do
    {place, outcome} = place(dispatch_run, run)

    %{
      dispatch_run: dispatch_run,
      run: run,
      take_in: dispatch_run.take_in,
      attempt: dispatch_run.attempt,
      of: dispatch_run.of,
      place: place,
      outcome: outcome
    }
  end

  defp place(%DispatchRun{state: state}, _run) when state in [:waiting, :claimed],
    do: {:queued, nil}

  defp place(%DispatchRun{state: :handed_over}, _run), do: {:running, nil}

  defp place(%DispatchRun{state: :ended, end_cause: :lost, result_outcome: :questions}, _run),
    do: {:questions, :questions}

  defp place(%DispatchRun{state: :ended, end_cause: :lost}, _run), do: {:lost, nil}

  defp place(%DispatchRun{state: :ended, end_cause: cause}, _run)
       when cause in [:released, :closed, :undone],
       do: {:cancelled, nil}

  defp place(%DispatchRun{state: :ended, end_cause: :run_ended, result_outcome: outcome}, run) do
    cond do
      is_nil(outcome) -> {:running, nil}
      outcome in [:proposal, :questions] -> {outcome, outcome}
      match?(%Run{state: "cancelled"}, run) -> {:cancelled, nil}
      match?(%Run{state: "lost"}, run) -> {:lost, nil}
      true -> {:no_result, outcome}
    end
  end

  defp place(%DispatchRun{state: :ended}, _run), do: {:no_result, :error}

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

      place when place in [:no_result, :lost, :cancelled] ->
        if latest.attempt >= latest.of, do: :used_up, else: place

      place ->
        place
    end
  end

  # status/3 is `status/2` for `work_item`, whose current take in has `steps`: `:questions`
  # where its stage waits for answers and the latest run has ended, at any stage, confirmed
  # or not.
  @doc false
  @spec status([step], boolean, WorkItem.t()) :: status
  def status([_ | _] = steps, confirmed?, %WorkItem{stage_state: :waiting_answers}) do
    case List.last(steps).place do
      place when place in [:queued, :running] -> status(steps, confirmed?)
      _ended -> :questions
    end
  end

  def status(steps, confirmed?, %WorkItem{}), do: status(steps, confirmed?)

  # member_view/2 is `current` (`current/2`) with the status a member's move on `work_item`
  # reads (the moduledoc). A proposal that waits at Confirm keeps `:confirm`, wherever the
  # work item went after a gate `none`.
  @doc false
  @spec member_view(map, WorkItem.t()) :: map
  def member_view(%{status: :confirm} = current, %WorkItem{}), do: current
  def member_view(%{step: nil} = current, %WorkItem{}), do: current

  def member_view(%{step: %{place: place}} = current, %WorkItem{})
      when place in [:queued, :running],
      do: %{current | status: place}

  def member_view(current, %WorkItem{stage_state: :waiting_answers}),
    do: %{current | status: :questions}

  def member_view(current, %WorkItem{stage_state: :at_gate, stage_id: stage_id} = work_item) do
    if stage_id == Apiary.Stages.explore_stage_id(work_item),
      do: current,
      else: %{current | status: :gate}
  end

  def member_view(current, %WorkItem{}), do: current

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
  # A run reads from what the run of the queue keeps, as `status/2` reads it. The status of
  # an ended work item is that of its last take in, which `status/2` does not give. For example, the live work items
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
            WHEN l.place IN ('no_result', 'lost', 'cancelled') AND l.attempt >= l.of
              THEN 'used_up'
            ELSE l.place
          END AS status
          FROM (SELECT 1) AS one
          LEFT JOIN LATERAL (
            SELECT d.attempt, d.of, CASE
              WHEN d.state IN ('waiting', 'claimed') THEN 'queued'
              WHEN d.state = 'handed_over' THEN 'running'
              WHEN d.end_cause = 'lost' AND d.result_outcome = 'questions' THEN 'questions'
              WHEN d.end_cause = 'lost' THEN 'lost'
              WHEN d.end_cause IN ('released', 'closed', 'undone') THEN 'cancelled'
              WHEN d.end_cause <> 'run_ended' THEN 'no_result'
              WHEN d.result_outcome IS NULL THEN 'running'
              WHEN d.result_outcome IN ('proposal', 'questions') THEN d.result_outcome
              WHEN r.state = 'cancelled' THEN 'cancelled'
              WHEN r.state = 'lost' THEN 'lost'
              ELSE 'no_result'
            END AS place
            FROM dispatch_runs AS d
            LEFT JOIN runs AS r ON r.dispatch_run_id = d.id
              AND (r.registered_at IS NOT NULL OR r.node_id IS NOT NULL)
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
  # every take in for `:all`, each where it stands, by take in, then attempt. `now` is not
  # read: it is kept for the callers that give it. One query for the runs with their
  # registered runs; then the adapters of the runs that stopped at a call to one, and the
  # walks of the runs whose harness walk failed.
  @doc false
  @spec steps(Ecto.UUID.t(), [pos_integer] | :all, DateTime.t()) :: [step]
  def steps(work_item_id, take_ins, %DateTime{} = _now) when is_binary(work_item_id) do
    query =
      from d in DispatchRun,
        left_join: r in subquery(Run.registered()),
        on: r.dispatch_run_id == d.id,
        where: d.work_item_id == ^work_item_id,
        order_by: [asc: d.take_in, asc: d.attempt],
        select: {d, r}

    query = if take_ins == :all, do: query, else: where(query, [d], d.take_in in ^take_ins)
    rows = Repo.all(query)

    # The adapter of each run that stopped at a call to one, a third query only when one
    # did, and the walk of each run whose harness walk failed or whose harness had no skill
    # for its workflow, a fourth only when one did.
    gaps = for {d, %Run{reason: reason}} <- rows, reason == WorkflowGap.code(), do: d.id

    dispatch_runs =
      rows |> Enum.map(&elem(&1, 0)) |> Repo.preload(:failed_adapter) |> failed_walks(gaps)

    rows = Enum.zip_with(dispatch_runs, rows, fn d, {_d, r} -> {d, r} end)

    for {dispatch_run, run} <- rows, do: step(dispatch_run, run)
  end

  # The runs ended `harness_unresolved`, and the runs `gaps` whose registered run ended
  # `workflow_not_in_harness`, with their walk (`harness_walk`), read in one query, and the
  # adapter of each walk that names one (`failed_adapter`), in another only when one does,
  # and every run's organisation and workspace, whose names the failure's words show; the
  # others as they are.
  defp failed_walks(dispatch_runs, gaps) do
    case for(%DispatchRun{end_cause: :harness_unresolved, id: id} <- dispatch_runs, do: id) ++
           gaps do
      [] ->
        dispatch_runs

      ids ->
        walks =
          Repo.all(
            from h in RunHarness, where: h.dispatch_run_id in ^ids, preload: :failed_adapter
          )
          |> Map.new(&{&1.dispatch_run_id, &1})

        for dispatch_run <- Repo.preload(dispatch_runs, [:organisation, :workspace]) do
          case Map.fetch(walks, dispatch_run.id) do
            {:ok, walk} -> %{dispatch_run | harness_walk: walk}
            :error -> dispatch_run
          end
        end
    end
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

  # proposal_version/3 is the version of the proposal the run `attempt` of take in
  # `take_in` of the work item `id` stands at: the number of the newest version of the
  # `proposal` named `main` a run of the take in up to it pushed; nil for none.
  @doc false
  @spec proposal_version(Ecto.UUID.t(), pos_integer, pos_integer) :: pos_integer | nil
  def proposal_version(id, take_in, attempt), do: version(id, take_in, attempt, "proposal")

  # version/4 is the version of the type `type` the run `attempt` of take in `take_in` of
  # the work item `id` stands at, the version a review comment on that type is on: the
  # number of the newest version of its artifact named `main` a run of the take in up to
  # it pushed; nil for none. A review comment's `on` has a type and a number and no
  # artifact name, so `main` is the only artifact of a type it can be on.
  @doc false
  @spec version(Ecto.UUID.t(), pos_integer, pos_integer, String.t()) :: pos_integer | nil
  def version(id, take_in, attempt, type) do
    Repo.one(
      from v in Version,
        join: a in Artifact,
        on: a.id == v.artifact_id,
        join: d in DispatchRun,
        on: d.id == v.run_id,
        where: a.work_item_id == ^id and a.type == ^type and a.name == "main",
        where: d.work_item_id == ^id and d.take_in == ^take_in and d.attempt <= ^attempt,
        order_by: [desc: v.number],
        limit: 1,
        select: v.number
    )
  end

  # versions/2 is the type and number of each version of an artifact named `main` that the
  # runs of take in `take_in` of the work item `id` pushed, the versions a review comment
  # of that take in is on. Versions restart per artifact, so a number alone is not enough.
  @doc false
  @spec versions(Ecto.UUID.t(), pos_integer) :: MapSet.t({String.t(), pos_integer})
  def versions(id, take_in), do: id |> versions_query(take_in) |> Repo.all() |> MapSet.new()

  # versions/3 is `versions/2` limited to the versions that runs at the stage
  # `{stage_id, explore?}` pushed (`at_stage/2`).
  @doc false
  @spec versions(Ecto.UUID.t(), pos_integer, {String.t() | nil, boolean}) ::
          MapSet.t({String.t(), pos_integer})
  def versions(id, take_in, {stage_id, explore?}) do
    id
    |> versions_query(take_in)
    |> where(^at_stage(stage_id, explore?))
    |> Repo.all()
    |> MapSet.new()
  end

  # at_stage/2 is the condition on a run of the queue, bound as `:dispatch`, that it ran at
  # the stage `stage_id`, or with no stage where `explore?`, as a run with no stage is
  # Explore's. Every run counts for a nil `stage_id`.
  @doc false
  @spec at_stage(String.t() | nil, boolean) :: Ecto.Query.dynamic_expr()
  def at_stage(nil, _explore?), do: dynamic(true)

  def at_stage(stage_id, true),
    do: dynamic([dispatch: d], d.stage_id == ^stage_id or is_nil(d.stage_id))

  def at_stage(stage_id, false), do: dynamic([dispatch: d], d.stage_id == ^stage_id)

  defp versions_query(id, take_in) do
    from v in Version,
      join: a in Artifact,
      on: a.id == v.artifact_id,
      join: d in DispatchRun,
      as: :dispatch,
      on: d.id == v.run_id,
      where: a.work_item_id == ^id and a.name == "main",
      where: d.work_item_id == ^id and d.take_in == ^take_in,
      select: {a.type, v.number}
  end

  # proposal/2 is version `number` of the work item `id`'s proposal named `main`, as a page
  # shows it (`document/3`).
  @doc false
  @spec proposal(Ecto.UUID.t(), pos_integer | nil) ::
          %{text: String.t(), version_id: String.t(), images: [String.t()]} | nil
  def proposal(id, number), do: document(id, "proposal", number)

  # document/3 is version `number` of the work item `id`'s artifact of `type` named `main`,
  # as a page shows it: `text`, the Markdown of its `text/markdown` file; `version_id`, the
  # version's public id (`av_…`); and `images`, the filenames of its image files, in
  # filename order. The version's `sources.json` is in none of them. Nil for no such
  # version, a version with no Markdown file, or one that cannot be read as UTF-8 text.
  @doc false
  @spec document(Ecto.UUID.t(), String.t(), pos_integer | nil) ::
          %{text: String.t(), version_id: String.t(), images: [String.t()]} | nil
  def document(_id, _type, nil), do: nil

  def document(id, type, number) when is_binary(type) and is_integer(number) do
    version =
      Repo.one(
        from v in Version,
          join: a in Artifact,
          on: a.id == v.artifact_id,
          where:
            a.work_item_id == ^id and a.type == ^type and a.name == "main" and
              v.number == ^number,
          preload: [files: ^from(f in ArtifactFile, order_by: f.filename)]
      )

    with %Version{files: files} <- version,
         %{} = file <- Enum.find(files, &markdown?/1),
         {:ok, source} <- Apiary.Artifacts.open_file(file),
         {:ok, text} <- bytes(source),
         true <- String.valid?(text) do
      %{
        text: text,
        version_id: version.public_id,
        images: for(%{content_type: "image/" <> _subtype} = image <- files, do: image.filename)
      }
    else
      _none -> nil
    end
  end

  defp markdown?(%{content_type: content_type}),
    do: String.starts_with?(content_type, "text/markdown")

  defp bytes(path) when is_binary(path), do: File.read(path)
  defp bytes(stream), do: {:ok, stream |> Enum.to_list() |> IO.iodata_to_binary()}

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
