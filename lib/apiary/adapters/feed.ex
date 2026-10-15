defmodule Apiary.Adapters.Feed do
  @moduledoc false

  # An adapter's change feed (the integration contract's `changes.schema.json`): one
  # append-only log per adapter, read back by the adapter after a cursor, in order. Its
  # entries are the work items taken in from the adapter's items, the link state of the
  # adapter's collections, and the adapter's interval:
  #
  #   * `%{kind: "work_item", work_item_id: "wi_…", ref: ref, status: "taken_in" | "undone",
  #     url: url}`;
  #   * `%{kind: "collection", collection_ref: ref, status: "linked" | "unlinked"}`;
  #   * `%{kind: "sync", interval: seconds | nil}`, nil for the adapter's declared default.
  #
  # `append/2` writes one, numbered `seq`, from 1 per adapter and never twice, in the
  # table `adapter_feed`. The number is taken from the adapter's row of
  # `adapter_feed_counters` by an upsert that adds one, inside the transaction that writes
  # the change the entry tells of; the row stays locked until that transaction ends, so a
  # second entry of the adapter waits for the first and an entry rolled back gives its
  # number back. Entries become visible in the order of their numbers, so a reader that
  # moves its cursor past a number never misses an entry that commits later.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Nodes.Node
  alias Apiary.Repo

  @statuses %{"work_item" => ~w(taken_in undone), "collection" => ~w(linked unlinked)}
  @min_interval 60
  @max_interval 86_400

  # Appends `entry` to the feed of `adapter`, inside the caller's transaction: `{:ok,
  # seq}`, its number. Raises `ArgumentError` outside a transaction, for a node that is not
  # an adapter, and for an entry that is none of the shapes above: a mistake in the caller,
  # never input.
  @doc false
  @spec append(Node.t(), map) :: {:ok, pos_integer}
  def append(%Node{kind: :adapter, id: id, organisation_id: organisation_id}, %{} = entry)
      when is_binary(id) and is_binary(organisation_id) do
    unless Repo.in_transaction?() do
      raise ArgumentError,
            "Apiary.Adapters.Feed.append/2 writes inside the transaction of the change it tells of"
    end

    {kind, data} = shape!(entry)
    adapter_id = Ecto.UUID.dump!(id)
    organisation_id = Ecto.UUID.dump!(organisation_id)

    {1, [%{last_seq: seq}]} =
      Repo.insert_all(
        "adapter_feed_counters",
        [%{adapter_id: adapter_id, organisation_id: organisation_id, last_seq: 1}],
        on_conflict: from(c in "adapter_feed_counters", update: [inc: [last_seq: 1]]),
        conflict_target: [:adapter_id],
        returning: [:last_seq]
      )

    {1, _rows} =
      Repo.insert_all("adapter_feed", [
        %{
          id: Ecto.UUID.bingenerate(),
          organisation_id: organisation_id,
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

  # The entry's kind and its other members, as the feed stores them, string keys.
  defp shape!(%{kind: "sync", interval: interval} = entry)
       when map_size(entry) == 2 and
              (is_nil(interval) or
                 (is_integer(interval) and interval >= @min_interval and
                    interval <= @max_interval)),
       do: {"sync", %{"interval" => interval}}

  defp shape!(%{kind: "collection", collection_ref: ref, status: status} = entry)
       when map_size(entry) == 3 and is_binary(ref) do
    status!("collection", status)
    {"collection", %{"collection_ref" => ref, "status" => status}}
  end

  defp shape!(
         %{kind: "work_item", work_item_id: work_item_id, ref: ref, status: status, url: url} =
           entry
       )
       when map_size(entry) == 5 and is_binary(work_item_id) and is_binary(ref) and
              is_binary(url) do
    status!("work_item", status)

    {"work_item",
     %{"work_item_id" => work_item_id, "ref" => ref, "status" => status, "url" => url}}
  end

  defp shape!(entry) do
    raise ArgumentError, "not an entry of the change feed: #{inspect(Map.get(entry, :kind))}"
  end

  defp status!(kind, status) do
    unless status in Map.fetch!(@statuses, kind) do
      raise ArgumentError, "a #{kind} entry's status is not #{inspect(status)}"
    end
  end
end
