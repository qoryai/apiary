defmodule Apiary.Runs.LeakedSecrets do
  @moduledoc """
  LeakedSecrets finds the secrets a run prints, when Qory Apiary stores the text they are
  in, and reads them back for the run's diagnostics document (`Apiary.Runs.Diagnostics`).
  A secret printed into a run's output is compromised: the document lists it, with its
  value while the text is kept, so that the reader replaces it.

  **What is scanned** (`Apiary.SecretScan.scan/1`), each once, as it is stored:

    * the run's output, each log chunk as the projection stores it
      (`Apiary.Runs.Projector`). A chunk is scanned after the end of the step's chunk
      before it that a secret may start in (`Apiary.SecretScan.carry/1`). That end comes
      from the same pass of the projection, or from the chunks stored before it. A secret
      that two chunks split is found when each event between them, such as a heartbeat or
      another step's output, is in the pass that projects the second chunk, or is at or
      below `runs.projected_sequence` as that pass begins, so that no event before it is
      still missing. Otherwise the second chunk starts a new text, so no two pieces that
      were not printed together are read as one secret, and the secret is not found;
    * the data of each event other than `dev.qory.run.log`, whose output is in the log
      chunks, as `event_text/1` writes it, in the same pass;
    * a dispatch's machine log, when Qory Apiary stores it;
    * a dispatch's release reason, when the release is stored.

  **What is kept** (`Apiary.Runs.LeakedSecret`): where each secret is, never the secret. At
  most #{1_000} rows for a run's output and events, and as many for each of a dispatch's
  machine log and release reason; the secrets found beyond them are counted
  (`runs.leaked_secrets_omitted`, `dispatches.machine_log_secrets_omitted`,
  `dispatches.release_reason_secrets_omitted`). The same text stored again, as a rebuild
  of the projection stores the log, adds no row and counts nothing twice. Texts stored
  before this scan existed are not scanned.
  """

  use Gettext, backend: ApiaryWeb.Gettext

  import Ecto.Query

  alias Apiary.Dispatches.Dispatch
  alias Apiary.Repo
  alias Apiary.Runs.{Event, LeakedSecret, LogChunk, Run}
  alias Apiary.SecretScan

  @cap 1_000
  @log_event "dev.qory.run.log"
  # The chunks before a pass's first chunk of a step read for the end a secret may start
  # in, and the chunks read at once for a secret's value.
  @carry_chunks 8
  @value_chunks 4

  @doc "cap/0 is the most secrets kept for a run's output and events: #{@cap}."
  @spec cap() :: pos_integer
  def cap, do: @cap

  ## Storing

  @doc """
  record_run/3 finds the secrets in `chunks`, the log chunks a pass of the projection
  stores for `run`, and in `events`, the events it folds, and keeps where they are. Called
  in the pass's transaction, under the run's projection lock.
  """
  @spec record_run(Run.t(), [map], [struct]) :: :ok
  def record_run(%Run{} = run, chunks, events) do
    times = Map.new(events, &{&1.sequence, &1.time})
    rows = output_rows(run, chunks, events, times) ++ event_rows(events)
    store_run(run, rows)
  end

  @doc """
  record_dispatch/4 finds the secrets in `text`, the machine log (`:machine_log`) or the
  release reason (`:release_reason`) of `dispatch`, stored at `at`, and keeps where they
  are. Called in the transaction that stores the text.
  """
  @spec record_dispatch(
          struct,
          :machine_log | :release_reason,
          String.t() | nil,
          DateTime.t()
        ) ::
          :ok
  def record_dispatch(%Dispatch{} = dispatch, place, text, %DateTime{} = at)
      when place in [:machine_log, :release_reason] do
    case if(is_binary(text), do: SecretScan.scan(text), else: []) do
      [] ->
        :ok

      found ->
        place = Atom.to_string(place)

        count =
          Repo.aggregate(
            from(l in LeakedSecret, where: l.dispatch_id == ^dispatch.id and l.place == ^place),
            :count
          )

        {kept, over} = Enum.split(found, max(@cap - count, 0))

        rows =
          for finding <- kept do
            value = binary_part(text, finding.offset, finding.length)

            row(dispatch, finding, value, %{
              dispatch_id: dispatch.id,
              place: place,
              at: at
            })
          end

        Repo.insert_all(LeakedSecret, rows, on_conflict: :nothing, log: false)
        omitted(dispatch, place, length(over))
    end
  end

  defp omitted(_dispatch, _place, 0), do: :ok

  defp omitted(dispatch, "machine_log", count) do
    Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
      inc: [machine_log_secrets_omitted: count]
    )

    :ok
  end

  defp omitted(dispatch, "release_reason", count) do
    Repo.update_all(from(d in Dispatch, where: d.id == ^dispatch.id),
      inc: [release_reason_secrets_omitted: count]
    )

    :ok
  end

  # The secrets in the run's output: each step's chunks, and those of no step, in sequence
  # order, each scanned after the end of the text before it that a secret may start in.
  # A secret is found once its last byte is stored, and kept where its first byte is.
  # The end is carried from the step's chunk before when each event between them is in
  # this pass, or at or below the run's projected sequence as the pass begins, so that no
  # event before it is still missing (`between?/3`). Otherwise the chunk starts a new text.
  defp output_rows(run, chunks, events, times) do
    stored = stored(run, events)

    chunks
    |> Enum.group_by(& &1.step)
    |> Enum.flat_map(fn {step, chunks} ->
      [first | _] = chunks = Enum.sort_by(chunks, & &1.sequence)

      {rows, _carry} =
        Enum.flat_map_reduce(chunks, before(run, step, first, stored), fn chunk, carried ->
          {tail, parts} =
            case carried do
              {tail, parts, previous} when is_integer(previous) ->
                if between?(stored, previous, chunk.sequence), do: {tail, parts}, else: {"", []}

              _nothing ->
                {"", []}
            end

          base = byte_size(tail)
          text = tail <> chunk.bytes
          parts = parts ++ [{chunk.sequence, base}]

          rows =
            for finding <- SecretScan.scan(text), finding.offset + finding.length > base do
              {sequence, start} = part_at(parts, finding.offset)

              %{
                kind: finding.kind,
                place: if(step, do: "step", else: "log"),
                step: step,
                source_sequence: sequence,
                offset: finding.offset - start,
                length: finding.length,
                value: binary_part(text, finding.offset, finding.length),
                at: Map.get(times, sequence) || Map.get(times, chunk.sequence, DateTime.utc_now())
              }
            end

          {tail, parts} = carry(text, parts)
          {rows, {tail, parts, chunk.sequence}}
        end)

      rows
    end)
  end

  # The end of the step's output stored before `first` that a secret in `first` may start
  # in, with the chunks it is in and the last one's sequence: the step's chunks back from
  # `first` as long as every event between two of them is stored. Read only when `first`
  # starts with a character a secret is made of, or with the `[` or `;` of a colour code
  # that the end of the chunk before cut.
  defp before(run, step, %{sequence: sequence, bytes: <<byte, _::binary>>}, stored)
       when byte in ?A..?Z or byte in ?a..?z or byte in ?0..?9 or byte in ~c"_.-[;" do
    chunks =
      Repo.all(
        from(l in LogChunk,
          where: l.run_id == ^run.id and l.sequence < ^sequence,
          where: ^same_step(step),
          order_by: [desc: l.sequence],
          limit: @carry_chunks,
          select: {l.sequence, l.bytes}
        ),
        log: false
      )

    {joined, _next} =
      Enum.reduce_while(chunks, {[], sequence}, fn {previous, _bytes} = chunk, {joined, next} ->
        if between?(stored, previous, next),
          do: {:cont, {[chunk | joined], previous}},
          else: {:halt, {joined, next}}
      end)

    {text, parts} =
      Enum.reduce(joined, {"", []}, fn {sequence, bytes}, {text, parts} ->
        {text <> bytes, parts ++ [{sequence, byte_size(text)}]}
      end)

    {tail, parts} = carry(text, parts)
    last = if joined == [], do: nil, else: joined |> List.last() |> elem(0)
    {tail, parts, last}
  end

  defp before(_run, _step, _first, _stored), do: {"", [], nil}

  # The events stored as a pass begins: every sequence up to the run's projected
  # sequence, below which none is missing, and those of the pass.
  defp stored(%Run{projected_sequence: projected}, events),
    do: {projected || 0, MapSet.new(events, & &1.sequence)}

  # Whether every event between sequences `from` and `to` is stored.
  defp between?({projected, pass}, from, to) do
    first = max(from + 1, projected + 1)
    first > to - 1 or Enum.all?(first..(to - 1)//1, &MapSet.member?(pass, &1))
  end

  defp same_step(nil), do: dynamic([l], is_nil(l.step))
  defp same_step(step), do: dynamic([l], l.step == ^step)

  # The end of `text` a secret may start in, and the chunks it is in, each with where it
  # starts in that end (below 0 for the chunk the end starts inside).
  defp carry(text, parts) do
    tail = SecretScan.carry(text)
    cut = byte_size(text) - byte_size(tail)
    parts = parts |> Enum.map(fn {sequence, start} -> {sequence, start - cut} end) |> trim()
    {tail, parts}
  end

  defp trim([_first, {_sequence, start} = second | rest]) when start <= 0,
    do: trim([second | rest])

  defp trim(parts), do: parts

  # The chunk byte `offset` of the text is in: the last that starts at or before it.
  defp part_at(parts, offset) do
    parts |> Enum.filter(fn {_sequence, start} -> start <= offset end) |> List.last()
  end

  defp event_rows(events) do
    for %Event{type: type} = event <- events,
        type != @log_event,
        text = event_text(event.data),
        finding <- SecretScan.scan(text) do
      %{
        kind: finding.kind,
        place: "event",
        step: nil,
        source_sequence: event.sequence,
        offset: finding.offset,
        length: finding.length,
        value: binary_part(text, finding.offset, finding.length),
        at: event.time
      }
    end
  end

  @doc """
  event_text/1 is the text of an event's data that is scanned, and that a secret's offset
  in an event is read in: each key and each string, at any depth, keys in sorted order,
  one per line.
  """
  @spec event_text(term) :: binary
  def event_text(data), do: data |> strings() |> Enum.join("\n")

  defp strings(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.flat_map(fn {key, value} -> [to_string(key) | strings(value)] end)
  end

  defp strings(list) when is_list(list), do: Enum.flat_map(list, &strings/1)
  defp strings(string) when is_binary(string), do: [string]
  defp strings(_other), do: []

  # The rows of `rows` not kept yet, at most what the cap leaves, with what each secret
  # belongs to; the rest counted. A secret kept already whose end a later chunk extended
  # is kept at its new length.
  defp store_run(_run, []), do: :ok

  defp store_run(%Run{} = run, rows) do
    rows = longest(rows)
    sequences = rows |> Enum.map(& &1.source_sequence) |> Enum.uniq()

    kept =
      Repo.all(
        from(l in LeakedSecret,
          where: l.run_id == ^run.id and l.source_sequence in ^sequences,
          select: {{l.source_sequence, l.offset}, {l.id, l.length}}
        ),
        log: false
      )
      |> Map.new()

    {known, new} = Enum.split_with(rows, &Map.has_key?(kept, {&1.source_sequence, &1.offset}))

    for row <- known,
        {id, length} = Map.fetch!(kept, {row.source_sequence, row.offset}),
        row.length > length do
      Repo.update_all(from(l in LeakedSecret, where: l.id == ^id),
        set: [
          kind: Atom.to_string(row.kind),
          length: row.length,
          matched_id: SecretScan.identify(row.kind, row.value, run.organisation_id)
        ]
      )
    end

    store_new(run, new)
  end

  # One row for each place a secret starts, the longest found there, in the order found:
  # a secret that one pass's chunks split is found at the end of the first chunk, cut
  # short, and again, whole, with the next.
  defp longest(rows) do
    {order, best} =
      Enum.reduce(rows, {[], %{}}, fn row, {order, best} ->
        key = {row.source_sequence, row.offset}

        case best do
          %{^key => kept} when kept.length >= row.length -> {order, best}
          %{^key => _shorter} -> {order, Map.put(best, key, row)}
          _new -> {[key | order], Map.put(best, key, row)}
        end
      end)

    order |> Enum.reverse() |> Enum.map(&Map.fetch!(best, &1))
  end

  defp store_new(_run, []), do: :ok

  defp store_new(run, new) do
    count = Repo.aggregate(from(l in LeakedSecret, where: l.run_id == ^run.id), :count)
    {kept, over} = Enum.split(new, max(@cap - count, 0))

    rows =
      for row <- kept do
        row(run, row, row.value, %{
          run_id: run.id,
          place: row.place,
          step: row.step,
          source_sequence: row.source_sequence,
          at: row.at
        })
      end

    Repo.insert_all(LeakedSecret, rows, on_conflict: :nothing, log: false)

    if over != [] do
      Repo.update_all(from(r in Run, where: r.id == ^run.id),
        inc: [leaked_secrets_omitted: length(over)]
      )
    end

    :ok
  end

  defp row(owner, finding, value, fields) do
    Map.merge(fields, %{
      id: Ecto.UUID.generate(),
      organisation_id: owner.organisation_id,
      workspace_id: owner.workspace_id,
      kind: Atom.to_string(finding.kind),
      offset: finding.offset,
      length: finding.length,
      matched_id: SecretScan.identify(finding.kind, value, owner.organisation_id),
      inserted_at: DateTime.utc_now()
    })
  end

  ## Reading

  @typedoc "A secret as the diagnostics document lists it."
  @type entry :: %{
          kind: String.t(),
          place: String.t(),
          step: pos_integer | nil,
          sequence: pos_integer | nil,
          dispatch: String.t() | nil,
          at: DateTime.t(),
          id: String.t() | nil,
          value: String.t() | nil,
          message: String.t()
        }

  @doc """
  read/3 is the secrets found in `run`'s text and in its dispatch's, `dispatch`, the
  earliest first, at most #{@cap}, and how many more were found.

  `opts`:

    * `machine_logs`, whether the reader reads machine logs (false by default): without
      it, the secrets of the machine log are left out and not counted.
    * `machine_log`, the machine log's text, for the values; nil once it cannot be read,
      as after the retention deleted it, when its secrets have no value.
    * `events`, the query of the run's events the reader reads
      (the edition's `client_reads`): a secret in an event outside it has no value.

  Each secret has its value while its text is kept: a log chunk the retention deleted,
  an event outside `events`, has none.
  """
  @spec read(Run.t(), struct | nil, keyword) :: {[entry], non_neg_integer}
  def read(%Run{} = run, dispatch, opts) do
    machine_logs? = Keyword.get(opts, :machine_logs, false)
    machine_log = Keyword.get(opts, :machine_log)

    places =
      if(machine_logs?, do: ["machine_log", "release_reason"], else: ["release_reason"])

    rows =
      Repo.all(
        from(l in LeakedSecret,
          where: l.run_id == ^run.id,
          order_by: [asc: l.at, asc: l.source_sequence, asc: l.offset]
        ),
        log: false
      ) ++ dispatch_rows(dispatch, places)

    {shown, over} =
      rows
      |> Enum.sort_by(&{DateTime.to_unix(&1.at, :microsecond), &1.place, &1.offset})
      |> Enum.split(@cap)

    omitted =
      run.leaked_secrets_omitted + length(over) +
        if(dispatch, do: dispatch.release_reason_secrets_omitted, else: 0) +
        if(dispatch && machine_logs?, do: dispatch.machine_log_secrets_omitted, else: 0)

    events = event_data(Keyword.fetch!(opts, :events), shown)

    texts = %{
      "machine_log" => machine_log,
      "release_reason" => dispatch && dispatch.release_reason
    }

    entries =
      for row <- shown do
        %{
          kind: row.kind,
          place: row.place,
          step: row.step,
          sequence: if(row.place == "event", do: row.source_sequence),
          dispatch: if(row.dispatch_id, do: dispatch.public_id),
          at: row.at,
          id: row.matched_id,
          value: value(run, row, events, texts),
          message: message(row.place)
        }
      end

    {entries, omitted}
  end

  defp dispatch_rows(nil, _places), do: []

  defp dispatch_rows(%Dispatch{id: id}, places) do
    Repo.all(
      from(l in LeakedSecret, where: l.dispatch_id == ^id and l.place in ^places),
      log: false
    )
  end

  defp event_data(events, rows) do
    sequences = for %{place: "event", source_sequence: sequence} <- rows, do: sequence

    if sequences == [] do
      %{}
    else
      Repo.all(
        from(e in events, where: e.sequence in ^sequences, select: {e.sequence, e.data}),
        log: false
      )
      |> Map.new(fn {sequence, data} -> {sequence, event_text(data)} end)
    end
  end

  defp value(_run, %{place: "event"} = row, events, _texts),
    do: events |> Map.get(row.source_sequence) |> slice(row)

  defp value(_run, %{place: place} = row, _events, texts)
       when place in ["machine_log", "release_reason"],
       do: texts |> Map.get(place) |> slice(row)

  defp value(run, row, _events, _texts), do: run |> chunk_text(row, nil, "") |> slice(row)

  # The step's output from the chunk the secret starts in, as far as its end, read a few
  # chunks at a time; nil once the chunk is gone.
  defp chunk_text(run, row, after_sequence, text) do
    from_sequence =
      if after_sequence,
        do: dynamic([l], l.sequence > ^after_sequence),
        else: dynamic([l], l.sequence == ^row.source_sequence)

    chunks =
      Repo.all(
        from(l in LogChunk,
          where: l.run_id == ^run.id and l.sequence >= ^row.source_sequence,
          where: ^from_sequence,
          where: ^same_step(row.step),
          order_by: [asc: l.sequence],
          limit: @value_chunks,
          select: {l.sequence, l.bytes}
        ),
        log: false
      )

    cond do
      chunks == [] and is_nil(after_sequence) ->
        nil

      chunks == [] ->
        text

      true ->
        text = text <> IO.iodata_to_binary(Enum.map(chunks, &elem(&1, 1)))
        {last, _bytes} = List.last(chunks)

        if byte_size(text) >= row.offset + row.length,
          do: text,
          else: chunk_text(run, row, last, text)
    end
  end

  defp slice(text, %{offset: offset, length: length})
       when is_binary(text) and byte_size(text) >= offset + length,
       do: binary_part(text, offset, length)

  defp slice(_text, _row), do: nil

  @doc "message/1 is what the document says of a secret found at `place`."
  @spec message(String.t()) :: String.t()
  def message(place) when place in ["step", "log"],
    do: gettext("This secret is compromised: it was printed into the run's log. Replace it.")

  def message("event"),
    do:
      gettext("This secret is compromised: it was printed into an event of the run. Replace it.")

  def message("machine_log"),
    do: gettext("This secret is compromised: it was printed into the machine log. Replace it.")

  def message("release_reason"),
    do:
      gettext(
        "This secret is compromised: it was printed into the reason the machine was released. Replace it."
      )
end
