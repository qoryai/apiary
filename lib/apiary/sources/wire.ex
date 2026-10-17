defmodule Apiary.Sources.Wire do
  @moduledoc false

  # The bodies an adapter posts with the items of a collection and the comments of an item,
  # read as the integration contract has them (qoryai/integrations,
  # `contracts/integration/v1`). Pure functions: nothing here touches the database or a
  # log, nothing here puts a value it was sent in an error, and every function answers
  # `:error` for anything it does not accept, never raises on input. Each takes the raw
  # body, at most 1 MiB, or the map `Apiary.Adapters.Wire.decode/1` made of it.
  #
  # `items/1` reads the body of `POST /v1/source-items` (`source-items.schema.json`):
  # exactly `version` (1), `time`, `collection_ref` and `items`, and `listing` when given.
  # Without `listing` the body is an event, with 1 to 100 items; with it, a part of a
  # listing, with 0 to 100. Each item holds exactly `ref`, `url`, `title`, `body`,
  # `body_format`, `filed_by`, `labels`, `state`, `state_reason`, `comment_count`,
  # `created_at` and `updated_at`, and `key`, `type`, `target` and `truncated` when given.
  #
  # `comments/1` reads the body of `POST /v1/source-items/comments`
  # (`source-item-comments.schema.json`): exactly `version` (1), `time`, `item_ref` and
  # `comments`, and `complete` when given, which holds exactly `since`. Without `complete`
  # the body names 1 to 100 comments; with it, 0 to 100. Each comment holds exactly `ref`,
  # `url`, `author`, `body`, `body_format`, `created_at` and `updated_at`, and `deleted`
  # (only `true`) and `truncated` when given.
  #
  # Every bound of the contract holds, and past one the body is refused: nothing is cut.
  # A count is bounded before the elements it counts are read, and an object's members
  # before they are compared. Text is counted in code points, as the contract's lengths
  # are, its size in bytes bounded first, and none of it may hold U+0000, which the
  # database cannot keep. Times, URLs, a target and a listing part are read as
  # `Apiary.Adapters.Wire` reads them for a listing of collections, which holds two of
  # them tighter than the contract: a part numbered past
  # `Apiary.Adapters.Wire.max_part/0` is refused, and a URL may hold only RFC 3986's
  # characters, every `%` followed by two hexadecimal digits, no user information, and a
  # port from 1 to 65,535 when one is written.
  #
  # An entry whose ref the body names twice is taken once: the one with the later
  # `updated_at`, and of two with the same `updated_at` the one named last, as the newer
  # `updated_at` wins when it is stored. The entries keep the order they were named in.

  alias Apiary.Adapters.Wire

  @max_bytes 1024 * 1024
  @max_entries 100
  @max_ref 200
  @max_key 64
  @max_title 1024
  @max_body 65_536
  @max_name 100
  @max_labels 100
  @max_label 100
  @max_state_reason 64
  @max_word 40

  @items_required ~w(collection_ref items time version)
  @items_optional ~w(listing)
  @item_required ~w(body body_format comment_count created_at filed_by labels ref state
                    state_reason title updated_at url)
  @item_optional ~w(key target truncated type)
  @item_truncated ["title", "body", "filed_by.name", "labels"]

  @comments_required ~w(comments item_ref time version)
  @comments_optional ~w(complete)
  @comment_required ~w(author body body_format created_at ref updated_at url)
  @comment_optional ~w(deleted truncated)
  @comment_truncated ["body", "author.name"]

  @person_keys ~w(kind name)
  @person_kinds ~w(person automation)
  @states ~w(open closed)

  # `$defs/type` and `$defs/body_format`, anchored at both ends of the string.
  @type_pattern ~r/\A[a-z][a-z ]{0,39}\z/
  @body_format_pattern ~r/\A[a-z][a-z0-9_-]{0,39}\z/

  @type person :: %{name: String.t(), kind: String.t()}

  @type item :: %{
          ref: String.t(),
          url: String.t(),
          key: String.t() | nil,
          type: String.t() | nil,
          title: String.t(),
          body: String.t(),
          body_format: String.t(),
          filed_by: person,
          labels: [String.t()],
          state: String.t(),
          state_reason: String.t() | nil,
          comment_count: non_neg_integer,
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          target: Wire.target() | nil,
          truncated: [String.t()]
        }

  @type items :: %{
          time: DateTime.t(),
          collection_ref: String.t(),
          items: [item],
          listing:
            %{id: String.t(), part: pos_integer, started_at: DateTime.t(), complete: boolean}
            | nil
        }

  @type comment :: %{
          ref: String.t(),
          url: String.t(),
          author: person,
          body: String.t(),
          body_format: String.t(),
          created_at: DateTime.t(),
          updated_at: DateTime.t(),
          deleted: boolean,
          truncated: [String.t()]
        }

  @type comments :: %{
          time: DateTime.t(),
          item_ref: String.t(),
          comments: [comment],
          complete: %{since: DateTime.t()} | nil
        }

  # The largest body read, in bytes.
  @doc false
  @spec max_bytes() :: pos_integer
  def max_bytes, do: @max_bytes

  # The body of `POST /v1/source-items`: `{:ok, items}` or `:error`.
  @doc false
  @spec items(term) :: {:ok, items} | :error
  def items(raw) when is_binary(raw), do: with({:ok, body} <- decode(raw), do: items(body))

  def items(%{} = body) do
    with true <- members?(body, @items_required, @items_optional),
         true <- body["version"] === 1,
         {:ok, time} <- Wire.time(body["time"]),
         true <- Wire.text?(body["collection_ref"], 1, @max_ref),
         {:ok, listing} <- listing(body),
         {:ok, items} <- entries(body["items"], if(listing, do: 0, else: 1), &item/1) do
      {:ok, %{time: time, collection_ref: body["collection_ref"], items: items, listing: listing}}
    else
      _ -> :error
    end
  end

  def items(_body), do: :error

  # The body of `POST /v1/source-items/comments`: `{:ok, comments}` or `:error`.
  @doc false
  @spec comments(term) :: {:ok, comments} | :error
  def comments(raw) when is_binary(raw),
    do: with({:ok, body} <- decode(raw), do: comments(body))

  def comments(%{} = body) do
    with true <- members?(body, @comments_required, @comments_optional),
         true <- body["version"] === 1,
         {:ok, time} <- Wire.time(body["time"]),
         true <- Wire.text?(body["item_ref"], 1, @max_ref),
         {:ok, complete} <- complete(body),
         {:ok, comments} <-
           entries(body["comments"], if(complete, do: 0, else: 1), &comment/1) do
      {:ok, %{time: time, item_ref: body["item_ref"], comments: comments, complete: complete}}
    else
      _ -> :error
    end
  end

  def comments(_body), do: :error

  defp decode(raw) when byte_size(raw) <= @max_bytes, do: Wire.decode(raw)
  defp decode(_raw), do: :error

  defp listing(%{"listing" => listing}) when is_map(listing) and map_size(listing) <= 4,
    do: Wire.listing_part(listing)

  defp listing(%{"listing" => _other}), do: :error
  defp listing(%{}), do: {:ok, nil}

  defp target(%{"target" => target}) when is_map(target) and map_size(target) > 2, do: :error
  defp target(item), do: Wire.target(item)

  defp complete(%{"complete" => %{} = complete}) do
    with true <- members?(complete, ["since"], []),
         {:ok, since} <- Wire.time(complete["since"]) do
      {:ok, %{since: since}}
    else
      _ -> :error
    end
  end

  defp complete(%{"complete" => _other}), do: :error
  defp complete(%{}), do: {:ok, nil}

  # `min` to 100 entries, each read by `read`, and one per ref.
  defp entries(list, min, read) do
    if count_in?(list, min, @max_entries) do
      list
      |> Enum.reduce_while({:ok, []}, fn entry, {:ok, acc} ->
        case read.(entry) do
          {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
          :error -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, reversed} -> {:ok, one_per_ref(Enum.reverse(reversed))}
        :error -> :error
      end
    else
      :error
    end
  end

  # Of the entries that share a ref, the one with the latest `updated_at`, the last named
  # of those, at the place it was named.
  defp one_per_ref(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {entry, index}, kept ->
      Map.update(kept, entry.ref, {index, entry}, fn {_index, earlier} = previous ->
        if DateTime.before?(entry.updated_at, earlier.updated_at),
          do: previous,
          else: {index, entry}
      end)
    end)
    |> Map.values()
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
  end

  defp item(%{} = item) do
    with true <- members?(item, @item_required, @item_optional),
         true <- Wire.text?(item["ref"], 1, @max_ref),
         true <- Wire.url?(item["url"]),
         {:ok, key} <- optional(item, "key", &Wire.text?(&1, 1, @max_key)),
         {:ok, type} <- optional(item, "type", &word?(&1, @type_pattern)),
         true <- Wire.text?(item["title"], 1, @max_title),
         true <- Wire.text?(item["body"], 0, @max_body),
         true <- word?(item["body_format"], @body_format_pattern),
         {:ok, filed_by} <- person(item["filed_by"]),
         true <- labels?(item["labels"]),
         true <- item["state"] in @states,
         true <- state_reason?(item["state_reason"]),
         count when is_integer(count) and count >= 0 <- item["comment_count"],
         {:ok, created_at} <- Wire.time(item["created_at"]),
         {:ok, updated_at} <- Wire.time(item["updated_at"]),
         {:ok, target} <- target(item),
         {:ok, truncated} <- truncated(item, @item_truncated) do
      {:ok,
       %{
         ref: item["ref"],
         url: item["url"],
         key: key,
         type: type,
         title: item["title"],
         body: item["body"],
         body_format: item["body_format"],
         filed_by: filed_by,
         labels: item["labels"],
         state: item["state"],
         state_reason: item["state_reason"],
         comment_count: count,
         created_at: created_at,
         updated_at: updated_at,
         target: target,
         truncated: truncated
       }}
    else
      _ -> :error
    end
  end

  defp item(_item), do: :error

  defp comment(%{} = comment) do
    with true <- members?(comment, @comment_required, @comment_optional),
         true <- Wire.text?(comment["ref"], 1, @max_ref),
         true <- Wire.url?(comment["url"]),
         {:ok, author} <- person(comment["author"]),
         true <- Wire.text?(comment["body"], 0, @max_body),
         true <- word?(comment["body_format"], @body_format_pattern),
         {:ok, created_at} <- Wire.time(comment["created_at"]),
         {:ok, updated_at} <- Wire.time(comment["updated_at"]),
         {:ok, deleted} <- optional(comment, "deleted", &(&1 === true)),
         {:ok, truncated} <- truncated(comment, @comment_truncated) do
      {:ok,
       %{
         ref: comment["ref"],
         url: comment["url"],
         author: author,
         body: comment["body"],
         body_format: comment["body_format"],
         created_at: created_at,
         updated_at: updated_at,
         deleted: deleted == true,
         truncated: truncated
       }}
    else
      _ -> :error
    end
  end

  defp comment(_comment), do: :error

  # `$defs/person`: exactly a name of 1 to 100 code points and its kind.
  defp person(%{} = person) do
    with true <- members?(person, @person_keys, []),
         true <- Wire.text?(person["name"], 1, @max_name),
         true <- person["kind"] in @person_kinds do
      {:ok, %{name: person["name"], kind: person["kind"]}}
    else
      _ -> :error
    end
  end

  defp person(_person), do: :error

  # `$defs/labels`: at most 100, each 1 to 100 code points, none twice.
  defp labels?(labels) do
    count_in?(labels, 0, @max_labels) and Enum.all?(labels, &Wire.text?(&1, 1, @max_label)) and
      length(Enum.uniq(labels)) == length(labels)
  end

  # `$defs/state_reason`: null, or at most 64 code points.
  defp state_reason?(nil), do: true
  defp state_reason?(reason), do: Wire.text?(reason, 0, @max_state_reason)

  # The fields an adapter cut: at least one, each of `fields`, none twice.
  defp truncated(%{"truncated" => list}, fields) do
    if count_in?(list, 1, length(fields)) and Enum.all?(list, &(&1 in fields)) and
         length(Enum.uniq(list)) == length(list),
       do: {:ok, list},
       else: :error
  end

  defp truncated(%{}, _fields), do: {:ok, []}

  # A member that may be left out: `{:ok, nil}` when it is, `{:ok, value}` when `valid?`
  # holds for it, `:error` otherwise. A member written as null is not left out.
  defp optional(map, key, valid?) do
    case Map.fetch(map, key) do
      :error -> {:ok, nil}
      {:ok, value} -> if valid?.(value), do: {:ok, value}, else: :error
    end
  end

  # A word of one to 40 ASCII characters that `pattern` holds, its size bounded first.
  defp word?(value, pattern),
    do: is_binary(value) and byte_size(value) <= @max_word and Regex.match?(pattern, value)

  # Every member of `required`, and of the others only those of `optional`: the count of
  # members bounded before any is compared.
  defp members?(map, required, optional) do
    map_size(map) <= length(required) + length(optional) and
      Enum.all?(required, &Map.has_key?(map, &1)) and
      Enum.all?(Map.keys(map), &(&1 in required or &1 in optional))
  end

  # Whether `list` is a list of `min` to `max` elements, counting no further than `max + 1`.
  defp count_in?(list, min, max) when is_list(list),
    do: length(Enum.take(list, max + 1)) in min..max//1

  defp count_in?(_list, _min, _max), do: false
end
