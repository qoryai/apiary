defmodule Apiary.Adapters.CallAddress do
  # Where Qory Apiary calls an adapter (`Apiary.Adapters.Calls`): the `call_url` the
  # adapter declared at its latest start (`Apiary.Adapters.declare/2`), checked before
  # every call, and the address the call connects to.
  #
  # `check/2`, in this order:
  #
  #   1. `{:error, :no_address}` when the adapter declares no `call_url`: Qory Apiary makes
  #      no call to it;
  #   2. `{:error, {:not_allowed, :form}}` for an address that is not `https://`, has
  #      user information, a query or a fragment, or a path that does not end with `/`,
  #      and for a host that is not exactly the adapter's name as its node has it, then
  #      `.`, then the instance's public name (the host of `PUBLIC_URL`), compared without
  #      case; `{:error, {:not_allowed, :public_host}}` when `PUBLIC_URL` has no host. An
  #      adapter named `tracker` on the instance `qory.example.com` is called at
  #      `https://tracker.qory.example.com/…` and nowhere else;
  #   3. the host is resolved, every address it has: `{:error, {:not_allowed, {:address,
  #      ip, kind}}}` for the first address that is forbidden
  #      (`Apiary.Integrations.Fetch.Address`), its kind `:link_local`, `:metadata` (the
  #      cloud metadata address `169.254.169.254` and the others), `:unspecified`,
  #      `:multicast`, `:broadcast`, `:reserved` (`240.0.0.0/4`) or `:loopback`;
  #      `{:error, :unresolved}` when it has none. A private
  #      address is allowed: inside the instance's network the adapter's name leads to the
  #      reverse proxy's private address, and step 2 limits the host. A loopback address,
  #      `127.0.0.0/8` or `::1`, is allowed too, which `Fetch.Address` forbids: an adapter
  #      may run on the instance's machine. A loopback address written inside an IPv6 one,
  #      such as `::ffff:127.0.0.1`, stays forbidden;
  #   4. `{:ok, target}`: the base address, the host, the port, the first address, which
  #      the call connects to with the host kept for `Host`, SNI and the certificate's
  #      check, so a second lookup cannot send it elsewhere, and the adapter's instance id
  #      the call is signed for.
  #
  # The instance's public name is `opts[:instance_host]`, else the host of `PUBLIC_URL`
  # (`instance_host/0`). The resolver is `opts[:resolver]`, else `config :apiary,
  # Apiary.Adapters.Calls, resolver:`, else the system's (`Apiary.Integrations.Fetch.DNS`):
  # a module with `resolve/1` or a function of a host.
  #
  # The module reference leaves out this module of the `factory` feature.
  @moduledoc false

  import Bitwise

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

  @typedoc "The kind of a forbidden address an adapter's host resolves to."
  @type kind ::
          :link_local | :metadata | :unspecified | :multicast | :broadcast | :reserved | :loopback

  @typedoc "Why an address is not allowed."
  @type not_allowed :: :form | :public_host | {:address, :inet.ip_address(), kind}

  @typedoc "Why an adapter is not called."
  @type refusal :: :no_address | {:not_allowed, not_allowed} | :unresolved

  @doc false
  @spec check(Node.t(), keyword) :: {:ok, target} | {:error, refusal}
  def check(adapter, opts \\ [])

  def check(%Node{kind: :adapter, call_url: url, call_instance_id: instance_id} = adapter, opts)
      when is_binary(url) and is_binary(instance_id) do
    with {:ok, uri} <- parse(url),
         :ok <- host(uri.host, adapter, opts),
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
    with {:ok, uri} <- parse(url),
         :ok <- host(uri.host, adapter, []),
         do: true,
         else: (_ -> false)
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
      _other -> {:error, {:not_allowed, :form}}
    end
  end

  # Exactly `<adapter name>.<instance's public name>`.
  defp host(host, %Node{name: name}, opts) when is_binary(name) do
    case Keyword.get_lazy(opts, :instance_host, &instance_host/0) do
      instance when is_binary(instance) and instance != "" ->
        if String.downcase(host) == String.downcase(name <> "." <> instance),
          do: :ok,
          else: {:error, {:not_allowed, :form}}

      _none ->
        {:error, {:not_allowed, :public_host}}
    end
  end

  defp host(_host, _adapter, _opts), do: {:error, {:not_allowed, :form}}

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
        case Enum.reject(addresses, &allowed?/1) do
          [] -> {:ok, hd(addresses)}
          [ip | _] -> {:error, {:not_allowed, {:address, ip, kind(ip)}}}
        end

      _none ->
        {:error, :unresolved}
    end
  end

  # Step 3's rule: `Fetch.Address`'s, with loopback allowed.
  defp allowed?({127, _, _, _}), do: true
  defp allowed?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp allowed?(address), do: Address.classify(address) != :forbidden

  # The kind of a forbidden address, by `Fetch.Address.classify/1`'s forbidden classes in
  # its order: an IPv6 address that carries an IPv4 one is the kind of the IPv4 one.
  defp kind({169, 254, 169, 254}), do: :metadata
  defp kind({100, 100, 100, 200}), do: :metadata
  defp kind({192, 0, 0, 192}), do: :metadata
  defp kind({0, _, _, _}), do: :unspecified
  defp kind({127, _, _, _}), do: :loopback
  defp kind({169, 254, _, _}), do: :link_local
  defp kind({255, 255, 255, 255}), do: :broadcast
  defp kind({a, _, _, _}) when a in 224..239, do: :multicast
  defp kind({_, _, _, _}), do: :reserved
  defp kind({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: kind(v4(hi, lo))
  defp kind({0, 0, 0, 0, 0, 0, 0, 0}), do: :unspecified
  defp kind({0, 0, 0, 0, 0, 0, 0, 1}), do: :loopback
  defp kind({0, 0, 0, 0, 0, 0, hi, lo}), do: kind(v4(hi, lo))
  defp kind({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: kind(v4(hi, lo))
  defp kind({0x64, 0xFF9B, 1, _, _, _, hi, lo}), do: kind(v4(hi, lo))
  defp kind({0x2002, hi, lo, _, _, _, _, _}), do: kind(v4(hi, lo))
  defp kind({0xFD00, 0x0EC2, _, _, _, _, _, _}), do: :metadata
  defp kind({first, _, _, _, _, _, _, _}) when (first &&& 0xFFC0) == 0xFE80, do: :link_local
  defp kind({_, _, _, _, _, _, _, _}), do: :multicast

  defp v4(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  defp lookup(host, resolver) when is_function(resolver, 1), do: resolver.(host)
  defp lookup(host, resolver) when is_atom(resolver), do: resolver.resolve(host)
end
