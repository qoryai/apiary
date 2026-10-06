defmodule Apiary.Integrations.FetchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Apiary.Integrations.Fetch

  @url "https://github.com/qoryai/qory-github/releases/download/v0.1.0/description.json"

  # Every request reaches this plug, which records what it saw and answers by `answer`.
  defp get(url, answer, opts \\ []) do
    test = self()

    plug = fn conn ->
      send(
        test,
        {:request, conn.host, Plug.Conn.get_req_header(conn, "host"),
         Plug.Conn.get_req_header(conn, "authorization"), conn.request_path}
      )

      answer.(conn)
    end

    Fetch.get(
      url,
      Keyword.merge([req_options: [plug: plug], private_hosts: [], forge_hosts: %{}], opts)
    )
  end

  defp ok(body), do: fn conn -> Plug.Conn.send_resp(conn, 200, body) end

  defp redirect(location),
    do: fn conn ->
      conn |> Plug.Conn.put_resp_header("location", location) |> Plug.Conn.send_resp(302, "")
    end

  test "reads a body, connecting to the address the host resolved to, the name kept for Host" do
    assert get(@url, ok("{}")) == {:ok, "{}"}
    assert_received {:request, "203.0.113.10", ["github.com"], [], "/qoryai/qory-github/" <> _}
  end

  test "refuses a host that resolves to a private address, and asks nothing" do
    log =
      capture_log(fn ->
        assert get("https://private.example.com/x/description.json", ok("{}")) ==
                 {:error, :fetch_failed}
      end)

    assert log =~ "address_refused"
    refute_received {:request, _, _, _, _}
  end

  test "refuses loopback, metadata, unique local addresses and a mix of public and private" do
    for host <- ~w(loopback metadata ula mixed) do
      capture_log(fn ->
        assert get("https://#{host}.example.com/description.json", ok("{}")) ==
                 {:error, :fetch_failed}
      end)
    end

    refute_received {:request, _, _, _, _}
  end

  test "refuses what the resolver cannot find, and an answer other than 200" do
    capture_log(fn ->
      assert get("https://nowhere.example.com/description.json", ok("{}")) ==
               {:error, :fetch_failed}

      assert get(@url, fn conn -> Plug.Conn.send_resp(conn, 404, "") end) ==
               {:error, :fetch_failed}
    end)
  end

  test "refuses http, another port, userinfo and an address for a host" do
    for url <- [
          "http://github.com/description.json",
          "https://github.com:8443/description.json",
          "https://dana@github.com/description.json",
          "https://203.0.113.10/description.json",
          "https://localhost/description.json"
        ] do
      capture_log(fn -> assert get(url, ok("{}")) == {:error, :fetch_failed} end)
    end

    refute_received {:request, _, _, _, _}
  end

  test "follows a redirect to a public host, pinned again" do
    assert get(@url, fn conn ->
             if conn.request_path =~ "qory-github",
               do: redirect("https://objects.example.com/asset").(conn),
               else: ok("{}").(conn)
           end) == {:ok, "{}"}

    assert_received {:request, _, ["github.com"], _, _}
    assert_received {:request, "203.0.113.10", ["objects.example.com"], _, "/asset"}
  end

  test "refuses a redirect to a private address, or to http" do
    for location <- [
          "https://private.example.com/asset",
          "http://objects.example.com/asset",
          "https://169.254.169.254/latest"
        ] do
      capture_log(fn -> assert get(@url, redirect(location)) == {:error, :fetch_failed} end)
    end
  end

  test "stops after too many hops" do
    log =
      capture_log(fn ->
        assert get(@url, redirect("https://github.com/again"), max_redirects: 3) ==
                 {:error, :fetch_failed}
      end)

    assert log =~ "too_many_redirects"
    for _ <- 1..4, do: assert_received({:request, _, _, _, _})
    refute_received {:request, _, _, _, _}
  end

  test "refuses a body over the cap, declared or not" do
    log =
      capture_log(fn ->
        assert get(@url, ok(String.duplicate("a", 101)), max_bytes: 100) ==
                 {:error, :fetch_failed}
      end)

    assert log =~ "too_large"

    assert get(@url, ok(String.duplicate("a", 100)), max_bytes: 100) ==
             {:ok, String.duplicate("a", 100)}
  end

  test "gives up on a fetch slower than its time" do
    slow = fn conn ->
      Process.sleep(500)
      ok("{}").(conn)
    end

    log = capture_log(fn -> assert get(@url, slow, timeout: 50) == {:error, :fetch_failed} end)
    assert log =~ "timeout"
  end

  test "sends a token to the public forge the fetch is for, and to no other host" do
    assert {:ok, _} = get(@url, ok("{}"), token: "forge-token", forge_host: "github.com")
    assert_received {:request, _, ["github.com"], ["Bearer forge-token"], _}

    url = "https://git.example.com/acme/shop/releases/download/v1.0.0/description.json"

    assert {:ok, _} = get(url, ok("{}"), token: "forge-token", forge_host: "git.example.com")
    assert_received {:request, _, ["git.example.com"], [], _}

    assert {:ok, _} = get(@url, ok("{}"), token: "forge-token", forge_host: "gitlab.com")
    assert_received {:request, _, ["github.com"], [], _}
  end

  test "sends no token on a fetch for no forge, whatever token it is given" do
    forges = %{"git.example.com" => "forgejo"}

    for url <- [@url, "https://git.example.com/acme/shop/description.json"] do
      assert {:ok, _} = get(url, ok("{}"), token: "forge-token", forge_hosts: forges)
      assert_received {:request, _, _, [], _}
    end
  end

  test "never sends the token on to the host a redirect names" do
    assert {:ok, _} =
             get(
               @url,
               fn conn ->
                 if conn.request_path =~ "qory-github",
                   do: redirect("https://objects.example.com/asset").(conn),
                   else: ok("{}").(conn)
               end,
               token: "forge-token",
               forge_host: "github.com"
             )

    assert_received {:request, _, ["github.com"], ["Bearer forge-token"], _}
    assert_received {:request, _, ["objects.example.com"], [], _}
  end

  test "keeps the token on a redirect to the forge's own host" do
    assert {:ok, _} =
             get(
               @url,
               fn conn ->
                 if conn.request_path =~ "qory-github",
                   do: redirect("https://github.com/acme/asset").(conn),
                   else: ok("{}").(conn)
               end,
               token: "forge-token",
               forge_host: "github.com"
             )

    assert_received {:request, _, ["github.com"], ["Bearer forge-token"], "/qoryai/" <> _}
    assert_received {:request, _, ["github.com"], ["Bearer forge-token"], "/acme/asset"}
  end

  test "sends a token to a forge the operator lists, and to no other host on the lists" do
    url = "https://private.example.com/acme/shop/releases/download/v1.0.0/description.json"
    forges = %{"private.example.com" => "forgejo"}
    opts = [token: "forge-token", forge_host: "private.example.com"]

    assert {:ok, _} = get(url, ok("{}"), [forge_hosts: forges] ++ opts)
    assert_received {:request, "10.1.2.3", ["private.example.com"], ["Bearer forge-token"], _}

    assert {:ok, _} = get(url, ok("{}"), [private_hosts: ["private.example.com"]] ++ opts)
    assert_received {:request, "10.1.2.3", ["private.example.com"], [], _}
  end

  test "never sends a listed forge's token on to the host a redirect names" do
    url = "https://git.example.com/acme/shop/releases/download/v1.0.0/description.json"

    assert {:ok, _} =
             get(
               url,
               fn conn ->
                 if conn.request_path =~ "acme/shop",
                   do: redirect("https://objects.example.com/asset").(conn),
                   else: ok("{}").(conn)
               end,
               token: "forge-token",
               forge_host: "git.example.com",
               forge_hosts: %{"git.example.com" => "forgejo", "objects.example.com" => "forgejo"}
             )

    assert_received {:request, _, ["git.example.com"], ["Bearer forge-token"], _}
    assert_received {:request, _, ["objects.example.com"], [], "/asset"}
  end

  test "reaches a listed forge's private address on a fetch of its own release" do
    url = "https://private.example.com/acme/shop/releases/download/v1.0.0/description.json"
    forges = %{"private.example.com" => "gitlab"}

    assert {:ok, "{}"} =
             get(url, ok("{}"), forge_hosts: forges, forge_host: "private.example.com")

    assert_received {:request, "10.1.2.3", ["private.example.com"], _, _}

    log =
      capture_log(fn ->
        assert get(url, ok("{}"),
                 forge_hosts: %{"git.example.com" => "gitlab"},
                 forge_host: "private.example.com"
               ) == {:error, :fetch_failed}
      end)

    assert log =~ "address_refused"
    refute_received {:request, _, _, _, _}
  end

  test "lends a listed forge's allowance to no fetch that starts elsewhere" do
    log =
      capture_log(fn ->
        assert get(@url, redirect("https://private.example.com/acme/admin"),
                 token: "forge-token",
                 forge_hosts: %{"private.example.com" => "gitlab"},
                 forge_host: "private.example.com"
               ) == {:error, :fetch_failed}
      end)

    assert log =~ "address_refused"
    assert_received {:request, _, ["github.com"], [], _}
    refute_received {:request, "10.1.2.3", _, _, _}
  end

  test "reaches no listed forge's private address from a release elsewhere, or a URL" do
    forges = %{"private.example.com" => "gitlab"}

    log =
      capture_log(fn ->
        assert get(@url, redirect("https://private.example.com/acme/admin"),
                 forge_hosts: forges,
                 forge_host: "github.com"
               ) == {:error, :fetch_failed}
      end)

    assert log =~ "address_refused"
    assert_received {:request, _, ["github.com"], _, _}
    refute_received {:request, _, ["private.example.com"], _, _}

    capture_log(fn ->
      assert get("https://private.example.com/acme/shop/description.json", ok("{}"),
               forge_hosts: forges
             ) == {:error, :fetch_failed}
    end)

    refute_received {:request, _, _, _, _}
  end

  test "reaches no loopback or metadata address of a listed forge" do
    for host <- ~w(loopback.example.com metadata.example.com) do
      log =
        capture_log(fn ->
          assert get(
                   "https://#{host}/acme/shop/releases/download/v1.0.0/description.json",
                   ok("{}"),
                   forge_hosts: %{host => "forgejo"},
                   forge_host: host
                 ) == {:error, :fetch_failed}
        end)

      assert log =~ "address_refused"
    end

    refute_received {:request, _, _, _, _}
  end

  test "resolves the host again on every hop, and refuses an answer changed to loopback" do
    lookups = :counters.new(1, [])

    resolver = fn
      "rebind.example.com" ->
        :counters.add(lookups, 1, 1)

        if :counters.get(lookups, 1) == 1,
          do: {:ok, [Apiary.FetchStub.public()]},
          else: {:ok, [{127, 0, 0, 1}]}

      host ->
        Apiary.FetchStub.resolve(host)
    end

    log =
      capture_log(fn ->
        assert get(
                 "https://rebind.example.com/acme/shop/description.json",
                 redirect("https://rebind.example.com/again"),
                 resolver: resolver
               ) == {:error, :fetch_failed}
      end)

    assert log =~ "address_refused"
    assert :counters.get(lookups, 1) == 2
    assert_received {:request, "203.0.113.10", ["rebind.example.com"], _, "/acme/shop/" <> _}
    refute_received {:request, _, _, _, _}
  end

  test "reaches a private address only for a host on the operator's allow list" do
    url = "https://private.example.com/acme/shop/releases/download/v1.0.0/description.json"
    assert {:ok, "{}"} = get(url, ok("{}"), private_hosts: ["private.example.com"])
    assert_received {:request, "10.1.2.3", ["private.example.com"], _, _}

    capture_log(fn ->
      assert get("https://loopback.example.com/description.json", ok("{}"),
               private_hosts: ["loopback.example.com"]
             ) ==
               {:error, :fetch_failed}
    end)
  end

  test "the allow list is host names, and a wrong entry stops the boot" do
    assert Fetch.parse_private_hosts(nil) == []

    assert Fetch.parse_private_hosts(" git.example.com, Forge.Example.com ") == [
             "git.example.com",
             "forge.example.com"
           ]

    assert_raise ArgumentError, fn -> Fetch.parse_private_hosts("10.0.0.1") end
    assert_raise ArgumentError, fn -> Fetch.parse_private_hosts("forge.local") end
  end

  test "an IPv6 address is pinned as one" do
    assert {:ok, "{}"} = get("https://v6.example.com/description.json", ok("{}"))
    assert_received {:request, "2001:db8::10", ["v6.example.com"], _, _}
  end

  test "the log names the URL and never the token" do
    log =
      capture_log(fn ->
        get("https://private.example.com/description.json", ok("{}"), token: "forge-token")
      end)

    assert log =~ "private.example.com"
    refute log =~ "forge-token"
  end
end
