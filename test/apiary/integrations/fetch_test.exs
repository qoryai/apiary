defmodule Apiary.Integrations.FetchTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Apiary.Integrations.Fetch

  @url "https://github.com/qoryai/qory-github/releases/download/v0.1.0/description.json"

  # Every request reaches this plug, which records what it saw, any credential among it,
  # and answers by `answer`.
  defp get(url, answer, opts \\ []) do
    test = self()

    plug = fn conn ->
      send(
        test,
        {:request, conn.host, Plug.Conn.get_req_header(conn, "host"),
         Plug.Conn.get_req_header(conn, "authorization") ++
           Plug.Conn.get_req_header(conn, "private-token"), conn.request_path}
      )

      answer.(conn)
    end

    Fetch.get(url, Keyword.merge([req_options: [plug: plug]], opts))
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

  test "keeps an encoded slash in the path as it is, on the first hop and after a redirect" do
    url =
      "https://gitlab.com/api/v4/projects/acme%2Ftools%2Fshop/releases/v1.0.0/downloads/description.json"

    assert get(url, fn conn ->
             if conn.request_path =~ "/downloads/",
               do: redirect("../packages/description.json").(conn),
               else: ok("{}").(conn)
           end) == {:ok, "{}"}

    assert_received {:request, _, ["gitlab.com"], _,
                     "/api/v4/projects/acme%2Ftools%2Fshop/releases/v1.0.0/downloads/description.json"}

    assert_received {:request, _, ["gitlab.com"], _,
                     "/api/v4/projects/acme%2Ftools%2Fshop/releases/v1.0.0/packages/description.json"}
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

  test "sends no credential, on the first hop or after a redirect" do
    assert {:ok, _} =
             get(@url, fn conn ->
               if conn.request_path =~ "qory-github",
                 do: redirect("https://objects.example.com/asset").(conn),
                 else: ok("{}").(conn)
             end)

    assert_received {:request, _, ["github.com"], [], _}
    assert_received {:request, _, ["objects.example.com"], [], "/asset"}
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

  test "an IPv6 address is pinned as one" do
    assert {:ok, "{}"} = get("https://v6.example.com/description.json", ok("{}"))
    assert_received {:request, "2001:db8::10", ["v6.example.com"], _, _}
  end

  test "the log names the URL" do
    log = capture_log(fn -> get("https://private.example.com/description.json", ok("{}")) end)
    assert log =~ "https://private.example.com/description.json"
  end

  describe "request/3" do
    # Sends `method` to `url` through a plug that records the request and answers by
    # `answer`.
    defp request(method, url, answer, opts \\ []) do
      test = self()

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test, {:sent, conn.method, conn.host, conn.port, conn.req_headers, body})
        answer.(conn)
      end

      Fetch.request(method, url, Keyword.merge([req_options: [plug: plug]], opts))
    end

    test "posts the body with the headers given, and returns the last hop and the content type" do
      answer = fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/x-git-upload-pack-result", nil)
        |> Plug.Conn.send_resp(200, "0000")
      end

      assert {:ok, %{body: "0000", url: url, content_type: type}} =
               request(:post, @url, answer,
                 body: "0014command=ls-refs\n",
                 headers: [{"git-protocol", "version=2"}],
                 user_agent: "git/2.0 (test)"
               )

      assert url == @url
      assert type == "application/x-git-upload-pack-result"
      assert_received {:sent, "POST", "203.0.113.10", 443, headers, "0014command=ls-refs\n"}
      headers = Map.new(headers)
      assert headers["git-protocol"] == "version=2"
      assert headers["user-agent"] == "git/2.0 (test)"
      refute Map.has_key?(headers, "accept")
      refute Map.has_key?(headers, "authorization")
    end

    test "takes the address's port with any_port, and only then" do
      url = "https://git.example.com:8443/a/b/info/refs"

      assert {:ok, %{url: ^url}} = request(:get, url, ok("x"), any_port: true)
      assert_received {:sent, "GET", _address, 8443, headers, ""}
      assert Map.new(headers)["host"] == "git.example.com:8443"

      capture_log(fn -> assert request(:get, url, ok("x")) == {:error, :failed} end)
    end

    test "returns each failure by its class" do
      capture_log(fn ->
        assert request(:get, "https://private.example.com/x", ok("x")) == {:error, :not_allowed}
        assert request(:get, "https://nowhere.example.com/x", ok("x")) == {:error, :unreachable}

        for status <- [401, 403, 404] do
          assert request(:get, @url, &Plug.Conn.send_resp(&1, status, "")) ==
                   {:error, :not_found}
        end

        for status <- [502, 503, 504] do
          assert request(:get, @url, &Plug.Conn.send_resp(&1, status, "")) ==
                   {:error, :unreachable}
        end

        assert request(:get, @url, &Plug.Conn.send_resp(&1, 500, "")) == {:error, :failed}

        assert request(:get, @url, ok(String.duplicate("a", 11)), max_bytes: 10) ==
                 {:error, :too_large}
      end)
    end

    test "a 404 writes no log line; other failures do, with the URL" do
      assert capture_log(fn ->
               request(:get, @url, &Plug.Conn.send_resp(&1, 404, ""))
             end) == ""

      log = capture_log(fn -> request(:get, @url, &Plug.Conn.send_resp(&1, 500, "")) end)
      assert log =~ "a public git request failed"
      assert log =~ @url
    end

    test "with max_redirects 0, a redirect is not followed" do
      capture_log(fn ->
        assert request(:post, @url, redirect("https://github.com/elsewhere"), max_redirects: 0) ==
                 {:error, :failed}
      end)

      assert_received {:sent, "POST", _, _, _, _}
      refute_received {:sent, _, _, _, _, _}
    end
  end
end
