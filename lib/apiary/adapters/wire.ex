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
  # accepts, so `900.0` and `9e2` are refused where an integer is due. Each integer field
  # is checked so, one by one; the numbers inside an adapter's `description` are no such
  # field, and follow `description.schema.json`, which allows a fraction or an exponent.
  #
  # `time/1` reads a time as the contract writes it (`$defs/time`): RFC 3339 in UTC with
  # whole seconds, `2026-10-15T12:00:00Z`, never a leap second (`:60`), and nothing else.
  #
  # `url?/1` holds a URL to the contract's `$defs/url` (`https://`, at most 2,048
  # characters, an RFC 3986 URI) and to what the instance stores and sends a person to
  # (`Apiary.Nodes.Node.connect_url_changeset/2`): only RFC 3986's characters, every `%`
  # followed by two hexadecimal digits, a host, a port from 1 to 65,535 when one is
  # written, and no user information.
  #
  # `declaration/1` reads the raw body of `POST /v1/adapter` (`adapter.schema.json`),
  # decoded as `decode/1` decodes it: exactly `version` (1), `time`, `connect_url`, `sync`,
  # which holds exactly `default_interval` and `minimum_interval`, integers from 60 to
  # 86,400, the minimum at most the default, and `sends_changes`, a boolean, `setup_url`
  # when given (`setup_url?/1`; nil when absent: the adapter has nothing to set up), and
  # `description`, the description the adapter's program prints, which
  # `Apiary.Integrations.Description.parse/1` reads and checks. It is given the
  # description's value as the body carries it, its bytes from the first of the value to
  # the last, found by a scan of the raw body (`member_value/2`), so the description's
  # limit on its raw bytes, 256 KiB, is measured on what the adapter sent: an encoding of
  # the decoded value would write its numbers and its whitespace otherwise, `1e5` as
  # `1.0e5`.
  #
  # `setup_url?/1` holds the address an instance admin is sent to, to set the adapter up,
  # to what `adapter.schema.json` allows of `setup_url`: a URL as `url?/1` holds one, with
  # no fragment, and no query parameter named `state`, written plainly or percent-encoded
  # (`%73tate`), first in the query or after a `&`, with a value or without one. The pass
  # goes there as `state` (`Apiary.Adapters.SetupPass`). Any other query is allowed.
  #
  # `listing/1` reads the body of `POST /v1/source-collections`
  # (`source-collections.schema.json`): exactly `version` (1), `time`, `connection_id`
  # (`ac_` and sixteen characters), `collections`, at most 100, each exactly `ref`,
  # `url` and `title`, `target` when given, which holds exactly `system` and `path`, and
  # `items` when given, which is `false` (`items: true` when it is not given), and
  # `environment_ref` when given, 1 to 200 characters like a ref (nil when absent: the
  # collection has no environment definition); and `listing`, exactly `id`, `part`,
  # `started_at` and `complete`. A ref named twice in one part is taken as the last time
  # it is named.
  #
  # `source_disconnect/1` reads the body of `POST /v1/sources/disconnect`
  # (`sources-disconnect.schema.json`): exactly `version` (1), `time`, `connection_id`
  # (`ac_` and sixteen characters, as a listing names it) and `collection_ref`.
  #
  # Their text is counted in code points, as the contract's lengths are, and none of it
  # may hold U+0000, which the database cannot keep. A part numbered past `max_part/0`,
  # `$defs/listing`'s maximum, is refused: the parts of a listing are kept until it
  # completes.

  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/
  # RFC 3986's characters: unreserved, reserved, and `%` of a percent-encoding.
  @uri_characters ~r{\A[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+\z}
  # A `%` that does not start a percent-encoding.
  @bare_percent ~r/%(?![0-9A-Fa-f]{2})/
  # `https://`, an authority with no `@`, then nothing, or a path, a query or a fragment:
  # as `nodes_connect_url_check` holds a stored address.
  @no_user_information ~r{\Ahttps://[^/?#@]+(?:[/?#].*)?\z}s
  # A query parameter named `state`, each letter written plainly or percent-encoded: the
  # pattern `adapter.schema.json` refuses in `setup_url`, as written there.
  @state_parameter ~r/\A[^?#]*\?(?:[^&#]*&)*(?:s|%73)(?:t|%74)(?:a|%61)(?:t|%74)(?:e|%65)(?:[=&#]|\z)/
  @max_url 2048
  @min_interval 60
  @max_interval 86_400
  @declaration_keys ~w(connect_url description sync time version)
  @sync_keys ~w(default_interval minimum_interval sends_changes)
  @listing_body_keys ~w(collections connection_id listing time version)
  @listing_keys ~w(complete id part started_at)
  @collection_keys ~w(ref title url)
  @target_keys ~w(path system)
  @disconnect_keys ~w(collection_ref connection_id time version)
  @max_collections 100
  @max_part 10_000
  @max_title 1024
  @max_ref 200
  @system ~r/\A[a-z0-9.-]{1,253}\z/

  @type declaration :: %{
          time: DateTime.t(),
          connect_url: String.t(),
          setup_url: String.t() | nil,
          default_interval: pos_integer,
          minimum_interval: pos_integer,
          sends_changes: boolean,
          description: Apiary.Integrations.Description.t()
        }

  @type target :: %{system: String.t(), path: String.t()}

  @type collection :: %{
          ref: String.t(),
          url: String.t(),
          title: String.t(),
          target: target | nil,
          items: boolean,
          environment_ref: String.t() | nil
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

  @type source_disconnect :: %{
          time: DateTime.t(),
          connection_id: String.t(),
          collection_ref: String.t()
        }

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

  # Whether `value` is an address an adapter may declare to be set up at: `url?/1`'s, with
  # no fragment and no query parameter named `state`, as `adapter.schema.json` has it.
  @doc false
  @spec setup_url?(term) :: boolean
  def setup_url?(value) when is_binary(value) do
    url?(value) and not String.contains?(value, "#") and
      not Regex.match?(@state_parameter, value)
  end

  def setup_url?(_value), do: false

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

  # The raw body of `POST /v1/adapter`: `{:ok, declaration}` or `:error`. The description
  # is read last, once every other member is as the contract has it.
  @doc false
  @spec declaration(term) :: {:ok, declaration} | :error
  def declaration(raw) when is_binary(raw) do
    with {:ok, body} <- decode(raw),
         true <- Enum.sort(Map.keys(Map.delete(body, "setup_url"))) == @declaration_keys,
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         true <- url?(body["connect_url"]),
         {:ok, setup_url} <- setup_url(body),
         %{} = sync <- body["sync"],
         true <- Enum.sort(Map.keys(sync)) == @sync_keys,
         default when is_integer(default) <- sync["default_interval"],
         minimum when is_integer(minimum) <- sync["minimum_interval"],
         true <- default in @min_interval..@max_interval,
         true <- minimum in @min_interval..@max_interval,
         true <- minimum <= default,
         sends_changes when is_boolean(sends_changes) <- sync["sends_changes"],
         {:ok, value} <- member_value(raw, "description"),
         {:ok, description} <- Apiary.Integrations.Description.parse(value) do
      {:ok,
       %{
         time: time,
         connect_url: body["connect_url"],
         setup_url: setup_url,
         default_interval: default,
         minimum_interval: minimum,
         sends_changes: sends_changes,
         description: description
       }}
    else
      _ -> :error
    end
  end

  def declaration(_raw), do: :error

  # `setup_url` when the body gives one, held to `setup_url?/1`; nil when it gives none.
  defp setup_url(%{"setup_url" => url}),
    do: if(setup_url?(url), do: {:ok, url}, else: :error)

  defp setup_url(%{}), do: {:ok, nil}

  # The bytes of the value of the top-level member `name` of `raw`, as `raw` carries them:
  # from the first byte of the value to its last, without the whitespace around it.
  # `{:ok, bytes}`, or `:error` where the object has no such member.
  #
  # Meant for a `raw` that `decode/1` read: a JSON object that Jason accepted, with no
  # member twice, so the scan does not check the grammar again; on any other `raw` it
  # answers `:error` where it cannot read on, and never raises, but what it finds there
  # means nothing. It reads each member's
  # name as Jason does, its escapes read, so a name written `"descr\u0069ption"` is found
  # as `description`, and steps over each value: a string to its closing quote, past every
  # escaped character; an object or a list to the bracket that closes it, counting the
  # brackets outside strings; any other value to the first byte that cannot be in it.
  # Each step looks for its next byte with `:binary.match/3`, so the scan is linear in the
  # size of `raw`, at most the 1 MiB `ApiaryWeb.Contract.RawBody` reads.
  @doc false
  @spec member_value(binary, String.t()) :: {:ok, binary} | :error
  def member_value(raw, name) when is_binary(raw) and is_binary(name) do
    patterns = %{
      string: :binary.compile_pattern(["\"", "\\"]),
      nested: :binary.compile_pattern(["\"", "{", "[", "}", "]"]),
      scalar: :binary.compile_pattern([",", "}", "]", " ", "\t", "\n", "\r"])
    }

    case skip_space(raw) do
      "{" <> rest -> members(rest, name, patterns)
      _other -> :error
    end
  end

  def member_value(_raw, _name), do: :error

  defp members(rest, name, patterns) do
    with "\"" <> _ = rest <- skip_space(rest),
         {key, rest} <- string_span(rest, patterns),
         ":" <> rest <- skip_space(rest),
         value = skip_space(rest),
         after_value when is_binary(after_value) <- skip_value(value, patterns),
         {:ok, key} <- Jason.decode(key) do
      bytes = binary_part(value, 0, byte_size(value) - byte_size(after_value))

      case {key == name, skip_space(after_value)} do
        {true, _rest} -> {:ok, bytes}
        {false, "," <> rest} -> members(rest, name, patterns)
        {false, _end_of_object} -> :error
      end
    else
      _end_of_object_or_unreadable -> :error
    end
  end

  # JSON's whitespace: space, tab, line feed and carriage return.
  defp skip_space(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r], do: skip_space(rest)
  defp skip_space(rest), do: rest

  # `{string, rest}`: the string `rest` starts with, its quotes included, and what follows;
  # `:error` where it does not close.
  defp string_span("\"" <> body = rest, patterns) do
    case string_length(body, 0, patterns) do
      length when is_integer(length) ->
        {binary_part(rest, 0, length + 1), binary_part(body, length, byte_size(body) - length)}

      :error ->
        :error
    end
  end

  # The bytes of a string's body from the byte `at` up to its closing quote, that quote
  # included, counted from the body's first byte; `:error` where it does not close.
  defp string_length(body, at, _patterns) when at >= byte_size(body), do: :error

  defp string_length(body, at, patterns) do
    case :binary.match(body, patterns.string, scope: {at, byte_size(body) - at}) do
      {found, _} ->
        case :binary.at(body, found) do
          ?" -> found + 1
          ?\\ -> string_length(body, found + 2, patterns)
        end

      :nomatch ->
        :error
    end
  end

  # What follows the value `rest` starts with, or `:error` where it does not end.
  defp skip_value("\"" <> _ = rest, patterns) do
    case string_span(rest, patterns) do
      {_string, after_string} -> after_string
      :error -> :error
    end
  end

  defp skip_value(<<open, _::binary>> = rest, patterns) when open in [?{, ?[],
    do: skip_nested(rest, 1, 1, patterns)

  defp skip_value(rest, patterns) do
    case :binary.match(rest, patterns.scalar) do
      {at, _} -> binary_part(rest, at, byte_size(rest) - at)
      :nomatch -> ""
    end
  end

  # What follows the object or list `rest` starts with, `depth` brackets open before the
  # byte `at`, or `:error` where it does not close.
  defp skip_nested(rest, 0, at, _patterns), do: binary_part(rest, at, byte_size(rest) - at)
  defp skip_nested(rest, _depth, at, _patterns) when at >= byte_size(rest), do: :error

  defp skip_nested(rest, depth, at, patterns) do
    case :binary.match(rest, patterns.nested, scope: {at, byte_size(rest) - at}) do
      {found, _} -> skip_nested_at(rest, depth, found, patterns)
      :nomatch -> :error
    end
  end

  defp skip_nested_at(rest, depth, found, patterns) do
    case :binary.at(rest, found) do
      ?" ->
        tail = binary_part(rest, found + 1, byte_size(rest) - found - 1)

        case string_length(tail, 0, patterns) do
          length when is_integer(length) ->
            skip_nested(rest, depth, found + 1 + length, patterns)

          :error ->
            :error
        end

      close when close in [?}, ?]] ->
        skip_nested(rest, depth - 1, found + 1, patterns)

      _open ->
        skip_nested(rest, depth + 1, found + 1, patterns)
    end
  end

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
         {:ok, items} <- items(item),
         {:ok, environment_ref} <- environment_ref(item),
         true <-
           Enum.sort(Map.keys(Map.drop(item, ["target", "items", "environment_ref"]))) ==
             @collection_keys,
         true <- text?(item["ref"], 1, @max_ref),
         true <- url?(item["url"]),
         true <- text?(item["title"], 1, @max_title) do
      {:ok,
       %{
         ref: item["ref"],
         url: item["url"],
         title: item["title"],
         target: target,
         items: items,
         environment_ref: environment_ref
       }}
    else
      _ -> :error
    end
  end

  defp collection(_item), do: :error

  # A collection's `items`: `false` when given, the only value the contract has; true when
  # it is not.
  defp items(%{"items" => false}), do: {:ok, false}
  defp items(%{"items" => _other}), do: :error
  defp items(%{}), do: {:ok, true}

  # A collection's `environment_ref` (`$defs/environment_ref`, a ref): `{:ok, ref}`,
  # `{:ok, nil}` when the collection has none, or `:error`.
  defp environment_ref(%{"environment_ref" => ref}),
    do: if(text?(ref, 1, @max_ref), do: {:ok, ref}, else: :error)

  defp environment_ref(%{}), do: {:ok, nil}

  # The `target` of `item`, a collection or an item (`$defs/target`): `{:ok, target}`,
  # `{:ok, nil}` when `item` has none, or `:error`.
  @doc false
  @spec target(map) :: {:ok, target | nil} | :error
  def target(%{"target" => %{} = target}) do
    with true <- Enum.sort(Map.keys(target)) == @target_keys,
         system when is_binary(system) <- target["system"],
         true <- Regex.match?(@system, system),
         true <- text?(target["path"], 1, @max_ref) do
      {:ok, %{system: system, path: target["path"]}}
    else
      _ -> :error
    end
  end

  def target(%{"target" => _other}), do: :error
  def target(%{}), do: {:ok, nil}

  # One part of a listing (`$defs/listing`): `{:ok, part}` or `:error`.
  @doc false
  @spec listing_part(term) :: {:ok, map} | :error
  def listing_part(%{} = listing) do
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

  def listing_part(_listing), do: :error

  # The body of `POST /v1/sources/disconnect`, decoded (`decode/1`): `{:ok, disconnect}`
  # or `:error`.
  @doc false
  @spec source_disconnect(term) :: {:ok, source_disconnect} | :error
  def source_disconnect(%{} = body) do
    with true <- Enum.sort(Map.keys(body)) == @disconnect_keys,
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         true <- Apiary.Adapters.Connection.public_id?(body["connection_id"]),
         true <- text?(body["collection_ref"], 1, @max_ref) do
      {:ok,
       %{
         time: time,
         connection_id: body["connection_id"],
         collection_ref: body["collection_ref"]
       }}
    else
      _ -> :error
    end
  end

  def source_disconnect(_body), do: :error

  # Whether `value` is a string of `min` to `max` code points, with no U+0000.
  @doc false
  @spec text?(term, non_neg_integer, pos_integer) :: boolean
  def text?(value, min, max) when is_binary(value) do
    byte_size(value) <= 4 * max and String.valid?(value) and
      not String.contains?(value, <<0>>) and length(String.codepoints(value)) in min..max//1
  end

  def text?(_value, _min, _max), do: false
end
