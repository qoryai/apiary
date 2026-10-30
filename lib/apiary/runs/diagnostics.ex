defmodule Apiary.Runs.Diagnostics do
  @moduledoc """
  A run's diagnostics: one JSON document about one run, the document of the diagnostics
  contract (`priv/contract/diagnostics/v1/diagnostics.schema.json`, vendored from the
  integrations at the commit in `test/fixtures/contract/diagnostics/v1/.contract-ref`),
  `version` 1. The run page's Copy diagnostics copies it, and
  `GET /v1/runs/<run id>/diagnostics`, signed with a diagnostics key, answers with it.

  **What it contains.** `instance`, the product's name in the edition and the version;
  `run`, the run's id, state, reason, exit, times, organisation, workspace, step,
  workflow, work item, target, gateway and the names of its variables; `queue`, the
  state and end cause of the run's row in its workspace's queue; `dispatches`, the
  dispatch whose claim registered the run, at most one, with the starter's release
  reason; `preparation`, the steps from the machine's start to the session's
  (`Apiary.Runs.Preparation`), each with its output, and why it stopped; `events`, the
  run's last events, at most `max_events/0`, with `events_omitted`; `log`, the run's
  output that belongs to no step, its last `max_log_bytes/0` bytes, with `truncated`;
  `machine_logs`; and `leaked_secrets`, the secrets found in the run's text when it was
  stored, with `leaked_secrets_omitted` (`Apiary.Runs.LeakedSecrets`). A secret of a
  machine log is listed only in a document with `machine_logs`. Each member is written from the run's columns one by one, so a
  column marked `redact: true` on the run (the run key, the run code's hash, the registry
  credential's hash, the provider's ids) is never in it, and the variables appear by name
  alone. A value outside its pattern in the contract is left out, as a member the run has
  not got is.

  **Who reads what.** The reader is a person who reads the run and its log (`run.read`
  and `run.read_log`; the caller checks both), or a diagnostics key, which reads as the
  instance (`Apiary.AccessKeys.diagnostics_scope/1`). Either reads the log and the steps'
  output. `machine_logs` is there for an instance admin (`Apiary.Access.instance_admin?/1`)
  and for a diagnostics key. The events are read as the run page reads them, through the
  edition (its `client_reads` callback, `:run_events`), under the person's scope or
  the instance's; the `dev.qory.run.log` events are left out, as their output is in `log`
  and in the steps' output already. `log` and `events` are also left out once the
  retention removed them (`runs.log_pruned_at`, `runs.events_pruned_at`).

  **Text.** Every text member is the stored text as it is: valid UTF-8, each byte that
  is not part of it replaced by U+FFFD, and no U+0000, also replaced by U+FFFD; keys of
  an event's data and strings at any depth in it too. A secret printed into the run's
  output stays in the document, so that the reader sees it, and is listed in
  `leaked_secrets`.

  **Its size.** The encoded document is at most `max_bytes/0` bytes. The members other
  than the events are written first. While they are larger than that, the log loses its
  first part (`truncated` true), then each machine log, then each step's output. The
  events then take what is left, the latest first, so the oldest are the ones left out,
  counted in `events_omitted`. Reading the events costs at most what the document can
  hold: their sizes are read first, and only the events that fit are read whole.
  """

  import Ecto.Query, only: [from: 2, dynamic: 1, dynamic: 2]

  alias Apiary.{Access, AccessKeys, Edition, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Accounts.Scope
  alias Apiary.Dispatches.{Dispatch, DispatchRun, MachineLogs}
  alias Apiary.Harnesses.RunHarness
  alias Apiary.Organisations.{Organisation, Workspace}
  alias Apiary.Runs.{Event, LeakedSecrets, LogChunk, Preparation, Run}
  alias Apiary.WorkItems.WorkItem

  @max_bytes 8 * 1024 * 1024
  @max_events 5_000
  @max_log_bytes 1024 * 1024
  # The log is read from its end in pages of this many chunks.
  @log_page 500
  # The events' sizes are read in pages of this many.
  @event_page 1_000
  # What an event's members other than its data take, at most, encoded, beside its data.
  @event_frame 200
  # What the document's `events_omitted` and the commas between the events may add to the
  # size measured without them.
  @slack 64

  @log_event "dev.qory.run.log"

  @code ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @step ~r/\A[a-z][a-z_]{0,39}\z/
  @workflow ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @variable ~r/\A[A-Za-z_][A-Za-z0-9_]{0,127}\z/
  @place_text ~r/\A[^\x00-\x1f\x7f]{1,256}\z/u
  @int32 -2_147_483_648..2_147_483_647

  @typedoc "The document: a map with string keys, as JSON has it."
  @type document :: %{String.t() => term}

  @typedoc """
  Who reads the document: a person's scope, in the run's workspace, or `:instance`, a
  diagnostics key, which reads as the instance.
  """
  @type reader :: Scope.t() | :instance

  @doc "max_bytes/0 is the most bytes the encoded document holds: 8 MiB."
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  @doc "max_events/0 is the most events the document holds: 5,000."
  @spec max_events() :: pos_integer
  def max_events, do: @max_events

  @doc "max_log_bytes/0 is the most bytes of the log the document holds: 1 MiB."
  @spec max_log_bytes() :: pos_integer
  def max_log_bytes, do: @max_log_bytes

  @doc """
  encode/3 is the document about `run` for `scope`, encoded as JSON, at most
  `max_bytes/0` bytes: for the person of `scope`, or, for the scope of a diagnostics key,
  as the instance. The caller has read `run` under the scope, and checked that a person
  reads its log.

  `opts`: `now`, the document's time (the current time).
  """
  @spec encode(Run.t(), Scope.t(), keyword) :: String.t()
  def encode(%Run{} = run, %Scope{} = scope, opts \\ []) do
    run
    |> document(reader(scope), opts)
    |> Jason.encode!()
  end

  defp reader(%Scope{access_key: %AccessKey{} = key} = scope) do
    if AccessKeys.diagnostics_scope(key) == :instance, do: :instance, else: scope
  end

  defp reader(%Scope{} = scope), do: scope

  @doc """
  document/3 is the document about `run` for `reader`, as a map, whose encoding is at
  most `max_bytes/0` bytes (`:max_bytes` in `opts` sets another bound, for a test of the
  cut). `opts`: `now`, the document's time (the current time).
  """
  @spec document(Run.t(), reader, keyword) :: document
  def document(%Run{} = run, reader, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    run = Repo.preload(run, [:organisation, :workspace, :gateway, :dispatch_run], force: true)
    dispatch = dispatch(run)

    {scope, machine_logs?} =
      case reader do
        :instance -> {Scope.for_instance(run.organisation, run.workspace), true}
        %Scope{} = scope -> {scope, Access.instance_admin?(scope)}
      end

    machine_log = if(machine_logs? and dispatch, do: machine_log(dispatch))

    {leaked, leaked_omitted} =
      LeakedSecrets.read(run, dispatch,
        machine_logs: machine_logs?,
        machine_log: machine_log && machine_log.text,
        events: events_query(scope, run)
      )

    base =
      %{
        "version" => 1,
        "time" => time(now),
        "instance" => instance(),
        "run" => run_member(run),
        "dispatches" => if(dispatch, do: [dispatch_member(dispatch)], else: []),
        "preparation" => preparation(scope, run),
        "leaked_secrets" => Enum.map(leaked, &leaked_member/1),
        "leaked_secrets_omitted" => leaked_omitted
      }
      |> put("queue", queue(run.dispatch_run))
      |> put("log", if(is_nil(run.log_pruned_at), do: log(run)))
      |> put("machine_logs", if(machine_logs?, do: machine_logs(machine_log)))
      |> fit(max_bytes)

    if is_nil(run.events_pruned_at) do
      events(scope, run, base, max_bytes)
    else
      base
    end
  end

  ## The members

  defp instance do
    version =
      case Application.spec(:apiary, :vsn) do
        nil -> "unknown"
        vsn -> to_string(vsn)
      end

    %{"edition" => text(Apiary.ProductName.edition_name()), "version" => text(version)}
  end

  defp run_member(%Run{} = run) do
    %{
      "id" => run.public_id,
      "state" => run.state,
      "created_at" => time(run.inserted_at),
      "organisation" => %{"slug" => organisation_slug(run.organisation)},
      "workspace" => %{"id" => workspace_id(run.workspace)}
    }
    |> put("reason", code(run.reason))
    |> put("exit_state", if(run.exit_state in Run.states(), do: run.exit_state))
    |> put("exit_reason", code(run.exit_reason))
    |> put("exit_code", if(run.exit_code in @int32, do: run.exit_code))
    |> put("started_at", time(run.started_at))
    |> put("exited_at", time(run.exited_at))
    |> put("step", run.dispatch_run && matching(run.dispatch_run.step, @step))
    |> put("workflow", workflow(run.dispatch_run))
    |> put("work_item", work_item(run.dispatch_run))
    |> put("target", target(run))
    |> put("gateway", run.gateway && run.gateway.public_id)
    |> put("variables", variables(run.registration_variables))
  end

  defp organisation_slug(%Organisation{slug: slug}), do: slug
  defp workspace_id(%Workspace{public_id: public_id}), do: public_id

  defp workflow(%DispatchRun{id: id}) do
    Repo.one(
      from h in RunHarness,
        where: h.dispatch_run_id == ^id and h.state == :resolved,
        select: h.workflow
    )
    |> matching(@workflow)
  end

  defp workflow(nil), do: nil

  defp work_item(%DispatchRun{work_item_id: id}) when is_binary(id),
    do: Repo.one(from w in WorkItem, where: w.id == ^id, select: w.public_id)

  defp work_item(_dispatch_run), do: nil

  defp target(%Run{target_system: system, target_path: path}) do
    with system when is_binary(system) <- matching(system, @place_text),
         path when is_binary(path) <- matching(path, @place_text) do
      %{"system" => system, "path" => path}
    end
  end

  defp variables(variables) when is_map(variables) do
    variables |> Map.keys() |> Enum.filter(&matching(&1, @variable)) |> Enum.sort()
  end

  defp variables(_none), do: nil

  defp queue(%DispatchRun{state: state, end_cause: cause}) do
    put(%{"state" => Atom.to_string(state)}, "end_cause", cause && code(Atom.to_string(cause)))
  end

  defp queue(nil), do: nil

  # The dispatch whose claim registered the run. A run whose start failed keeps it in
  # `dispatch_id`. Any other run: of the run's row in the queue, the one claimed last at
  # or before the run's row was written. A claim writes its run in the transaction that
  # writes the dispatch, at the claim's time, and a dispatch released or lapsed before
  # its handover takes its run with it, so no later dispatch of the row is the run's. Nil
  # for a run registered without a claim.
  defp dispatch(%Run{dispatch_id: id}) when is_binary(id),
    do:
      Repo.one(
        from d in Dispatch, join: p in assoc(d, :pool), where: d.id == ^id, preload: [pool: p]
      )

  defp dispatch(%Run{dispatch_run_id: nil}), do: nil

  defp dispatch(%Run{dispatch_run_id: id} = run) do
    registered = run.inserted_at

    Repo.one(
      from d in Dispatch,
        join: p in assoc(d, :pool),
        where: d.dispatch_run_id == ^id and d.claimed_at <= ^registered,
        order_by: [desc: d.claimed_at, desc: d.id],
        limit: 1,
        preload: [pool: p]
    )
  end

  defp dispatch_member(%Dispatch{} = dispatch) do
    %{
      "id" => dispatch.public_id,
      "pool" => dispatch.pool.public_id,
      "claimed_at" => time(dispatch.claimed_at)
    }
    |> put("lease_until", time(dispatch.lease_until))
    |> put("dispatched_at", time(dispatch.dispatched_at))
    |> put("handed_over_at", time(dispatch.handed_over_at))
    |> put("stale_at", time(dispatch.stale_at))
    |> put("ended_at", time(dispatch.ended_at))
    |> put("end_cause", dispatch.end_cause && code(Atom.to_string(dispatch.end_cause)))
    |> put("release_reason", nonempty(dispatch.release_reason))
  end

  # The preparation (`Apiary.Runs.Preparation`), read under `scope` with the steps'
  # output.
  defp preparation(%Scope{} = scope, %Run{} = run) do
    preparation = Preparation.read(scope, run, log: true, release_reason: :as_stored)

    %{"steps" => Enum.map(preparation.steps, &step_member/1)}
    |> put("session_started_at", time(preparation.session_started_at))
    |> put("stopped", stopped_member(preparation.stopped))
  end

  defp step_member(step) do
    %{
      "number" => step.number,
      "state" => step.state,
      "output" => output_member(step.output)
    }
    |> put("name", nonempty(step.name))
    |> put("kind", step.kind && code(step.kind))
    |> put("exit_code", if(step.exit_code in @int32, do: step.exit_code))
    |> put("started_at", time(step.started_at))
    |> put("exited_at", time(step.exited_at))
    |> put(
      "duration_ms",
      if(is_integer(step.duration_ms) and step.duration_ms >= 0, do: step.duration_ms)
    )
  end

  defp output_member(%{text: text, truncated: truncated}),
    do: %{"text" => text(text), "truncated" => truncated}

  defp stopped_member(nil), do: nil

  defp stopped_member(%{cause: cause, step: step, fixer: fixer, text: line}) do
    %{
      "cause" => Atom.to_string(cause),
      "fixer" => Atom.to_string(fixer),
      "text" => nonempty(line) || "\u{FFFD}"
    }
    |> put("step", if(cause == :step_failed, do: step))
  end

  # The machine log of the run's dispatch, where it has one that can be read.
  defp machine_log(%Dispatch{public_id: public_id}) do
    case MachineLogs.read(public_id) do
      {:ok, log} -> log
      {:error, _none} -> nil
    end
  end

  defp machine_logs(nil), do: []

  defp machine_logs(log) do
    [
      %{
        "dispatch" => log.dispatch_id,
        "uploaded_at" => time(log.uploaded_at),
        "truncated" => log.truncated,
        "text" => text(log.text)
      }
    ]
  end

  # A secret found in the run's text (`Apiary.Runs.LeakedSecrets`).
  defp leaked_member(secret) do
    %{
      "kind" => secret.kind,
      "place" => secret.place,
      "time" => time(secret.at),
      "message" => secret.message
    }
    |> put("step", secret.step)
    |> put("sequence", secret.sequence)
    |> put("dispatch", secret.dispatch)
    |> put("id", secret.id)
    |> put("value", secret.value && text(secret.value))
  end

  ## The log

  # The run's output that belongs to no step, every stream, in sequence order: its last
  # `@max_log_bytes` bytes once it is text, read from its end.
  defp log(%Run{id: run_id}) do
    chunks = from l in LogChunk, where: l.run_id == ^run_id and is_nil(l.step)

    total =
      Repo.one(from l in chunks, select: coalesce(sum(fragment("octet_length(?)", l.bytes)), 0))
      |> to_integer()

    {bytes, whole?} = read_log_tail(chunks, @max_log_bytes, total)
    {kept, cut?} = bytes |> text() |> last_bytes(@max_log_bytes)
    %{"text" => kept, "truncated" => cut? or not whole?}
  end

  # The last chunks whose bytes come to `wanted` or more, in sequence order, and whether
  # they are the whole log.
  defp read_log_tail(chunks, wanted, total) do
    {parts, size} = read_log_pages(chunks, wanted, nil, [], 0)
    {IO.iodata_to_binary(parts), size >= total}
  end

  defp read_log_pages(chunks, wanted, before, acc, size) do
    page =
      Repo.all(
        from l in chunks,
          where: ^before_sequence(before),
          order_by: [desc: l.sequence],
          limit: @log_page,
          select: {l.sequence, l.bytes}
      )

    {acc, size, last} =
      Enum.reduce_while(page, {acc, size, before}, fn {sequence, bytes}, {acc, size, _last} ->
        acc = [bytes | acc]
        size = size + byte_size(bytes)
        if size >= wanted, do: {:halt, {acc, size, :done}}, else: {:cont, {acc, size, sequence}}
      end)

    cond do
      last == :done -> {acc, size}
      length(page) < @log_page -> {acc, size}
      true -> read_log_pages(chunks, wanted, last, acc, size)
    end
  end

  defp before_sequence(nil), do: dynamic(true)
  defp before_sequence(sequence), do: dynamic([l], l.sequence < ^sequence)

  ## The events

  # The run's events that `scope` reads, the latest first, as many as fit in what
  # `document` leaves of `max_bytes`, at most `@max_events`, put back in sequence order;
  # and how many earlier ones are left out, counted below the oldest kept, so that an
  # event stored since is not counted.
  defp events(%Scope{} = scope, %Run{} = run, document, max_bytes) do
    events = events_query(scope, run)
    budget = max_bytes - byte_size(Jason.encode!(document)) - @slack
    sizes = event_sizes(events, budget)

    kept =
      case sizes do
        [] -> []
        _sizes -> read_events(events, sizes, budget)
      end

    omitted =
      case kept do
        [] ->
          Repo.one(from e in events, select: count(e.id))

        [%{"sequence" => oldest} | _] ->
          Repo.one(from e in events, where: e.sequence < ^oldest, select: count(e.id))
      end

    document
    |> Map.put("events", kept)
    |> Map.put("events_omitted", max(omitted, 0))
  end

  # The run's events as the run page reads them for `scope` (`Apiary.Runs.Record`), the
  # edition narrowing them (`:run_events`), without the `dev.qory.run.log` events.
  defp events_query(%Scope{} = scope, %Run{id: id} = run) do
    query =
      from e in Event,
        where: e.organisation_id == ^run.organisation_id and e.workspace_id == ^run.workspace_id,
        where: e.run_id == ^id and e.type != @log_event

    Edition.client_reads(scope, :run_events, run, query)
  end

  # The sequences and the estimated sizes of the latest events whose estimates fit in
  # `budget`, the latest first: the size of an event's data as the database writes it,
  # and its other members' at most.
  defp event_sizes(events, budget), do: event_sizes(events, budget, nil, [], 0)

  defp event_sizes(events, budget, before, acc, count) do
    page =
      Repo.all(
        from e in events,
          where: ^before_event(before),
          order_by: [desc: e.sequence],
          limit: @event_page,
          select:
            {e.sequence, fragment("octet_length(?::text) + octet_length(?)", e.data, e.type)}
      )
      |> Enum.map(fn {sequence, size} -> {sequence, size + @event_frame} end)

    {acc, count, budget, done?} =
      Enum.reduce_while(page, {acc, count, budget, false}, fn {sequence, size},
                                                              {acc, count, left, _done} ->
        cond do
          count >= @max_events -> {:halt, {acc, count, left, true}}
          size > left -> {:halt, {acc, count, left, true}}
          true -> {:cont, {[{sequence, size} | acc], count + 1, left - size, false}}
        end
      end)

    if done? or length(page) < @event_page do
      Enum.reverse(acc)
    else
      {last, _size} = hd(acc)
      event_sizes(events, budget, last, acc, count)
    end
  end

  defp before_event(nil), do: dynamic(true)
  defp before_event(sequence), do: dynamic([e], e.sequence < ^sequence)

  # The events of `sizes`, read whole and encoded, the latest first, as many as fit in
  # `budget` once encoded; in sequence order.
  defp read_events(events, [{latest, _size} | _] = sizes, budget) do
    {oldest, _size} = List.last(sizes)

    Repo.all(
      from e in events,
        where: e.sequence >= ^oldest and e.sequence <= ^latest,
        order_by: [desc: e.sequence],
        select: %{sequence: e.sequence, type: e.type, time: e.time, data: e.data}
    )
    |> Enum.reduce_while({[], budget}, fn event, {kept, left} ->
      member = event_member(event)
      size = byte_size(Jason.encode!(member)) + 1

      if size > left,
        do: {:halt, {kept, left}},
        else: {:cont, {[member | kept], left - size}}
    end)
    |> elem(0)
  end

  defp event_member(%{sequence: sequence, type: type, time: time, data: data}) do
    %{
      "sequence" => sequence,
      "type" => text(type),
      "time" => DateTime.to_iso8601(time),
      "data" => if(is_map(data), do: data(data), else: %{})
    }
  end

  # An event's data with every key and every string at any depth as `text/1` makes it.
  defp data(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {text(key), data(value)} end)

  defp data(list) when is_list(list), do: Enum.map(list, &data/1)
  defp data(string) when is_binary(string), do: text(string)
  defp data(other), do: other

  ## The size

  # The document cut to `max_bytes` once encoded, the events aside: the log's first part,
  # then each machine log's, then each step's output, as long as it is larger. Each byte
  # cut from a text takes at least that byte from the encoding.
  defp fit(document, max_bytes) do
    over = byte_size(Jason.encode!(document)) - max_bytes

    with true <- over > 0,
         %{} = cut <- cut_once(document, over) do
      fit(cut, max_bytes)
    else
      _fits_or_nothing_to_cut -> document
    end
  end

  defp cut_once(%{"log" => %{"text" => text} = log} = document, over) when text != "" do
    {kept, _cut} = last_bytes(text, max(byte_size(text) - over, 0))
    %{document | "log" => %{log | "text" => kept, "truncated" => true}}
  end

  defp cut_once(%{"machine_logs" => logs} = document, over) when is_list(logs) do
    case Enum.find_index(logs, &(&1["text"] != "")) do
      nil ->
        cut_steps(document, over)

      index ->
        logs =
          List.update_at(logs, index, fn %{"text" => text} = log ->
            {kept, _cut} = last_bytes(text, max(byte_size(text) - over, 0))
            %{log | "text" => kept, "truncated" => true}
          end)

        %{document | "machine_logs" => logs}
    end
  end

  defp cut_once(document, over), do: cut_steps(document, over)

  defp cut_steps(%{"preparation" => %{"steps" => steps} = preparation} = document, over) do
    case Enum.find_index(steps, &(get_in(&1, ["output", "text"]) not in [nil, ""])) do
      nil ->
        nil

      index ->
        steps =
          List.update_at(steps, index, fn %{"output" => %{"text" => text} = output} = step ->
            {kept, _cut} = last_bytes(text, max(byte_size(text) - over, 0))
            %{step | "output" => %{output | "text" => kept, "truncated" => true}}
          end)

        %{document | "preparation" => %{preparation | "steps" => steps}}
    end
  end

  ## Values

  # Text as the document holds it: valid UTF-8, each byte outside it replaced by U+FFFD,
  # U+0000 replaced by U+FFFD.
  defp text(value) when is_binary(value) do
    value
    |> String.replace_invalid("\u{FFFD}")
    |> String.replace(<<0>>, "\u{FFFD}")
  end

  # The last `limit` bytes of `text`, valid UTF-8, starting at a character, and whether
  # anything was cut.
  defp last_bytes(text, limit) when byte_size(text) <= limit, do: {text, false}

  defp last_bytes(text, limit) do
    tail = binary_part(text, byte_size(text) - limit, limit)
    {drop_continuation(tail), true}
  end

  # A UTF-8 continuation byte, 0b10xxxxxx, starts no character.
  defp drop_continuation(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_continuation(rest)

  defp drop_continuation(text), do: text

  defp code(value), do: matching(value, @code)

  # A value of the contract's pattern; nil for one outside it.
  defp matching(value, regex) when is_binary(value) do
    if Regex.match?(regex, value), do: value
  end

  defp matching(_value, _regex), do: nil

  # A text member of 1 character or more, nil for nothing or an empty text.
  defp nonempty(nil), do: nil

  defp nonempty(value) when is_binary(value) do
    shown = text(value)
    if shown != "", do: shown
  end

  defp time(nil), do: nil
  defp time(%DateTime{} = at), do: at |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp put(map, _key, nil), do: map
  defp put(map, key, value), do: Map.put(map, key, value)

  defp to_integer(%Decimal{} = value), do: Decimal.to_integer(value)
  defp to_integer(value) when is_integer(value), do: value
end
