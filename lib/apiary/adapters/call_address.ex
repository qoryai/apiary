defmodule Apiary.Adapters.CallAddress do
  # Where Qory Apiary calls an adapter (`Apiary.Adapters.Calls`): the `call_url` the
  # adapter declared at its latest start (`Apiary.Adapters.declare/2`), checked before
  # every call, and the address the call connects to.
  #
  # `check/2`, in this order:
  #
  #   1. `{:error, :no_address}` when the adapter declares no `call_url`: Qory Apiary makes
  #      no call to it;
  #   2. `{:error, :not_allowed}` for an address that is not `https://`, has user
  #      information, a query or a fragment, or a path that does not end with `/`, and for
  #      a host that is not exactly the adapter's name as its node has it, then `.`, then
  #      the instance's public name (the host of `PUBLIC_URL`), compared without case;
  #      always when `PUBLIC_URL` has no host. An adapter named `tracker` on the instance
  #      `qory.example.com` is called at `https://tracker.qory.example.com/…` and nowhere
  #      else;
  #   3. the host is resolved, every address it has: `{:error, :not_allowed}` when any is
  #      forbidden (`Apiary.Integrations.Fetch.Address`: loopback, link-local with the
  #      cloud metadata address `169.254.169.254`, the other metadata addresses,
  #      unspecified, multicast and broadcast), `{:error, :unresolved}` when it has none.
  #      A private address is allowed: inside the instance's network the adapter's name
  #      leads to the reverse proxy's private address, and step 2 limits the host;
  #   4. `{:ok, target}`: the base address, the host, the port, the first address, which
  #      the call connects to with the host kept for `Host`, SNI and the certificate's
  #      check, so a second lookup cannot send it elsewhere, and the adapter's instance id
  #      the call is signed for.
  #
  # The resolver is `opts[:resolver]`, else `config :apiary, Apiary.Adapters.Calls,
  # resolver:`, else the system's (`Apiary.Integrations.Fetch.DNS`): a module with
  # `resolve/1` or a function of a host.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  alias Apiary.Adapters.Wire
  alias Apiary.Integrations.Fetch
  alias Apiary.Integrations.Fetch.Address
  alias Apiary.Nodes.Node

  @typedoc "Where a call goes: checked, resolved and pinned."
  @type target :: %{
          base: String.t(),
          host: String.t(),
          port: :inet.port_number(),
          address: :inet.ip_address(),
          instance_id: String.t()
        }

  @typedoc "Why an adapter is not called."
  @type refusal :: :no_address | :not_allowed | :unresolved

  @doc false
  @spec check(Node.t(), keyword) :: {:ok, target} | {:error, refusal}
  def check(adapter, opts \\ [])

  def check(%Node{kind: :adapter, call_url: url, call_instance_id: instance_id} = adapter, opts)
      when is_binary(url) and is_binary(instance_id) do
    with {:ok, uri} <- parse(url),
         :ok <- host(uri.host, adapter),
         {:ok, address} <- resolve(uri.host, opts) do
      {:ok,
       %{
         base: url,
         host: uri.host,
         port: uri.port,
         address: address,
         instance_id: instance_id
       }}
    end
  end

  def check(%Node{kind: :adapter}, _opts), do: {:error, :no_address}

  @doc false
  # placed?/1 is whether the adapter's `call_url` passes steps 1 and 2 of `check/2`,
  # without a lookup: what the instance admin's page of the adapter shows.
  @spec placed?(Node.t()) :: boolean
  def placed?(%Node{kind: :adapter, call_url: url} = adapter) when is_binary(url) do
    with {:ok, uri} <- parse(url), :ok <- host(uri.host, adapter), do: true, else: (_ -> false)
  end

  def placed?(%Node{}), do: false

  @doc false
  # host_for/1 is the one host the adapter is called at, `<adapter name>.<instance name>`,
  # in lower case.
  @spec host_for(Node.t()) :: String.t()
  def host_for(%Node{name: name}), do: String.downcase("#{name}.#{instance_host()}")

  # A `call_url` as the contract allows one (`Apiary.Adapters.Wire.call_url?/1`): https,
  # a host, an optional port and a path that ends with `/`, and nothing else.
  defp parse(url) do
    with true <- Wire.call_url?(url),
         %URI{scheme: "https", userinfo: nil, query: nil, fragment: nil, host: host} = uri
         when is_binary(host) and host != "" <- URI.parse(url) do
      {:ok, uri}
    else
      _other -> {:error, :not_allowed}
    end
  end

  # Exactly `<adapter name>.<instance's public name>`.
  defp host(host, %Node{name: name}) when is_binary(name) do
    case instance_host() do
      instance when is_binary(instance) and instance != "" ->
        if String.downcase(host) == String.downcase(name <> "." <> instance),
          do: :ok,
          else: {:error, :not_allowed}

      _none ->
        {:error, :not_allowed}
    end
  end

  defp host(_host, _adapter), do: {:error, :not_allowed}

  @doc false
  # The host of the instance's public address, `PUBLIC_URL`'s.
  @spec instance_host() :: String.t() | nil
  def instance_host, do: URI.parse(ApiaryWeb.Endpoint.url()).host

  # Every address the host resolves to must be one a call may reach, not only the first,
  # the one connected to, since which one a lookup puts first is the name's owner's to
  # choose.
  defp resolve(host, opts) do
    resolver =
      Keyword.get_lazy(opts, :resolver, fn ->
        :apiary
        |> Application.get_env(Apiary.Adapters.Calls, [])
        |> Keyword.get(:resolver, Fetch.DNS)
      end)

    case lookup(host, resolver) do
      {:ok, [_ | _] = addresses} ->
        if Enum.any?(addresses, &(Address.classify(&1) == :forbidden)),
          do: {:error, :not_allowed},
          else: {:ok, hd(addresses)}

      _none ->
        {:error, :unresolved}
    end
  end

  defp lookup(host, resolver) when is_function(resolver, 1), do: resolver.(host)
  defp lookup(host, resolver) when is_atom(resolver), do: resolver.resolve(host)
end
