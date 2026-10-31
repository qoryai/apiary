defmodule Apiary.Integrations.Fetch do
  @moduledoc """
  Fetch reads one file of an integration's release over https, with the guards a server
  needs when it fetches an address someone typed in:

    * **Resolve, check, pin.** The host is resolved, and the fetch is refused unless every
      address it resolves to is public (`Apiary.Integrations.Fetch.Address`): never a
      private, loopback, link-local or cloud metadata address, for any host, with no
      setting to allow one. The request then connects to the first of them, by address,
      with the host name kept for the `Host` header, SNI and the certificate's check, so a
      second lookup cannot send it elsewhere. Each request opens one connection and
      closes it when the request ends, on an answer, an error or the time running out
      (Apiary.Integrations.Fetch.Connection); no connection pool is kept.
    * **Every hop.** A redirect is followed by hand, and its target passes the same
      checks: https, port 443 (any port with `any_port: true`), an exact host name that
      is not a refused one, resolved and pinned again. At most `max_redirects` hops (5).
    * **Caps.** At most `max_bytes` of body (1 MiB), counted as it arrives, a declared
      `Content-Length` over it refused before; and the whole fetch, every hop, within
      `timeout` milliseconds (15 seconds). No body is decompressed.
    * **No credentials.** A request carries a `Host`, a `User-Agent` and an `Accept`
      header, and no credential: no `Authorization`, no token of any kind, on any hop. A
      release is read as anyone may read it, so a private one is not found.
    * **One answer.** Every failure is `{:error, :fetch_failed}`, the same to every
      caller and page, with what failed in a log line, which names the URL.

  The options, beside the caps, exist for the tests and are read from
  `config :apiary, Apiary.Integrations.Fetch` where not given: `:resolver`, a module with
  `resolve/1` or a function of a host answering `{:ok, [address]}` or `{:error, reason}`
  (`:inet` by default); `:req_options`, merged into the request's.

  `request/3` is the same fetch for a public git repository's smart-HTTP requests
  (Apiary.Harnesses.PublicGit), with three differences, each an option: a `POST` with
  a `:body`, the `:headers` the protocol sends in place of `Accept`, and, with
  `any_port: true`, the port the address has, on every hop. It returns the address of
  the last hop and the answer's `Content-Type`, and a failure by its class
  (`t:failure/0`).
  """

  require Logger

  alias Apiary.Integrations.Fetch.Address
  alias Apiary.Kinds.Hosts

  @max_bytes 1_048_576
  @timeout 15_000
  @max_redirects 5
  @redirects [301, 302, 303, 307, 308]

  @typedoc "An option of `get/2` and `request/3`: see the module's documentation."
  @type option ::
          {:max_bytes, pos_integer}
          | {:timeout, pos_integer}
          | {:max_redirects, non_neg_integer}
          | {:resolver, module | (String.t() -> {:ok, [:inet.ip_address()]} | {:error, term})}
          | {:req_options, keyword}
          | {:body, binary}
          | {:headers, [{String.t(), String.t()}]}
          | {:any_port, boolean}
          | {:user_agent, String.t()}

  @typedoc """
  Why `request/3` failed: `:not_allowed`, a host that is a refused name or resolves to an
  address that is not public, on any hop; `:unreachable`, a host that resolves to no
  address, no connection, no answer in time, or a `502`, `503` or `504`; `:too_large`, a
  body over `max_bytes`; `:not_found`, a `401`, `403` or `404`; `:failed`, anything else,
  such as another status, an address that is not https, or too many redirects.
  """
  @type failure :: :not_allowed | :unreachable | :too_large | :not_found | :failed

  @typedoc "What `request/3` read: the body, the address of the last hop, and the `Content-Type`."
  @type answer :: %{body: binary, url: String.t(), content_type: String.t() | nil}

  @doc """
  get/2 reads the body of `url`, an https URL, under the guards of the module's
  documentation: `{:ok, body}` for a `200` within them, else `{:error, :fetch_failed}`
  and a log line saying why.
  """
  @spec get(String.t(), [option]) :: {:ok, binary} | {:error, :fetch_failed}
  def get(url, opts \\ []) when is_binary(url) do
    case run(:get, url, opts) do
      {:ok, answer} ->
        {:ok, answer.body}

      {:error, reason} ->
        Logger.warning(
          "an integration release could not be fetched url=#{url} reason=#{inspect(reason)}"
        )

        {:error, :fetch_failed}
    end
  end

  @doc """
  request/3 sends `method`, `:get` or `:post`, to `url`, an https URL, under the guards of
  the module's documentation: `{:ok, answer}` for a `200` within them, else `{:error,
  failure}` (`t:failure/0`), and a log line saying why for every failure but
  `:not_found`.
  """
  @spec request(:get | :post, String.t(), [option]) :: {:ok, answer} | {:error, failure}
  def request(method, url, opts \\ []) when method in [:get, :post] and is_binary(url) do
    case run(method, url, opts) do
      {:ok, answer} ->
        {:ok, answer}

      {:error, reason} ->
        failure = failure(reason)

        if failure != :not_found,
          do: Logger.warning("a public git request failed url=#{url} reason=#{inspect(reason)}")

        {:error, failure}
    end
  end

  defp failure({:host_refused, _host}), do: :not_allowed
  defp failure({:address_refused, _host, _addresses}), do: :not_allowed
  defp failure({:unresolved, _host}), do: :unreachable
  defp failure({:unresolved, _host, _reason}), do: :unreachable
  defp failure({:transport, _message}), do: :unreachable
  defp failure(:timeout), do: :unreachable
  defp failure({:status, status}) when status in [502, 503, 504], do: :unreachable
  defp failure({:status, status}) when status in [401, 403, 404], do: :not_found
  defp failure(:too_large), do: :too_large
  defp failure(_other), do: :failed

  defp run(method, url, opts) do
    opts = :apiary |> Application.get_env(__MODULE__, []) |> Keyword.merge(opts)

    timeout = Keyword.get(opts, :timeout, @timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    task =
      Task.async(fn ->
        try do
          follow(method, url, 0, deadline, opts)
        rescue
          error -> {:error, {:raised, Exception.message(error)}}
        catch
          :exit, reason -> {:error, {:exit, reason}}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _none -> {:error, :timeout}
    end
  end

  # One hop: `url` checked, resolved and pinned, then asked; a redirect followed from here.
  defp follow(method, url, hops, deadline, opts) do
    with {:ok, uri} <- check_url(url, opts),
         {:ok, address} <- resolve(uri.host, opts),
         {:ok, response} <- send_request(method, uri, address, deadline, opts) do
      cond do
        response.status == 200 ->
          if Req.Response.get_private(response, :too_large),
            do: {:error, :too_large},
            else: {:ok, answer(response, uri)}

        response.status in @redirects ->
          redirect(method, uri, response, hops, deadline, opts)

        true ->
          {:error, {:status, response.status}}
      end
    end
  end

  defp answer(response, uri) do
    content_type =
      case Req.Response.get_header(response, "content-type") do
        [value | _] -> value
        [] -> nil
      end

    %{body: response.body, url: URI.to_string(uri), content_type: content_type}
  end

  defp redirect(method, uri, response, hops, deadline, opts) do
    max = Keyword.get(opts, :max_redirects, @max_redirects)

    case Req.Response.get_header(response, "location") do
      _location when hops >= max ->
        {:error, :too_many_redirects}

      [location | _] ->
        next = uri |> URI.merge(location) |> URI.to_string()
        follow(method, next, hops + 1, deadline, opts)

      [] ->
        {:error, :redirect_without_location}
    end
  end

  defp check_url(url, opts) do
    any_port = Keyword.get(opts, :any_port, false)

    case URI.parse(url) do
      %URI{scheme: "https", host: host, port: port, userinfo: nil} = uri
      when is_binary(host) and (port == 443 or (any_port and port in 1..65_535)) ->
        cond do
          not Hosts.exact?(host) -> {:error, {:host_invalid, host}}
          Hosts.refused_name?(host) -> {:error, {:host_refused, host}}
          true -> {:ok, %{uri | fragment: nil}}
        end

      _other ->
        {:error, {:url_invalid, url}}
    end
  end

  # Every address the host resolves to must be public, not only the first, the one
  # connected to, since which one a lookup puts first is the name's owner's to choose.
  defp resolve(host, opts) do
    case lookup(host, Keyword.get(opts, :resolver, __MODULE__.DNS)) do
      {:ok, [_ | _] = addresses} ->
        case Enum.reject(addresses, &(Address.classify(&1) == :public)) do
          [] -> {:ok, hd(addresses)}
          refused -> {:error, {:address_refused, host, Enum.map(refused, &Address.ntoa/1)}}
        end

      {:ok, []} ->
        {:error, {:unresolved, host}}

      {:error, reason} ->
        {:error, {:unresolved, host, reason}}
    end
  end

  defp lookup(host, resolver) when is_function(resolver, 1), do: resolver.(host)
  defp lookup(host, resolver) when is_atom(resolver), do: resolver.resolve(host)

  defp send_request(method, uri, address, deadline, opts) do
    max_bytes = Keyword.get(opts, :max_bytes, @max_bytes)
    host = uri.host

    # The Host header keeps a port other than 443, as a client sends it.
    host_header = if uri.port == 443, do: host, else: "#{host}:#{uri.port}"

    headers =
      [
        {"host", host_header},
        {"user-agent", Keyword.get(opts, :user_agent, "qory-apiary")}
      ] ++ Keyword.get(opts, :headers, [{"accept", "*/*"}])

    # One connection for this request alone, to the checked address
    # (`Apiary.Integrations.Fetch.Connection`), closed when the request ends. A test's
    # `plug` in `req_options` takes the connection's place.
    options =
      [
        url: %{uri | host: Address.ntoa(address)},
        method: method,
        headers: headers,
        adapter: __MODULE__.Connection,
        redirect: false,
        retry: false,
        decode_body: false,
        compressed: false,
        raw: true,
        into: collect(max_bytes)
      ]
      |> body(method, opts)
      |> Keyword.merge(Keyword.get(opts, :req_options, []))

    request =
      options
      |> Req.new()
      |> Req.Request.put_private(:fetch_connection, {address, host, deadline})

    case Req.request(request) do
      {:ok, response} -> {:ok, response}
      {:error, exception} -> {:error, {:transport, Exception.message(exception)}}
    end
  end

  defp body(options, :post, opts), do: Keyword.put(options, :body, Keyword.get(opts, :body, ""))
  defp body(options, :get, _opts), do: options

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
