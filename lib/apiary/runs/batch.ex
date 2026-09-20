defmodule Apiary.Runs.Batch do
  @moduledoc """
  A delivery's body read as a batch: a non-empty JSON array of events of one run.

  Only the envelope is checked, what the receiver needs to key, order and store
  an event: `id` and `subject` (UUIDs), `type` (in the `ai.qory.` namespace),
  `sequence` (ten digits), `source` (`urn:qory:run:<subject>`), `time` (RFC 3339)
  and `data` (an object). A type this release does not know is kept; `data` is
  not validated against its type's schema and is stored as received. Anything
  else is `:error`, which says nothing about what was wrong.

  Pure: nothing here touches the database or logs.
  """

  @enforce_keys [:subject, :events]
  defstruct [:subject, :events]

  @uuid ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/
  @sequence ~r/\A[0-9]{10}\z/
  @type_prefix "ai.qory."
  @source_prefix "urn:qory:run:"
  @heartbeat "ai.qory.run.heartbeat"

  @doc "Parses the raw body of a delivery."
  def parse(body) when is_binary(body) do
    with {:ok, [_ | _] = items} <- Jason.decode(body),
         {:ok, [%{subject: subject} | _] = events} <- events(items, []),
         true <- Enum.all?(events, &(&1.subject == subject)) do
      {:ok, %__MODULE__{subject: subject, events: events}}
    else
      _ -> :error
    end
  end

  def parse(_body), do: :error

  @doc "The latest `time` of the batch's heartbeats, or nil when it holds none."
  def last_heartbeat(%__MODULE__{events: events}) do
    events
    |> Enum.filter(&(&1.type == @heartbeat))
    |> Enum.map(& &1.time)
    |> Enum.max(DateTime, fn -> nil end)
  end

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
         true <- storable?(type),
         {:ok, time} <- time(time) do
      {:ok,
       %{
         event_id: id,
         subject: subject,
         type: type,
         sequence: String.to_integer(sequence),
         time: time,
         data: storable(data)
       }}
    else
      _ -> :error
    end
  end

  defp event(_item), do: :error

  defp time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, %DateTime{microsecond: {microsecond, _precision}} = time, _offset} ->
        {:ok, %{time | microsecond: {microsecond, 6}}}

      _ ->
        :error
    end
  end

  # Postgres holds no NUL in text or in jsonb. A type with one is no type; in
  # `data` it is replaced with U+FFFD, the one place an event is not stored
  # exactly as received.
  defp storable?(text), do: not String.contains?(text, <<0>>)

  defp storable(%{} = map) do
    Map.new(map, fn {key, value} -> {storable(key), storable(value)} end)
  end

  defp storable(list) when is_list(list), do: Enum.map(list, &storable/1)
  defp storable(text) when is_binary(text), do: String.replace(text, <<0>>, "�")
  defp storable(other), do: other
end
