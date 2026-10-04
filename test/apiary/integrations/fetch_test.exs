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

    Fetch.get(url, Keyword.merge([req_options: [plug: plug], private_hosts: []], opts))
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

  test "sends a token to a public forge's host only" do
    assert {:ok, _} = get(@url, ok("{}"), token: "forge-token")
    assert_received {:request, _, ["github.com"], ["Bearer forge-token"], _}

    assert {:ok, _} =
             get(
               "https://git.example.com/acme/shop/releases/download/v1.0.0/description.json",
               ok("{}"),
               token: "forge-token"
             )

    assert_received {:request, _, ["git.example.com"], [], _}
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
               token: "forge-token"
             )

    assert_received {:request, _, ["github.com"], ["Bearer forge-token"], _}
    assert_received {:request, _, ["objects.example.com"], [], _}
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
