defmodule ApiaryWeb.WorkItemLive.View do
  # What the work item page draws, from what `Apiary.WorkItems` reads: the plain maps
  # `ApiaryWeb.WorkItemComponents` takes. It reads nothing but the people and the
  # workspaces of the runs, and writes nothing.
  #
  # **People.** `Apiary.WorkItems.ExploreView` names people by the ids of their accounts.
  # `people/2` looks every account of a page up, once, and `person/2` gives the
  # components' person, `%{id:, name:, email:, you:}`: a person by their short name, the
  # local part of the address of their account, and that address, whether or not they are
  # a member of the organisation, as the Work items list names people; and **Former
  # member** for a deleted account, an id no account has, and no id at all. Where no id
  # means no person (no owner, or a close by the instance), the page passes nil and asks
  # for none.
  #
  # **Runs.** A run names the workspace it was queued in, where it stays when its work
  # item moves. Its id links its page only where the reader may read the runs of that
  # workspace (`run.read`, asked with the scope's person in that workspace); elsewhere it
  # is its short id alone, and a run that ended before its handover has no id at all.
  # How long a run took is in the run pages' words (`ApiaryWeb.RunComponents`).
  #
  # The feature is hidden from the documentation, so the module is too.
  @moduledoc false

  use ApiaryWeb, :verified_routes

  alias Apiary.{Access, Organisations}
  alias Apiary.Accounts.Scope
  alias ApiaryWeb.{People, RunComponents}

  @qory [:started, :asked, :proposed, :no_result, :lost, :cancelled]

  ## People

  @doc false
  # people/2 is the components' person of each id of `ids`, by id, named by their account,
  # read in one query for the page.
  @spec people(Scope.t(), [Ecto.UUID.t() | nil]) :: %{Ecto.UUID.t() => map}
  def people(%Scope{} = scope, ids) do
    me = scope.user && scope.user.id

    accounts = People.accounts(ids)

    for id <- ids, is_binary(id), into: %{} do
      email = People.account(accounts, id)
      {id, %{id: id, name: People.short(email), email: email, you: id == me}}
    end
  end

  @doc false
  # person/2 is the person `id` among `people`: Former member for an id not among them,
  # and for nil.
  @spec person(map, Ecto.UUID.t() | nil) :: map
  def person(_people, nil), do: former(nil)
  def person(people, id), do: Map.get(people, id) || former(id)

  defp former(id),
    do: %{id: id, name: People.former_member(), email: People.former_member(), you: false}

  ## The page

  @doc false
  # page/5 is everything the page draws of the work item `row`: the work item map, the
  # take in's earlier runs, the earlier take ins, the changes of its confirmation, and the
  # Thread (`thread` of `Apiary.WorkItems.thread/3`, or none), with the
  # names its ticket has (`Apiary.WorkItems.ticket_names/2`); and the people it names, for
  # `person/2`.
  @spec page(Scope.t(), Apiary.WorkItems.WorkItem.t(), map, [map], map) :: map
  def page(%Scope{} = scope, row, explore, thread, names) do
    ctx = context(scope, row, explore, thread)
    runs = Enum.map(explore.earlier_runs, &run(&1, ctx))
    latest = if explore.run, do: latest_run(explore.run, explore, ctx), else: no_run()

    %{
      work_item: work_item(row, explore, names, latest, ctx),
      earlier_runs: runs,
      earlier_take_ins: Enum.map(explore.earlier_take_ins, &take_in(&1, ctx)),
      changes:
        Map.new(explore.changes, fn {field, %{value: value, by_id: by_id}} ->
          {field, %{value: value, by: person(ctx.people, by_id)}}
        end),
      thread: thread(thread, row, names, ctx),
      people: ctx.people
    }
  end

  defp context(scope, row, explore, thread) do
    take_ins = explore.earlier_take_ins

    all_runs =
      Enum.flat_map(take_ins, & &1.runs) ++ explore.earlier_runs ++ List.wrap(explore.run)

    ids =
      [row.owner_id, row.taken_in_by_id, explore.ended_by_id, explore.confirmed_by_id] ++
        explore.answers_by_ids ++
        Enum.map(all_runs, & &1.answered_by_id) ++
        Enum.flat_map(take_ins, &[&1.taken_in_by_id, &1.ended_by_id]) ++
        Enum.map(Map.values(explore.changes), & &1.by_id) ++
        Enum.flat_map(thread, &[&1[:actor_id], &1[:owner_id]]) ++
        ApiaryWeb.WorkItemLive.Comments.people_ids(thread) ++
        [scope.user && scope.user.id]

    workspace_ids =
      Enum.map(all_runs, & &1.workspace_id) ++
        for(%{run: %{workspace_id: id}} <- thread, do: id)

    %{
      scope: scope,
      people: people(scope, ids),
      readable: readable(scope, workspace_ids),
      all_runs: all_runs
    }
  end

  # The workspaces of `ids` whose runs the scope's person may read, by id.
  defp readable(scope, ids) do
    case ids |> Enum.reject(&is_nil/1) |> Enum.uniq() do
      [] ->
        %{}

      ids ->
        for workspace <- Organisations.list_workspaces(scope),
            workspace.id in ids,
            Access.can?(%{scope | workspace: workspace}, :"run.read", workspace),
            into: %{},
            do: {workspace.id, workspace}
    end
  end

  defp run_path(ctx, %{id: id, workspace_id: workspace_id}) when is_binary(id) do
    case Map.get(ctx.readable, workspace_id) do
      nil -> nil
      workspace -> ~p"/#{ctx.scope.organisation}/#{workspace}/runs/#{id}"
    end
  end

  defp run_path(_ctx, _run), do: nil

  defp work_item(row, explore, names, latest, ctx) do
    %{
      number: row.number,
      title: row.title,
      key: names[:key],
      url: row.url,
      repository: names[:collection_title] || row.collection_title,
      status: explore.status,
      stage: explore.stage,
      owner: row.owner_id && person(ctx.people, row.owner_id),
      ended_by: ended_by(explore.status, explore.ended_by_id, ctx),
      ended_at: explore.ended_at,
      ended_reason: reason(explore.ended_reason),
      updated_at: row.updated_at,
      taken_in_by: person(ctx.people, row.taken_in_by_id),
      taken_in_at: row.taken_in_at,
      first_instruction: row.first_instruction,
      runs: runs_summary(ctx),
      run: latest,
      confirmed_by: explore.confirmed_at && person(ctx.people, explore.confirmed_by_id),
      confirmed_at: explore.confirmed_at
    }
  end

  # Who ended it: none for a live work item, and none where the instance closed it.
  defp ended_by(status, by_id, ctx) do
    cond do
      status not in [:declined, :closed, :undone] -> nil
      status == :closed and is_nil(by_id) -> nil
      true -> person(ctx.people, by_id)
    end
  end

  # The reason the instance gave for a close, as the components name it: one they have
  # words for, or none.
  defp reason("adapter_removed"), do: :adapter_removed
  defp reason(_other), do: nil

  # Details' runs: those handed over, of every take in, the latest of them, and how many
  # are not ended; nil before any.
  defp runs_summary(ctx) do
    case Enum.filter(ctx.all_runs, &is_binary(&1.id)) do
      [] ->
        nil

      runs ->
        latest = List.last(runs)

        %{
          latest: %{id: latest.id, path: run_path(ctx, latest)},
          count: length(runs),
          running: Enum.count(runs, &(&1.state in [:pending, :running]))
        }
    end
  end

  defp latest_run(run, explore, ctx) do
    run
    |> run(ctx)
    |> Map.put(:answers_by, Enum.map(explore.answers_by_ids, &person(ctx.people, &1)))
  end

  # The take in's first run before it exists, as Explore stands then (queued): its place,
  # of the most a take in has, and nothing it gave.
  defp no_run do
    %{
      id: nil,
      path: nil,
      workspace_id: nil,
      attempt: 1,
      of: Apiary.Dispatches.of(),
      state: nil,
      place: :queued,
      started_at: nil,
      ended_at: nil,
      duration_ms: nil,
      duration: nil,
      outcome: nil,
      end_cause: nil,
      proposal: nil,
      understanding: nil,
      questions: [],
      answered_by: nil,
      answered_at: nil,
      answers_by: []
    }
  end

  defp run(run, ctx) do
    Map.merge(run, %{
      path: run_path(ctx, run),
      duration: run.duration_ms && RunComponents.format_duration_ms(run.duration_ms),
      answered_by: run.answered_at && person(ctx.people, run.answered_by_id),
      answers_by: []
    })
  end

  defp take_in(take_in, ctx) do
    %{
      taken_in_by: person(ctx.people, take_in.taken_in_by_id),
      taken_in_at: take_in.taken_in_at,
      ended: take_in.ended,
      ended_by: ended_by(take_in.ended, take_in.ended_by_id, ctx),
      ended_at: take_in.ended_at,
      ended_reason: reason(take_in.ended_reason),
      runs: Enum.map(take_in.runs, &run(&1, ctx))
    }
  end

  ## The Thread

  # The Thread's events as `ApiaryWeb.WorkItemComponents.thread_event/1` takes them, each
  # a map of its attributes. A decline that recorded no stage it has words for has no
  # line. A comment stays as it is, for `ApiaryWeb.WorkItemLive.Comments.comment_line/1`.
  defp thread(entries, row, names, ctx) do
    entries
    |> Enum.reject(&(&1.kind == :declined and &1.stage not in [:explore, :confirm]))
    |> Enum.map(fn
      %{kind: :comment} = comment -> comment
      entry -> event(entry, row, names, ctx)
    end)
  end

  defp event(entry, row, names, ctx) do
    base = %{kind: entry.kind, at: entry.at}

    base
    |> put_actor(entry, ctx)
    |> Map.merge(event_fields(entry, row, names, ctx))
  end

  defp put_actor(event, %{kind: kind}, _ctx) when kind in @qory, do: event
  defp put_actor(event, %{kind: :closed, actor_id: nil}, _ctx), do: Map.put(event, :actor, nil)

  defp put_actor(event, entry, ctx),
    do: Map.put(event, :actor, person(ctx.people, entry[:actor_id]))

  defp event_fields(%{kind: :taken_in} = entry, row, names, ctx) do
    %{
      key: names[:key],
      url: row.url,
      again: entry.again,
      owner: entry.owner_id && person(ctx.people, entry.owner_id),
      first_instruction: entry.first_instruction
    }
  end

  defp event_fields(%{kind: :started} = entry, _row, _names, ctx),
    do: %{run: run_ref(entry.run, ctx), start: entry.start}

  defp event_fields(%{kind: :asked} = entry, _row, _names, ctx),
    do: %{
      run: run_ref(entry.run, ctx),
      questions: entry.questions,
      duration: duration(entry.duration_ms)
    }

  defp event_fields(%{kind: :proposed} = entry, _row, _names, ctx),
    do: %{
      run: run_ref(entry.run, ctx),
      duration: duration(entry.duration_ms),
      owner: entry.owner_id && person(ctx.people, entry.owner_id)
    }

  defp event_fields(%{kind: :no_result} = entry, _row, _names, ctx),
    do: %{run: run_ref(entry.run, ctx), outcome: entry.outcome}

  defp event_fields(%{kind: kind} = entry, _row, _names, ctx)
       when kind in [:lost, :cancelled, :explore_again],
       do: %{run: run_ref(entry.run, ctx)}

  defp event_fields(%{kind: :answered} = entry, _row, _names, ctx),
    do: %{run: run_ref(entry.run, ctx), questions: entry.questions}

  defp event_fields(%{kind: :confirmed} = entry, _row, _names, _ctx),
    do: %{changed: entry.changed}

  defp event_fields(%{kind: :declined} = entry, _row, _names, _ctx), do: %{stage: entry.stage}

  defp event_fields(%{kind: :closed} = entry, _row, _names, _ctx),
    do: %{reason: reason(entry.reason)}

  defp event_fields(_entry, _row, _names, _ctx), do: %{}

  defp run_ref(run, ctx) do
    %{id: run.id, path: run_path(ctx, run), attempt: run.attempt, of: run.of}
  end

  defp duration(ms) when is_integer(ms), do: RunComponents.format_duration_ms(ms)
  defp duration(_none), do: RunComponents.short_id(nil)
end
