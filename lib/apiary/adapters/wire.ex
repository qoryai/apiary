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

  @type declaration :: %{
          time: DateTime.t(),
          connect_url: String.t(),
          default_interval: pos_integer,
          minimum_interval: pos_integer,
          sends_changes: boolean
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
end
