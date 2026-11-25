defmodule Apiary.Findings do
  @moduledoc false

  # The findings of a work item: the problems that its reviews and checks raised about a
  # target, each with its history of events, and the base of each target.
  #
  # **Scope.** A finding belongs to one take in of the work item and one target. The
  # findings and the bases of an earlier take in are kept, but no read here lists them, and
  # they gate nothing. A finding's id is `f` and its number (`Apiary.Findings.Finding.id/1`):
  # the numbers count the findings of the work item from 1, across its take ins and its
  # targets.
  #
  # **Who writes.** A run writes through `post/3`, from the run API's
  # `POST /v1/runs/<id>/findings`: a raise, a repeat, a reply (`fixed` or `disputed`) and a
  # close (`fixed` or `dismissed`). A person's Accept as it is accepts the open findings of
  # the escalated stage (`accept_open/3`, from `Apiary.Stages`). Every write locks the work
  # item first, so two writes for one work item run one after the other. Events are only
  # added; the table's trigger refuses an update and a delete.
  #
  # **What a repeat does.** A repeat of an open finding adds `repeated`. A repeat of a
  # finding that a run closed reopens it with `reopened`. A repeat of a finding that a
  # person closed adds `repeated_after_person_close` and leaves it closed: a run never
  # reopens what a person closed. A run's close of such a finding is kept as an event and
  # changes nothing either.
  #
  # **The gate.** A stage passes only while it owns no open blocking finding of the work
  # item's current take in (`gate/2`, `open_blocking/2`). The findings that another stage
  # owns, and the findings that are not blocking, never keep it from passing.

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, only: [from: 2]

  alias Apiary.Findings.{Base, Event, Finding}
  alias Apiary.Repo
  alias Apiary.WorkItems.WorkItem

  # The most findings a list has, the run contract's limit of its answer, and the most
  # events of a finding it shows, the newest.
  @max_listed 500
  @max_events 100
  # The most ids that a refusal of a pass lists.
  @max_refused 50

  @typedoc "A stage of a process version's document, with its `id` and `name`."
  @type stage :: map

  @typedoc """
  Why a pass is refused: the stage, the ids of up to 50 of its open blocking findings and
  their count.
  """
  @type refusal ::
          {:open_blocking_findings,
           %{
             stage_id: String.t(),
             stage: String.t() | nil,
             findings: [String.t()],
             count: pos_integer
           }}

  ## Reads

  @doc """
  The findings of the current take in of `work_item` on the target `target_id`, open ones
  first, then by number, each with its target and its newest #{@max_events} events, at
  most #{@max_listed}. A target id of nil has none.
  """
  @spec list(WorkItem.t(), Ecto.UUID.t() | nil) :: [Finding.t()]
  def list(%WorkItem{}, nil), do: []

  def list(%WorkItem{id: id, take_in: take_in}, target_id) do
    findings =
      Repo.all(
        from f in Finding,
          where: f.work_item_id == ^id and f.take_in == ^take_in and f.target_id == ^target_id,
          order_by: [desc: f.state == "open", asc: f.number],
          limit: @max_listed,
          preload: [:target]
      )

    events = newest_events(Enum.map(findings, & &1.id))
    Enum.map(findings, &%{&1 | events: Map.get(events, &1.id, [])})
  end

  # The newest #{@max_events} events of each finding, oldest first. A lateral join reads
  # them on the index of (finding_id, position), newest first and at most
  # #{@max_events} rows for each finding: a finding may have many more.
  defp newest_events([]), do: %{}

  defp newest_events(ids) do
    newest =
      from e in Event,
        where: e.finding_id == parent_as(:finding).id,
        order_by: [desc: e.position],
        limit: @max_events

    from(f in Finding,
      as: :finding,
      where: f.id in ^ids,
      inner_lateral_join: e in subquery(newest),
      on: true,
      order_by: [e.finding_id, e.position],
      select: e
    )
    |> Repo.all()
    |> Enum.group_by(& &1.finding_id)
  end

  @doc "The bases of the current take in of `work_item` on the target `target_id`."
  @spec bases(WorkItem.t(), Ecto.UUID.t() | nil) :: [Base.t()]
  def bases(%WorkItem{}, nil), do: []

  def bases(%WorkItem{id: id, take_in: take_in}, target_id) do
    Repo.all(
      from b in Base,
        where: b.work_item_id == ^id and b.take_in == ^take_in and b.target_id == ^target_id,
        preload: [:target]
    )
  end

  @doc """
  The open findings that the stage `stage_id` owns in the current take in of `work_item`,
  on every target, blocking ones first, then by number: `%{number, severity, point}`.
  """
  @spec open(WorkItem.t(), String.t() | nil) :: [map]
  def open(%WorkItem{}, nil), do: []
  # A work item that is not stored yet, as the prediction of a first take in reads one.
  def open(%WorkItem{take_in: nil}, _stage_id), do: []

  def open(%WorkItem{id: id, take_in: take_in}, stage_id) do
    Repo.all(
      from f in Finding,
        where: f.work_item_id == ^id and f.take_in == ^take_in,
        where: f.stage_id == ^stage_id and f.state == "open",
        order_by: [desc: f.severity == "blocking", asc: f.number],
        select: %{number: f.number, severity: f.severity, point: f.point}
    )
  end

  @doc """
  The text of each of `open` (`open/2`) for a person who reads them in one line each: the
  finding's id and its point, as a sentence.
  """
  @spec texts([map]) :: [String.t()]
  def texts(open) do
    for %{number: number, point: point} <- open do
      point = if String.ends_with?(point, [".", "!", "?"]), do: point, else: point <> "."
      "#{Finding.id(number)}: #{point}"
    end
  end

  @doc "The numbers of the open blocking findings that the stage `stage_id` owns (`open/2`)."
  @spec open_blocking(WorkItem.t(), String.t() | nil) :: [pos_integer]
  def open_blocking(work_item, stage_id),
    do: for(%{severity: "blocking", number: number} <- open(work_item, stage_id), do: number)

  @doc """
  The count of open blocking findings of each stage that owns a finding in the current
  take in of `work_item`, 0 included: `[{stage_id, count}]`, by stage id.
  """
  @spec open_blocking_counts(WorkItem.t()) :: [{String.t(), non_neg_integer}]
  def open_blocking_counts(%WorkItem{id: id, take_in: take_in}) do
    Repo.all(
      from f in Finding,
        where: f.work_item_id == ^id and f.take_in == ^take_in,
        group_by: f.stage_id,
        order_by: f.stage_id,
        select:
          {f.stage_id,
           type(
             fragment(
               "count(*) FILTER (WHERE ? = 'open' AND ? = 'blocking')",
               f.state,
               f.severity
             ),
             :integer
           )}
    )
  end

  ## The gate

  @doc """
  Whether `stage` may pass: `:ok` while it owns no open blocking finding of the work
  item's current take in, else `{:error, refusal}` with the stage, the ids of up to
  #{@max_refused} of those findings and their count. Call it with the work item locked:
  no other write changes the result until the caller's transaction ends.
  """
  @spec gate(WorkItem.t(), stage) :: :ok | {:error, refusal}
  def gate(%WorkItem{} = work_item, %{"id" => stage_id} = stage) do
    case open_blocking(work_item, stage_id) do
      [] ->
        :ok

      numbers ->
        {:error,
         {:open_blocking_findings,
          %{
            stage_id: stage_id,
            stage: stage["name"],
            findings: numbers |> Enum.take(@max_refused) |> Enum.map(&Finding.id/1),
            count: length(numbers)
          }}}
    end
  end

  @doc """
  The two lines a person reads when an approval or a move forward of the stage `stage` is
  refused for its `count` open blocking findings: the action, then the rule. The action is
  the one the page offers there: `:request_changes`, or `:another_round` at Explore's
  Confirm and at a gate `none`, which have no Request changes.
  """
  @spec refusal_lines(pos_integer, String.t(), :request_changes | :another_round) ::
          [String.t()]
  def refusal_lines(count, stage, action) do
    [
      refusal_action(action, count),
      gettext("%{stage} passes only when none is open.", stage: stage)
    ]
  end

  defp refusal_action(:request_changes, count) do
    ngettext(
      "Click Request changes. 1 blocking finding is open.",
      "Click Request changes. %{count} blocking findings are open.",
      count
    )
  end

  defp refusal_action(:another_round, count) do
    ngettext(
      "Click Run another round. 1 blocking finding is open.",
      "Click Run another round. %{count} blocking findings are open.",
      count
    )
  end

  @doc """
  The message of the run contract's refusal `open_blocking_findings` of a verdict
  `passed` of the stage `stage` (its name in the contract), whose `count` open blocking
  findings include `ids`: two lines, the second indented by two spaces.
  """
  @spec verdict_message(String.t(), pos_integer, [String.t()]) :: String.t()
  def verdict_message(stage, 1, ids),
    do:
      "Send changes-requested in place of passed: #{stage} has 1 open blocking finding.\n" <>
        "  The open blocking finding is #{Enum.join(ids, ", ")}."

  def verdict_message(stage, count, ids),
    do:
      "Send changes-requested in place of passed: #{stage} has #{count} open blocking findings.\n" <>
        "  The open blocking findings are #{Enum.join(ids, ", ")}."

  @doc """
  The name of each stage of a process version's `document` in the run contract, by stage
  id: the stage's name in lower case, each run of characters other than `a-z` and `0-9`
  written as one hyphen, at most 64 characters, `Code review` as `code-review`. A stage
  gets the characters of its id after `st_` in place of that name when its name has no
  letter or digit, when that name is also another stage's, or when that name equals the
  characters after `st_` of another stage's id.
  """
  @spec stage_names(map | nil) :: %{String.t() => String.t()}
  def stage_names(%{"stages" => stages}) when is_list(stages) do
    named = for %{"id" => id} = stage <- stages, is_binary(id), do: {id, slug(stage["name"])}
    counts = Enum.frequencies(for {_id, name} <- named, name, do: name)
    id_names = Enum.frequencies(for {id, _name} <- named, do: id_name(id))

    Map.new(named, fn {id, name} ->
      # The id of the stage itself does not count against its name: `st_build` may be
      # `build`.
      taken = Map.get(id_names, name, 0) - if(id_name(id) == name, do: 1, else: 0)

      if is_binary(name) and counts[name] == 1 and taken == 0,
        do: {id, name},
        else: {id, id_name(id)}
    end)
  end

  def stage_names(_document), do: %{}

  @doc "The name of the stage `stage_id` in the run contract, by `stage_names/1`."
  @spec stage_name(map | nil, String.t()) :: String.t()
  def stage_name(document, stage_id),
    do: Map.get(stage_names(document), stage_id) || id_name(stage_id)

  defp slug(name) when is_binary(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.slice(0, 64)
      |> String.trim("-")

    if slug == "", do: nil, else: slug
  end

  defp slug(_name), do: nil

  defp id_name("st_" <> rest), do: rest
  defp id_name(id), do: id

  ## A run's events

  @doc """
  Writes a run's batch of findings events, under the work item's lock, in one
  transaction: first the bases, then the events in the order given. `run` has the run's
  `run_id` and `dispatch_run_id`. `batch` has `bases`, `[%{target_id, base}]`, and
  `events`, each with `kind` (`raise`, `repeat`, `reply_fixed`, `reply_disputed`,
  `close_fixed` or `close_dismissed`), `by`, `version` and `reason`; a raise has `ref`,
  `target_id`, `stage_id`, `source_kind`, `source_name`, `severity`, `place`, `point`,
  `problem`, `fix` and `proof`, and each other kind the finding's `number`. A repeat or a
  close may also have `run_stage_id`, the stage of the run: the repeat or the close is
  refused for a finding that another stage owns.

  `{:ok, %{created: [{ref, id}], open_blocking: [{stage_id, count}]}}`, the counts after
  the batch (`open_blocking_counts/1`). `{:error, :not_found}` for a work item that is
  gone or a run of the queue that ended (`Apiary.Runs.PushedCommit.refusal/1`), read
  again under the lock; `{:error, {:not_found, index}}` for the event at `index` whose
  finding the current take in of the work item does not have on that target;
  `{:error, {:other_stage, index}}` for the repeat or the close at `index` of a finding
  that a stage other than its `run_stage_id` owns, checked under the lock;
  `{:error, :base_changed}` for a base that differs from the one stored. An error writes
  nothing.
  """
  @spec post(WorkItem.t(), map, map) ::
          {:ok, %{created: [{String.t(), String.t()}], open_blocking: [{String.t(), integer}]}}
          | {:error,
             :not_found
             | :base_changed
             | {:not_found, non_neg_integer}
             | {:other_stage, non_neg_integer}}
  def post(%WorkItem{} = work_item, %{run_id: _, dispatch_run_id: dispatch_run_id} = run, batch) do
    Repo.transact(fn ->
      with %WorkItem{} = held <- held(work_item),
           %Apiary.Dispatches.DispatchRun{} = queued <-
             Repo.get(Apiary.Dispatches.DispatchRun, dispatch_run_id),
           nil <- Apiary.Runs.PushedCommit.refusal(queued),
           :ok <- write_bases(held, batch.bases),
           {:ok, created} <- write_events(held, run, batch.events) do
        {:ok, %{created: created, open_blocking: open_blocking_counts(held)}}
      else
        {:error, _reason} = error -> error
        _gone -> {:error, :not_found}
      end
    end)
  end

  defp held(%WorkItem{id: id, workspace_id: workspace_id}) do
    Repo.one(
      from w in WorkItem,
        where: w.id == ^id and w.workspace_id == ^workspace_id,
        lock: "FOR UPDATE"
    )
  end

  # A base is written once for each take in and target; the same base again writes
  # nothing, and another is refused.
  defp write_bases(work_item, bases) do
    Enum.reduce_while(bases, :ok, fn %{target_id: target_id, base: base}, :ok ->
      stored =
        Repo.one(
          from b in Base,
            where: b.work_item_id == ^work_item.id and b.take_in == ^work_item.take_in,
            where: b.target_id == ^target_id,
            select: b.base
        )

      cond do
        stored == base ->
          {:cont, :ok}

        is_binary(stored) ->
          {:halt, {:error, :base_changed}}

        true ->
          Repo.insert!(%Base{
            organisation_id: work_item.organisation_id,
            work_item_id: work_item.id,
            take_in: work_item.take_in,
            target_id: target_id,
            base: base,
            inserted_at: DateTime.utc_now()
          })

          {:cont, :ok}
      end
    end)
  end

  defp write_events(work_item, run, events) do
    events
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {event, index}, {:ok, created} ->
      case write_event(work_item, run, event) do
        {:ok, nil} -> {:cont, {:ok, created}}
        {:ok, number} -> {:cont, {:ok, [{event.ref, Finding.id(number)} | created]}}
        :not_found -> {:halt, {:error, {:not_found, index}}}
        :other_stage -> {:halt, {:error, {:other_stage, index}}}
      end
    end)
    |> case do
      {:ok, created} -> {:ok, Enum.reverse(created)}
      error -> error
    end
  end

  defp write_event(work_item, run, %{kind: "raise"} = event) do
    now = DateTime.utc_now()

    finding =
      Repo.insert!(%Finding{
        organisation_id: work_item.organisation_id,
        work_item_id: work_item.id,
        number: next_number(work_item),
        take_in: work_item.take_in,
        target_id: event.target_id,
        stage_id: event.stage_id,
        source_kind: event.source_kind,
        source_name: event.source_name,
        severity: event.severity,
        place: event.place,
        point: event.point,
        problem: event.problem,
        fix: event.fix,
        proof: event.proof,
        state: "open",
        inserted_at: now,
        updated_at: now
      })

    insert_event!(work_item, finding, "raised", qory(run, event))
    {:ok, finding.number}
  end

  defp write_event(work_item, run, %{kind: kind, number: number, target_id: target_id} = event) do
    case current(work_item, number, target_id) do
      nil ->
        :not_found

      %Finding{stage_id: stage_id}
      when is_map_key(event, :run_stage_id) and stage_id != event.run_stage_id ->
        :other_stage

      finding ->
        {event_kind, changes} = run_change(kind, finding)
        insert_event!(work_item, finding, event_kind, qory(run, event))
        changed!(finding, changes)
        {:ok, nil}
    end
  end

  # The event a run's event writes, and the finding's changes. A finding that a person
  # closed stays closed, whatever the run writes.
  defp run_change("repeat", %Finding{state: "open"}), do: {"repeated", %{}}

  defp run_change("repeat", %Finding{closed_by_person: true}),
    do: {"repeated_after_person_close", %{}}

  defp run_change("repeat", %Finding{}), do: {"reopened", %{state: "open"}}
  defp run_change("reply_fixed", %Finding{}), do: {"replied_fixed", %{disputed: false}}
  defp run_change("reply_disputed", %Finding{}), do: {"replied_disputed", %{disputed: true}}
  defp run_change("close_fixed", %Finding{closed_by_person: true}), do: {"closed_fixed", %{}}
  defp run_change("close_fixed", %Finding{}), do: {"closed_fixed", %{state: "fixed"}}

  defp run_change("close_dismissed", %Finding{closed_by_person: true}),
    do: {"closed_dismissed", %{}}

  defp run_change("close_dismissed", %Finding{}), do: {"closed_dismissed", %{state: "dismissed"}}

  defp qory(run, event),
    do: %{
      actor_kind: "qory",
      actor_name: event.by,
      run_id: run.run_id,
      version: event[:version],
      reason: event[:reason]
    }

  # The next number of the work item's findings. The work item is locked, so no other
  # write takes the same number; the unique index refuses one that would.
  defp next_number(%WorkItem{id: id}),
    do:
      (Repo.one(from f in Finding, where: f.work_item_id == ^id, select: max(f.number)) || 0) + 1

  # The finding `number` of the current take in of the work item, on the target `target_id`.
  defp current(%WorkItem{id: id, take_in: take_in}, number, target_id) do
    Repo.one(
      from f in Finding,
        where: f.work_item_id == ^id and f.take_in == ^take_in and f.number == ^number,
        where: f.target_id == ^target_id
    )
  end

  defp insert_event!(work_item, finding, kind, fields) do
    position =
      (Repo.one(from e in Event, where: e.finding_id == ^finding.id, select: max(e.position)) ||
         0) + 1

    Repo.insert!(
      struct!(
        Event,
        Map.merge(fields, %{
          finding_id: finding.id,
          position: position,
          kind: kind,
          # 1 where no round has started, as at a stage with no sequence.
          round: max(work_item.stage_round || 1, 1),
          stage_id: work_item.stage_id || finding.stage_id,
          inserted_at: DateTime.utc_now()
        })
      )
    )
  end

  defp changed!(_finding, changes) when changes == %{}, do: :ok

  defp changed!(finding, changes) do
    finding
    |> Ecto.Changeset.change(Map.put(changes, :updated_at, DateTime.utc_now()))
    |> Repo.update!()

    :ok
  end

  ## Accept as it is

  @doc """
  Accepts, as the user `user_id`, every open finding that the stage `stage_id` owns in the
  current take in of `work_item`, blocking or not, on each target: one `accepted` event
  each, which closes the finding as the person's. Call it in a transaction, with the work
  item locked.
  """
  @spec accept_open(WorkItem.t(), String.t(), Ecto.UUID.t()) :: :ok
  def accept_open(%WorkItem{id: id, take_in: take_in} = work_item, stage_id, user_id) do
    findings =
      Repo.all(
        from f in Finding,
          where: f.work_item_id == ^id and f.take_in == ^take_in,
          where: f.stage_id == ^stage_id and f.state == "open",
          order_by: f.number
      )

    Enum.each(findings, fn finding ->
      insert_event!(work_item, finding, "accepted", %{actor_kind: "person", user_id: user_id})
      changed!(finding, %{state: "accepted", closed_by_person: true})
    end)
  end
end
