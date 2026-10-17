defmodule Apiary.Adapters.Wire do
  @moduledoc false

  # The bodies an adapter (a node of kind `adapter`) posts, read as the integration
  # contract has them (qoryai/integrations, `contracts/integration/v1`). Pure functions:
  # nothing here touches the database or a log, and nothing here puts a value it was sent
  # in an error. Every function answers `:error` for anything it does not accept, never
  # raises on input.
  #
  # `decode/1` reads a raw body strictly: a JSON object, with no member twice in it or in
  # any object inside it, which a parser that keeps the last of them cannot tell
  # (`definitions.schema.json`: "no object repeats a member, at any depth"). A number
  # written with a fraction or an exponent decodes as a float, which no integer field
  # accepts, so `900.0` and `9e2` are refused where an integer is due.
  #
  # `time/1` reads a time as the contract writes it (`$defs/time`): RFC 3339 in UTC with
  # whole seconds, `2026-10-15T12:00:00Z`, and nothing else.
  #
  # `url?/1` holds a URL to the contract's `$defs/url` (`https://`, at most 2,048
  # characters, an RFC 3986 URI) and to what the instance stores and sends a person to
  # (`Apiary.Nodes.Node.connect_url_changeset/2`): only RFC 3986's characters, every `%`
  # followed by two hexadecimal digits, a host, a port from 1 to 65,535 when one is
  # written, and no user information.
  #
  # `declaration/1` reads the body of `POST /v1/adapter` (`adapter.schema.json`): exactly
  # `version` (1), `time`, `connect_url` and `sync`, which holds exactly
  # `default_interval` and `minimum_interval`, integers from 60 to 86,400, the minimum at
  # most the default, and `sends_changes`, a boolean.
  #
  # `listing/1` reads the body of `POST /v1/source-collections`
  # (`source-collections.schema.json`): exactly `version` (1), `time`, `connection_id`
  # (`ac_` and sixteen characters), `collections`, at most 100, each exactly `ref`,
  # `url` and `title`, and `target` when given, which holds exactly `system` and `path`;
  # and `listing`, exactly `id`, `part`, `started_at` and `complete`. A ref named twice in
  # one part is taken as the last time it is named.
  #
  # `source_disconnect/1` reads the body of `POST /v1/sources/disconnect`
  # (`sources-disconnect.schema.json`): exactly `version` (1), `time` and
  # `collection_ref`.
  #
  # Their text is counted in code points, as the contract's lengths are, and none of it
  # may hold U+0000, which the database cannot keep. A part numbered past `max_part/0` is
  # refused: the parts of a listing are kept until it completes.

  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/
  # RFC 3986's characters: unreserved, reserved, and `%` of a percent-encoding.
  @uri_characters ~r{\A[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+\z}
  # A `%` that does not start a percent-encoding.
  @bare_percent ~r/%(?![0-9A-Fa-f]{2})/
  # `https://`, an authority with no `@`, then nothing, or a path, a query or a fragment:
  # as `nodes_connect_url_check` holds a stored address.
  @no_user_information ~r{\Ahttps://[^/?#@]+(?:[/?#].*)?\z}s
  @max_url 2048
  @min_interval 60
  @max_interval 86_400
  @declaration_keys ~w(connect_url sync time version)
  @sync_keys ~w(default_interval minimum_interval sends_changes)
  @listing_body_keys ~w(collections connection_id listing time version)
  @listing_keys ~w(complete id part started_at)
  @collection_keys ~w(ref title url)
  @target_keys ~w(path system)
  @disconnect_keys ~w(collection_ref time version)
  @max_collections 100
  @max_part 10_000
  @max_title 1024
  @max_ref 200
  @system ~r/\A[a-z0-9.-]{1,253}\z/

  @type declaration :: %{
          time: DateTime.t(),
          connect_url: String.t(),
          default_interval: pos_integer,
          minimum_interval: pos_integer,
          sends_changes: boolean
        }

  @type target :: %{system: String.t(), path: String.t()}

  @type collection :: %{
          ref: String.t(),
          url: String.t(),
          title: String.t(),
          target: target | nil
        }

  @type listing :: %{
          time: DateTime.t(),
          connection_id: String.t(),
          collections: [collection],
          listing: %{
            id: String.t(),
            part: pos_integer,
            started_at: DateTime.t(),
            complete: boolean
          }
        }

  @type source_disconnect :: %{time: DateTime.t(), collection_ref: String.t()}

  # The shortest and the longest interval the contract allows, in seconds.
  @doc false
  @spec interval_range() :: Range.t()
  def interval_range, do: @min_interval..@max_interval

  # The raw body as a map of maps, or `:error` for anything that is not a JSON object, or
  # that holds a member twice at any depth.
  @doc false
  @spec decode(term) :: {:ok, map} | :error
  def decode(raw) when is_binary(raw) do
    case Jason.decode(raw, objects: :ordered_objects) do
      {:ok, %Jason.OrderedObject{} = object} -> plain(object)
      _other -> :error
    end
  end

  def decode(_raw), do: :error

  defp plain(%Jason.OrderedObject{values: values}) do
    keys = Enum.map(values, &elem(&1, 0))

    if length(Enum.uniq(keys)) == length(keys) do
      Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
        case plain(value) do
          {:ok, value} -> {:cont, {:ok, Map.put(acc, key, value)}}
          :error -> {:halt, :error}
        end
      end)
    else
      :error
    end
  end

  defp plain(list) when is_list(list) do
    list
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case plain(value) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      :error -> :error
    end
  end

  defp plain(value), do: {:ok, value}

  # A time as the contract writes it, `{:ok, time}` in UTC, or `:error`.
  @doc false
  @spec time(term) :: {:ok, DateTime.t()} | :error
  def time(value) when is_binary(value) do
    with true <- Regex.match?(@whole_seconds, value),
         {:ok, time, 0} <- DateTime.from_iso8601(value) do
      {:ok, time}
    else
      _ -> :error
    end
  end

  def time(_value), do: :error

  # Whether `value` is a URL the instance stores and sends a person to.
  @doc false
  @spec url?(term) :: boolean
  def url?(value) when is_binary(value) do
    byte_size(value) <= @max_url and String.starts_with?(value, "https://") and
      Regex.match?(@uri_characters, value) and not Regex.match?(@bare_percent, value) and
      Regex.match?(@no_user_information, value) and parses?(value)
  end

  def url?(_value), do: false

  # RFC 3986's parser agrees: https, a host, no user information, and a port in range.
  defp parses?(value) do
    case URI.new(value) do
      {:ok, %URI{scheme: "https", host: host, userinfo: nil, port: port}}
      when is_binary(host) and host != "" and is_integer(port) and port in 1..65_535 ->
        true

      _other ->
        false
    end
  end

  # The body of `POST /v1/adapter`, decoded (`decode/1`): `{:ok, declaration}` or
  # `:error`.
  @doc false
  @spec declaration(term) :: {:ok, declaration} | :error
  def declaration(%{} = body) do
    with true <- Enum.sort(Map.keys(body)) == @declaration_keys,
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         true <- url?(body["connect_url"]),
         %{} = sync <- body["sync"],
         true <- Enum.sort(Map.keys(sync)) == @sync_keys,
         default when is_integer(default) <- sync["default_interval"],
         minimum when is_integer(minimum) <- sync["minimum_interval"],
         true <- default in @min_interval..@max_interval,
         true <- minimum in @min_interval..@max_interval,
         true <- minimum <= default,
         sends_changes when is_boolean(sends_changes) <- sync["sends_changes"] do
      {:ok,
       %{
         time: time,
         connect_url: body["connect_url"],
         default_interval: default,
         minimum_interval: minimum,
         sends_changes: sends_changes
       }}
    else
      _ -> :error
    end
  end

  def declaration(_body), do: :error

  # The highest part number of a listing that is read.
  @doc false
  @spec max_part() :: pos_integer
  def max_part, do: @max_part

  # The body of `POST /v1/source-collections`, decoded (`decode/1`): `{:ok, listing}` or
  # `:error`.
  @doc false
  @spec listing(term) :: {:ok, listing} | :error
  def listing(%{} = body) do
    with true <- Enum.sort(Map.keys(body)) == @listing_body_keys,
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         true <- Apiary.Adapters.Connection.public_id?(body["connection_id"]),
         {:ok, collections} <- collections(body["collections"]),
         {:ok, listing} <- listing_part(body["listing"]) do
      {:ok,
       %{
         time: time,
         connection_id: body["connection_id"],
         collections: collections,
         listing: listing
       }}
    else
      _ -> :error
    end
  end

  def listing(_body), do: :error

  defp collections(list) when is_list(list) and length(list) <= @max_collections do
    list
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case collection(item) do
        {:ok, collection} -> {:cont, {:ok, [collection | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      # The last time a ref is named stands, once.
      {:ok, reversed} -> {:ok, reversed |> Enum.uniq_by(& &1.ref) |> Enum.reverse()}
      :error -> :error
    end
  end

  defp collections(_list), do: :error

  defp collection(%{} = item) do
    with {:ok, target} <- target(item),
         true <- Enum.sort(Map.keys(Map.delete(item, "target"))) == @collection_keys,
         true <- text?(item["ref"], 1, @max_ref),
         true <- url?(item["url"]),
         true <- text?(item["title"], 1, @max_title) do
      {:ok, %{ref: item["ref"], url: item["url"], title: item["title"], target: target}}
    else
      _ -> :error
    end
  end

  defp collection(_item), do: :error

  defp target(%{"target" => %{} = target}) do
    with true <- Enum.sort(Map.keys(target)) == @target_keys,
         system when is_binary(system) <- target["system"],
         true <- Regex.match?(@system, system),
         true <- text?(target["path"], 1, @max_ref) do
      {:ok, %{system: system, path: target["path"]}}
    else
      _ -> :error
    end
  end

  defp target(%{"target" => _other}), do: :error
  defp target(%{}), do: {:ok, nil}

  defp listing_part(%{} = listing) do
    with true <- Enum.sort(Map.keys(listing)) == @listing_keys,
         true <- text?(listing["id"], 1, @max_ref),
         part when is_integer(part) and part in 1..@max_part <- listing["part"],
         {:ok, started_at} <- time(listing["started_at"]),
         complete when is_boolean(complete) <- listing["complete"] do
      {:ok, %{id: listing["id"], part: part, started_at: started_at, complete: complete}}
    else
      _ -> :error
    end
  end

  defp listing_part(_listing), do: :error

  # The body of `POST /v1/sources/disconnect`, decoded (`decode/1`): `{:ok, disconnect}`
  # or `:error`.
  @doc false
  @spec source_disconnect(term) :: {:ok, source_disconnect} | :error
  def source_disconnect(%{} = body) do
    with true <- Enum.sort(Map.keys(body)) == @disconnect_keys,
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         true <- text?(body["collection_ref"], 1, @max_ref) do
      {:ok, %{time: time, collection_ref: body["collection_ref"]}}
    else
      _ -> :error
    end
  end

  def source_disconnect(_body), do: :error

  # A string of `min` to `max` code points, with no U+0000.
  defp text?(value, min, max) when is_binary(value) do
    byte_size(value) <= 4 * max and String.valid?(value) and
      not String.contains?(value, <<0>>) and length(String.codepoints(value)) in min..max//1
  end

  defp text?(_value, _min, _max), do: false
end
