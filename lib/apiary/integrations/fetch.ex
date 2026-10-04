defmodule Apiary.Integrations.Fetch do
  @moduledoc """
  Fetch reads one file of an integration's release over https, with the guards a server
  needs when it fetches an address someone typed in:

    * **Resolve, check, pin.** The host is resolved, and the fetch is refused unless every
      address it resolves to is public (`Apiary.Integrations.Fetch.Address`); the request
      then connects to the first of them, by address, with the host name kept for the
      `Host` header, SNI and the certificate's check, so a second lookup cannot send it
      elsewhere.
    * **Every hop.** A redirect is followed by hand, and its target passes the same
      checks: https, port 443, an exact host name that is not a refused one, resolved and
      pinned again. At most `max_redirects` hops (5).
    * **Caps.** At most `max_bytes` of body (1 MiB), counted as it arrives, a declared
      `Content-Length` over it refused before; and the whole fetch, every hop, within
      `timeout` milliseconds (15 seconds). No body is decompressed.
    * **Tokens stay with the public forges.** A `token`, which an edition gives for a
      private release (`c:Apiary.Edition.release_token/2`), is sent only to a public
      forge's own host (`Apiary.Integrations.Source.public_forge_hosts/0`), on the hop
      to the host first asked, and never to a self-hosted host or a host a redirect
      names.
    * **The operator's allow list.** A host listed in `INTEGRATION_PRIVATE_HOSTS` (comma
      separated host names) may resolve to private addresses, such as a self-hosted forge
      on the operator's network. Loopback, link-local and metadata addresses stay
      refused for every host.
    * **One answer.** Every failure is `{:error, :fetch_failed}`, the same to every
      caller and page, with what failed in a log line, which names the URL and never a
      token.

  The options, beside `:token`, exist for the tests and are read from
  `config :apiary, Apiary.Integrations.Fetch` where not given: `:resolver`, a module with
  `resolve/1` or a function of a host answering `{:ok, [address]}` or `{:error, reason}`
  (`:inet` by default); `:req_options`, merged into the request's; `:private_hosts`.
  """

  require Logger

  alias Apiary.Integrations.Fetch.Address
  alias Apiary.Integrations.Source
  alias Apiary.Kinds.Hosts

  @max_bytes 1_048_576
  @timeout 15_000
  @max_redirects 5
  @redirects [301, 302, 303, 307, 308]

  @typedoc "An option of `get/2`: see the module's documentation."
  @type option ::
          {:token, String.t() | nil}
          | {:max_bytes, pos_integer}
          | {:timeout, pos_integer}
          | {:max_redirects, non_neg_integer}
          | {:resolver, module | (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term})}
          | {:private_hosts, [String.t()]}
          | {:req_options, keyword}

  @doc """
  get/2 reads the body of `url`, an https URL, under the guards of the module's
  documentation: `{:ok, body}` for a `200` within them, else `{:error, :fetch_failed}`
  and a log line saying why.
  """
  @spec get(String.t(), [option]) :: {:ok, binary} | {:error, :fetch_failed}
  def get(url, opts \\ []) when is_binary(url) do
    opts = Keyword.merge(Application.get_env(:apiary, __MODULE__, []), opts)
    timeout = Keyword.get(opts, :timeout, @timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    task =
      Task.async(fn ->
        try do
          follow(url, 0, nil, deadline, opts)
        rescue
          error -> {:error, {:raised, Exception.message(error)}}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end
      end)

    result =
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _none -> {:error, :timeout}
      end

    case result do
      {:ok, body} ->
        {:ok, body}

      {:error, reason} ->
        Logger.warning(
          "an integration release could not be fetched url=#{url} reason=#{inspect(reason)}"
        )

        {:error, :fetch_failed}
    end
  end

  # One hop: `url` checked, resolved and pinned, then asked; a redirect followed from here.
  defp follow(url, hops, first_host, deadline, opts) do
    with {:ok, uri} <- check_url(url),
         first_host = first_host || uri.host,
         {:ok, address} <- resolve(uri.host, opts),
         {:ok, response} <- request(uri, address, first_host, deadline, opts) do
      cond do
        response.status == 200 ->
          if Req.Response.get_private(response, :too_large),
            do: {:error, :too_large},
            else: {:ok, response.body}

        response.status in @redirects ->
          redirect(uri, response, hops, first_host, deadline, opts)

        true ->
          {:error, {:status, response.status}}
      end
    end
  end

  defp redirect(uri, response, hops, first_host, deadline, opts) do
    max = Keyword.get(opts, :max_redirects, @max_redirects)

    case Req.Response.get_header(response, "location") do
      _location when hops >= max ->
        {:error, :too_many_redirects}

      [location | _] ->
        next = uri |> URI.merge(location) |> URI.to_string()
        follow(next, hops + 1, first_host, deadline, opts)

      [] ->
        {:error, :redirect_without_location}
    end
  end

  defp check_url(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: 443, userinfo: nil} = uri when is_binary(host) ->
        cond do
          not Hosts.exact?(host) -> {:error, {:host_invalid, host}}
          Hosts.refused_name?(host) -> {:error, {:host_refused, host}}
          true -> {:ok, %{uri | fragment: nil}}
        end

      _other ->
        {:error, {:url_invalid, url}}
    end
  end

  # Every address the host resolves to must be one the fetch may reach; the first is the
  # one connected to.
  defp resolve(host, opts) do
    private_ok? = host in private_hosts(opts)

    case lookup(host, Keyword.get(opts, :resolver, __MODULE__.DNS)) do
      {:ok, [_ | _] = addresses} ->
        refused =
          Enum.reject(addresses, fn address ->
            case Address.classify(address) do
              :public -> true
              :private -> private_ok?
              :forbidden -> false
            end
          end)

        if refused == [],
          do: {:ok, hd(addresses)},
          else: {:error, {:address_refused, host, Enum.map(refused, &Address.ntoa/1)}}

      {:ok, []} ->
        {:error, {:unresolved, host}}

      {:error, reason} ->
        {:error, {:unresolved, host, reason}}
    end
  end

  defp lookup(host, resolver) when is_function(resolver, 1), do: resolver.(host)
  defp lookup(host, resolver) when is_atom(resolver), do: resolver.resolve(host)

  defp private_hosts(opts) do
    case Keyword.fetch(opts, :private_hosts) do
      {:ok, hosts} ->
        hosts

      :error ->
        parse_private_hosts(Application.get_env(:apiary, :integration_private_hosts_setting))
    end
  end

  @doc """
  parse_private_hosts/1 reads the `INTEGRATION_PRIVATE_HOSTS` setting: host names separated
  by commas, none when unset. Raises `ArgumentError` for an entry that is not an exact
  host name, which `boot!/0` asks at boot.
  """
  @spec parse_private_hosts(String.t() | nil) :: [String.t()]
  def parse_private_hosts(nil), do: []

  def parse_private_hosts(setting) when is_binary(setting) do
    for entry <- String.split(setting, ",", trim: true),
        host = entry |> String.trim() |> String.downcase(),
        host != "" do
      if Hosts.exact?(host) and not Hosts.refused_name?(host),
        do: host,
        else:
          raise(ArgumentError, "INTEGRATION_PRIVATE_HOSTS: #{inspect(host)} is not a host name")
    end
  end

  @doc "boot!/0 checks `INTEGRATION_PRIVATE_HOSTS` at boot, and stops a boot it refuses."
  @spec boot!() :: :ok
  def boot! do
    _hosts = parse_private_hosts(Application.get_env(:apiary, :integration_private_hosts_setting))
    :ok
  end

  defp request(uri, address, first_host, deadline, opts) do
    remaining = deadline - System.monotonic_time(:millisecond)
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    host = uri.host

    headers =
      [{"host", host}, {"user-agent", "qory-apiary"}, {"accept", "*/*"}] ++
        token_header(Keyword.get(opts, :token), host, first_host)

    options =
      [
        url: %{uri | host: Address.ntoa(address)},
        method: :get,
        headers: headers,
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        raw: true,
        inet6: tuple_size(address) == 8,
        receive_timeout: max(remaining, 1),
        connect_options: [hostname: host, timeout: max(remaining, 1)],
        into: collect(max_bytes)
      ]
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    case Req.request(options) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
    end
  end

  # The token goes to the host first asked alone, and only when that host is a public
  # forge's: never to a self-hosted host, never across a redirect.
  defp token_header(token, host, first_host) when is_binary(token) and token != "" do
    if host == first_host and host in Source.public_forge_hosts(),
      do: [{"authorization", "Bearer " <> token}],
      else: []
  end

  defp token_header(_token, _host, _first_host), do: []

  # The body, kept only up to `max_bytes`: a declared length over it, or a body that grows
  # past it, stops the read.
  defp collect(max_bytes) do
    fn {:data, data}, {request, response} ->
      body = if is_binary(response.body), do: response.body, else: ""
      declared = declared_length(response)

      cond do
        is_integer(declared) and declared > max_bytes ->
          {:halt, {request, Req.Response.put_private(response, :too_large, true)}}

        byte_size(body) + byte_size(data) > max_bytes ->
          {:halt, {request, Req.Response.put_private(response, :too_large, true)}}

        true ->
          {:cont, {request, %{response | body: body <> data}}}
      end
    end
  end

  defp declared_length(response) do
    with [value | _] <- Req.Response.get_header(response, "content-length"),
         {length, ""} <- Integer.parse(value) do
      length
    else
      _ -> nil
    end
  end

  defmodule DNS do
    @moduledoc """
    DNS is the resolver `Apiary.Integrations.Fetch` asks by default: every IPv4 and IPv6
    address of a host, by the system's resolver (`:inet.getaddrs/2`).
    """

    @doc "resolve/1 is every address of `host`: `{:ok, addresses}`, or `{:error, reason}`."
    @spec resolve(String.t()) :: {:ok, [:inet.ip_address()]} | {:error, term}
    def resolve(host) do
      name = String.to_charlist(host)
      results = for family <- [:inet, :inet6], do: :inet.getaddrs(name, family)

      case for({:ok, addresses} <- results, address <- addresses, do: address) do
        [] ->
          {:error,
           results
           |> Enum.find_value(fn
             {:error, reason} -> reason
             _ -> nil
           end)}

        addresses ->
          {:ok, Enum.uniq(addresses)}
      end
    end
  end
end
