defmodule Apiary.Adapters.CallAddressTest do
  # Where Qory Apiary calls an adapter (`Apiary.Adapters.CallAddress.check/2`): only the
  # adapter's https `call_url` at exactly `<adapter name>.<instance name>`, never an
  # address that is link-local or a cloud metadata address, a loopback address allowed,
  # every address of the host checked, and the first one pinned for the call. A refusal
  # has its reason: the address's form, the instance's missing host, or the forbidden
  # address and its kind.
  use ExUnit.Case, async: true

  alias Apiary.Adapters.CallAddress
  alias Apiary.FetchStub
  alias Apiary.Nodes.Node

  # The tests' instance name: the host of the endpoint's URL.
  @instance "localhost"

  defp adapter(url, name \\ "tracker"),
    do: %Node{kind: :adapter, name: name, call_url: url, call_instance_id: "instance-1"}

  # A resolver that answers `addresses` for `host` alone and fails the test for any other.
  defp answers(host, addresses) do
    fn
      ^host -> {:ok, addresses}
      other -> flunk("resolved #{other}")
    end
  end

  test "the instance name is the host of the endpoint's URL" do
    assert CallAddress.instance_host() == @instance
  end

  test "the adapter's call_url at <adapter name>.<instance name> is checked, resolved and pinned" do
    assert CallAddress.check(adapter("https://tracker.localhost/calls/")) ==
             {:ok,
              %{
                base: "https://tracker.localhost/calls/",
                host: "tracker.localhost",
                port: 443,
                address: FetchStub.public(),
                instance_id: "instance-1"
              }}

    assert {:ok, %{port: 8443, base: "https://Tracker.LOCALHOST:8443/"}} =
             CallAddress.check(adapter("https://Tracker.LOCALHOST:8443/"))
  end

  test "a private address is called: inside the instance's network the name leads there" do
    for address <- [
          {10, 1, 2, 3},
          {172, 28, 0, 5},
          {192, 168, 1, 2},
          {0xFD00, 0, 0, 0, 0, 0, 0, 1}
        ] do
      resolver = answers("tracker.localhost", [address])

      assert {:ok, %{address: ^address}} =
               CallAddress.check(adapter("https://tracker.localhost/"), resolver: resolver)
    end
  end

  test "a loopback address is called: the adapter may run on the instance's machine" do
    for address <- [{127, 0, 0, 1}, {127, 8, 9, 1}, {0, 0, 0, 0, 0, 0, 0, 1}] do
      resolver = answers("tracker.localhost", [address])

      assert {:ok, %{address: ^address, host: "tracker.localhost"}} =
               CallAddress.check(adapter("https://tracker.localhost:8443/"), resolver: resolver)
    end
  end

  test "an adapter that declares no call_url is :no_address" do
    assert CallAddress.check(%Node{kind: :adapter, name: "tracker"}) == {:error, :no_address}
  end

  test "an address that is not https, or has user information, a query or a fragment, is not allowed for its form" do
    for url <- [
          "http://tracker.localhost/",
          "https://user@tracker.localhost/",
          "https://tracker.localhost/calls/?x=1",
          "https://tracker.localhost/calls/#x",
          "https://tracker.localhost/calls",
          "tracker.localhost/"
        ] do
      assert CallAddress.check(adapter(url), resolver: &flunk("resolved #{&1}")) ==
               {:error, {:not_allowed, :form}},
             url
    end
  end

  test "a host other than exactly <adapter name>.<instance name> is not allowed for its form, and not resolved" do
    for {url, name} <- [
          {"https://other.localhost/", "tracker"},
          {"https://tracker.other.localhost/", "tracker"},
          {"https://a.tracker.localhost/", "tracker"},
          {"https://localhost/", "tracker"},
          {"https://tracker.localhost.example/", "tracker"},
          {"https://tracker-2.localhost/", "tracker"},
          {"https://tracker.localhost/", "tracker-2"},
          {"https://127.0.0.1/", "tracker"},
          {"https://[::1]/", "tracker"},
          {"https://acme tracker.localhost/", "acme tracker"}
        ] do
      assert CallAddress.check(adapter(url, name), resolver: &flunk("resolved #{&1}")) ==
               {:error, {:not_allowed, :form}},
             url
    end
  end

  test "an instance whose public address has no host calls no adapter, and resolves nothing" do
    for instance <- [nil, ""] do
      assert CallAddress.check(adapter("https://tracker.localhost/"),
               instance_host: instance,
               resolver: &flunk("resolved #{&1}")
             ) == {:error, {:not_allowed, :public_host}}
    end
  end

  test "a host with a forbidden address among its addresses is not allowed, with the first such address and its kind" do
    for {addresses, ip, kind} <- [
          {[{169, 254, 169, 254}], {169, 254, 169, 254}, :metadata},
          {[{169, 254, 1, 1}], {169, 254, 1, 1}, :link_local},
          {[{0xFE80, 0, 0, 0, 0, 0, 0, 1}], {0xFE80, 0, 0, 0, 0, 0, 0, 1}, :link_local},
          {[{0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x254}], {0xFD00, 0x0EC2, 0, 0, 0, 0, 0, 0x254},
           :metadata},
          {[{100, 100, 100, 200}], {100, 100, 100, 200}, :metadata},
          {[{192, 0, 0, 192}], {192, 0, 0, 192}, :metadata},
          {[{0, 0, 0, 0}], {0, 0, 0, 0}, :unspecified},
          {[{0, 0, 0, 0, 0, 0, 0, 0}], {0, 0, 0, 0, 0, 0, 0, 0}, :unspecified},
          {[{224, 0, 0, 1}], {224, 0, 0, 1}, :multicast},
          {[{0xFF02, 0, 0, 0, 0, 0, 0, 1}], {0xFF02, 0, 0, 0, 0, 0, 0, 1}, :multicast},
          {[{255, 255, 255, 255}], {255, 255, 255, 255}, :broadcast},
          {[{240, 0, 0, 1}], {240, 0, 0, 1}, :reserved},
          # A loopback address written inside an IPv6 one, and metadata written so: the
          # kind of the IPv4 address it carries.
          {[{0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}], {0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1}, :loopback},
          {[{0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}], {0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE},
           :metadata},
          {[{0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0x0101}],
           {0x64, 0xFF9B, 0, 0, 0, 0, 0xA9FE, 0x0101}, :link_local},
          {[{0x2002, 0xE000, 0x0001, 0, 0, 0, 0, 1}], {0x2002, 0xE000, 0x0001, 0, 0, 0, 0, 1},
           :multicast},
          # The first address loopback, a later one metadata: every address counts.
          {[{127, 0, 0, 1}, {169, 254, 169, 254}], {169, 254, 169, 254}, :metadata},
          {[FetchStub.public(), {169, 254, 169, 254}, {0, 0, 0, 0}], {169, 254, 169, 254},
           :metadata}
        ] do
      resolver = answers("tracker.localhost", addresses)

      assert CallAddress.check(adapter("https://tracker.localhost/"), resolver: resolver) ==
               {:error, {:not_allowed, {:address, ip, kind}}},
             inspect(addresses)
    end
  end

  test "a host that resolves to no address is :unresolved" do
    for answer <- [{:ok, []}, {:error, :nxdomain}] do
      assert CallAddress.check(adapter("https://tracker.localhost/"),
               resolver: fn _ -> answer end
             ) ==
               {:error, :unresolved}
    end
  end

  test "the resolver is the configured one unless the call gives one" do
    # `Apiary.FetchStub` resolves a name by its first label: `metadata` to
    # 169.254.169.254, `loopback` to 127.0.0.1.
    assert CallAddress.check(adapter("https://metadata.localhost/", "metadata")) ==
             {:error, {:not_allowed, {:address, {169, 254, 169, 254}, :metadata}}}

    assert {:ok, %{address: {127, 0, 0, 1}}} =
             CallAddress.check(adapter("https://loopback.localhost/", "loopback"))

    assert CallAddress.check(adapter("https://nowhere.localhost/", "nowhere")) ==
             {:error, :unresolved}
  end

  test "placed?/1 is the check of the address alone, without a lookup; host_for/1 is the one host" do
    assert CallAddress.host_for(%Node{name: "Tracker"}) == "tracker.localhost"
    assert CallAddress.placed?(adapter("https://tracker.localhost/calls/"))
    assert CallAddress.placed?(adapter("https://loopback.localhost/", "loopback"))
    refute CallAddress.placed?(adapter("https://other.localhost/calls/"))
    refute CallAddress.placed?(adapter("http://tracker.localhost/calls/"))
    refute CallAddress.placed?(%Node{kind: :adapter, name: "tracker"})
  end
end
