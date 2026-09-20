defmodule Apiary.Runs.Batch do
  @moduledoc """
  A delivery's body read as a batch: a non-empty JSON array of events of one run.

  Only the envelope is checked, what the receiver needs to key, order and store
  an event: `id` and `subject` (UUIDs), `type` (in the `ai.qory.` namespace),
  `sequence` (ten digits, from `0000000001`), `source` (`urn:qory:run:<subject>`),
  `time` (RFC 3339, from 1970 to 9999) and `data` (an object). A type this
  release does not know is kept; `data` is not validated against its type's
  schema and is stored as received. Anything else is `:error`, which says
  nothing about what was wrong.

  The limits are what the tables can hold, so that nothing that parses fails to
  store: at most `max_events/0` events (the contract cuts a batch at a hundred),
  `data` nested no deeper than `max_depth/0`, a `time` Postgres has a timestamp
  for, no NUL in a `type`.

  Pure: nothing here touches the database or logs.
  """

  @enforce_keys [:subject, :events]
  defstruct [:subject, :events]

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @sequence ~r/\A[0-9]{10}\z/
  @type_prefix "ai.qory."
  @source_prefix "urn:qory:run:"
  @max_events 1000
  @max_depth 64
  @years 1970..9999

  @doc "The most events a batch may hold."
  def max_events, do: @max_events

  @doc "The deepest `data` may nest, the object itself being level one."
  def max_depth, do: @max_depth

  @doc "Parses the raw body of a delivery."
  def parse(body) when is_binary(body) do
    with {:ok, [_ | _] = items} <- Jason.decode(body),
         true <- length(items) <= @max_events,
         {:ok, [%{subject: subject} | _] = events} <- events(items, []),
         true <- Enum.all?(events, &(&1.subject == subject)) do
      {:ok, %__MODULE__{subject: subject, events: events}}
    else
      _ -> :error
    end
  end

  def parse(_body), do: :error

  defp events([], acc), do: {:ok, Enum.reverse(acc)}

  defp events([item | rest], acc) do
    case event(item) do
      {:ok, event} -> events(rest, [event | acc])
      :error -> :error
    end
  end

  defp event(%{
         "id" => id,
         "subject" => subject,
         "type" => @type_prefix <> _ = type,
         "sequence" => sequence,
         "source" => @source_prefix <> source_subject,
         "time" => time,
         "data" => %{} = data
       })
       when is_binary(id) and is_binary(subject) and is_binary(sequence) and is_binary(time) and
              source_subject == subject do
    with true <- Regex.match?(@uuid, id),
         true <- Regex.match?(@uuid, subject),
         true <- Regex.match?(@sequence, sequence),
         sequence = String.to_integer(sequence),
         true <- sequence >= 1,
         true <- storable?(type),
         {:ok, time} <- time(time),
         {:ok, data} <- data(data) do
      {:ok,
       %{
         event_id: id,
         subject: subject,
         type: type,
         sequence: sequence,
         time: time,
         data: data
       }}
    else
      _ -> :error
    end
  end

  defp event(_item), do: :error

  defp time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{year: year, microsecond: {microsecond, _precision}} = time, _offset}
      when year in @years ->
        {:ok, %{time | microsecond: {microsecond, 6}}}

      _ ->
        :error
    end
  end

  # Postgres holds no NUL in text or in jsonb. A type with one is no type; in
  # `data` it is replaced with U+FFFD, the one place an event is not stored
  # exactly as received.
  defp storable?(text), do: not String.contains?(text, <<0>>)

  defp data(data) do
    {:ok, storable(data, 1)}
  catch
    :too_deep -> :error
  end

  defp storable(nested, depth) when (is_map(nested) or is_list(nested)) and depth > @max_depth,
    do: throw(:too_deep)

  defp storable(%{} = map, depth) do
    Map.new(map, fn {key, value} -> {storable(key, depth), storable(value, depth + 1)} end)
  end

  defp storable(list, depth) when is_list(list), do: Enum.map(list, &storable(&1, depth + 1))
  defp storable(text, _depth) when is_binary(text), do: String.replace(text, <<0>>, "\uFFFD")
  defp storable(other, _depth), do: other
end
