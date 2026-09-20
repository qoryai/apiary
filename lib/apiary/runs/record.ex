defmodule Apiary.Runs.Record do
  @moduledoc """
  The record of one run, as the run page reads it: its events in windows by sequence, the
  timeline laid out from them, its log chunks and its connections.

  Every function takes the caller's scope first and the run second, and reads only rows
  that carry the scope's organisation, the scope's hive and the run's row id. A run of
  another hive is never reached: `fetch_run/2` does not find it, and a `%Run{}` of another
  hive handed in reads nothing.

  What an event carries is the runner's input. It is returned as data, bounded by
  `Apiary.Runs.Record.Timeline`; nothing here renders it.
  """

  import Ecto.Query, warn: false

  alias Apiary.Accounts.Scope
  alias Apiary.Organisations.{Hive, Organisation}
  alias Apiary.Repo
  alias Apiary.Runs
  alias Apiary.Runs.{Connection, Event, LogChunk, Run}
  alias Apiary.Runs.Record.Timeline

  @policy_applied "ai.qory.run.policy_applied"
  @session_started "ai.qory.session.started"
  @egress "ai.qory.run.egress"

  @log_page 200
  @default_log_limit 2_000
  @max_log_limit 10_000

  ## The run

  @doc """
  The run of the scope's hive whose subject is `run_id`, the id the runner prints.
  `:error` for a subject the hive has not seen and for anything that is not a UUID.
  """
  def fetch_run(%Scope{} = scope, run_id) do
    with {:ok, run_id} <- cast_uuid(run_id) do
      {:ok, scope |> Runs.get_run_by_run_id!(run_id) |> Repo.preload(:access_key)}
    end
  rescue
    Ecto.NoResultsError -> :error
  end

  # `Ecto.UUID.cast/1` takes sixteen raw bytes too; a URL never means those.
  defp cast_uuid(<<_::binary-size(36)>> = id), do: Ecto.UUID.cast(id)
  defp cast_uuid(_other), do: :error

  @doc "The run again, as the database has it now; nil when it is gone."
  def reload(%Scope{} = scope, %Run{id: id}) do
    case Repo.one(from r in runs(scope), where: r.id == ^id) do
      %Run{} = run -> Repo.preload(run, :access_key)
      nil -> nil
    end
  end

  @doc """
  The policy in force: the data of the run's last `run.policy_applied`, with the sequence
  it was applied at under `:sequence` and its time under `:time`. nil when the run has none.
  """
  def policy(%Scope{} = scope, %Run{} = run) do
    case last_of_type(scope, run, @policy_applied) do
      %{data: %{} = data} = event -> %{data: data, sequence: event.sequence, time: event.time}
      _ -> nil
    end
  end

  @doc "The runtime's session id, from the run's last `session.started`; nil without one."
  def session_id(%Scope{} = scope, %Run{} = run) do
    case last_of_type(scope, run, @session_started) do
      %{data: %{"session_id" => id}} when is_binary(id) -> id
      _ -> nil
    end
  end

  defp last_of_type(scope, run, type) do
    Repo.one(
      from e in events(scope, run),
        where: e.type == ^type,
        order_by: [desc: e.sequence],
        limit: 1,
        select: %{sequence: e.sequence, time: e.time, data: e.data}
    )
  end

  ## The timeline

  @doc """
  The layout of the run's timeline (`Timeline.index/2`), from a light read of every event
  that makes an item: no payload is loaded.
  """
  def timeline(%Scope{} = scope, %Run{} = run) do
    types = Enum.map(Timeline.types(), &("ai.qory." <> &1))

    light =
      Repo.all(
        from e in events(scope, run),
          where: e.type in ^types,
          order_by: e.sequence,
          select: %{
            sequence: e.sequence,
            type: e.type,
            time: e.time,
            tool_use_id: fragment("?->>'tool_use_id'", e.data),
            agent_id: fragment("?->>'agent_id'", e.data),
            agent_type: fragment("?->>'agent_type'", e.data),
            host: fragment("?->>'host'", e.data),
            port: fragment("?->>'port'", e.data),
            decision: fragment("?->>'decision'", e.data),
            background_tasks: fragment("?->'background_tasks'", e.data)
          }
      )

    light
    |> Enum.map(&bound_light/1)
    |> Timeline.index(alive: run.state in Run.alive_states())
  end

  # Ids pair events up and name lanes; a runner that sends a megabyte for one is cut.
  defp bound_light(event) do
    event
    |> Map.update!(:tool_use_id, &short/1)
    |> Map.update!(:agent_id, &short/1)
    |> Map.update!(:agent_type, &short/1)
    |> Map.update!(:host, &short/1)
  end

  defp short(value) when is_binary(value), do: String.slice(value, 0, 255)
  defp short(_value), do: nil

  @doc """
  The full items of the light items `light` of `index`, payloads bounded. `full:` lists
  the item sequences whose payloads are given whole.
  """
  def items(%Scope{} = scope, %Run{} = run, %{lanes: lanes}, light, opts \\ []) do
    case Timeline.needed(light, lanes) do
      [] ->
        []

      sequences ->
        events =
          Repo.all(
            from e in events(scope, run),
              where: e.sequence in ^sequences,
              select: %{sequence: e.sequence, type: e.type, time: e.time, data: e.data}
          )
          |> Map.new(fn event -> {event.sequence, %{event | data: data(event.data)}} end)

        Timeline.build(light, events, opts)
    end
  end

  defp data(%{} = data), do: data
  defp data(_other), do: %{}

  ## Connections

  @doc """
  The run's connections, one per host, port and path, denied destinations first and then
  the most recently seen. Each is the projection's counts with the fields of the last
  egress event of the destination beside them (`decision`, `rule`, `path_rule`,
  `credential`, `mode`, `outcome`, `request_method`): the reason a row gives is the last
  attempt's.
  """
  def connections(%Scope{} = scope, %Run{} = run) do
    rows =
      Repo.all(
        from c in Connection,
          where: c.organisation_id == ^organisation_id(scope) and c.hive_id == ^hive_id(scope),
          where: c.run_id == ^run.id,
          order_by: [desc: c.denied > 0, desc: c.last_seen_at, desc: c.last_sequence, asc: c.host]
      )

    sequences = Enum.map(rows, & &1.last_sequence)

    last =
      Repo.all(
        from e in events(scope, run),
          where: e.type == ^@egress and e.sequence in ^sequences,
          select: %{sequence: e.sequence, time: e.time, data: e.data}
      )
      |> Map.new(fn event ->
        {event.sequence, Timeline.connection(%{event | data: data(event.data)})}
      end)

    for row <- rows do
      attempt = Map.get(last, row.last_sequence, %{})

      %{
        id: row.id,
        host: row.host,
        port: row.port,
        path: row.path,
        method: row.method,
        request_method: attempt[:request_method],
        attempts: row.attempts,
        allowed: row.allowed,
        denied: row.denied,
        decision: attempt[:decision] || row.last_decision,
        rule: attempt[:rule] || row.last_rule,
        path_rule: attempt[:path_rule],
        credential: attempt[:credential],
        mode: attempt[:mode],
        outcome: attempt[:outcome] || row.last_outcome,
        first_seen_at: row.first_seen_at,
        last_seen_at: row.last_seen_at,
        last_sequence: row.last_sequence
      }
    end
  end

  ## The log

  @doc """
  What the run's log holds: `%{chunks, bytes, through, streams}`; `through` is the last
  chunk's sequence (0 without chunks) and `streams` the stream names in the record.
  """
  def log_summary(%Scope{} = scope, %Run{} = run) do
    summary =
      Repo.one(
        from l in log_chunks(scope, run),
          select: %{
            chunks: count(l.id),
            bytes: coalesce(sum(fragment("octet_length(?)", l.bytes)), 0),
            through: coalesce(max(l.sequence), 0)
          }
      )

    streams =
      Repo.all(
        from l in log_chunks(scope, run), distinct: true, select: l.stream, order_by: l.stream
      )

    summary
    |> Map.update!(:bytes, &to_integer/1)
    |> Map.put(:streams, streams)
  end

  defp to_integer(%Decimal{} = n), do: Decimal.to_integer(n)
  defp to_integer(n) when is_integer(n), do: n

  @doc """
  The sequence of the last of the first `limit` chunks after `after_sequence`, or
  `after_sequence` itself when none follows: how far `log_pages/5` will go.

  `stream:` keeps one stream (`"stdout"`, `"stderr"`, `"terminal"`); `limit: :all` takes
  every chunk.
  """
  def log_through(%Scope{} = scope, %Run{} = run, after_sequence, opts \\ []) do
    query = log_after(scope, run, after_sequence, opts[:stream])

    through =
      case log_limit(opts[:limit]) do
        :all ->
          Repo.one(from l in query, select: max(l.sequence))

        limit ->
          Repo.one(
            from l in subquery(
                   from l in query,
                     order_by: l.sequence,
                     limit: ^limit,
                     select: %{sequence: l.sequence}
                 ),
                 select: max(l.sequence)
          )
      end

    through || after_sequence
  end

  @doc """
  Calls `fun` with the bytes of each page of chunks after `after_sequence` up to and
  including `through`, in sequence order, threading `acc`: `fun.(iodata, acc)` answers
  `{:cont, acc}` or `{:halt, acc}`. A page is #{@log_page} chunks, so a long log is never
  held whole.
  """
  def log_pages(%Scope{} = scope, %Run{} = run, after_sequence, through, acc, fun, opts \\ []) do
    page =
      Repo.all(
        from l in log_after(scope, run, after_sequence, opts[:stream]),
          where: l.sequence <= ^through,
          order_by: l.sequence,
          limit: @log_page,
          select: {l.sequence, l.bytes}
      )

    case page do
      [] ->
        acc

      chunks ->
        {last, _bytes} = List.last(chunks)

        case fun.(Enum.map(chunks, &elem(&1, 1)), acc) do
          {:cont, acc} when length(chunks) == @log_page ->
            log_pages(scope, run, last, through, acc, fun, opts)

          {_either, acc} ->
            acc
        end
    end
  end

  defp log_after(scope, run, after_sequence, stream) do
    query = from l in log_chunks(scope, run), where: l.sequence > ^after_sequence
    if is_binary(stream), do: from(l in query, where: l.stream == ^stream), else: query
  end

  defp log_limit(:all), do: :all
  defp log_limit(limit) when is_integer(limit), do: limit |> max(1) |> min(@max_log_limit)
  defp log_limit(_other), do: @default_log_limit

  ## Scoping

  defp runs(%Scope{} = scope) do
    from r in Run,
      where: r.organisation_id == ^organisation_id(scope) and r.hive_id == ^hive_id(scope)
  end

  defp events(%Scope{} = scope, %Run{id: id}) do
    from e in Event,
      where: e.organisation_id == ^organisation_id(scope) and e.hive_id == ^hive_id(scope),
      where: e.run_id == ^id
  end

  defp log_chunks(%Scope{} = scope, %Run{id: id}) do
    from l in LogChunk,
      where: l.organisation_id == ^organisation_id(scope) and l.hive_id == ^hive_id(scope),
      where: l.run_id == ^id
  end

  defp organisation_id(%Scope{organisation: %Organisation{id: id}}), do: id
  defp hive_id(%Scope{hive: %Hive{id: id}}), do: id
end
