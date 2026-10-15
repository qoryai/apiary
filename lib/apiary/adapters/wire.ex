defmodule Apiary.Adapters.Wire do
  @moduledoc false

  # The bodies an adapter (a node of kind `adapter`) posts, read as the integration
  # contract has them (qoryai/integrations, `contracts/integration/v1`, at the commit in
  # `.integrations-contract-ref`). Pure functions: nothing here touches the database or a
  # log, and nothing here puts a value it was sent in an error.
  #
  # `decode/1` reads a raw body strictly: a JSON object, with no member twice in it or in
  # any object inside it, which a parser that keeps the last of them cannot tell. `time/1`
  # reads a time as the contract writes it: RFC 3339 in UTC with whole seconds,
  # `2026-10-15T12:00:00Z`, and nothing else. `url?/1` holds a URL to the contract's
  # `url` and to what the instance stores and sends a person to: `https://`, at most
  # 2,048 characters, printable ASCII alone (so no whitespace and no control character)
  # with no backslash, a host, a port of digits when there is a `:` after the host, and no
  # user information.
  #
  # `declaration/1` reads the body of `POST /v1/adapter` (`adapter.schema.json`): exactly
  # `version` (1), `time`, `connect_url` and `sync`, which holds exactly
  # `default_interval` and `minimum_interval`, integers from 60 to 86,400, the minimum at
  # most the default, and `sends_changes`, a boolean. Anything else is `:error`.

  @whole_seconds ~r/\A[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\z/
  # Printable ASCII, from `!` to `~`: no space, no control character, nothing past ASCII.
  @printable_ascii ~r/\A[\x21-\x7e]+\z/
  # The host and the port of an authority with no user information.
  @authority ~r/\A(?:\[[0-9A-Fa-f:.]+\]|[^:@\[\]]+)(?::[0-9]{1,5})?\z/
  @max_url 2048
  @min_interval 60
  @max_interval 86_400

  @type declaration :: %{
          time: DateTime.t(),
          connect_url: String.t(),
          default_interval: pos_integer,
          minimum_interval: pos_integer,
          sends_changes: boolean
        }

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
    Enum.reduce_while(list, {:ok, []}, fn value, {:ok, acc} ->
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
      Regex.match?(@printable_ascii, value) and not String.contains?(value, "\\") and
      authority?(value)
  end

  def url?(_value), do: false

  # A host, and no user information: the authority, up to the first `/`, `?` or `#`, is a
  # host (a name or an address, or an address in brackets) and, after a `:`, a port of one
  # to five digits; and the URL parses with that host.
  defp authority?("https://" <> rest) do
    authority = rest |> String.split(["/", "?", "#"], parts: 2) |> hd()

    Regex.match?(@authority, authority) and
      match?(
        %URI{scheme: "https", host: host, userinfo: nil} when host not in [nil, ""],
        URI.parse("https://" <> rest)
      )
  end

  # The body of `POST /v1/adapter`, decoded (`decode/1`): `{:ok, declaration}` or
  # `:error`.
  @doc false
  @spec declaration(term) :: {:ok, declaration} | :error
  def declaration(%{} = body) do
    with true <- Enum.sort(Map.keys(body)) == ~w(connect_url sync time version),
         true <- body["version"] === 1,
         {:ok, time} <- time(body["time"]),
         true <- url?(body["connect_url"]),
         %{} = sync <- body["sync"],
         true <- Enum.sort(Map.keys(sync)) == ~w(default_interval minimum_interval sends_changes),
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
