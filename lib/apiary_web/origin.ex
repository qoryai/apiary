defmodule ApiaryWeb.Origin do
  @moduledoc """
  From where a person acts, for the audit trail (`Apiary.Audit`): the address of the
  request and its client, `%{remote_ip:, user_agent:}`, which `ApiaryWeb.UserAuth` puts on
  the scope it loads (`Apiary.Accounts.Scope.put_origin/2`). The client is the
  `user-agent` header as sent; the audit trail cuts both to the lengths it keeps.

  ## The address behind a reverse proxy

  The address is the peer's, the one the connection came from: behind a reverse proxy,
  the proxy's, unless the instance trusts the proxy. `TRUSTED_PROXIES` names the proxies
  it trusts, addresses or CIDR ranges separated by commas (`10.0.0.0/8, 192.0.2.7`),
  checked at boot (`boot!/0`); unset or empty trusts none, the default. Only when the peer
  is one of them is `X-Forwarded-For` read, from its right-most hop leftwards: each hop a
  trusted proxy added is passed over, and the first that is not a trusted proxy is the
  address. The hops to its left were written by the client, which may write anything,
  and are never read. A hop may carry a port (`198.51.100.9:4711`, `[2001:db8::1]:443`),
  which is left out; an empty one is skipped; one that is not an address ends the walk at
  the last trusted one. An IPv4 address a dual-stack socket reports as IPv4-mapped IPv6
  is recorded as the IPv4 address. A range of every address (`0.0.0.0/0`, `::/0`) is
  refused: it would believe any client about its own address. A LiveView reads the same
  header from its connection's information (`x_headers`).
  """

  import Bitwise

  @typedoc "A range of addresses: the first address, as a tuple, and the prefix length."
  @type range :: {:inet.ip_address(), non_neg_integer}

  @doc "The origin of a request."
  @spec from_conn(Plug.Conn.t()) :: Apiary.Accounts.Scope.origin()
  def from_conn(%Plug.Conn{} = conn) do
    %{
      remote_ip: address(conn.remote_ip, Plug.Conn.get_req_header(conn, "x-forwarded-for")),
      user_agent: conn |> Plug.Conn.get_req_header("user-agent") |> List.first()
    }
  end

  @doc """
  The origin of a LiveView, from its connection's information, which the endpoint's socket
  is given with the peer's data, the user agent and the `x-` headers: nil for a socket
  without it, as one outside a mount has.
  """
  @spec from_socket(Phoenix.LiveView.Socket.t()) :: Apiary.Accounts.Scope.origin()
  def from_socket(%Phoenix.LiveView.Socket{private: %{connect_info: info}} = socket)
      when not is_nil(info) do
    peer = Phoenix.LiveView.get_connect_info(socket, :peer_data)

    forwarded =
      for {name, value} <- Phoenix.LiveView.get_connect_info(socket, :x_headers) || [],
          String.downcase(name) == "x-forwarded-for",
          do: value

    %{
      remote_ip: address(peer && peer[:address], forwarded),
      user_agent: Phoenix.LiveView.get_connect_info(socket, :user_agent)
    }
  end

  def from_socket(%Phoenix.LiveView.Socket{}), do: nil

  @doc """
  The address a request came from, as text: `peer`, the connection's, or, when `peer` is a
  trusted proxy, the right-most hop of the `X-Forwarded-For` values `forwarded` that is
  not a trusted proxy. `trusted` defaults to the instance's (`trusted_proxies/0`).
  """
  @spec address(:inet.ip_address() | nil, [String.t()], [range]) :: String.t() | nil
  def address(peer, forwarded, trusted \\ trusted_proxies())

  def address(peer, forwarded, trusted) when is_tuple(peer) do
    peer =
      if trusted?(peer, trusted),
        do: walk(hops(forwarded), peer, trusted),
        else: peer

    peer |> unmap() |> text()
  end

  def address(_peer, _forwarded, _trusted), do: nil

  # From the right: past the trusted proxies, to the first address that is not one.
  defp walk([], last, _trusted), do: last

  defp walk([hop | rest], last, trusted) do
    case parse_address(hop) do
      {:ok, address} ->
        if trusted?(address, trusted), do: walk(rest, address, trusted), else: address

      :error ->
        last
    end
  end

  defp hops(values) do
    values
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&without_port/1)
    |> Enum.reverse()
  end

  # `[2001:db8::1]:443` and `[2001:db8::1]` are the address in brackets; `192.0.2.1:4711`,
  # with one colon, an IPv4 address and a port. A bare IPv6 address has more colons.
  defp without_port("[" <> rest) do
    case String.split(rest, "]", parts: 2) do
      [address, port] when port == "" or binary_part(port, 0, 1) == ":" -> address
      _other -> "[" <> rest
    end
  end

  defp without_port(hop) do
    case String.split(hop, ":") do
      [address, _port] -> address
      _other -> hop
    end
  end

  defp text(address) do
    case :inet.ntoa(address) do
      {:error, _reason} -> nil
      text -> List.to_string(text)
    end
  end

  defp parse_address(text) do
    case :inet.parse_strict_address(String.to_charlist(text)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  ## The trusted proxies

  @doc """
  Whether `address` is in one of `ranges`. An IPv4 address a dual-stack socket reports as
  IPv4-mapped IPv6 (`::ffff:192.0.2.7`) is read as the IPv4 address.
  """
  @spec trusted?(:inet.ip_address(), [range]) :: boolean
  def trusted?(address, ranges) do
    address = unmap(address)
    Enum.any?(ranges, fn {first, prefix} -> in_range?(address, first, prefix) end)
  end

  defp unmap({0, 0, 0, 0, 0, 0xFFFF, high, low}),
    do: {high >>> 8, high &&& 0xFF, low >>> 8, low &&& 0xFF}

  defp unmap(address), do: address

  defp in_range?(address, first, prefix) when tuple_size(address) == tuple_size(first) do
    bits = if tuple_size(address) == 4, do: 32, else: 128
    shift = bits - prefix
    integer(address) >>> shift == integer(first) >>> shift
  end

  defp in_range?(_address, _first, _prefix), do: false

  defp integer({a, b, c, d}), do: (a <<< 24) + (b <<< 16) + (c <<< 8) + d

  defp integer(address) when tuple_size(address) == 8,
    do: address |> Tuple.to_list() |> Enum.reduce(0, fn part, acc -> (acc <<< 16) + part end)

  @doc """
  The ranges a value of `TRUSTED_PROXIES` names: `{:ok, ranges}`, none for nil or a blank
  value; `{:error, reason}` for an entry that is not an address or a CIDR range, and for
  a range of every address, a prefix of 0.

      iex> ApiaryWeb.Origin.parse_trusted_proxies("10.0.0.0/8, 192.0.2.7")
      {:ok, [{{10, 0, 0, 0}, 8}, {{192, 0, 2, 7}, 32}]}
  """
  @spec parse_trusted_proxies(String.t() | nil) :: {:ok, [range]} | {:error, String.t()}
  def parse_trusted_proxies(nil), do: {:ok, []}

  def parse_trusted_proxies(value) when is_binary(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, ranges} ->
      case range(entry) do
        {:ok, {_address, 0}} ->
          {:halt,
           {:error,
            "#{inspect(entry)} is every address, which would believe any client about its " <>
              "own; name the proxies in front of the instance"}}

        {:ok, range} ->
          {:cont, {:ok, ranges ++ [range]}}

        :error ->
          {:halt, {:error, "#{inspect(entry)} is not an address or a CIDR range"}}
      end
    end)
  end

  defp range(entry) do
    {text, prefix} =
      case String.split(entry, "/", parts: 2) do
        [text, prefix] -> {text, prefix}
        [text] -> {text, nil}
      end

    with {:ok, address} <- parse_address(text) do
      bits = if tuple_size(address) == 4, do: 32, else: 128

      case prefix && Integer.parse(prefix) do
        nil -> {:ok, {address, bits}}
        {n, ""} when n >= 0 and n <= bits -> {:ok, {address, n}}
        _other -> :error
      end
    end
  end

  @doc """
  Reads `TRUSTED_PROXIES` as `config/runtime.exs` left it, checks it and fixes the
  trusted proxies for the life of the node. Called at boot; raises on a value
  `parse_trusted_proxies/1` refuses, so the instance does not start.
  """
  @spec boot!() :: [range]
  def boot! do
    case parse_trusted_proxies(Application.get_env(:apiary, :trusted_proxies_setting)) do
      {:ok, ranges} ->
        Application.put_env(:apiary, :trusted_proxies, ranges)
        ranges

      {:error, reason} ->
        raise ArgumentError, """
        environment variable TRUSTED_PROXIES is not valid: #{reason}.
        Leave it unset to trust no proxy, or name the reverse proxies in front of the
        instance, addresses or CIDR ranges separated by commas, for example:
        TRUSTED_PROXIES=10.0.0.0/8,192.0.2.7
        """
    end
  end

  @doc "The trusted proxies, as `boot!/0` fixed them; none before it ran."
  @spec trusted_proxies() :: [range]
  def trusted_proxies, do: Application.get_env(:apiary, :trusted_proxies, [])
end
