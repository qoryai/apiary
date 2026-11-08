defmodule Apiary.Runs.RunList do
  @moduledoc """
  The run list of the instance, one page at a time: the answer to
  `GET /v1/runs`, signed with a diagnostics key, in the shape of the diagnostics contract's
  run list (`priv/contract/diagnostics/v1/runs.schema.json`, vendored from the
  integrations at the commit in `test/fixtures/contract/diagnostics/v1/.contract-ref`).
  `Apiary.Runs.list_instance_runs/2` is the way in.

  **The query.** Each parameter is optional and appears at most once: `workspace`
  (`<organisation slug>/<workspace slug>`), `work_item` (a work item's number in that
  workspace, only with `workspace`), `workflow`, `state` (one of `Apiary.Runs.Run.states/0`),
  `since` (RFC 3339 in UTC, ending in `Z`), `before` (a run's `rn_` id, for the next page)
  and `limit` (1 to 100, 25 when absent). The raw query string is read, since Plug keeps
  only the last value of a name given twice. A name that is not one of these, a name
  given twice, an empty value, a value outside its rule, `work_item` without
  `workspace`, a workspace that does not exist and a `before` of no run are refused with
  the parameter's name. A `work_item`, `workflow` or `state` that no run has gives an
  empty page.

  **The page.** The runs are ordered by `created_at` (the run's `inserted_at`), the last
  first, then by the run's `rn_` id, the greatest first, compared byte by byte. `before`
  selects the runs created earlier than that run, or at the same time with a smaller id.
  `next` is the id of the page's last run when at least one more run matches, else nil.
  One query reads the page with its organisation, workspace, workflow and work item; the
  workspace and `before` are each looked up first, when given.

  **Each row.** `workflow` is the workflow of the run's resolved harness walk, as in the
  run diagnostics (`Apiary.Runs.Diagnostics`), and the work item is the one of the run's
  row in its workspace's queue; for a run whose start failed, that row is the one of its
  dispatch, which it left. The work item's number and title are there only while the
  work item is in the run's workspace. `duration_seconds` counts whole seconds from
  `started_at` to `exited_at`, or to `now` for a started run that is pending or running
  without an exit. A member the run has not got, or whose value is outside the contract's
  pattern, is left out.

  It reads every run of the instance and writes nothing: no read is recorded, and nothing
  of the runs or the query is logged.
  """

  import Ecto.Query, only: [from: 2, where: 3]

  alias Apiary.Dispatches.{Dispatch, DispatchRun}
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Repo
  alias Apiary.Runs.Run
  alias Apiary.WorkItems.WorkItem

  @names ~w(workspace work_item workflow state since before limit)
  @default_limit 25
  @max_limit 100
  @max_number 9_223_372_036_854_775_807

  @slug "[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?"
  @workspace Regex.compile!("\\A(#{@slug})/(#{@slug})\\z")
  @number ~r/\A[1-9][0-9]{0,18}\z/
  @limit ~r/\A[1-9][0-9]{0,2}\z/
  @workflow ~r/\A[a-z][a-z0-9-]{0,54}\z/
  @code ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @since ~r/\A([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(?:\.([0-9]{1,9}))?Z\z/
  @max_title 1024
  @max_parameter 64

  @typedoc "A query whose every parameter follows its rule, before the database is read."
  @type filters :: %{
          workspace: {String.t(), String.t()} | nil,
          work_item: pos_integer | nil,
          workflow: String.t() | nil,
          state: String.t() | nil,
          since: DateTime.t() | nil,
          before: String.t() | nil,
          limit: 1..100
        }

  @doc """
  answer/2 is the page that `query`, the raw query string, asks for, as the contract's
  document: `{:ok, %{"runs" => rows, "next" => id or nil}}`, or `{:error, parameter}` with
  the name of a parameter the request breaks the rule of. `opts`: `now`, the time the
  answer is built (the current time).
  """
  @spec answer(String.t(), keyword) :: {:ok, map} | {:error, String.t()}
  def answer(query, opts \\ []) when is_binary(query) do
    with {:ok, filters} <- parse(query), do: page(filters, opts)
  end

  @doc """
  parse/1 is the filters of `query`, the raw query string, or `{:error, parameter}` with
  the name of the first parameter that breaks its rule, as the refusal shows it: each
  control character replaced with U+FFFD, and cut to its first 64 characters. It reads
  no database, so a workspace's existence and a `before`'s run are checked by `page/2`.
  """
  @spec parse(String.t()) :: {:ok, filters} | {:error, String.t()}
  def parse(query) when is_binary(query) do
    empty = %{
      workspace: nil,
      work_item: nil,
      workflow: nil,
      state: nil,
      since: nil,
      before: nil,
      limit: @default_limit
    }

    query
    |> String.split("&")
    # An empty pair, as of `a=1&&b=2` or a trailing `&`, is no parameter, as Plug reads it.
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, empty, MapSet.new()}, fn pair, {:ok, filters, seen} ->
      {name, value} = pair(pair)

      with true <- name in @names and not MapSet.member?(seen, name),
           true <- value != "",
           {:ok, filters} <- put(filters, name, value) do
        {:cont, {:ok, filters, MapSet.put(seen, name)}}
      else
        _refused -> {:halt, {:error, shown(name)}}
      end
    end)
    |> case do
      {:ok, %{work_item: number, workspace: nil}, _seen} when is_integer(number) ->
        {:error, "work_item"}

      {:ok, filters, _seen} ->
        {:ok, filters}

      {:error, _name} = refused ->
        refused
    end
  end

  # A pair's name and value, each percent-decoded as Plug decodes a query; a pair without
  # `=` has an empty value.
  defp pair(pair) do
    case String.split(pair, "=", parts: 2) do
      [name, value] -> {decode(name), decode(value)}
      [name] -> {decode(name), ""}
    end
  end

  defp decode(text) do
    URI.decode_www_form(text)
  rescue
    ArgumentError -> text
  end

  defp put(filters, "workspace", value) do
    case Regex.run(@workspace, value, capture: :all_but_first) do
      [organisation, workspace] -> {:ok, %{filters | workspace: {organisation, workspace}}}
      nil -> :error
    end
  end

  defp put(filters, "work_item", value) do
    with true <- Regex.match?(@number, value),
         number when number <= @max_number <- String.to_integer(value) do
      {:ok, %{filters | work_item: number}}
    else
      _outside -> :error
    end
  end

  defp put(filters, "workflow", value) do
    if Regex.match?(@workflow, value), do: {:ok, %{filters | workflow: value}}, else: :error
  end

  defp put(filters, "state", value) do
    if value in Run.states(), do: {:ok, %{filters | state: value}}, else: :error
  end

  defp put(filters, "since", value) do
    case since(value) do
      %DateTime{} = since -> {:ok, %{filters | since: since}}
      nil -> :error
    end
  end

  defp put(filters, "before", value) do
    if Run.public_id?(value), do: {:ok, %{filters | before: value}}, else: :error
  end

  defp put(filters, "limit", value) do
    with true <- Regex.match?(@limit, value),
         limit when limit <= @max_limit <- String.to_integer(value) do
      {:ok, %{filters | limit: limit}}
    else
      _outside -> :error
    end
  end

  # The earliest microsecond at or after the time `value` names: the database keeps
  # microseconds, so a run created at or after a time with nanoseconds is one created at
  # or after the next whole microsecond. Nil for a value outside the rule: seconds 00 to
  # 59, and a date and time that exist.
  defp since(value) do
    with [year, month, day, hour, minute, second | fraction] <-
           Regex.run(@since, value, capture: :all_but_first),
         [year, month, day, hour, minute, second] =
           Enum.map([year, month, day, hour, minute, second], &String.to_integer/1),
         true <- second <= 59,
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second),
         {:ok, at} <- DateTime.new(date, time, "Etc/UTC") do
      DateTime.add(at, microseconds_up(fraction), :microsecond)
    else
      _outside -> nil
    end
  end

  defp microseconds_up([]), do: 0
  defp microseconds_up([""]), do: 0

  defp microseconds_up([digits]) do
    nanoseconds = digits |> String.pad_trailing(9, "0") |> String.to_integer()
    div(nanoseconds + 999, 1000)
  end

  # A name as a refusal shows it: valid UTF-8, each control character replaced with
  # U+FFFD, its first 64 characters.
  defp shown(name) do
    name
    |> String.replace_invalid("\u{FFFD}")
    |> String.replace(~r/[\x00-\x1f\x7f]/u, "\u{FFFD}")
    |> String.codepoints()
    |> Enum.take(@max_parameter)
    |> Enum.join()
  end

  @doc """
  page/2 is the page `filters` asks for, as answer/2 returns it, or `{:error, parameter}`
  for a workspace that does not exist (`workspace`) and a `before` that is the id of no
  run (`before`). `opts`: `now`, the time the answer is built (the current time).
  """
  @spec page(filters, keyword) :: {:ok, map} | {:error, String.t()}
  def page(filters, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    with {:ok, workspace_id} <- workspace_id(filters.workspace),
         {:ok, before} <- before(filters.before) do
      rows = Repo.all(query(filters, workspace_id, before))
      {page, more} = Enum.split(rows, filters.limit)

      next =
        case {page, more} do
          {[_ | _], [_ | _]} -> List.last(page).id
          _last -> nil
        end

      {:ok, %{"runs" => Enum.map(page, &row(&1, now)), "next" => next}}
    end
  end

  defp workspace_id(nil), do: {:ok, nil}

  defp workspace_id({organisation, workspace}) do
    Repo.one(
      from w in Workspace,
        join: o in Organisation,
        on: o.id == w.organisation_id,
        where: o.slug == ^organisation and w.slug == ^workspace,
        select: w.id
    )
    |> case do
      nil -> {:error, "workspace"}
      id -> {:ok, id}
    end
  end

  defp before(nil), do: {:ok, nil}

  defp before(public_id) do
    case Repo.one(from r in Run, where: r.public_id == ^public_id, select: r.inserted_at) do
      nil -> {:error, "before"}
      at -> {:ok, {at, public_id}}
    end
  end

  # The page and one run more, whose presence says there is a next page. Each run has one
  # organisation, one workspace, at most one row of the queue, one harness walk of that row
  # (a unique index) and one work item, so the joins add no row.
  defp query(filters, workspace_id, before) do
    from(r in Run,
      join: o in Organisation,
      on: o.id == r.organisation_id,
      join: ws in Workspace,
      on: ws.id == r.workspace_id,
      left_join: x in Dispatch,
      on: x.id == r.dispatch_id,
      left_join: d in DispatchRun,
      on: d.id == coalesce(r.dispatch_run_id, x.dispatch_run_id),
      left_join: h in RunHarness,
      as: :walk,
      on: h.dispatch_run_id == d.id and h.state == :resolved,
      left_join: w in WorkItem,
      as: :work_item,
      on: w.id == d.work_item_id and w.workspace_id == r.workspace_id,
      order_by: [desc: r.inserted_at, desc: fragment("? COLLATE \"C\"", r.public_id)],
      limit: ^(filters.limit + 1),
      select: %{
        id: r.public_id,
        number: r.number,
        state: r.state,
        reason: r.reason,
        inserted_at: r.inserted_at,
        started_at: r.started_at,
        exited_at: r.exited_at,
        organisation_slug: o.slug,
        workspace_id: ws.public_id,
        workspace_slug: ws.slug,
        workflow: h.workflow,
        work_item_number: w.number,
        work_item_title: w.title
      }
    )
    |> filter(:workspace, workspace_id)
    |> filter(:work_item, filters.work_item)
    |> filter(:workflow, filters.workflow)
    |> filter(:state, filters.state)
    |> filter(:since, filters.since)
    |> filter(:before, before)
  end

  defp filter(query, _name, nil), do: query
  defp filter(query, :workspace, id), do: where(query, [r], r.workspace_id == ^id)

  defp filter(query, :work_item, number),
    do: where(query, [work_item: w], w.number == ^number)

  defp filter(query, :workflow, workflow),
    do: where(query, [walk: h], h.workflow == ^workflow)

  defp filter(query, :state, state), do: where(query, [r], r.state == ^state)
  defp filter(query, :since, since), do: where(query, [r], r.inserted_at >= ^since)

  defp filter(query, :before, {at, public_id}) do
    where(
      query,
      [r],
      r.inserted_at < ^at or
        (r.inserted_at == ^at and fragment("? COLLATE \"C\" < ?", r.public_id, ^public_id))
    )
  end

  defp row(run, now) do
    %{
      "id" => run.id,
      "number" => run.number,
      "organisation" => %{"slug" => run.organisation_slug},
      "workspace" => %{"id" => run.workspace_id, "slug" => run.workspace_slug},
      "state" => run.state,
      "created_at" => time(run.inserted_at)
    }
    |> put_member("workflow", matching(run.workflow, @workflow))
    |> put_work_item(run.work_item_number, title(run.work_item_title))
    |> put_member("reason", matching(run.reason, @code))
    |> put_member("started_at", time(run.started_at))
    |> put_member("duration_seconds", duration(run, now))
  end

  defp put_work_item(row, number, title) when is_integer(number) and is_binary(title),
    do: Map.merge(row, %{"work_item_number" => number, "work_item_title" => title})

  defp put_work_item(row, _number, _title), do: row

  # Whole seconds, rounded down, from the start to the exit, or to `now` for a run that
  # started, has not exited and is pending or running. Nil for a run that has not started,
  # and for one that ended without an exit.
  defp duration(%{started_at: nil}, _now), do: nil

  defp duration(%{started_at: started, exited_at: %DateTime{} = exited}, _now),
    do: seconds(started, exited)

  defp duration(%{started_at: started, state: state}, now) when state in ["pending", "running"],
    do: seconds(started, now)

  defp duration(_run, _now), do: nil

  defp seconds(from, to), do: max(DateTime.diff(to, from, :microsecond), 0) |> div(1_000_000)

  # The title as the contract takes it: valid UTF-8 without U+0000, 1 to 1,024 characters.
  defp title(nil), do: nil

  defp title(title) do
    shown =
      title
      |> String.replace_invalid("\u{FFFD}")
      |> String.replace(<<0>>, "\u{FFFD}")
      |> String.codepoints()
      |> Enum.take(@max_title)
      |> Enum.join()

    if shown != "", do: shown
  end

  defp matching(value, regex) when is_binary(value) do
    if Regex.match?(regex, value), do: value
  end

  defp matching(_value, _regex), do: nil

  defp time(nil), do: nil
  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp put_member(map, _key, nil), do: map
  defp put_member(map, key, value), do: Map.put(map, key, value)
end
