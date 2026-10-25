defmodule Apiary.Adapters.Feed do
  @moduledoc false

  # An adapter's change feed (the integration contract's `changes.schema.json`): one
  # append-only log per adapter, which the adapter reads back after a cursor, in order
  # (`GET /v1/work-items/changes`, `ApiaryWeb.Contract.ChangesController`). It holds the
  # work items taken in from the adapter's items, the link state of the adapter's
  # collections, the grants of the adapter's connections, and the adapter's interval, and
  # nothing of any other adapter.
  #
  # ## Writing: `append/2`
  #
  # `append(adapter, entry)` writes one entry to the feed of `adapter`, inside the
  # caller's transaction, the one that makes the change the entry tells of, and answers
  # `{:ok, seq}`, the entry's number. The entry is a map with atom keys, exactly one of:
  #
  #   * `%{kind: "work_item", work_item_id: id, ref: ref, status: status, url: url}`: a
  #     work item taken in from one of the adapter's items (`status` `"taken_in"`), or
  #     undone (`"undone"`). `id` is the work item's public id, `wi_` and 1 to 64 of
  #     `A-Z a-z 0-9 _ -`; `ref` the item's ref as the adapter sent it; `url` the work
  #     item's page, at most 2,048 characters of RFC 3986, `https://` and a host, or
  #     `http://` to a loopback address alone (`localhost`, `127.0.0.1` or `[::1]`, with
  #     a port or not), then nothing or a path (`work_item_url?/1`).
  #   * `%{kind: "collection", collection_ref: ref, status: status}`: one of the adapter's
  #     collections linked (`"linked"`, `Apiary.Adapters.Collection.linked?/1`), or
  #     unlinked (`"unlinked"`). `ref`
  #     is the collection's ref as the adapter listed it.
  #   * `%{kind: "sync", interval: seconds | nil}`: the adapter's interval, 60 to 86,400
  #     seconds, or nil for the default the adapter declared.
  #   * `%{kind: "grant", connection_id: id, grant_ref: ref, status: status}`: a grant of
  #     one of the adapter's connections linked (`"linked"`, a report accepted,
  #     `Apiary.Adapters.Grants.report/2`), or unlinked (`"unlinked"`, its connection
  #     ended, or the adapter ended the grant with a grant end,
  #     `Apiary.Adapters.Grants.end_grant/2`). `id` is the connection's public id,
  #     `ac_…`; `ref` the grant's ref as the adapter reported it.
  #
  # A ref is 1 to 200 characters (code points) of valid UTF-8, with no NUL, which the
  # store cannot hold. Anything else raises `ArgumentError`: outside a transaction, for a
  # node that is not an adapter, for a member missing, extra or out of its range. That is
  # a mistake in the caller, never input, and the message carries no value of the entry.
  #
  # The contract asks the writers, not the feed, for what the entries mean together:
  # whenever a linked collection ends, by any path, its writer appends an `unlinked`
  # entry for it, so that the last entry per `collection_ref`, read from the start, is the
  # link state of the live collection with that ref, or `unlinked` when none is live; and
  # the last entry per `work_item_id` is that work item's status; and the last `grant`
  # entry per `connection_id` and `grant_ref` whether Qory Apiary holds that grant. The
  # feed keeps the entries in the order they commit, which is what lets a reader rely on
  # the last one.
  #
  # The number is taken from the adapter's row of `adapter_feed_counters` by an upsert
  # that adds one, inside the caller's transaction; the row stays locked until that
  # transaction ends, so a second entry of the adapter waits for the first, and an entry
  # rolled back gives its number back. Entries become visible in the order of their
  # numbers, with no gap, so a reader that moves its cursor past a number never misses an
  # entry that commits later.
  #
  # ## Reading: `read/4`
  #
  # `read(adapter, after, revision, opts)` answers the entries after the number `after`
  # (0 for the start), at most `page_size/0` of them, in order, each as the contract
  # writes it (`Jason.OrderedObject`, its kind first), with the number the page ends at,
  # the answer's cursor. An entry of a kind newer than `revision`, the contract revision
  # the adapter named, is left out, and the page still ends past it
  # (`definitions.schema.json`), so a replay from the start stays in step.
  # `{:error, :stale}` when `after` is past the last entry the feed holds: a cursor this
  # feed never gave.
  #
  # A cursor is `c_` and the number in decimal, at least eight digits (`cursor/1`), opaque
  # to the adapter; `parse_cursor/1` reads one back, only as `cursor/1` writes it.

  import Ecto.Query, only: [from: 2]

  alias Apiary.Adapters.{Connection, Wire}
  alias Apiary.Nodes.Node
  alias Apiary.Repo

  # The entries a page holds at most.
  @page_size 100
  # The contract revision that defines each kind: an adapter that names an earlier one is
  # not sent it.
  @kind_revision %{"work_item" => 1, "collection" => 1, "sync" => 1, "grant" => 1}
  @work_item_id ~r/\Awi_[A-Za-z0-9_-]{1,64}\z/
  @cursor ~r/\Ac_([0-9]{8,18})\z/
  @max_ref 200
  # A work item's url, as the contract's pattern has it: https and a host, or http to a
  # loopback address, with a port or not; then nothing, or a path.
  @work_item_url ~r{\A(https://[^/?#@\s]+|http://(localhost|127\.0\.0\.1|\[::1\])(:[0-9]+)?)(/\S*)?\z}
  # RFC 3986's characters: unreserved, reserved, and `%` of a percent-encoding.
  @uri_characters ~r{\A[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+\z}
  # A `%` that does not start a percent-encoding.
  @bare_percent ~r/%(?![0-9A-Fa-f]{2})/
  @max_url 2048

  @typedoc "An entry, as `append/2` takes it."
  @type entry ::
          %{
            kind: String.t(),
            work_item_id: String.t(),
            ref: String.t(),
            status: String.t(),
            url: String.t()
          }
          | %{kind: String.t(), collection_ref: String.t(), status: String.t()}
          | %{kind: String.t(), interval: pos_integer | nil}
          | %{
              kind: String.t(),
              connection_id: String.t(),
              grant_ref: String.t(),
              status: String.t()
            }

  @doc false
  @spec append(Node.t(), entry) :: {:ok, pos_integer}
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

  # The page of `adapter`'s feed after the number `after_seq`, for an adapter of the
  # contract revision `revision`: `{:ok, %{seq: seq, changes: changes}}`, `seq` the number
  # the page ends at (`after_seq` when it holds nothing), `changes` the entries the
  # revision defines, each as the contract writes it; or `{:error, :stale}` for an
  # `after_seq` past the feed's last entry. `opts[:limit]`, `page_size/0` unless given, is
  # the most it reads.
  @doc false
  @spec read(Node.t(), non_neg_integer, pos_integer, keyword) ::
          {:ok, %{seq: non_neg_integer, changes: [Jason.OrderedObject.t()]}}
          | {:error, :stale}
  def read(%Node{kind: :adapter, id: id}, after_seq, revision, opts \\ [])
      when is_integer(after_seq) and after_seq >= 0 and is_integer(revision) do
    limit = Keyword.get(opts, :limit, @page_size)

    if after_seq > last_seq(id) do
      {:error, :stale}
    else
      rows =
        Repo.all(
          from(f in "adapter_feed",
            where: f.adapter_id == type(^id, :binary_id) and f.seq > ^after_seq,
            order_by: [asc: f.seq],
            limit: ^limit,
            select: %{seq: f.seq, kind: f.kind, data: f.data}
          )
        )

      seq = rows |> List.last(%{seq: after_seq}) |> Map.fetch!(:seq)

      changes =
        for %{kind: kind, data: data} <- rows,
            Map.fetch!(@kind_revision, kind) <= revision,
            do: change(kind, data)

      {:ok, %{seq: seq, changes: changes}}
    end
  end

  # The most entries a page holds.
  @doc false
  @spec page_size() :: pos_integer
  def page_size, do: @page_size

  # The cursor of the number `seq`: `c_` and at least eight decimal digits.
  @doc false
  @spec cursor(non_neg_integer) :: String.t()
  def cursor(seq) when is_integer(seq) and seq >= 0,
    do: "c_" <> String.pad_leading(Integer.to_string(seq), 8, "0")

  # The number of a cursor as `cursor/1` writes it, `{:ok, seq}`; `:error` for anything
  # else, a number written with more leading zeros than `cursor/1` gives it included.
  @doc false
  @spec parse_cursor(term) :: {:ok, non_neg_integer} | :error
  def parse_cursor(value) when is_binary(value) do
    with [_, digits] <- Regex.run(@cursor, value),
         seq = String.to_integer(digits),
         true <- cursor(seq) == value do
      {:ok, seq}
    else
      _ -> :error
    end
  end

  def parse_cursor(_value), do: :error

  # The last number the feed of the adapter `id` has given, as committed: 0 for none.
  defp last_seq(id) do
    Repo.one(
      from(c in "adapter_feed_counters",
        where: c.adapter_id == type(^id, :binary_id),
        select: c.last_seq
      )
    ) || 0
  end

  # An entry as the contract writes it, its kind first, its members in the contract's
  # order.
  defp change("work_item", data),
    do: ordered("work_item", data, ~w(work_item_id ref status url))

  defp change("collection", data), do: ordered("collection", data, ~w(collection_ref status))
  defp change("sync", data), do: ordered("sync", data, ~w(interval))

  defp change("grant", data),
    do: ordered("grant", data, ~w(connection_id grant_ref status))

  defp ordered(kind, data, members) do
    Jason.OrderedObject.new([{"kind", kind} | Enum.map(members, &{&1, Map.fetch!(data, &1)})])
  end

  # The entry's kind and its other members, as the feed stores them, string keys.
  defp shape!(%{kind: "work_item", work_item_id: id, ref: ref, status: status, url: url} = e)
       when map_size(e) == 5 do
    unless is_binary(id) and Regex.match?(@work_item_id, id) do
      raise ArgumentError, "a work_item entry's work_item_id is wi_ and 1 to 64 of A-Za-z0-9_-"
    end

    ref!(ref, "a work_item entry's ref")
    status!(status, ~w(taken_in undone), "a work_item entry's status is taken_in or undone")

    unless work_item_url?(url) do
      raise ArgumentError,
            "a work_item entry's url is https, or http to a loopback address, at most 2048 characters"
    end

    {"work_item", %{"work_item_id" => id, "ref" => ref, "status" => status, "url" => url}}
  end

  defp shape!(%{kind: "collection", collection_ref: ref, status: status} = entry)
       when map_size(entry) == 3 do
    ref!(ref, "a collection entry's collection_ref")
    status!(status, ~w(linked unlinked), "a collection entry's status is linked or unlinked")

    {"collection", %{"collection_ref" => ref, "status" => status}}
  end

  defp shape!(%{kind: "sync", interval: interval} = entry) when map_size(entry) == 2 do
    unless is_nil(interval) or (is_integer(interval) and interval in Wire.interval_range()) do
      raise ArgumentError, "a sync entry's interval is nil or 60 to 86400 seconds"
    end

    {"sync", %{"interval" => interval}}
  end

  defp shape!(%{kind: "grant", connection_id: id, grant_ref: ref, status: status} = entry)
       when map_size(entry) == 4 do
    unless Connection.public_id?(id) do
      raise ArgumentError, "a grant entry's connection_id is a connection's public id"
    end

    ref!(ref, "a grant entry's grant_ref")
    status!(status, ~w(linked unlinked), "a grant entry's status is linked or unlinked")

    {"grant", %{"connection_id" => id, "grant_ref" => ref, "status" => status}}
  end

  defp shape!(entry) do
    kind = Map.get(entry, :kind)
    kind = if kind in Map.keys(@kind_revision), do: kind, else: "a kind it does not know"

    raise ArgumentError,
          "not an entry this feed writes (#{kind}), or not with its kind's members"
  end

  defp ref!(ref, what) do
    unless is_binary(ref) and String.valid?(ref) and ref != "" and
             length(String.to_charlist(ref)) <= @max_ref and not String.contains?(ref, <<0>>) do
      raise ArgumentError, "#{what} is 1 to 200 characters of UTF-8, with no NUL"
    end
  end

  # Whether `url` is a work item's page as the contract has it (`append/2`), and one RFC
  # 3986's parser reads with that scheme, a host and a port in range.
  @doc false
  @spec work_item_url?(term) :: boolean
  def work_item_url?(url) when is_binary(url) do
    byte_size(url) <= @max_url and Regex.match?(@uri_characters, url) and
      not Regex.match?(@bare_percent, url) and Regex.match?(@work_item_url, url) and
      parses?(url)
  end

  def work_item_url?(_url), do: false

  defp parses?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, userinfo: nil, port: port}}
      when scheme in ["https", "http"] and is_binary(host) and host != "" and
             is_integer(port) and port in 1..65_535 ->
        true

      _other ->
        false
    end
  end

  defp status!(status, allowed, message) do
    unless status in allowed, do: raise(ArgumentError, message)
  end
end
