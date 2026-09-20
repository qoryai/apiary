defmodule ApiaryWeb.ConnectionLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias ApiaryWeb.RunComponents

  setup :register_and_log_in_user

  @denied %{
    "host" => "files.cdn.example",
    "decision" => "denied",
    "rule" => "",
    "outcome" => "refused"
  }
  @registry %{"host" => "registry.example", "rule" => "registry.example"}

  defp open(conn, path \\ "/hive/connections") do
    {:ok, view, _html} = live(conn, path)
    render_async(view)
    view
  end

  defp dst(host, port \\ 443, path \\ ""),
    do: RunComponents.destination_id(%{host: host, port: port, path: path})

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  test "requires sign-in" do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/hive/connections")
  end

  describe "empty and loading states" do
    test "nothing in range: widen it, with the limit of what is seen", %{conn: conn} do
      view = open(conn)
      assert has_element?(view, "h2", "No connections in the last 7 days")

      assert text(view, "#connections-empty") =~
               "Widen the range, or wait for a run to reach out."

      assert text(view, "#connections-empty") =~ "Only programs that honour the proxy"
      assert has_element?(view, "#nav-connections[aria-current=page]")
    end

    test "the first render is the table's skeleton", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/hive/connections")
      assert html =~ "connections-loading"
      render_async(view)
      refute has_element?(view, "#connections-loading")
    end

    test "filters that match nothing can be cleared", %{conn: conn, scope: scope} do
      started_run(scope, shop(), egress: [@registry])
      view = open(conn, ~p"/hive/connections?decision=denied")
      assert has_element?(view, "h2", "No connections match these filters")
      view |> element("#connections-clear") |> render_click()
      assert_patch(view, ~p"/hive/connections")
    end
  end

  describe "destinations across runs (C2, C3)" do
    setup %{scope: scope} do
      %{
        a:
          started_run(scope, Map.put(shop(), "task", "checkout-tax"),
            ago: 600,
            egress: [@registry, @denied, @denied]
          ),
        b:
          started_run(scope, shop("gitlab.example"),
            ago: 300,
            egress: [
              @registry,
              Map.merge(@registry, %{"decision" => "denied", "outcome" => "refused"}),
              @registry
            ]
          ),
        theirs: started_run(scope_fixture(), shop(), egress: [%{"host" => "secret.example"}])
      }
    end

    test "one row per destination with its reason, denied first", %{conn: conn} do
      view = open(conn)

      assert text(view, "#connections-summary") == "2 destinations 2 denied 2 runs"

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#destinations > tr.q-row")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      assert rows == [dst("files.cdn.example"), dst("registry.example")]

      cdn = text(view, "##{dst("files.cdn.example")}")
      assert cdn =~ "Denied files.cdn.example :443 CONNECT"
      assert cdn =~ "0 / 2"
      assert cdn =~ "No rule matches. Enforce mode denies it."
      assert cdn =~ "Refused"
      assert has_element?(view, "##{dst("files.cdn.example")}.q-denied")

      registry = text(view, "##{dst("registry.example")}")
      assert registry =~ "3 / 1"
      assert registry =~ "Rule registry.example · last attempt"
      assert registry =~ "Connected"

      refute render(view) =~ "secret.example"
      assert text(view, "#connections-footer") =~ "Denied destinations come first"
    end

    test "a row opens onto the runs that reached it", %{conn: conn, a: a, b: b} do
      view = open(conn)
      id = dst("registry.example")
      refute has_element?(view, "##{id}-runs")

      view |> element("##{id}-toggle") |> render_click()
      assert has_element?(view, "##{id}-toggle[aria-expanded=true][aria-controls='#{id}-runs']")
      assert text(view, "##{id}-runs") =~ "2 runs reached this destination"

      first = text(view, "##{id}-run-#{b.run_id}")
      assert first =~ "Running"
      assert first =~ "gitlab.example/acme/shop"
      assert first =~ "1 denied"

      second = text(view, "##{id}-run-#{a.run_id}")
      assert second =~ "checkout-tax #{String.slice(a.run_id, 0, 8)}"
      assert second =~ "1 allowed"

      assert has_element?(
               view,
               "##{id}-run-#{a.run_id}[href='/hive/runs/#{a.run_id}/connections']"
             )

      view |> element("##{id}-toggle") |> render_click()
      refute has_element?(view, "##{id}-runs")
    end

    test "more than ten runs page in place", %{conn: conn, scope: scope} do
      for n <- 1..11, do: started_run(scope, %{}, ago: n, egress: [%{"host" => "busy.example"}])
      view = open(conn)
      id = dst("busy.example")

      view |> element("##{id}-toggle") |> render_click()
      assert text(view, "##{id}-runs") =~ "11 runs reached this destination"
      assert text(view, "##{id}-more") == "Show 1 more"

      view |> element("##{id}-more") |> render_click()
      refute has_element?(view, "##{id}-more")
    end

    test "a destination the page does not hold opens nothing", %{conn: conn} do
      view = open(conn)

      for params <- [
            %{"host" => "nowhere.example", "port" => "443", "path" => ""},
            %{"host" => "registry.example", "port" => "444", "path" => ""},
            %{"host" => ["registry.example"], "port" => "443", "path" => ""},
            %{"id" => "dst-0"},
            %{}
          ] do
        render_click(view, "toggle_destination", params)
        render_click(view, "more_destination_runs", params)
      end

      refute has_element?(view, "tr.q-sub")
    end

    test "two hosts that collide under a short hash have their own ids, and open one at a time",
         %{conn: conn, scope: scope} do
      # :erlang.phash2 gives both of these tuples the same number.
      pair = [{"h8601.example", 443, ""}, {"h24259.example", 443, ""}]
      assert [same, same] = Enum.map(pair, &:erlang.phash2/1)

      started_run(scope, %{},
        egress: [%{"host" => "h8601.example"}, %{"host" => "h24259.example"}]
      )

      view = open(conn)

      [a, b] = ids = Enum.map(pair, fn {host, port, path} -> dst(host, port, path) end)
      assert a != b
      for id <- ids, do: assert(has_element?(view, "##{id}"))

      view |> element("##{a}-toggle") |> render_click()
      assert has_element?(view, "##{a}-runs")
      refute has_element?(view, "##{b}-runs")
      assert has_element?(view, "##{b}-toggle[aria-expanded=false]")
    end

    test "every filter is the URL; per repository is the page with repo set", %{conn: conn} do
      view = open(conn, ~p"/hive/connections?forge=gitlab.example&repo=acme/shop")

      assert text(view, "#connections-repo-note") == "Showing gitlab.example/acme/shop only. Its policy"
      assert has_element?(view, "##{dst("registry.example")}")
      refute has_element?(view, "##{dst("files.cdn.example")}")
      assert text(view, "#connections-summary") =~ "1 destination 1 denied 1 run"

      view |> element("#connections-decision button", "Allowed") |> render_click()

      assert_patch(
        view,
        ~p"/hive/connections?#{%{"decision" => "allowed", "forge" => "gitlab.example", "repo" => "acme/shop"}}"
      )

      view |> element("#filter-repo-remove") |> render_click()
      assert_patch(view, ~p"/hive/connections?decision=allowed")
      render_async(view)
      refute has_element?(view, "##{dst("files.cdn.example")}")

      view |> form("#filter-host-form") |> render_change(%{"host" => "registry.example"})
      assert_patch(view, ~p"/hive/connections?decision=allowed&host=registry.example")

      view
      |> form("#filter-since-form")
      |> render_change(%{"since" => "1h", "_target" => ["since"]})

      assert_patch(view, ~p"/hive/connections?decision=allowed&host=registry.example&since=1h")
    end

    test "a forge with a colon filters and reads back", %{conn: conn, scope: scope} do
      started_run(scope, %{"forge" => "git.example:8443", "repository" => "acme/shop"},
        egress: [%{"host" => "colon.example"}]
      )

      view = open(conn)
      value = Apiary.Runs.Filters.repo_value({"git.example:8443", "acme/shop"})
      view |> form("#filter-repo-form") |> render_change(%{"repo" => value})

      assert_patch(
        view,
        ~p"/hive/connections?#{%{"forge" => "git.example:8443", "repo" => "acme/shop"}}"
      )

      render_async(view)
      assert has_element?(view, "##{dst("colon.example")}")
      refute has_element?(view, "##{dst("registry.example")}")
      assert text(view, "#connections-repo-note") == "Showing git.example:8443/acme/shop only. Its policy"
    end

    test "the range is bounded: the widest is 90 days, and it cannot be removed", %{conn: conn} do
      view = open(conn)
      view |> element("#filter-since-remove") |> render_click()
      assert_patch(view, ~p"/hive/connections?since=90d")
      render_async(view)
      assert has_element?(view, "#filter-since-button", "last 90 days")
      refute has_element?(view, "#filter-since-remove")
    end

    test "a menu narrows on the server", %{conn: conn} do
      view = open(conn)
      # The box shows once a menu is long; what it sends narrows on the server.
      refute has_element?(view, "#filter-host-narrow")
      render_change(view, "narrow", %{"_filter" => "host", "q" => "cdn"})
      render_async(view)
      assert has_element?(view, "#filter-host-search[value=cdn]")
      assert text(view, "#filter-host-form") =~ "files.cdn.example 1"
      refute text(view, "#filter-host-form") =~ "registry.example"
    end

    test "unknown values are dropped and the URL is rewritten", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/hive/connections?decision=denied"}}} =
               live(conn, ~p"/hive/connections?decision=denied&state=failed&group=task&x=1")
    end

    test "while batches land nothing moves; the reader asks again, and what was open stays open",
         %{conn: conn, scope: scope} do
      view = open(conn)
      id = dst("registry.example")
      view |> element("##{id}-toggle") |> render_click()
      refute has_element?(view, "#connections-refresh")

      started_run(scope, shop(), ago: 1, egress: [%{"host" => "new.example"}, @registry])
      assert has_element?(view, "#connections-refresh", "New activity")
      refute has_element?(view, "##{dst("new.example")}")

      view |> element("#connections-refresh") |> render_click()
      render_async(view)
      assert has_element?(view, "##{dst("new.example")}")
      assert text(view, "##{id}-runs") =~ "3 runs reached this destination"
      refute has_element?(view, "#connections-refresh")
    end
  end
end
