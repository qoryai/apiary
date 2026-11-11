defmodule Apiary.Runs do
  @moduledoc """
  The runs of a workspace, as the console reads them.

  Events come in through `Apiary.Runs.Ingest`, are folded by `Apiary.Runs.Projector` and
  watched by `Apiary.Runs.Liveness`; this module is what pages call. Every function takes
  the caller's scope first and reads only the scope's workspace. One reads more:
  `workspace_facts/3`, for the organisation's overview, which reads the workspaces of the
  scope's organisation it is given. One reads the whole instance and takes no scope:
  `list_instance_runs/2`, for `GET /v1/runs` signed with a diagnostics key.

  Changes are announced on two topics of `Apiary.PubSub`:

    * `topic(workspace_id)`, `"runs:<workspace_id>"`: `{:run_changed, %Run{}}` whenever a
      run of the workspace was projected or found lost, among other changes of its row
      or of its dispatch, such as the starter's first `dispatched` and the redemption of
      the run's code;
    * `topic(workspace_id, run_id)`, `"run:<workspace_id>:<run_id>"` (`run_id` is the
      row's id): `{:run_projected, %Run{}, first_sequence, last_sequence}` after a
      projection, with the lowest and highest sequence it folded, and
      `{:run_changed, %Run{}}` as above, and `{:machine_end_changed, %Run{}}` when the
      pool's starter reported about the removal of the run's machine, at
      `POST /v1/dispatches/<dispatch_id>/machine-end`.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query, warn: false
  import Apiary.Days, only: [sql_day: 2]
  import Apiary.Runs.Place, only: [shown_host: 1]

  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Days
  alias Apiary.Edition
  alias Apiary.Nodes.Node
  alias Apiary.Organisations.{Workspace, Organisation}
  alias Apiary.Repo
  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Runs.{Connection, Filters, ListFacts, RunApi, Target, Run}
  alias Apiary.WorkItems.WorkItem

  @default_limit 50
  @max_limit 200
  @page_size 50
  @hits_page 10

  ## Topics

  def topic(workspace_id), do: "runs:#{workspace_id}"
  def topic(workspace_id, run_id), do: "run:#{workspace_id}:#{run_id}"

  @doc """
  The topic of the sidebar's alive count: `{:runs_touched, workspace_id}` whenever a run
  of the workspace changed, and nothing else, so every page of the workspace can follow it
  without taking the messages of `topic/1`.
  """
  def touched_topic(workspace_id), do: "runs:#{workspace_id}:touched"

  @doc "Subscribes the caller to `touched_topic/1` of the scope's workspace."
  def subscribe_touched(%Scope{workspace: %Workspace{id: workspace_id}}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, touched_topic(workspace_id))
  end

  @doc "Subscribes the caller to the scope's workspace."
  def subscribe(%Scope{workspace: %Workspace{id: workspace_id}}) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id))
  end

  @doc "Subscribes the caller to one run of the scope's workspace."
  def subscribe(%Scope{workspace: %Workspace{id: workspace_id}}, %Run{
        id: id,
        workspace_id: workspace_id
      }) do
    Phoenix.PubSub.subscribe(Apiary.PubSub, topic(workspace_id, id))
  end

  @doc "Ends `subscribe/2` for one run of the scope's workspace."
  def unsubscribe(%Scope{workspace: %Workspace{id: workspace_id}}, %Run{
        id: id,
        workspace_id: workspace_id
      }) do
    Phoenix.PubSub.unsubscribe(Apiary.PubSub, topic(workspace_id, id))
  end

  @doc """
  The queued runs of the scope's workspace (`Apiary.Runs.Run.queued?/1`), and its runs
  with the ids `ids`, whatever their state: what the runs list reads again when the
  workspace's queue changes. One query.
  """
  @spec queued_or(Scope.t(), [Ecto.UUID.t()]) :: [Run.t()]
  def queued_or(%Scope{} = scope, ids) when is_list(ids) do
    Repo.all(where(in_scope(scope), ^dynamic([run: r], ^Run.queued_condition() or r.id in ^ids)))
  end

  @doc false
  def broadcast_changed(%Run{} = run) do
    broadcast_touched(run)
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.workspace_id), {:run_changed, run})
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.workspace_id, run.id), {:run_changed, run})
  end

  @doc false
  def broadcast_machine_end(%Run{} = run) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(run.workspace_id, run.id),
      {:machine_end_changed, run}
    )
  end

  @doc false
  def broadcast_projected(%Run{} = run, first_sequence, last_sequence) do
    broadcast_touched(run)
    Phoenix.PubSub.broadcast(Apiary.PubSub, topic(run.workspace_id), {:run_changed, run})

    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      topic(run.workspace_id, run.id),
      {:run_projected, run, first_sequence, last_sequence}
    )
  end

  defp broadcast_touched(%Run{workspace_id: workspace_id}) do
    Phoenix.PubSub.broadcast(
      Apiary.PubSub,
      touched_topic(workspace_id),
      {:runs_touched, workspace_id}
    )
  end

  ## Reads

  @doc "How many runs of the workspace are alive now: pending or running."
  def count_alive(%Scope{} = scope) do
    # Tagged, so that what measures a page's own reads can tell the sidebar's timed count
    # from them (`metadata.options[:sidebar]` of the repo's telemetry event).
    Repo.aggregate(from(r in in_scope(scope), where: r.state in ^Run.alive_states()), :count,
      telemetry_options: [sidebar: true]
    )
  end

  @doc "One run of the scope's workspace by its row id; raises when the workspace has none such."
  def get_run!(%Scope{} = scope, id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.one!(from r in in_scope(scope), where: r.id == ^id)
      :error -> raise Ecto.NoResultsError, queryable: Run
    end
  end

  @doc """
  One run of the scope's workspace by its `public_id`, `rn_` and 16 characters, the id in the API;
  raises `Ecto.NoResultsError` when the workspace has none such, which a run of
  another workspace and a malformed id both are, the node's run id among them.
  """
  def get_run_by_public_id!(%Scope{} = scope, public_id) do
    if Run.public_id?(public_id),
      do: Repo.one!(from r in in_scope(scope), where: r.public_id == ^public_id),
      else: raise(Ecto.NoResultsError, queryable: Run)
  end

  @doc """
  One run of the scope's workspace by `param`: its number in that workspace
  (`Run.parse_number/1`), the form in the run's URL, or its `public_id`, `rn_` and 16
  characters; nil for a number or id the workspace does not have and for anything of neither shape.
  """
  @spec get_run_by_param(Scope.t(), term) :: Run.t() | nil
  def get_run_by_param(%Scope{} = scope, param) do
    case Run.parse_number(param) do
      {:ok, number} ->
        Repo.one(from r in in_scope(scope), where: r.number == ^number)

      :error ->
        if Run.public_id?(param),
          do: Repo.one(from r in in_scope(scope), where: r.public_id == ^param)
    end
  end

  @doc "The workspace's runs, newest first. `limit:` defaults to #{@default_limit}, at most #{@max_limit}."
  def list_runs(%Scope{} = scope, opts \\ []) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(1) |> min(@max_limit)

    Repo.all(
      from r in in_scope(scope), order_by: [desc: r.inserted_at, desc: r.id], limit: ^limit
    )
  end

  @doc """
  A page of the runs of every workspace of the instance, for `GET /v1/runs` signed with a
  diagnostics key (`run.list_instance`, `Apiary.Access`): `query` is the request's raw
  query string. `{:ok, document}`, the contract's run list, `%{"runs" => rows, "next" =>
  id or nil}`, or `{:error, parameter}` with the name of the parameter the request breaks
  the rule of (`Apiary.Runs.RunList`). One query reads the page's runs, after a query for
  the workspace and one for `before` when the request has them. `opts`: `now`, the time
  the answer is built (the current time).
  """
  @spec list_instance_runs(String.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def list_instance_runs(query, opts \\ []) when is_binary(query),
    do: Apiary.Runs.RunList.answer(query, opts)

  ## The runs list

  @doc """
  A page of the workspace's runs under the filters, in their order (`sort`: newest first by
  when they started, a run that has not started placed by when its record was written
  (when it was queued, for a run of a workspace's queue; else when it registered), the
  queued runs (`Apiary.Runs.Run.queued?/1`) before all others, the most recently queued
  first; oldest first; the longest first, by the duration its exit gave or else the time it reported
  elapsed; the most denials first), `per` to a page. Returns the page's runs, the page it
  is (the last one, when the filters asked for one beyond it), the total, the pages and
  the page size.
  """
  def page_runs(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    query = filtered(scope, filters, now)
    total = Repo.aggregate(query, :count)
    pages = max(ceil(total / filters.per), 1)
    page = min(filters.page, pages)

    runs = page_of(query, filters, page)

    %{runs: runs, page: page, total: total, pages: pages, per: filters.per}
  end

  # Newest first, the queued runs (`Apiary.Runs.Run.queued?/1`) come first, the most
  # recently queued first; then the other runs from the index, in its order. A page with
  # the last queued runs is filled up with the first of the others after them.
  defp page_of(query, %Filters{sort: "newest", per: per}, page) do
    offset = (page - 1) * per
    queued_runs = where(query, ^Run.queued_condition())

    queued =
      Repo.all(
        from r in queued_runs,
          order_by: [desc: r.inserted_at, desc: r.id],
          limit: ^per,
          offset: ^offset
      )

    rest_offset =
      cond do
        length(queued) == per -> nil
        queued != [] or offset == 0 -> 0
        true -> max(offset - Repo.aggregate(queued_runs, :count), 0)
      end

    if rest_offset do
      rest =
        from r in sorted(not_queued(query), "newest"),
          limit: ^(per - length(queued)),
          offset: ^rest_offset

      queued ++ Repo.all(rest)
    else
      queued
    end
  end

  defp page_of(query, filters, page), do: Repo.all(page_query(query, filters, page))

  defp not_queued(query), do: where(query, ^dynamic(not (^Run.queued_condition())))

  # Newest and oldest first are the order of the index
  # `runs_workspace_id_started_or_first_heard_index`, expression included, read forwards or
  # backwards, so a page is read from the index and never sorted.
  defp page_query(query, %Filters{sort: sort, per: per}, page) do
    from r in sorted(query, sort),
      limit: ^per,
      offset: ^((page - 1) * per)
  end

  defp sorted(query, "oldest"),
    do: order_by(query, [r], asc: coalesce(r.started_at, r.inserted_at), asc: r.id)

  defp sorted(query, "longest"),
    do:
      order_by(query, [r],
        desc_nulls_last:
          fragment("COALESCE(?, ?::bigint * 1000)", r.duration_ms, r.elapsed_seconds),
        desc: coalesce(r.started_at, r.inserted_at),
        desc: r.id
      )

  defp sorted(query, "denials"),
    do:
      order_by(query, [r],
        desc: r.denied_count,
        desc: coalesce(r.started_at, r.inserted_at),
        desc: r.id
      )

  defp sorted(query, _newest),
    do: order_by(query, [r], desc: coalesce(r.started_at, r.inserted_at), desc: r.id)

  @doc """
  What the runs list shows of each of `runs`, runs of the scope's workspace, beside the
  fields of their rows, by run id: `%{workflow:, stage:, work_item:, started_by:}`. `workflow` is
  the name of the workflow the run's claim handed to its machine, `:prebuild` for a run
  that builds an environment, or nil where the run was handed none; `stage` the stage of
  the workspace's process that placed it, `%{name:, round:}`, where its name adds to the
  workflow's, else nil; `work_item` its work item, `%{number:, public_id:, title:, here:,
  target_system:, target_path:}`, where the work item moved to another workspace `here`
  false and the number and the target nil, else nil; `started_by` how it started: `:direct` (a run of no queue),
  `:image_requeue`, `:process` (any other run the stage runner placed), `{:test_run, person}`,
  `{:taken_in, person}`, `{:taken_in_again, person}`, `{:explore_again, person}`,
  `{:answers, attempt, of, person}` or `{:comment, attempt, of, person}`, `person` an
  account id; nil where no record says. A
  run of another workspace has none. Four reads, whatever the number of runs.
  """
  @spec list_facts(Scope.t(), [Run.t()]) :: %{Ecto.UUID.t() => map}
  def list_facts(%Scope{} = scope, runs) when is_list(runs), do: ListFacts.of(scope, runs)

  @doc """
  The work item of `run`, the `work_item` of `list_facts/2` for the run alone, in one read:
  nil for a run of no work item and for a run of another workspace.
  """
  @spec work_item(Scope.t(), Run.t()) :: map | nil
  def work_item(%Scope{} = scope, %Run{} = run), do: ListFacts.work_item(scope, run)

  # The query of a page of the runs that are not queued, which newest first follow the
  # queued ones (`page_of/3`).
  @doc false
  def page_runs_query(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()),
    do: scope |> filtered(filters, now) |> not_queued() |> page_query(filters, filters.page)

  @doc """
  The page of the list, under the filters and in their order, that holds the first run
  started on or before the end of `date`, a day in the scope's time zone
  (`Apiary.Accounts.Scope.time_zone/1`), as the filters' dates are: newest
  first, the runs that started after that day come before it; oldest first, the page that
  holds the first run started on or after the day's start. When no run is on that side of
  the day it is the last page; in any other order, the first. One count on the index.
  """
  @spec jump_page(Scope.t(), Filters.t(), Date.t(), DateTime.t()) :: pos_integer
  def jump_page(%Scope{} = scope, %Filters{} = filters, %Date{} = date, now \\ DateTime.utc_now()) do
    query = filtered(scope, filters, now)
    {start, next} = Days.range(date, Scope.time_zone(scope))

    before =
      case filters.sort do
        "newest" ->
          Repo.aggregate(
            where(
              query,
              ^dynamic(
                [run: r],
                coalesce(r.started_at, r.inserted_at) >= ^next or ^Run.queued_condition()
              )
            ),
            :count
          )

        "oldest" ->
          Repo.aggregate(
            from(r in query, where: coalesce(r.started_at, r.inserted_at) < ^start),
            :count
          )

        _other ->
          0
      end

    total = Repo.aggregate(query, :count)
    last = max(ceil(total / filters.per), 1)
    min(div(before, filters.per) + 1, last)
  end

  @doc """
  The views of the runs list, each counted under every other filter (the views set the
  states and the denials, so those are left out): `%{all:, alive:, ended_badly:,
  with_denials:}`, in one query. The families are `Apiary.Runs.Filters.families/0`.
  """
  def view_counts(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    Repo.one(
      from r in filtered(scope, %{filters | states: [], denials: false}, now),
        select: %{
          all: count(r.id),
          alive: filter(count(r.id), r.state in ^Run.alive_states()),
          ended_badly: filter(count(r.id), r.state in ^Run.ended_badly_states()),
          with_denials: filter(count(r.id), r.denied_count > 0)
        }
    )
  end

  @doc """
  How many runs the filters return; with no filters, how many runs the workspace has, which
  the list's empty state says the filters hide.
  """
  def count_runs(scope, filters \\ nil, now \\ DateTime.utc_now())

  def count_runs(%Scope{} = scope, nil, _now), do: Repo.aggregate(in_scope(scope), :count)

  def count_runs(%Scope{} = scope, %Filters{} = filters, now),
    do: Repo.aggregate(filtered(scope, filters, now), :count)

  @doc """
  ran_on_a_node?/1 is whether a run of the scope's workspace names a node of it, as the
  runs list's node filter offers them, deleted ones included: what a reader the nodes are
  hidden from (`Apiary.Features.visible?/2`) may know of the workspace's nodes.
  """
  @spec ran_on_a_node?(Scope.t()) :: boolean
  def ran_on_a_node?(%Scope{} = scope) do
    Repo.exists?(
      from [run: r] in in_scope(scope),
        join: n in Node,
        on:
          n.id == r.node_id and n.organisation_id == r.organisation_id and
            n.workspace_id == r.workspace_id
    )
  end

  @doc """
  run_node/2 is the node in use of the scope's workspace that `value` names, by its public
  id or else by its name, among only the nodes a run of the workspace ran on: the nodes the
  runs list already names. `nil` for any other value. It is what a filter's node reads for
  a reader the nodes are hidden from (`Apiary.Features.visible?/2`), who may read a node's
  name only as a run names it.
  """
  @spec run_node(Scope.t(), String.t()) :: Node.t() | nil
  def run_node(
        %Scope{
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id}
        } = scope,
        value
      )
      when is_binary(value) do
    ran = from r in in_scope(scope), where: r.node_id == parent_as(:node).id, select: 1

    from(n in Node,
      as: :node,
      where: n.organisation_id == ^organisation_id and n.workspace_id == ^workspace_id,
      where: is_nil(n.deleted_at),
      where: n.public_id == ^value or n.name == ^value,
      where: exists(ran)
    )
    |> Repo.all()
    |> Enum.sort_by(&(&1.public_id != value))
    |> List.first()
  end

  @rail_size 20

  @doc "How many targets the rail lists before \"n more\", and how many each asks for."
  def rail_size, do: @rail_size

  @typedoc "A target, by its id (`tg_…`), its system and its path, and the runs it has under the filters."
  @type target_count :: %{
          public_id: String.t(),
          system: String.t(),
          path: String.t(),
          runs: non_neg_integer
        }

  @doc """
  The rail of the runs list: the targets of the runs under the filters without their
  target, counted in runs. `%{all:, pinned:, targets:, more:, unassigned:}`: `all` counts
  every run under those filters; `pinned` is each of `pinned:` (a list of the person's
  pinned targets, `%{id:, public_id:, system:, path:}` as `Apiary.Targets.list_pins/2`
  gives them, in its order) with its runs, none left out; `targets` the targets with the most
  runs, `limit:` of them (default #{@rail_size}), the pinned ones left out; `more` how many
  more there are; `unassigned` the runs that name no target. `narrow:` keeps the targets
  whose `system/path` holds the text anywhere, as text (`like/1`), and lists them all,
  pinned or not.
  """
  @spec target_counts(Scope.t(), Filters.t(), keyword) :: %{
          all: non_neg_integer,
          pinned: [target_count],
          targets: [target_count],
          more: non_neg_integer,
          unassigned: non_neg_integer
        }
  def target_counts(%Scope{} = scope, %Filters{} = filters, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    rail(filtered(scope, %{filters | target: nil}, now), opts)
  end

  # The targets each rail and Target section counts by: the runs' target, joined for the
  # id Qory Apiary gives it, which every link to a narrowed list writes.
  defp by_target(base) do
    from [run: r] in base,
      join: t in Target,
      as: :counted_target,
      on: t.id == r.target_id,
      group_by: [t.id, t.public_id, t.system, t.path]
  end

  # `base` is a query with the run bound as `:run`; what is counted per target is `count`,
  # a dynamic aggregate over `base`: the distinct runs on the runs list, the distinct
  # destinations on the connections page.
  defp rail(base, opts, count \\ dynamic([run: r], count(r.id, :distinct))) do
    limit = opts |> Keyword.get(:limit, @rail_size) |> max(1) |> min(@max_limit * 5)
    narrow = like(Keyword.get(opts, :narrow))
    pinned = if narrow, do: [], else: Enum.uniq_by(Keyword.get(opts, :pinned, []), & &1.id)
    pinned_ids = Enum.map(pinned, & &1.id)

    {rows, total} = count_targets(base, narrow, limit, pinned_ids, count)

    pinned_counts =
      case pinned_ids do
        [] ->
          %{}

        ids ->
          Repo.all(
            from [run: r] in base,
              where: r.target_id in ^ids,
              group_by: r.target_id,
              select: ^%{id: dynamic([run: r], r.target_id), n: count}
          )
          |> Map.new(&{&1.id, &1.n})
      end

    all = Repo.one(from q in base, select: ^count)
    unassigned = Repo.one(from [run: r] in base, where: is_nil(r.target_id), select: ^count)

    %{
      all: all,
      unassigned: unassigned,
      pinned:
        for(
          pin <- pinned,
          do: %{
            public_id: pin.public_id,
            system: pin.system,
            path: pin.path,
            runs: Map.get(pinned_counts, pin.id, 0)
          }
        ),
      targets:
        for(
          row <- rows,
          do: %{public_id: row.public_id, system: row.system, path: row.path, runs: row.n}
        ),
      more: max(total - length(rows), 0)
    }
  end

  # A target and its count, as a select of the rail's: `%{public_id:, system:, path:, n:}`.
  defp target_count_fields(count) do
    %{
      public_id: dynamic([counted_target: t], t.public_id),
      system: dynamic([counted_target: t], t.system),
      path: dynamic([counted_target: t], t.path),
      n: count
    }
  end

  # The targets under `base` with the most runs, `limit` of them, without the targets of
  # the row ids in `except`, and how many there are without those; narrowed to a `like/1`
  # pattern.
  defp count_targets(base, pattern, limit, except, count) do
    grouped = by_target(base)

    grouped =
      if pattern,
        do:
          where(
            grouped,
            [counted_target: t],
            ilike(fragment("? || '/' || ?", t.system, t.path), ^pattern)
          ),
        else: grouped

    grouped =
      if except != [],
        do: where(grouped, [counted_target: t], t.id not in ^except),
        else: grouped

    rows =
      Repo.all(
        from [counted_target: t] in grouped,
          order_by: ^[desc: count],
          order_by: [asc: t.path, asc: t.system],
          limit: ^(limit + 1),
          select: ^target_count_fields(count)
      )

    total =
      if length(rows) > limit,
        do:
          Repo.one(
            from g in subquery(select(grouped, [counted_target: t], %{s: t.id})),
              select: count()
          ),
        else: length(rows)

    {Enum.take(rows, limit), total}
  end

  @doc """
  What a `repo:` of the query names, among the workspace's targets: the id (`tg_…`) of the
  one target whose `system/path` or whose path it is (compared exactly, then without
  regard to case), the ids of every target on that path where it is on more than one
  system, in the order of their systems; nil where it names none.
  `ApiaryWeb.Narrowing.typed/2` asks it.
  """
  @spec resolve_target(Scope.t(), String.t()) :: [String.t()] | nil
  def resolve_target(%Scope{} = scope, text) when is_binary(text) do
    folded = String.downcase(text)

    rows =
      Repo.all(
        from t in targets_in(scope),
          where:
            fragment("lower(? || '/' || ?)", t.system, t.path) == ^folded or
              fragment("lower(?)", t.path) == ^folded,
          order_by: [asc: t.system, asc: t.path],
          select: %{public_id: t.public_id, system: t.system, path: t.path},
          limit: 50
      )

    exact = &Enum.filter(rows, fn row -> &1.(row.system, row.path) end)

    with [] <- exact.(fn system, path -> "#{system}/#{path}" == text end),
         [] <- exact.(fn _system, path -> path == text end),
         [] <- exact.(fn system, path -> String.downcase("#{system}/#{path}") == folded end),
         [] <- exact.(fn _system, path -> String.downcase(path) == folded end) do
      nil
    else
      [%{path: path} | _] = found -> for(%{path: ^path} = row <- found, do: row.public_id)
    end
  end

  @facet_size 50

  @doc "How many options a section of the Filter menu holds, and how many more each asks for."
  def facet_size, do: @facet_size

  @doc """
  The options of each section of the runs list's Filter menu, counted from the data: every
  facet is counted under the other filters and the range, not under itself, so a section
  shows what choosing another value would give. `%{state:, target:, runtime:, host:, node:,
  item:}`, each `%{options: [{label, value, count}], total: n}`: the most frequent values,
  #{@facet_size} of them unless `limits:` maps the facet's name to more, and the chosen one,
  with how many values there are. `narrow:` maps a facet's name to what the reader typed in
  its section, matched anywhere in the value, case-insensitively, as text and never as a
  pattern, over every value there is.
  """
  def run_facets(%Scope{} = scope, %Filters{} = filters, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    narrow = Keyword.get(opts, :narrow, %{})
    limits = Keyword.get(opts, :limits, %{})
    limit = &facet_limit(limits[&1])

    %{
      state: state_facet(scope, filters, now),
      target:
        target_facet(
          scope,
          filtered(scope, %{filters | target: nil}, now),
          filters.target,
          narrow["target"],
          limit.("target")
        ),
      runtime: text_facet(scope, filters, now, :runtime, narrow["runtime"], limit.("runtime")),
      host: text_facet(scope, filters, now, :host, narrow["host"], limit.("host")),
      node: node_facet(scope, filters, now, narrow["node"], limit.("node")),
      item: item_facet(scope, filters, now, narrow["item"], limit.("item"))
    }
  end

  defp facet_limit(n) when is_integer(n), do: n |> max(@facet_size) |> min(@facet_size * 20)
  defp facet_limit(_n), do: @facet_size

  defp state_facet(scope, filters, now) do
    # A queued run (`Apiary.Runs.Run.queued?/1`) is counted as `queued`, apart from the
    # other pending runs.
    counts =
      Repo.all(
        from r in filtered(scope, %{filters | states: []}, now),
          group_by: ^[dynamic([run: r], r.state), Run.queued_condition()],
          select:
            ^%{
              state: dynamic([run: r], r.state),
              queued: Run.queued_condition(),
              n: dynamic([run: r], count(r.id))
            }
      )
      |> Enum.reduce(%{}, fn %{state: state, queued: queued, n: n}, acc ->
        Map.update(acc, if(queued, do: "queued", else: state), n, &(&1 + n))
      end)

    options = for state <- Run.shown_states(), count = counts[state], do: {state, state, count}
    %{options: options, total: length(options)}
  end

  # `base` is a query with the run bound as `:run`, counted by `count` (distinct runs by
  # default), as the rail counts. A target's option is `{{system, path}, id, count}`, its
  # value the id (`tg_…`) the address writes and its label the pair the page names it by;
  # a chosen target the most frequent leave out comes first.
  defp target_facet(
         scope,
         base,
         chosen,
         narrow,
         limit,
         count \\ dynamic([run: r], count(r.id, :distinct))
       ) do
    pattern = like(narrow)
    {rows, total} = count_targets(base, pattern, limit, [], count)
    options = for row <- rows, do: {{row.system, row.path}, row.public_id, row.n}

    options =
      case chosen do
        [_ | _] = ids ->
          listed = MapSet.new(options, &elem(&1, 1))

          chosen_options(scope, base, Enum.reject(ids, &MapSet.member?(listed, &1)), count) ++
            options

        _none ->
          options
      end

    unassigned = Repo.one(from [run: r] in base, where: is_nil(r.target_id), select: ^count)

    options =
      if unassigned > 0 and is_nil(pattern),
        do: options ++ [{gettext("Unassigned"), "none", unassigned}],
        else: options

    %{options: options, total: total + if(unassigned > 0 and is_nil(pattern), do: 1, else: 0)}
  end

  # The options of chosen targets of the workspace, by their ids, in that order, each with
  # what `base` counts of it: two reads, however many there are.
  defp chosen_options(_scope, _base, [], _count), do: []

  defp chosen_options(scope, base, ids, count) do
    targets =
      Repo.all(
        from t in targets_in(scope),
          where: t.public_id in ^ids,
          select: %{id: t.id, public_id: t.public_id, system: t.system, path: t.path}
      )

    counts =
      Repo.all(
        from [run: r] in base,
          where: r.target_id in ^Enum.map(targets, & &1.id),
          group_by: r.target_id,
          select: ^%{id: dynamic([run: r], r.target_id), n: count}
      )
      |> Map.new(&{&1.id, &1.n})

    by_id = Map.new(targets, &{&1.public_id, &1})

    for id <- ids,
        target = by_id[id],
        do: {{target.system, target.path}, id, Map.get(counts, target.id, 0)}
  end

  defp text_facet(scope, filters, now, field, narrow, limit) do
    chosen = Map.fetch!(filters, field)
    values = scope |> filtered(Map.put(filters, field, nil), now) |> facet_values(field)
    pattern = like(narrow)

    grouped = from v in subquery(values), where: not is_nil(v.value), group_by: v.value

    grouped =
      if pattern, do: where(grouped, [v], ilike(v.value, ^pattern)), else: grouped

    rows =
      Repo.all(
        from v in grouped,
          order_by: [desc: count(v.id), asc: v.value],
          limit: ^(limit + 1),
          select: {v.value, count(v.id)}
      )

    total =
      if length(rows) > limit,
        do: Repo.one(from g in subquery(select(grouped, [v], v.value)), select: count()),
        else: length(rows)

    options = for {value, n} <- Enum.take(rows, limit), do: {value, value, n}

    options =
      if is_binary(chosen) and not Enum.any?(options, &(elem(&1, 1) == chosen)) do
        n = Repo.one(from v in subquery(values), where: v.value == ^chosen, select: count())
        [{chosen, chosen, n} | options]
      else
        options
      end

    %{options: options, total: total}
  end

  # Each run's value of a text facet: a host as the pages show it, a pool's name for a
  # pool's run (`Apiary.Runs.Place`); the field's value for any other facet.
  defp facet_values(base, :host), do: select(base, [r], %{id: r.id, value: shown_host(r)})
  defp facet_values(base, field), do: select(base, [r], %{id: r.id, value: field(r, ^field)})

  # The nodes the runs ran on, a pool for its instances' runs, deleted ones included. A node
  # in use is offered by its name, as one types it; a deleted one by its public id, since its
  # name may be another's now (`where_node/3` reads both). The chosen node keeps the value it
  # was chosen by, so a node page's link, by the node's id, shows its option checked.
  defp node_facet(scope, filters, now, narrow, limit) do
    base = filtered(scope, %{filters | node: nil}, now)
    pattern = like(narrow)

    grouped =
      from [run: r] in base,
        join: n in Node,
        on:
          n.id == r.node_id and n.organisation_id == r.organisation_id and
            n.workspace_id == r.workspace_id,
        group_by: [n.id, n.public_id, n.name, n.deleted_at]

    grouped = if pattern, do: where(grouped, [_r, n], ilike(n.name, ^pattern)), else: grouped

    rows =
      Repo.all(
        from [r, n] in grouped,
          order_by: [desc: count(r.id), asc: n.name, asc: n.public_id],
          limit: ^(limit + 1),
          select: {n.public_id, n.name, n.deleted_at, count(r.id)}
      )

    total =
      if length(rows) > limit,
        do: Repo.one(from g in subquery(select(grouped, [_r, n], n.id)), select: count()),
        else: length(rows)

    options =
      for {public_id, name, deleted_at, n} <- Enum.take(rows, limit),
          do:
            {node_label(name, deleted_at), node_value(public_id, name, deleted_at, filters.node),
             n}

    options =
      if is_binary(filters.node) and not Enum.any?(options, &(elem(&1, 1) == filters.node)) do
        n = Repo.aggregate(where_node(base, scope, filters.node), :count)
        [{filters.node, filters.node, n} | options]
      else
        options
      end

    %{options: options, total: total}
  end

  # The work items of the runs, by their number in the workspace, the most runs first, each
  # labelled as the list's Work item column writes it ("#3 Say hello"), its value the
  # number. A work item that moved to another workspace is not offered: its number here
  # is gone. Typed text narrows them by their title or their number.
  defp item_facet(scope, filters, now, narrow, limit) do
    base = filtered(scope, %{filters | item: nil}, now)
    pattern = like(narrow)

    grouped =
      from [run: r] in base,
        left_join: x in Dispatch,
        on: x.id == r.dispatch_id,
        join: d in DispatchRun,
        on: d.id == coalesce(r.dispatch_run_id, x.dispatch_run_id),
        join: w in WorkItem,
        as: :work_item,
        on: w.id == d.work_item_id and w.workspace_id == r.workspace_id,
        group_by: [w.id, w.number, w.title]

    grouped =
      if pattern,
        do:
          where(
            grouped,
            [work_item: w],
            ilike(w.title, ^pattern) or ilike(fragment("'#' || ?::text", w.number), ^pattern)
          ),
        else: grouped

    rows =
      Repo.all(
        from [run: r, work_item: w] in grouped,
          order_by: [desc: count(r.id), desc: w.number],
          limit: ^(limit + 1),
          select: {w.number, w.title, count(r.id)}
      )

    total =
      if length(rows) > limit,
        do: Repo.one(from g in subquery(select(grouped, [work_item: w], w.id)), select: count()),
        else: length(rows)

    options =
      for {number, title, n} <- Enum.take(rows, limit),
          do: {item_label(number, title), Integer.to_string(number), n}

    chosen = filters.item && Integer.to_string(filters.item)

    options =
      if chosen && not Enum.any?(options, &(elem(&1, 1) == chosen)) do
        title =
          Repo.one(
            from w in WorkItem,
              where:
                w.organisation_id == ^scope.organisation.id and
                  w.workspace_id == ^scope.workspace.id and w.number == ^filters.item,
              select: w.title
          )

        n = Repo.aggregate(where_item(base, scope, filters.item), :count)

        [
          {if(title, do: item_label(filters.item, title), else: "#" <> chosen), chosen, n}
          | options
        ]
      else
        options
      end

    %{options: options, total: total}
  end

  @doc """
  A work item as the runs list writes it, its number and its title: "#3 Say hello".
  """
  @spec item_label(integer, String.t()) :: String.t()
  def item_label(number, title), do: gettext("#%{number} %{title}", number: number, title: title)

  defp node_label(name, nil), do: name
  defp node_label(name, _deleted_at), do: gettext("%{name} (deleted)", name: name)

  defp node_value(public_id, _name, _deleted_at, public_id), do: public_id
  defp node_value(_public_id, name, nil, _chosen), do: name
  defp node_value(public_id, _name, _deleted_at, _chosen), do: public_id

  # What the reader typed, as the operand of ILIKE that matches it anywhere and as text:
  # the pattern's own characters are escaped, so "%" finds a per cent sign and nothing else.
  @doc false
  def like(narrow) when is_binary(narrow) do
    narrow = String.trim(narrow)

    if narrow != "" and byte_size(narrow) <= 256 and String.valid?(narrow) and
         not String.match?(narrow, ~r/[\x00-\x1F\x7F]/) do
      escaped =
        narrow
        |> String.replace("\\", "\\\\")
        |> String.replace("%", "\\%")
        |> String.replace("_", "\\_")

      "%" <> escaped <> "%"
    end
  end

  def like(_narrow), do: nil

  @doc "Whether the run is one the filters return: for a page deciding what a change means to it."
  def matches?(%Scope{} = scope, %Filters{} = filters, %Run{id: id}, now \\ DateTime.utc_now()) do
    Repo.exists?(from r in filtered(scope, filters, now), where: r.id == ^id)
  end

  @doc "Which of the runs with these row ids the filters return: one query for a page's flush."
  def matching_ids(%Scope{} = scope, %Filters{} = filters, ids, now \\ DateTime.utc_now())
      when is_list(ids) do
    Repo.all(from r in filtered(scope, filters, now), where: r.id in ^ids, select: r.id)
  end

  defp filtered(scope, %Filters{} = f, now) do
    {from, to} = Filters.bounds(f, now, Scope.time_zone(scope))

    in_scope(scope)
    |> where_if(f.states != [], where_states(f.states))
    |> where_target(scope, f.target)
    |> where_text(:runtime, f.runtime)
    |> where_host(f.host)
    |> where_node(scope, f.node)
    |> where_machine_type(f.machine_type)
    |> where_item(scope, f.item)
    |> where_query(f.q)
    |> where_if(f.denials, dynamic([r], r.denied_count > 0))
    |> where_if(from, dynamic([r], coalesce(r.started_at, r.inserted_at) >= ^from))
    |> where_if(to, dynamic([r], coalesce(r.started_at, r.inserted_at) < ^to))
  end

  # The states the page shows (`Apiary.Runs.Run.shown_states/0`) as a condition: `queued`
  # is a queued run (`Apiary.Runs.Run.queued?/1`), `pending` any other pending run.
  defp where_states(states) do
    stored = states -- ["queued", "pending"]
    condition = dynamic([run: r], r.state in ^stored)

    condition =
      if "queued" in states,
        do: dynamic(^condition or ^Run.queued_condition()),
        else: condition

    if "pending" in states,
      do:
        dynamic([run: r], ^condition or (r.state == "pending" and not (^Run.queued_condition()))),
      else: condition
  end

  defp where_if(query, condition, dynamic) do
    if condition, do: where(query, ^dynamic), else: query
  end

  # A target by the ids Qory Apiary gives (`tg_…`): the runs of the targets of the scope's
  # workspace with those ids, read in the same query, so an id of another workspace names
  # none here.
  defp where_target(query, _scope, nil), do: query
  defp where_target(query, _scope, :none), do: where(query, [run: r], is_nil(r.target_id))

  # A typed name that names no target is search text: the runs whose target's path is
  # that text, as the query field matches text, none until a target has it.
  defp where_target(query, _scope, {:name, name}),
    do: where(query, [run: r], not is_nil(r.target_id) and r.target_path == ^name)

  defp where_target(query, scope, ids) when is_list(ids) do
    targets = from t in targets_in(scope), where: t.public_id in ^ids, select: t.id
    where(query, [run: r], r.target_id in subquery(targets))
  end

  defp where_text(query, _field, nil), do: query
  defp where_text(query, field, value), do: where(query, [r], field(r, ^field) == ^value)

  # A host as the pages show it: a pool's name finds the pool's runs, and the host a
  # pool's run reported finds none of them (`Apiary.Runs.Place`).
  defp where_host(query, nil), do: query
  defp where_host(query, host), do: where(query, [r], shown_host(r) == ^host)

  # A node by its public id, or by the name of a node in use: a deleted node's runs are
  # found by its id, since its name may be another's now.
  defp where_node(query, _scope, nil), do: query

  defp where_node(query, scope, node) do
    nodes =
      from n in Node,
        where:
          n.organisation_id == ^scope.organisation.id and n.workspace_id == ^scope.workspace.id,
        where: n.public_id == ^node or (n.name == ^node and is_nil(n.deleted_at)),
        select: n.id

    where(query, [r], r.node_id in subquery(nodes))
  end

  # A machine type by its key: the runs whose run of the queue was queued on it.
  defp where_machine_type(query, nil), do: query

  defp where_machine_type(query, key) do
    queued = from d in DispatchRun, where: d.machine_type == ^key, select: d.id
    where(query, [r], r.dispatch_run_id in subquery(queued))
  end

  # A work item by its number in the scope's workspace: the runs of its runs of the queue,
  # a run whose start failed by the run of the queue of its dispatch.
  defp where_item(query, _scope, nil), do: query

  defp where_item(query, scope, number) do
    queued = item_runs(scope, number)
    dispatches = from x in Dispatch, where: x.dispatch_run_id in subquery(queued), select: x.id

    where(
      query,
      [r],
      r.dispatch_run_id in subquery(queued) or r.dispatch_id in subquery(dispatches)
    )
  end

  defp item_runs(scope, number) do
    from d in DispatchRun,
      join: w in WorkItem,
      on: w.id == d.work_item_id,
      where:
        w.organisation_id == ^scope.organisation.id and w.workspace_id == ^scope.workspace.id and
          w.number == ^number,
      select: d.id
  end

  # The free text: the run's id (`id_condition/1`), or its title or its target,
  # `system/path`, holding it anywhere.
  defp where_query(query, nil), do: query

  defp where_query(query, q) do
    case {like(q), id_condition(q)} do
      {nil, _id} ->
        query

      {pattern, id} ->
        text =
          dynamic(
            [r],
            ilike(r.about_title, ^pattern) or
              ilike(fragment("? || '/' || ?", r.target_system, r.target_path), ^pattern)
          )

        condition = if id, do: dynamic([r], ^text or ^id), else: text

        where(query, ^condition)
    end
  end

  ## Tool invocations

  @doc """
  tool_invocation?/2 says whether an egress attempt is a tool invocation: it names a `tool`
  and its `decision` is `"allowed"`, so the proxy handed the request to the tool. This is
  the one definition; every page, listing and query of this application holds to it.

  An attempt names a tool when the proxy decided it by its path for a host a tool serves.
  One a path rule refused names the tool as well, the tool whose host it was for, and
  never reached it: it is no tool invocation, and reads as any denial. A connection
  refused on its host names no tool. `connections.last_tool` keeps the tool of the last
  attempt in either case; with `last_decision` it says whether that attempt was a tool
  invocation.
  """
  @spec tool_invocation?(String.t() | nil, String.t() | nil) :: boolean
  def tool_invocation?(tool, decision),
    do: is_binary(tool) and tool != "" and decision == "allowed"

  # `tool_invocation?/2` in SQL, of a connection's last attempt: the fold never stores an
  # empty tool, so a tool is a non-null `last_tool`.
  defp tool_invocation do
    dynamic([c], not is_nil(c.last_tool) and c.last_decision == "allowed")
  end

  ## The workspace's connections

  @doc "How many destinations a page of the workspace's connections holds."
  def page_size, do: @page_size

  @doc """
  A page of the workspace's destinations across the runs in range: one row per host, port
  and path, with how many runs reached it, the attempts, and the decision, rule, outcome
  and the rest of the most recent attempt across those runs, the tool whose host it was
  for (`last_tool`) and what answered it (`last_status`) among them; the attempt is a tool
  invocation when `tool_invocation?/2` says so of `last_tool` and `last_decision`.
  Filters: `decision` (destinations with any attempt so decided), `target`, `host` (the
  destination's), `q` (a destination whose host or path holds the text), `tools` (tool
  invocations only: the destinations where the last attempt of a run was a tool
  invocation, that run's connection naming a tool with the decision allowed; each is kept
  whole, so its counts are those without the filter) and the range, which is over when a
  run last reached the destination and never wider than
  `Apiary.Runs.Filters.max_window_days/0` days, so the aggregate is over a bounded set.
  The order is `sort`: denied destinations first, the most denied attempts first, then
  the rest by when they were first seen, newest first (the default); the most recently seen first; the most runs first; the most
  attempts first.
  """
  def page_destinations(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    query = destinations(scope, filters, now)

    # One pass: the page's rows carry the totals of everything grouped, as window
    # aggregates over the same grouping, so the GROUP BY is not run a second time.
    read = fn page ->
      Repo.all(
        from d in subquery(query),
          order_by: ^destination_order(filters.sort),
          limit: @page_size,
          offset: ^((page - 1) * @page_size),
          select:
            {d,
             %{
               destinations: over(count()),
               denied:
                 type(
                   over(sum(fragment("CASE WHEN ? > 0 THEN 1 ELSE 0 END", d.denied))),
                   :integer
                 ),
               attempts: type(over(sum(d.attempts)), :integer)
             }}
      )
    end

    {page, found} =
      case {filters.page, read.(filters.page)} do
        {page, [_ | _] = found} ->
          {page, found}

        {1, []} ->
          {1, []}

        # A page past the end says nothing of how many there are: count, and read the last.
        {_beyond, []} ->
          total = Repo.one(from d in subquery(query), select: count())
          last = max(ceil(total / @page_size), 1)
          {last, read.(last)}
      end

    summary =
      case found do
        [{_row, totals} | _] -> totals
        [] -> %{destinations: 0, denied: 0, attempts: 0}
      end

    runs =
      Repo.one(from c in connections_in(scope, filters, now), select: count(c.run_id, :distinct))

    %{
      rows: Enum.map(found, &elem(&1, 0)),
      page: page,
      pages: max(ceil(summary.destinations / @page_size), 1),
      summary: Map.put(summary, :runs, runs)
    }
  end

  @harness_fetches_max 200

  @doc """
  The hosts the workspace's runs reached to fetch their harness (channel `stack`) under the
  filters, the most recently seen first, `limit:` at most (#{@harness_fetches_max} by
  default): `%{rows:, total:}`, `total` the hosts there are and `rows`
  `[%{host:, runs:, attempts:, allowed:, denied:, last_seen_at:, sources:}]`, one row per
  host. `sources` are the harness sources of the host in the harness records of the runs
  that fetched it, the most runs first. The filters are
  the destinations' (`decision`, `target`, `host`, `q`, `tools`, the range). These rows are
  no destination: no count, view, facet, rail or rule option of the destinations reads
  them, and no rule is made from one.
  """
  def harness_fetches(
        %Scope{} = scope,
        %Filters{} = filters,
        now \\ DateTime.utc_now(),
        opts \\ []
      ) do
    limit = Keyword.get(opts, :limit, @harness_fetches_max)
    base = connections_in(scope, filters, now, "stack")

    rows =
      Repo.all(
        from c in base,
          group_by: c.host,
          select: %{
            host: c.host,
            runs: count(c.run_id, :distinct),
            attempts: type(coalesce(sum(c.attempts), 0), :integer),
            allowed: type(coalesce(sum(c.allowed), 0), :integer),
            denied: type(coalesce(sum(c.denied), 0), :integer),
            last_seen_at: max(c.last_seen_at)
          }
      )
      |> Enum.filter(fn row ->
        case filters.decision do
          "denied" -> row.denied > 0
          "allowed" -> row.allowed > 0
          _all -> true
        end
      end)
      |> Enum.sort_by(&{DateTime.to_unix(&1.last_seen_at, :microsecond), &1.host}, :desc)

    shown = Enum.take(rows, limit)
    sources = fetch_sources(base, Enum.map(shown, & &1.host))

    %{
      rows: for(row <- shown, do: Map.put(row, :sources, Map.get(sources, row.host, []))),
      total: length(rows)
    }
  end

  # The sources of each host among the harness records of the runs that fetched it, the
  # most runs first. A run with no record (a run that is of no queue, or whose record was
  # deleted) is one the source of which is not recorded.
  defp fetch_sources(_base, []), do: %{}

  defp fetch_sources(base, hosts) do
    Repo.all(
      from [c, r] in base,
        left_join: h in Apiary.Harnesses.RunHarness,
        on: h.dispatch_run_id == r.dispatch_run_id,
        where: c.host in ^hosts,
        group_by: [c.host, h.pins, h.harness_hidden, is_nil(h.id), h.state],
        select:
          {c.host, count(c.run_id, :distinct), h.pins, h.harness_hidden, is_nil(h.id), h.state}
    )
    |> Enum.group_by(&elem(&1, 0))
    |> Map.new(fn {host, groups} ->
      sources =
        groups
        |> Enum.flat_map(fn {_host, runs, pins, hidden, unrecorded, state} ->
          for source <- Apiary.Harnesses.FetchSource.of(host, pins, hidden, unrecorded, state),
              do: {source, runs}
        end)
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.map(fn {source, counts} -> {source, Enum.sum(counts)} end)
        |> Enum.sort_by(fn {source, runs} -> {-runs, inspect(source)} end)
        |> Enum.map(&elem(&1, 0))

      {host, sources}
    end)
  end

  # Denied first: the destinations whose last attempt was denied, the most denied attempts
  # first and then the most recently seen, as To review weighs them; the rest by
  # first seen, newest first, so such a row does not move when it is seen again (see
  # Record.connections/3). Or the order the reader chose.
  defp destination_order(sort) do
    lead =
      case sort do
        "recent" ->
          [desc: dynamic([d], d.last_seen_at)]

        "runs" ->
          [desc: dynamic([d], d.runs), desc: dynamic([d], d.last_seen_at)]

        "attempts" ->
          [desc: dynamic([d], d.attempts), desc: dynamic([d], d.last_seen_at)]

        _denied ->
          [
            desc: dynamic([d], d.last_decision == "denied"),
            desc:
              dynamic(
                [d],
                fragment("CASE WHEN ? = 'denied' THEN ? END", d.last_decision, d.denied)
              ),
            desc:
              dynamic(
                [d],
                fragment("CASE WHEN ? = 'denied' THEN ? END", d.last_decision, d.last_seen_at)
              )
          ]
      end

    lead ++
      [
        desc: dynamic([d], d.first_seen_at),
        asc: dynamic([d], d.host),
        asc: dynamic([d], d.port),
        asc: dynamic([d], d.path)
      ]
  end

  @doc """
  The views of the workspace's connections, each counted in destinations under every other
  filter (the views set the decision): `%{all:, denied:, allowed:}`, a destination counted
  in each decision any of its attempts had.
  """
  def destination_views(%Scope{} = scope, %Filters{} = filters, now \\ DateTime.utc_now()) do
    grouped =
      from [c, r] in connections_in(scope, %{filters | decision: nil}, now),
        group_by: [c.host, c.port, c.path],
        select: %{allowed: sum(c.allowed), denied: sum(c.denied)}

    Repo.one(
      from d in subquery(grouped),
        select: %{
          all: count(),
          denied: filter(count(), d.denied > 0),
          allowed: filter(count(), d.allowed > 0)
        }
    )
  end

  @doc """
  The rail of the workspace's connections: the targets of the runs that reached out under
  the filters without their target, each counted in the destinations its runs reached (a
  host, port and path once however many runs reached it), as the page's views count, with
  the options of `target_counts/3`; `runs` in the result is that count, and `all` the
  destinations of every target.
  """
  def destination_target_counts(%Scope{} = scope, %Filters{} = filters, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    rail(connections_in(scope, %{filters | target: nil}, now), opts, destination_count())
  end

  # The destinations among connection rows: a host, port and path once.
  defp destination_count,
    do: dynamic([c], fragment("count(DISTINCT (?, ?, ?))", c.host, c.port, c.path))

  @doc """
  The runs that reached a destination, the most recent first, under the same filters:
  `%{runs: [%{run:, allowed:, denied:, last_seen_at:}], total:}`. `limit:` defaults to
  #{@hits_page}.
  """
  def destination_runs(%Scope{} = scope, %Filters{} = filters, {host, port, path}, opts \\ [])
      when is_binary(host) and is_integer(port) and is_binary(path) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    limit = opts |> Keyword.get(:limit, @hits_page) |> max(1) |> min(@max_limit)

    query =
      from c in connections_in(scope, filters, now),
        where: c.host == ^host and c.port == ^port and c.path == ^path

    hits =
      Repo.all(
        from [c, r] in query,
          order_by: [desc: c.last_seen_at, desc: c.id],
          limit: ^limit,
          select: %{run: r, allowed: c.allowed, denied: c.denied, last_seen_at: c.last_seen_at}
      )

    %{runs: hits, total: Repo.aggregate(query, :count)}
  end

  @doc """
  The targets whose runs reached a destination under the same filters, the ones with
  the most runs first, 25 at most: `%{target_id:, system:, path:, runs:,
  connection_id:}`, runs that name no target as one entry with nil for the three.
  `connection_id` is the most recent connection of the destination among the target's
  runs: the row a rule made from the destination is made from (`fetch_connection/2`).
  """
  def destination_targets(
        %Scope{} = scope,
        %Filters{} = filters,
        {host, port, path},
        opts \\ []
      )
      when is_binary(host) and is_integer(port) and is_binary(path) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    Repo.all(
      from [c, r] in connections_in(scope, filters, now),
        where: c.host == ^host and c.port == ^port and c.path == ^path,
        group_by: [r.target_id, r.target_system, r.target_path],
        order_by: [desc: count(c.run_id, :distinct), asc: r.target_system, asc: r.target_path],
        limit: 25,
        select: %{
          target_id: r.target_id,
          system: r.target_system,
          path: r.target_path,
          runs: count(c.run_id, :distinct),
          connection_id:
            type(
              fragment("(array_agg(? ORDER BY ? DESC, ? DESC))[1]", c.id, c.last_seen_at, c.id),
              :binary_id
            )
        }
    )
  end

  @doc """
  The target of the scope's workspace that runs name with this system and path, or nil:
  one indexed read, however many targets the workspace has.
  """
  def fetch_target(
        %Scope{
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id}
        },
        system,
        path
      )
      when is_binary(system) and is_binary(path) do
    Repo.one(
      from p in Target,
        where: p.organisation_id == ^organisation_id and p.workspace_id == ^workspace_id,
        where: p.system == ^system and p.path == ^path,
        limit: 1
    )
  end

  def fetch_target(%Scope{}, _system, _path), do: nil

  # The connections joined to their runs, the connection the first binding and the run
  # the second, as the edition narrows what the scope's person reads of them.
  defp client_connections(scope),
    do:
      Edition.client_reads(
        scope,
        :workspace_connections,
        nil,
        from(c in Connection,
          join: r in Run,
          on: r.id == c.run_id and r.workspace_id == c.workspace_id
        )
      )

  @doc """
  One connection of the scope's workspace by its row id, whole. `:error` for an id that is
  not a UUID and for a connection of another workspace.
  """
  def fetch_connection(
        %Scope{
          organisation: %Organisation{id: organisation_id},
          workspace: %Workspace{id: workspace_id}
        } = scope,
        id
      ) do
    with <<_::binary-size(36)>> <- id,
         {:ok, id} <- Ecto.UUID.cast(id),
         %Connection{} = connection <-
           Repo.one(
             from [c, _r] in client_connections(scope),
               where:
                 c.id == ^id and c.organisation_id == ^organisation_id and
                   c.workspace_id == ^workspace_id
           ) do
      {:ok, connection}
    else
      _ -> :error
    end
  end

  @doc """
  The options of the connections page's filters, `%{target:, host:}`, each
  `%{options: [{label, value, count}], total: n}` like `run_facets/3`: a target counted in
  destinations, as the rail counts it (`destination_target_counts/3`), a host in runs;
  `narrow:` as there. `decided: true` keeps the hosts to those of the destinations the
  filters' `decision` lists, as the list itself does (the query field's suggestions); the
  Filter menu's hosts do not. A host is the one the row shows: the instance's for a request
  to the run API (`Apiary.Runs.RunApi`).
  """
  def destination_facets(%Scope{} = scope, %Filters{} = filters, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    narrow = Keyword.get(opts, :narrow, %{})
    limits = Keyword.get(opts, :limits, %{})

    %{
      target:
        target_facet(
          scope,
          connections_in(scope, %{filters | target: nil}, now),
          filters.target,
          narrow["target"],
          facet_limit(limits["target"]),
          destination_count()
        ),
      host:
        destination_host_facet(
          scope,
          filters,
          now,
          narrow["host"],
          facet_limit(limits["host"]),
          Keyword.get(opts, :decided, false)
        )
    }
  end

  defp destination_host_facet(scope, filters, now, narrow, limit, decided) do
    base = connections_in(scope, %{filters | host: nil}, now)
    like = like(narrow)

    instance = RunApi.host()
    placeholder = RunApi.placeholder()

    # The host a row is listed under, as the `host:` filter finds it: the instance's for its
    # rows in any case and for the run API's requests, the placeholder for its rows in any
    # case, else the host as recorded.
    shown =
      from c in base,
        select: %{
          host:
            fragment(
              "CASE WHEN ? = ? OR lower(?) = ? THEN ? WHEN lower(?) = ? THEN ? ELSE ? END",
              c.last_rule,
              ^RunApi.rule(),
              c.host,
              ^instance,
              ^instance,
              c.host,
              ^placeholder,
              ^placeholder,
              c.host
            ),
          recorded: c.host,
          run_id: c.run_id,
          allowed: c.allowed,
          denied: c.denied
        }

    grouped = from c in subquery(shown), group_by: c.host

    # The box finds a host by what the row shows or by what was recorded, so the run API's
    # entry by either host.
    grouped =
      if like,
        do:
          having(
            grouped,
            [c],
            ilike(c.host, ^like) or fragment("bool_or(? ILIKE ?)", c.recorded, ^like)
          ),
        else: grouped

    grouped = if decided, do: having_decision(grouped, filters.decision), else: grouped

    rows =
      Repo.all(
        from c in grouped,
          order_by: [desc: count(c.run_id, :distinct), asc: c.host],
          limit: ^(limit + 1),
          select: {c.host, c.host, count(c.run_id, :distinct)}
      )

    total =
      if length(rows) > limit,
        do: Repo.one(from g in subquery(select(grouped, [c], c.host)), select: count()),
        else: length(rows)

    options = Enum.take(rows, limit)

    options =
      cond do
        RunApi.either_host?(filters.host) ->
          chosen_run_api_host(base, filters.host, options)

        is_binary(filters.host) and not Enum.any?(options, &(elem(&1, 1) == filters.host)) ->
          [{filters.host, filters.host, chosen_runs(base, filters.host)} | options]

        true ->
          options
      end

    %{options: options, total: total}
  end

  # The instance's host or the placeholder, chosen in any case, is the one entry of that
  # host: chosen by the text the filter has, counting the runs the filter finds, in place
  # of the entry in that host's lower case, or first where the list has none.
  defp chosen_run_api_host(base, chosen, options) do
    host = if RunApi.host?(chosen), do: RunApi.host(), else: RunApi.placeholder()
    entry = {host, chosen, chosen_runs(base, chosen)}

    case Enum.find_index(options, fn {_label, value, _n} -> value in [host, chosen] end) do
      nil -> [entry | options]
      index -> List.replace_at(options, index, entry)
    end
  end

  defp chosen_runs(base, host),
    do:
      Repo.one(from c in base, where: ^connection_host(host), select: count(c.run_id, :distinct))

  # The workspace's connection rows of one channel under the filters, joined to their run
  # (for the target). The destinations, their counts, facets and rule options read the
  # session's alone (the default): a run's harness fetch (channel `stack`) to the same
  # destination is a second row of the run, and the workspace's rules do not decide it.
  # `harness_fetches/3` is the one reader of `"stack"`.
  defp connections_in(scope, %Filters{} = f, now, channel \\ "session") do
    %Scope{
      organisation: %Organisation{id: organisation_id},
      workspace: %Workspace{id: workspace_id}
    } = scope

    {from, to} = Filters.bounds(f, now, Scope.time_zone(scope))

    connections =
      from(c in Connection,
        join: r in Run,
        as: :run,
        on: r.id == c.run_id and r.workspace_id == c.workspace_id,
        where: c.organisation_id == ^organisation_id and c.workspace_id == ^workspace_id,
        where: r.organisation_id == ^organisation_id and r.workspace_id == ^workspace_id,
        where: c.channel == ^channel
      )

    scope
    |> Edition.client_reads(:workspace_connections, nil, connections)
    |> where_if(f.host, connection_host(f.host))
    |> where_if(from, dynamic([c], c.last_seen_at >= ^from))
    |> where_if(to, dynamic([c], c.last_seen_at < ^to))
    |> where_target(scope, f.target)
    |> where_destination_text(f.q)
    |> where_tools(f.tools)
  end

  # The rows of a host: those recorded with it. The instance's host finds its rows in any
  # case and the requests to the run API, which the rows show with it; the placeholder
  # finds its rows in any case, those requests among them (`Apiary.Runs.RunApi`).
  defp connection_host(nil), do: nil

  defp connection_host(host) do
    cond do
      RunApi.host?(host) ->
        dynamic(
          [c],
          fragment("lower(?)", c.host) == ^RunApi.host() or c.last_rule == ^RunApi.rule()
        )

      RunApi.either_host?(host) ->
        dynamic([c], fragment("lower(?)", c.host) == ^RunApi.placeholder())

      true ->
        dynamic([c], c.host == ^host)
    end
  end

  # The free text of the connections: a destination whose host or path contains it, the
  # host as recorded or, for a request to the run API, the instance's.
  defp where_destination_text(query, nil), do: query

  defp where_destination_text(query, q) do
    case like(q) do
      nil ->
        query

      pattern ->
        where(
          query,
          [c],
          ilike(c.host, ^pattern) or ilike(c.path, ^pattern) or
            (c.last_rule == ^RunApi.rule() and ilike(^RunApi.host(), ^pattern))
        )
    end
  end

  # Tool invocations only: every row of a destination where any row under the same filters
  # says its last attempt was a tool invocation, so a destination is kept whole and counts
  # the same with the filter as without it, and so do the runs and the facets. A
  # destination whose rows name a tool only on refused attempts never reached the tool.
  defp where_tools(query, false), do: query

  defp where_tools(query, true) do
    tooled =
      from c in query,
        where: ^tool_invocation(),
        distinct: true,
        select: %{host: c.host, port: c.port, path: c.path}

    from c in query,
      join: t in subquery(tooled),
      on: t.host == c.host and t.port == c.port and t.path == c.path
  end

  # One row per destination. "Last" across runs is by the clock of the record: sequences
  # order the attempts of one run, and nothing but time orders two runs.
  defp destinations(scope, %Filters{} = f, now) do
    query =
      from [c, r] in connections_in(scope, f, now),
        group_by: [c.host, c.port, c.path],
        select: %{
          host: c.host,
          port: c.port,
          path: c.path,
          runs: count(c.run_id, :distinct),
          attempts: sum(c.attempts),
          allowed: sum(c.allowed),
          denied: sum(c.denied),
          first_seen_at: min(c.first_seen_at),
          last_seen_at: max(c.last_seen_at),
          method:
            fragment("(array_agg(? ORDER BY ? DESC, ? DESC))[1]", c.method, c.last_seen_at, c.id),
          last_request_method:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_request_method,
              c.last_seen_at,
              c.id
            ),
          last_decision:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_decision,
              c.last_seen_at,
              c.id
            ),
          last_rule:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_rule,
              c.last_seen_at,
              c.id
            ),
          last_path_rule:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_path_rule,
              c.last_seen_at,
              c.id
            ),
          last_credential:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_credential,
              c.last_seen_at,
              c.id
            ),
          last_outcome:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_outcome,
              c.last_seen_at,
              c.id
            ),
          last_mode:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_mode,
              c.last_seen_at,
              c.id
            ),
          last_tool:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_tool,
              c.last_seen_at,
              c.id
            ),
          last_status:
            fragment(
              "(array_agg(? ORDER BY ? DESC, ? DESC))[1]",
              c.last_status,
              c.last_seen_at,
              c.id
            )
        }

    having_decision(query, f.decision)
  end

  # Destinations, or hosts, with any attempt so decided.
  defp having_decision(query, "denied"), do: having(query, [c], sum(c.denied) > 0)
  defp having_decision(query, "allowed"), do: having(query, [c], sum(c.allowed) > 0)
  defp having_decision(query, _all), do: query

  @doc "The last heartbeat each access key of the workspace delivered, by the key's row id; keys that never did are absent."
  def last_heartbeats_by_key(%Scope{
        organisation: %Organisation{id: organisation_id},
        workspace: %Workspace{id: workspace_id}
      }) do
    Repo.all(
      from k in AccessKey,
        where: k.organisation_id == ^organisation_id and k.workspace_id == ^workspace_id,
        where: not is_nil(k.last_heartbeat_at),
        select: {k.id, k.last_heartbeat_at}
    )
    |> Map.new()
  end

  ## The workspace overview

  # The runs are placed by when they started, or, for a run that has only registered, by when
  # the workspace first heard of it: the expression of
  # `runs_workspace_id_started_or_first_heard_index`. A run's day is that expression taken
  # to the scope's time zone and cut to its date (`Apiary.Days.sql_day/2`): the columns
  # hold UTC with no zone, so the expression is read as UTC first, and the day does not
  # depend on the time zone the database connection is set to.
  defp by_start, do: dynamic([r], coalesce(r.started_at, r.inserted_at))

  @typedoc """
  One day of the workspace's runs, in the scope's time zone: how many (`runs`), and of them the alive, the ended
  well, the cancelled, the paused and the ended badly (`alive`, `ended_well`, `cancelled`,
  `paused`, `ended_badly`), with the denials of those runs and the cost they reported: `cost` is the
  sum of `cost_usd` over the day's runs, nil when none reported one, and `costed` how many
  did.
  """
  @type day_facts :: %{
          day: Date.t(),
          runs: non_neg_integer,
          alive: non_neg_integer,
          ended_well: non_neg_integer,
          cancelled: non_neg_integer,
          paused: non_neg_integer,
          ended_badly: non_neg_integer,
          denied: non_neg_integer,
          cost: Decimal.t() | nil,
          costed: non_neg_integer
        }

  @doc """
  The workspace's runs from `from` on, one row per day they started in the scope's time
  zone (`Apiary.Accounts.Scope.time_zone/1`; a run that has not started by when its
  record was written), oldest
  first; a day with no run has no row. `from` and `to` are moments: the start of a day in
  that zone (`Apiary.Days.start_of/2`) counts whole days. One grouped query
  over the index the runs list reads by; the caller fills the days in. `to`, when given,
  bounds the read above (exclusive), so one call can read today alone.
  """
  @spec day_facts(Scope.t(), DateTime.t(), DateTime.t() | nil) :: [day_facts]
  def day_facts(%Scope{} = scope, %DateTime{} = from, to \\ nil) do
    zone = Scope.time_zone(scope)

    query =
      in_scope(scope)
      |> where(^dynamic([r], ^by_start() >= ^from))
      |> where_if(to, dynamic([r], ^by_start() < ^to))

    Repo.all(
      from r in query,
        group_by: selected_as(:day),
        order_by: selected_as(:day),
        select: %{
          day: selected_as(sql_day(coalesce(r.started_at, r.inserted_at), ^zone), :day),
          runs: count(r.id),
          alive: filter(count(r.id), r.state in ^Run.alive_states()),
          ended_well: filter(count(r.id), r.state in ^Run.ended_well_states()),
          cancelled: filter(count(r.id), r.state in ^Run.cancelled_states()),
          paused: filter(count(r.id), r.state in ^Run.paused_states()),
          ended_badly: filter(count(r.id), r.state in ^Run.ended_badly_states()),
          denied: type(coalesce(sum(r.denied_count), 0), :integer),
          cost: sum(r.cost_usd),
          costed: count(r.cost_usd)
        }
    )
  end

  @doc """
  What the organisation's overview says of each of `workspaces`, the workspaces of the
  scope's organisation the reader reaches: `%{workspace_id => %{alive:, runs:, denied:,
  last_at:, days:, targets:}}`, where `runs` and `denied` count the last fourteen days in
  the scope's time zone (today included), `days` the runs of each of them, oldest first, `last_at` is when the
  workspace's last run started (nil when it has none) and `targets` how many targets it
  has. A workspace of another organisation is left out. Four reads, whatever the number
  of workspaces.
  """
  @spec workspace_facts(Scope.t(), [%Workspace{}], DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => map
        }
  def workspace_facts(scope, workspaces, now \\ DateTime.utc_now())

  def workspace_facts(%Scope{}, [], _now), do: %{}

  def workspace_facts(
        %Scope{organisation: %Organisation{id: organisation_id}} = scope,
        workspaces,
        now
      ) do
    ids = for %Workspace{id: id, organisation_id: ^organisation_id} <- workspaces, do: id
    zone = Scope.time_zone(scope)
    {days, {from, _to}} = Days.window(14, zone, now)

    per_day =
      Repo.all(
        from r in Run,
          where: r.organisation_id == ^organisation_id and r.workspace_id in ^ids,
          where: coalesce(r.started_at, r.inserted_at) >= ^from,
          group_by: [r.workspace_id, selected_as(:day)],
          select:
            {r.workspace_id,
             selected_as(sql_day(coalesce(r.started_at, r.inserted_at), ^zone), :day),
             count(r.id), type(coalesce(sum(r.denied_count), 0), :integer)}
      )

    alive =
      Repo.all(
        from r in Run,
          where: r.organisation_id == ^organisation_id and r.workspace_id in ^ids,
          where: r.state in ^Run.alive_states(),
          group_by: r.workspace_id,
          select: {r.workspace_id, count(r.id)}
      )
      |> Map.new()

    # The last run of each, read off the index the runs list reads by, one row each.
    last =
      from r in Run,
        where: r.workspace_id == parent_as(:workspace).id,
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: 1,
        select: %{at: coalesce(r.started_at, r.inserted_at)}

    last_at =
      Repo.all(
        from w in Workspace,
          as: :workspace,
          where: w.id in ^ids,
          left_lateral_join: l in subquery(last),
          on: true,
          select: {w.id, l.at}
      )
      |> Map.new()

    targets =
      Repo.all(
        from t in Target,
          where: t.organisation_id == ^organisation_id and t.workspace_id in ^ids,
          group_by: t.workspace_id,
          select: {t.workspace_id, count(t.id)}
      )
      |> Map.new()

    by_workspace = Enum.group_by(per_day, &elem(&1, 0))

    Map.new(ids, fn id ->
      rows = Map.get(by_workspace, id, [])
      counts = Map.new(rows, fn {_id, date, runs, _denied} -> {date, runs} end)

      {id,
       %{
         alive: Map.get(alive, id, 0),
         runs: rows |> Enum.map(&elem(&1, 2)) |> Enum.sum(),
         denied: rows |> Enum.map(&elem(&1, 3)) |> Enum.sum(),
         last_at: Map.get(last_at, id),
         days: Days.buckets(days, counts),
         targets: Map.get(targets, id, 0)
       }}
    end)
  end

  @typedoc """
  A target of the overview's Active targets: its `public_id`, which addresses its page, its
  `system` and `path`, whether the same
  path is on another system of the workspace too (`shared?`, which is when the system is
  shown), its `runs` and `denied` attempts since the window opened, its runs of each day
  of the window, oldest first (`days`), and its last run (`last`).
  """
  @type active_target :: %{
          id: Ecto.UUID.t(),
          public_id: String.t(),
          system: String.t(),
          path: String.t(),
          shared?: boolean,
          runs: non_neg_integer,
          denied: non_neg_integer,
          days: [non_neg_integer],
          last: Run.t() | nil
        }

  @doc """
  active_targets/3 is what the workspace overview's Active targets say: the `limit`
  (default 8) targets with the most runs that started on or after the day `from`, a day in
  the scope's time zone,
  most first (by path on a tie), each an `t:active_target/0` with its runs of every day
  from `from` to today; and `targets`, how many targets the workspace has. Five short
  reads over the window's runs and the targets, whatever their number.
  """
  @spec active_targets(Scope.t(), Date.t(), pos_integer) :: %{
          rows: [active_target],
          targets: non_neg_integer
        }
  def active_targets(scope, from, limit \\ 8)

  def active_targets(%Scope{} = scope, %Date{} = from, limit) do
    zone = Scope.time_zone(scope)
    start = Days.start_of(from, zone)
    window = where(in_scope(scope), ^dynamic([r], ^by_start() >= ^start))

    top =
      Repo.all(
        from r in window,
          join: t in Target,
          on: t.id == r.target_id,
          group_by: [t.id, t.public_id, t.system, t.path],
          order_by: [desc: count(r.id), asc: t.path, asc: t.system],
          limit: ^bound(limit),
          select: %{
            id: t.id,
            public_id: t.public_id,
            system: t.system,
            path: t.path,
            runs: count(r.id),
            denied: type(coalesce(sum(r.denied_count), 0), :integer)
          }
      )

    ids = Enum.map(top, & &1.id)

    per_day =
      Repo.all(
        from r in window,
          where: r.target_id in ^ids,
          group_by: [r.target_id, selected_as(:day)],
          select:
            {r.target_id,
             selected_as(sql_day(coalesce(r.started_at, r.inserted_at), ^zone), :day),
             count(r.id)}
      )
      |> Enum.group_by(&elem(&1, 0), &{elem(&1, 1), elem(&1, 2)})

    last =
      Repo.all(
        from r in window,
          where: r.target_id in ^ids,
          distinct: r.target_id,
          order_by: [r.target_id, desc: coalesce(r.started_at, r.inserted_at), desc: r.id]
      )
      |> Map.new(&{&1.target_id, &1})

    shared = shared_paths(scope, Enum.map(top, & &1.path))

    targets = Repo.aggregate(targets_in(scope), :count)

    today = Days.today(zone)
    days = if Date.compare(from, today) == :gt, do: [], else: Date.range(from, today)

    rows =
      for row <- top do
        counts = Map.new(Map.get(per_day, row.id, []))

        Map.merge(row, %{
          shared?: MapSet.member?(shared, row.path),
          days: Days.buckets(Enum.to_list(days), counts),
          last: Map.get(last, row.id)
        })
      end

    %{rows: rows, targets: targets}
  end

  @doc """
  shared_paths/2 is which of `paths` (every path, without them) name a target on more than
  one system of the workspace: where a page shows a target's system beside its path.
  """
  @spec shared_paths(Scope.t(), [String.t()] | :all) :: MapSet.t(String.t())
  def shared_paths(scope, paths \\ :all)

  def shared_paths(%Scope{}, []), do: MapSet.new()

  def shared_paths(%Scope{} = scope, paths) do
    query =
      if paths == :all,
        do: targets_in(scope),
        else: where(targets_in(scope), [t], t.path in ^Enum.uniq(paths))

    Repo.all(
      from t in query,
        group_by: t.path,
        having: count(t.id) > 1,
        select: t.path
    )
    |> MapSet.new()
  end

  @doc "The alive runs of the workspace, the most recently started first; at most `limit` (default 6)."
  @spec list_alive(Scope.t(), pos_integer) :: [Run.t()]
  def list_alive(%Scope{} = scope, limit \\ 6) do
    Repo.all(
      from r in in_scope(scope),
        where: r.state in ^Run.alive_states(),
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: ^bound(limit)
    )
  end

  @doc "The workspace's most recently started runs, alive or ended; at most `limit` (default 5)."
  @spec recent_runs(Scope.t(), pos_integer) :: [Run.t()]
  def recent_runs(%Scope{} = scope, limit \\ 5) do
    Repo.all(
      from r in in_scope(scope),
        order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
        limit: ^bound(limit)
    )
  end

  @doc """
  The runs the workspace found lost since `since`, the most recently lost first, at most
  `limit` (default 6): the ones a member may still want to open. Older losses are facts on
  the runs list, not tasks.
  """
  @spec lost_since(Scope.t(), DateTime.t(), pos_integer) :: [Run.t()]
  def lost_since(%Scope{} = scope, %DateTime{} = since, limit \\ 6) do
    Repo.all(
      from r in in_scope(scope),
        where: r.state == "lost" and r.lost_at >= ^since,
        order_by: [desc: r.lost_at, desc: r.id],
        limit: ^bound(limit)
    )
  end

  @doc """
  The last run each of these access keys started, by the key's row id, in one read of the
  index `runs (workspace_id, access_key_id, started)` (`DISTINCT ON`); a key with no run
  is absent. At most #{@max_limit} keys are read.
  """
  @spec last_runs_by_key(Scope.t(), [Ecto.UUID.t()]) :: %{optional(Ecto.UUID.t()) => Run.t()}
  def last_runs_by_key(%Scope{}, []), do: %{}

  def last_runs_by_key(%Scope{} = scope, key_ids) when is_list(key_ids) do
    ids = Enum.take(key_ids, @max_limit)

    Repo.all(
      from r in in_scope(scope),
        where: r.access_key_id in ^ids,
        distinct: r.access_key_id,
        order_by: [asc: r.access_key_id, desc: coalesce(r.started_at, r.inserted_at), desc: r.id]
    )
    |> Map.new(&{&1.access_key_id, &1})
  end

  @doc """
  The hosts each of these access keys' runs came from since `since`, by the key's row id:
  `%{key_id => %{count: n, host: name}}`, `host` being the one host when there is only one
  and nil otherwise; a key with no run in the window is absent. Each host is as the pages
  show it: a pool's run counts under its pool's name (`Apiary.Runs.Place`). A key is not a
  machine, so a page counts the hosts. One grouped read of the index
  `runs (workspace_id, access_key_id, started)`; at most #{@max_limit} keys.
  """
  @spec hosts_by_key(Scope.t(), [Ecto.UUID.t()], DateTime.t()) :: %{
          optional(Ecto.UUID.t()) => %{count: pos_integer, host: String.t() | nil}
        }
  def hosts_by_key(%Scope{}, [], _since), do: %{}

  def hosts_by_key(%Scope{} = scope, key_ids, %DateTime{} = since) when is_list(key_ids) do
    ids = Enum.take(key_ids, @max_limit)

    hosts =
      from r in in_scope(scope),
        where: r.access_key_id in ^ids,
        where: coalesce(r.started_at, r.inserted_at) >= ^since,
        select: %{key_id: r.access_key_id, host: shown_host(r)}

    Repo.all(
      from h in subquery(hosts),
        where: not is_nil(h.host),
        group_by: h.key_id,
        select: {h.key_id, count(h.host, :distinct), min(h.host), max(h.host)}
    )
    |> Map.new(fn {key_id, count, first, last} ->
      {key_id, %{count: count, host: if(first == last, do: first)}}
    end)
  end

  defp bound(limit), do: limit |> max(1) |> min(@max_limit)

  ## Search or jump to

  @doc """
  search_targets/3 is the workspace's targets whose system and path, as `system/path`,
  hold `text` anywhere, case-insensitively and as text (`like/1`): at most `limit`, by
  path. What the palette finds (`ApiaryWeb.JumpController`).
  """
  @spec search_targets(Scope.t(), String.t(), pos_integer) :: [Target.t()]
  def search_targets(
        %Scope{organisation: %Organisation{id: organisation_id}, workspace: %Workspace{id: id}},
        text,
        limit \\ 8
      ) do
    case like(text) do
      nil ->
        []

      pattern ->
        Repo.all(
          from t in Target,
            where: t.organisation_id == ^organisation_id and t.workspace_id == ^id,
            where: ilike(fragment("? || '/' || ?", t.system, t.path), ^pattern),
            order_by: [asc: t.path, asc: t.system],
            limit: ^bound(limit)
        )
    end
  end

  @doc """
  search_runs/3 is the workspace's runs that `text` names: by their id, the start of the
  `rn_` id (four characters after `rn_` at least, a whole id or the address of a run's page
  too) or the start of the node's run id (four hexadecimal characters at least), or by
  their title, which holds it anywhere; newest first, at most `limit`. What the palette
  finds (`ApiaryWeb.JumpController`).
  """
  @spec search_runs(Scope.t(), String.t(), pos_integer) :: [Run.t()]
  def search_runs(%Scope{} = scope, text, limit \\ 8) when is_binary(text) do
    condition =
      case {id_condition(text), like(text)} do
        {nil, nil} -> nil
        {nil, pattern} -> dynamic([r], ilike(r.about_title, ^pattern))
        {id, nil} -> id
        {id, pattern} -> dynamic([r], ^id or ilike(r.about_title, ^pattern))
      end

    if condition do
      Repo.all(
        from r in in_scope(scope),
          where: ^condition,
          order_by: [desc: coalesce(r.started_at, r.inserted_at), desc: r.id],
          limit: ^bound(limit)
      )
    else
      []
    end
  end

  # The run that what was typed names by an id, as a condition; nil when it names none. A
  # run page's address gives its `public_id`; `rn_` and four to sixteen characters are the
  # start of one; four to thirty-six hexadecimal characters and hyphens are the start of
  # the node's run id.
  defp id_condition(text) do
    text = text |> String.trim() |> String.downcase()

    case Regex.run(~r"/runs/(rn_[0-9a-z]{16})(?:[/?#]|$)", text, capture: :all_but_first) do
      [public_id] ->
        dynamic([r], r.public_id == ^public_id)

      nil ->
        cond do
          Regex.match?(~r/\Arn_[0-9a-hjkmnp-tv-z]{4,16}\z/, text) ->
            prefix = "rn\\_" <> binary_part(text, 3, byte_size(text) - 3) <> "%"
            dynamic([r], like(r.public_id, ^prefix))

          Regex.match?(~r/\A[0-9a-f-]{4,36}\z/, text) ->
            dynamic([r], fragment("?::text LIKE ?", r.node_run_id, ^(text <> "%")))

          true ->
            nil
        end
    end
  end

  defp in_scope(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from r in Run,
      as: :run,
      where: r.organisation_id == ^organisation_id and r.workspace_id == ^workspace_id
  end

  defp targets_in(%Scope{
         organisation: %Organisation{id: organisation_id},
         workspace: %Workspace{id: workspace_id}
       }) do
    from t in Target,
      where: t.organisation_id == ^organisation_id and t.workspace_id == ^workspace_id
  end
end
