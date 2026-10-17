defmodule Apiary.Adapters.Feed do
  @moduledoc false

  # An adapter's change feed (the integration contract's `changes.schema.json`): one
  # append-only log per adapter, which the adapter reads back after a cursor, in order.
  # The contract's entries are the work items taken in from the adapter's items, the link
  # state of its collections, and its interval; the one written here is the interval:
  #
  #   * `%{kind: "sync", interval: seconds | nil}`, nil for the adapter's declared
  #     default. The contract appends one at the adapter's first declaration and one
  #     whenever a person changes the interval (`Apiary.Adapters`).
  #
  # `append/2` writes one, numbered `seq`, from 1 per adapter and never twice, in the
  # table `adapter_feed`. The number is taken from the adapter's row of
  # `adapter_feed_counters` by an upsert that adds one, inside the transaction that writes
  # the change the entry tells of; the row stays locked until that transaction ends, so a
  # second entry of the adapter waits for the first and an entry rolled back gives its
  # number back. Entries become visible in the order of their numbers, so a reader that
  # moves its cursor past a number never misses an entry that commits later.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Adapters.Wire
  alias Apiary.Nodes.Node
  alias Apiary.Repo

  # Appends `entry` to the feed of `adapter`, inside the caller's transaction: `{:ok,
  # seq}`, its number. Raises `ArgumentError` outside a transaction, for a node that is not
  # an adapter, and for an entry that is not of the shape above: a mistake in the caller,
  # never input.
  @doc false
  @spec append(Node.t(), map) :: {:ok, pos_integer}
  def append(%Node{kind: :adapter, id: id, organisation_id: nil}, %{} = entry)
      when is_binary(id) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "Apiary.Adapters.Feed.append/2 writes inside the transaction of the change it tells of"
    end

    {kind, data} = shape!(entry)
    adapter_id = Ecto.UUID.dump!(id)

    {1, [%{last_seq: seq}]} =
      Repo.insert_all(
        "adapter_feed_counters",
        [%{adapter_id: adapter_id, last_seq: 1}],
        on_conflict: from(c in "adapter_feed_counters", update: [inc: [last_seq: 1]]),
        conflict_target: [:adapter_id],
        returning: [:last_seq]
      )

    {1, _rows} =
      Repo.insert_all("adapter_feed", [
        %{
          id: Ecto.UUID.bingenerate(),
          adapter_id: adapter_id,
          seq: seq,
          kind: kind,
          data: data,
          inserted_at: DateTime.utc_now()
        }
      ])

    {:ok, seq}
  end

  def append(_node, _entry) do
    raise ArgumentError, "Apiary.Adapters.Feed.append/2 takes an adapter and an entry"
  end

  # The entries of `adapter`'s feed, in order: `%{seq: seq, kind: kind, data: data}`, the
  # data with string keys, as stored.
  @doc false
  @spec entries(Node.t()) :: [%{seq: pos_integer, kind: String.t(), data: map}]
  def entries(%Node{kind: :adapter, id: id}) do
    Repo.all(
      from(f in "adapter_feed",
        where: f.adapter_id == type(^id, :binary_id),
        order_by: [asc: f.seq],
        select: %{seq: f.seq, kind: f.kind, data: f.data}
      )
    )
  end

  # The entry's kind and its other members, as the feed stores them, string keys.
  defp shape!(%{kind: "sync", interval: interval} = entry) when map_size(entry) == 2 do
    unless is_nil(interval) or (is_integer(interval) and interval in Wire.interval_range()) do
      raise ArgumentError, "a sync entry's interval is nil or 60 to 86400 seconds"
    end

    {"sync", %{"interval" => interval}}
  end

  # A collection that stopped being linked: `%{kind: "collection", collection_ref: ref,
  # status: "unlinked"}`, written whenever a linked collection ends or loses its workspace
  # (`Apiary.Adapters.Collections`).
  defp shape!(%{kind: "collection", collection_ref: ref, status: "unlinked"} = entry)
       when map_size(entry) == 3 and is_binary(ref) do
    {"collection", %{"collection_ref" => ref, "status" => "unlinked"}}
  end

  defp shape!(entry) do
    raise ArgumentError, "not an entry this feed writes: #{inspect(Map.get(entry, :kind))}"
  end
end
