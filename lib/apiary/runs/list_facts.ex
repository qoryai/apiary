defmodule Apiary.Runs.ListFacts do
  # ListFacts reads, for the runs of a page of the runs list, what the list shows beside the
  # fields of the run's row: the workflow it ran, the stage that placed it, its work item and how
  # it started. Four reads, whatever the number of runs: the runs with their run of the
  # queue, harness walk and work item; the process versions of the stages; the work items'
  # events. It writes nothing. `Apiary.Runs.list_facts/2` is the way in.
  #
  # The run of the queue of a run is its `dispatch_run_id`, or, for a run whose start
  # failed, the run of the queue of its dispatch (`dispatch_id`), which it left.
  #
  # By run id, each run's facts:
  #
  #   * `workflow`: the name of the workflow the claim handed to the machine, its harness
  #     walk's `workflow`, only while that walk is resolved with the origin `:file`,
  #     `:setting` or `:builtin` (`Apiary.Dispatches.Handover`, the harness members); the
  #     atom `:prebuild` for a run of the step `prebuild`; nil for every other run: a walk
  #     pending or failed, the origin `:none`, a run of the queue queued before walks were
  #     kept, and a run of no queue.
  #   * `stage`: `%{name: name, round: round or nil}`, the stage of the process that
  #     placed the run, with the feature `workflow_model` on, where the run of the queue
  #     has a stage (`stage_id`) and its version has a stage of that id, and the stage's
  #     name is not the workflow's: their names differ in more than case, and the name is
  #     not the first word of the workflow's name, before its first "-", so Explore with
  #     explore-a-ticket has none. `round` is the run's round inside a loop
  #     (`loop_entry` set), nil outside one. Nil otherwise.
  #   * `work_item`: `%{number: n, title: title, here: boolean, target_system: system,
  #     target_path: path}` for the work item of the run of the queue, the target nil for
  #     a work item with none. Where the work item moved to another workspace since,
  #     `here` is false and the number and the target are nil, since they are the other
  #     workspace's. Nil for no work item.
  #   * `started_by`: how the run started (`started_by/3`), nil where no record says.
  @moduledoc false

  import Ecto.Query, warn: false

  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Processes
  alias Apiary.Processes.Version
  alias Apiary.Repo
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.{WorkItem, WorkItemEvent}

  @handed_over [:file, :setting, :builtin]
  @starts [:taken_in, :answered, :explore_again]

  @typedoc """
  How a run started:

    * `:direct`, a run of no queue: a `qory run` on a machine;
    * `:image_requeue`, a run queued again after the run before it found its image missing;
    * `{:test_run, person}`, the run of a test work item, by who took it in;
    * `{:taken_in, person}` and `{:taken_in_again, person}`, the first run of the work
      item's first take in or of a later one, by who took it in;
    * `{:answers, attempt, of, person}`, a run queued by answers to the questions of the
      run before it, by who answered;
    * `{:comment, attempt, of, person}`, a run queued by a comment on the proposal of the
      run before it, or by a send of the review comments, by who commented or sent them;
    * `{:explore_again, person}`, a run queued by Explore again, by who asked;
    * `:process`, any other run the stage runner placed.

  `person` is the account id of the event's person; an event of the instance or an
  adapter has none, and the run then reads as no record says (nil).
  """
  @type started_by ::
          :direct
          | :image_requeue
          | :process
          | {:test_run | :taken_in | :taken_in_again | :explore_again, Ecto.UUID.t()}
          | {:answers | :comment, pos_integer, pos_integer, Ecto.UUID.t()}

  @doc false
  @spec of(Scope.t(), [Run.t()]) :: %{Ecto.UUID.t() => map}
  def of(%Scope{}, []), do: %{}

  def of(%Scope{organisation: organisation, workspace: workspace}, runs) do
    ids = Enum.map(runs, & &1.id)

    rows =
      Repo.all(
        from r in Run,
          where:
            r.id in ^ids and r.organisation_id == ^organisation.id and
              r.workspace_id == ^workspace.id,
          left_join: x in Dispatch,
          on: x.id == r.dispatch_id,
          left_join: d in DispatchRun,
          on: d.id == coalesce(r.dispatch_run_id, x.dispatch_run_id),
          left_join: h in RunHarness,
          on: h.dispatch_run_id == d.id,
          left_join: w in WorkItem,
          on: w.id == d.work_item_id,
          select: %{
            run_id: r.id,
            dispatch_run_id: d.id,
            step: d.step,
            take_in: d.take_in,
            attempt: d.attempt,
            of: d.of,
            image_requeue: d.image_requeue,
            process_version_id: d.process_version_id,
            stage_id: d.stage_id,
            round: d.round,
            stage_entry: d.stage_entry,
            loop_entry: d.loop_entry,
            walk_state: h.state,
            walk_origin: h.origin,
            walk_workflow: h.workflow,
            work_item_id: w.id,
            number: w.number,
            title: w.title,
            test: w.test,
            target_system: w.target_system,
            target_path: w.target_path,
            here: w.workspace_id == ^workspace.id
          }
      )

    stages = stage_names(rows)
    events = events(rows)

    Map.new(rows, fn row ->
      workflow = workflow(row)

      {row.run_id,
       %{
         workflow: workflow,
         stage: stage(row, stages, workflow),
         work_item: work_item(row),
         started_by: started_by(row, stages, Map.get(events, row.work_item_id, []))
       }}
    end)
  end

  defp workflow(%{step: step}) when is_nil(step), do: nil

  defp workflow(row) do
    cond do
      row.step == DispatchRun.prebuild() ->
        :prebuild

      row.walk_state == :resolved and row.walk_origin in @handed_over and
        is_binary(row.walk_workflow) and row.walk_workflow != "" ->
        row.walk_workflow

      true ->
        nil
    end
  end

  defp stage(row, stages, workflow) do
    with true <- Apiary.Stages.on?(),
         id when is_binary(id) <- row.stage_id,
         %{name: name} when is_binary(name) and name != "" <-
           stages[{row.process_version_id, id}],
         false <- same_name?(name, workflow) do
      %{name: name, round: if(row.loop_entry, do: row.round)}
    else
      _none -> nil
    end
  end

  defp same_name?(name, workflow) when is_binary(workflow) do
    name = String.downcase(name)
    workflow = String.downcase(workflow)
    name == workflow or name == workflow |> String.split("-", parts: 2) |> hd()
  end

  defp same_name?(_name, _workflow), do: false

  # The stages the rows name, by `{version id, stage id}`, each `%{name:, first:}`, `first`
  # whether it is the first stage of its version: one read of their versions.
  defp stage_names(rows) do
    version_ids = for %{stage_id: s, process_version_id: v} <- rows, s, v, uniq: true, do: v

    if version_ids == [] do
      %{}
    else
      for version <- Repo.all(from v in Version, where: v.id in ^version_ids),
          %{stage_id: stage_id, process_version_id: version_id} <- rows,
          version_id == version.id,
          stage = Processes.stage(version, stage_id),
          into: %{},
          do:
            {{version.id, stage_id},
             %{name: stage["name"], first: first_stage_id(version) == stage_id}}
    end
  end

  defp first_stage_id(%Version{document: %{"stages" => [%{"id" => id} | _rest]}}), do: id
  defp first_stage_id(_version), do: nil

  defp work_item(%{work_item_id: nil}), do: nil

  # A work item that moved to another workspace keeps its title alone: its number and its
  # target are the other workspace's.
  defp work_item(%{here: false} = row),
    do: %{number: nil, title: row.title, here: false, target_system: nil, target_path: nil}

  defp work_item(row),
    do: %{
      number: row.number,
      title: row.title,
      here: true,
      target_system: row.target_system,
      target_path: row.target_path
    }

  # The events that say who started a run of each work item, by work item, in the order
  # they happened, each take in numbered as `Apiary.WorkItems.ExploreView` numbers it.
  defp events(rows) do
    ids = for %{work_item_id: id} <- rows, id, uniq: true, do: id

    if ids == [] do
      %{}
    else
      from(e in WorkItemEvent,
        where: e.work_item_id in ^ids and e.kind in ^@starts,
        order_by: [asc: e.work_item_id, asc: e.at, asc: e.id],
        select: %{
          work_item_id: e.work_item_id,
          kind: e.kind,
          actor_kind: e.actor_kind,
          actor_id: e.actor_id,
          data: e.data
        }
      )
      |> Repo.all()
      |> Enum.group_by(& &1.work_item_id)
      |> Map.new(fn {id, events} -> {id, numbered(events)} end)
    end
  end

  # A `:taken_in` event names its take in in its data; one that does not counts on from
  # the one before.
  defp numbered(events) do
    {events, _taken} =
      Enum.map_reduce(events, 0, fn
        %{kind: :taken_in, data: %{"take_in" => n}} = event, _taken when is_integer(n) ->
          {Map.put(event, :take_in, n), n}

        %{kind: :taken_in} = event, taken ->
          {Map.put(event, :take_in, taken + 1), taken + 1}

        event, taken ->
          {Map.put(event, :take_in, event.data["take_in"]), taken}
      end)

    events
  end

  # How a run started, by its run of the queue, its stage and its work item's events (the
  # type). The first rule that holds decides, in this order: a run of no queue; a
  # prebuild, of which no record says; a run queued again after a missing image; a test
  # work item's run; the run a take in queued; a run after answers; a run of Explore
  # again; a run the stage runner placed.
  defp started_by(%{dispatch_run_id: nil}, _stages, _events), do: :direct

  defp started_by(row, stages, events) do
    cond do
      row.step == DispatchRun.prebuild() ->
        nil

      row.image_requeue ->
        :image_requeue

      row.test ->
        person(:test_run, find(events, :taken_in, row.take_in))

      queued_by_take_in?(row, stages) ->
        taken_in(row, find(events, :taken_in, row.take_in))

      answered = answers_event(events, row) ->
        answers(row, answered)

      again = find(events, :explore_again, row.take_in, row.attempt) ->
        person(:explore_again, again)

      row.stage_id ->
        :process

      true ->
        nil
    end
  end

  # The run a take in queued: its first attempt, and, for a run the stage runner placed,
  # the start of the first stage of its version (entry 0, round 1). The stage runner
  # numbers its runs on from the take in's last, so where the take in queued none (the
  # first stage waits, or has no workflow), a later stage's first run is attempt 1 too.
  defp queued_by_take_in?(%{attempt: 1, stage_id: nil}, _stages), do: true

  defp queued_by_take_in?(%{attempt: 1, stage_entry: 0, round: 1} = row, stages),
    do: match?(%{first: true}, stages[{row.process_version_id, row.stage_id}])

  defp queued_by_take_in?(_row, _stages), do: false

  defp taken_in(%{take_in: 1}, event), do: person(:taken_in, event)
  defp taken_in(_row, event), do: person(:taken_in_again, event)

  # The answers to the questions of the run before `row`, or a comment on that run's
  # proposal.
  defp answers_event(events, row), do: find(events, :answered, row.take_in, row.attempt - 1)

  defp answers(row, %{actor_kind: :person, actor_id: id, data: %{"comment" => true}})
       when is_binary(id),
       do: {:comment, row.attempt, row.of, id}

  # A send of the review comments, at the gate or while the questions wait, answers no
  # question: the run reads as queued by a comment.
  defp answers(row, %{actor_kind: :person, actor_id: id, data: %{"review_comments" => _}})
       when is_binary(id),
       do: {:comment, row.attempt, row.of, id}

  defp answers(row, %{actor_kind: :person, actor_id: id}) when is_binary(id),
    do: {:answers, row.attempt, row.of, id}

  defp answers(_row, _event), do: nil

  defp person(kind, %{actor_kind: :person, actor_id: id}) when is_binary(id), do: {kind, id}
  defp person(_kind, _event), do: nil

  # The latest event of `kind` of take in `take_in`, and of `attempt` where given.
  defp find(events, kind, take_in, attempt \\ nil) do
    events
    |> Enum.filter(fn event ->
      event.kind == kind and event.take_in == take_in and
        (is_nil(attempt) or event.data["attempt"] == attempt)
    end)
    |> List.last()
  end
end
