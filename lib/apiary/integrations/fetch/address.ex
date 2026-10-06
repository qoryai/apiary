defmodule Apiary.Integrations.Fetch.Address do
  @moduledoc """
  Address classifies an IP address a release's host resolves to, for
  `Apiary.Integrations.Fetch`, which connects to public addresses only.

    * **Forbidden**, whatever the operator allows: unspecified (`0.0.0.0/8`, `::`),
      loopback (`127.0.0.0/8`, `::1`), link-local (`169.254.0.0/16`, `fe80::/10`), which
      holds the cloud metadata address `169.254.169.254`, the other metadata addresses
      (`100.100.100.200`, `192.0.0.192`, and all of `fd00:ec2::/32`, where the IPv6
      metadata and pod identity addresses are), multicast, broadcast and the reserved
      `240.0.0.0/4`.
    * **Private**, allowed only for a host the operator lets resolve to one: a host
      listed in `INTEGRATION_PRIVATE_HOSTS`, or a forge listed in
      `INTEGRATION_FORGE_HOSTS` on a fetch of its own release (`Apiary.Integrations.Fetch`):
      `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, the shared space `100.64.0.0/10`,
      the rest of `192.0.0.0/24`, the benchmarking `198.18.0.0/15`, the unique local
      `fc00::/7` and Teredo's `2001::/32`.
    * **Public**: every other address.

  An IPv6 address that carries an IPv4 one, mapped (`::ffff:0:0/96`), compatible
  (`::/96`), NAT64 (`64:ff9b::/96`, and the local-use `64:ff9b:1::/48`, read as a `/96`
  within it), or 6to4 (`2002::/16`), is classified as the IPv4 address it carries.
  """

  import Bitwise

  @typedoc "What an address is to a fetch."
  @type class :: :public | :private | :forbidden

  @doc "classify/1 is the class of `address`, an `:inet` IPv4 or IPv6 tuple."
  @spec classify(:inet.ip_address()) :: class
  def classify({a, b, c, d} = ip) do
    cond do
      a == 0 or a == 127 or (a == 169 and b == 254) or a >= 224 -> :forbidden
      ip in [{100, 100, 100, 200}, {192, 0, 0, 192}] -> :forbidden
      a == 10 or (a == 172 and b in 16..31) or (a == 192 and b == 168) -> :private
      a == 100 and b in 64..127 -> :private
      a == 192 and b == 0 and c == 0 -> :private
      a == 198 and b in 18..19 -> :private
      true -> classify_public(ip, d)
    end
  end

  def classify({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: classify(v4(hi, lo))
  def classify({0, 0, 0, 0, 0, 0, 0, 0}), do: :forbidden
  def classify({0, 0, 0, 0, 0, 0, 0, 1}), do: :forbidden
  def classify({0, 0, 0, 0, 0, 0, hi, lo}), do: classify(v4(hi, lo))
  def classify({0x64, 0xFF9B, 0, 0, 0, 0, hi, lo}), do: classify(v4(hi, lo))
  # A local-use NAT64 prefix may be any /96 in the /48, so its last 32 bits are read as
  # the address it carries, whatever the bits between.
  def classify({0x64, 0xFF9B, 1, _, _, _, hi, lo}), do: classify(v4(hi, lo))
  def classify({0x2002, hi, lo, _, _, _, _, _}), do: classify(v4(hi, lo))
  def classify({0xFD00, 0x0EC2, _, _, _, _, _, _}), do: :forbidden

  def classify({first, second, _, _, _, _, _, _}) do
    cond do
      (first &&& 0xFFC0) == 0xFE80 -> :forbidden
      (first &&& 0xFF00) == 0xFF00 -> :forbidden
      (first &&& 0xFE00) == 0xFC00 -> :private
      first == 0x2001 and second == 0 -> :private
      true -> :public
    end
  end

  defp classify_public({255, 255, 255, 255}, _d), do: :forbidden
  defp classify_public(_ip, _d), do: :public

  defp v4(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  @doc "ntoa/1 is `address` written out, as a URI's host holds it."
  @spec ntoa(:inet.ip_address()) :: String.t()
  def ntoa(ip), do: ip |> :inet.ntoa() |> List.to_string()
end
