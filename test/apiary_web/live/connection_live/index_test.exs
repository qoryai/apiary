defmodule ApiaryWeb.ConnectionLive.IndexTest do
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures, only: [tool_invocation_data: 1]
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

  defp open(conn, %{workspace: _} = scope), do: open(conn, workspace_path(scope, "/network"))

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 2_000)
    view
  end

  # What the policy made of a row, and the links to it, are on the page only where the
  # instance has `security`; the rows are there in every configuration.
  defp security?, do: Apiary.Features.on?(:security)

  # The note of a page filtered to one target, with its policy's link where there is one.
  defp target_note(target),
    do: "Showing #{target} only." <> if(security?(), do: " Its policy", else: "")

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

  test "requires sign-in", %{scope: scope} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} =
             live(build_conn(), ~p"/#{scope.organisation}/#{scope.workspace}/network")
  end

  test "the page's old paths, the workspace's and a run's, send on here with the query, for good",
       %{conn: conn, scope: scope} do
    org = scope.organisation
    ws = scope.workspace

    for {old, new} <- [
          {~p"/#{org}/#{ws}/connections", ~p"/#{org}/#{ws}/network"},
          {~p"/#{org}/#{ws}/connections?decision=denied&since=30d",
           ~p"/#{org}/#{ws}/network?decision=denied&since=30d"},
          {~p"/#{org}/#{ws}/runs/r-1/connections?decision=denied",
           ~p"/#{org}/#{ws}/runs/r-1/network?decision=denied"}
        ] do
      assert redirected_to(get(conn, old), 301) == new
    end
  end

  describe "empty and loading states" do
    test "nothing in range: widen it, with the limit of what is seen", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      assert has_element?(view, "h2", "No connections in the last 7 days")

      assert text(view, "#connections-empty") =~
               "Widen the range, or wait for a run to reach out."

      assert text(view, "#connections-empty") =~ "Only programs that honour the proxy"
      assert has_element?(view, "#nav-network[aria-current=page]")
    end

    test "the first render is the table's skeleton", %{conn: conn, scope: scope} do
      {:ok, view, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/network")
      assert html =~ "connections-loading"
      render_async(view, 2_000)
      refute has_element?(view, "#connections-loading")
    end

    test "filters that match nothing can be cleared", %{conn: conn, scope: scope} do
      started_run(scope, shop(), egress: [@registry])
      view = open(conn, ~p"/#{scope.organisation}/#{scope.workspace}/network?decision=denied")
      assert has_element?(view, "h2", "No connections match these filters")
      view |> element("#connections-clear") |> render_click()
      assert_patch(view, ~p"/#{scope.organisation}/#{scope.workspace}/network")
    end
  end

  describe "tool invocations" do
    setup %{scope: scope} do
      call = tool_invocation_data(%{})

      refused =
        tool_invocation_data(%{
          "path" => "/media/acme/other/checkout.png",
          "path_rule" => "",
          "decision" => "denied",
          "outcome" => "refused"
        })
        |> Map.delete("status")

      started_run(scope, shop(), egress: [@registry, call, call, refused])
      :ok
    end

    test "are destinations that read as calls to their tool; a refused request is a denial",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)
      id = dst("files.tools.internal", 443, "/media/acme/shop/checkout.png")

      assert text(view, "##{id} .q-dest") ==
               "Tool files PUT /media/acme/shop/checkout.png files.tools.internal:443"

      assert has_element?(view, "##{id} .q-dest-tool .q-tool-name", "files")

      if security?(),
        do: assert(text(view, "##{id} .q-why") =~ "Handed to files by rule files.tools.internal"),
        else: refute(has_element?(view, "##{id} .q-why"))

      assert text(view, "##{id} .q-outcome") == "Answered 200"

      # Refused on its path, the request never reached the tool: host first, no tool mark.
      refused = dst("files.tools.internal", 443, "/media/acme/other/checkout.png")
      assert has_element?(view, "##{refused}.q-denied .q-dest")
      refute has_element?(view, "##{refused} .q-dest-tool")

      assert text(view, "##{refused} .q-dest") =~
               ~r"^files.tools.internal\s?:443 /media/acme/other/checkout.png$"

      if security?() do
        assert text(view, "##{refused} .q-why") =~ "Host allowed, no path rule matches."
        assert text(view, "##{refused} .q-why") =~ "Refused before reaching the tool files"
      end

      assert text(view, "##{refused} .q-outcome") == "Refused"

      # The plain host beside them reads as it did.
      refute has_element?(view, "##{dst("registry.example")} .q-dest-tool")
      assert text(view, "##{dst("registry.example")} .q-outcome") == "Connected"
    end

    test "tools=1 keeps the tool invocations, not the refused requests, and the Filter menu sets it",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)
      refute has_element?(view, "#connections-tools-form input[name=tools][checked]")

      view |> form("#connections-tools-form") |> render_change(%{"tools" => "1"})
      assert_patch(view, ~p"/#{scope.organisation}/#{scope.workspace}/network?tools=1")
      render_async(view, 2_000)

      assert has_element?(view, "#connections-tools-form input[name=tools][checked]")
      assert text(view, "#connections-token-tools") =~ "tools: yes"
      assert text(view, "#connections-summary") =~ "1 destination matches"
      refute has_element?(view, "##{dst("registry.example")}")

      refute has_element?(
               view,
               "##{dst("files.tools.internal", 443, "/media/acme/other/checkout.png")}"
             )

      assert has_element?(
               view,
               "##{dst("files.tools.internal", 443, "/media/acme/shop/checkout.png")}"
             )

      view |> element("#connections-token-tools a") |> render_click()
      assert_patch(view, ~p"/#{scope.organisation}/#{scope.workspace}/network")
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

    test "one row per destination with its reason, denied first", %{conn: conn, scope: scope} do
      view = open(conn, scope)

      # The views count the destinations; a summary line is for a narrowed list only.
      assert text(view, "#connections-view-all") == "All 2"
      assert text(view, "#connections-view-denied") == "Denied 2"
      assert text(view, "#connections-view-allowed") == "Allowed 1"
      refute has_element?(view, "#connections-summary")
      assert has_element?(view, "#connections-sort-denied[aria-checked=true]")

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#destinations > tr.q-row")
        |> Enum.map(&(&1 |> LazyHTML.attribute("id") |> hd()))

      assert rows == [dst("files.cdn.example"), dst("registry.example")]

      # The title is the host and its port (a path when there is one); the split says
      # allowed and denied in words, the denied number red only when there is one.
      cdn = text(view, "##{dst("files.cdn.example")}")
      assert text(view, "##{dst("files.cdn.example")} .q-dest") == "files.cdn.example :443"
      assert cdn =~ "0 / 2 0 allowed, 2 denied"
      assert has_element?(view, "##{dst("files.cdn.example")} .q-cx-split .q-cx-bad", "2")
      assert has_element?(view, "##{dst("registry.example")} .q-cx-split .q-cx-bad", "1")

      if security?(),
        do: assert(cdn =~ "No rule matches. Enforce mode denies it."),
        else: refute(cdn =~ "No rule matches")

      assert cdn =~ "Refused"
      assert has_element?(view, "##{dst("files.cdn.example")}.q-denied")

      registry = text(view, "##{dst("registry.example")}")
      assert registry =~ "3 / 1"

      if security?(),
        do: assert(registry =~ "Rule registry.example · last attempt"),
        else: refute(registry =~ "Rule")

      assert registry =~ "Connected"

      refute render(view) =~ "secret.example"
      assert text(view, "#connections-footer") == "1–2 of 2"
    end

    test "a row opens onto the runs that reached it", %{conn: conn, a: a, b: b, scope: scope} do
      view = open(conn, scope)
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
               "##{id}-run-#{a.run_id}[href='#{workspace_path(scope)}/runs/#{a.run_id}/network']"
             )

      view |> element("##{id}-toggle") |> render_click()
      refute has_element?(view, "##{id}-runs")
    end

    test "more than ten runs page in place", %{conn: conn, scope: scope} do
      for n <- 1..11, do: started_run(scope, %{}, ago: n, egress: [%{"host" => "busy.example"}])
      view = open(conn, scope)
      id = dst("busy.example")

      view |> element("##{id}-toggle") |> render_click()
      assert text(view, "##{id}-runs") =~ "11 runs reached this destination"
      assert text(view, "##{id}-more") == "Show 1 more"

      view |> element("##{id}-more") |> render_click()
      refute has_element?(view, "##{id}-more")
    end

    test "a destination the page does not hold opens nothing", %{conn: conn, scope: scope} do
      view = open(conn, scope)

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

      view = open(conn, scope)

      [a, b] = ids = Enum.map(pair, fn {host, port, path} -> dst(host, port, path) end)
      assert a != b
      for id <- ids, do: assert(has_element?(view, "##{id}"))

      view |> element("##{a}-toggle") |> render_click()
      assert has_element?(view, "##{a}-runs")
      refute has_element?(view, "##{b}-runs")
      assert has_element?(view, "##{b}-toggle[aria-expanded=false]")
    end

    test "every filter is the URL; per target is the page with repo set", %{
      conn: conn,
      scope: scope
    } do
      view =
        open(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/network?system=gitlab.example&target=acme/shop"
        )

      assert text(view, "#connections-target-note") == target_note("gitlab.example/acme/shop")

      assert has_element?(view, "##{dst("registry.example")}")
      refute has_element?(view, "##{dst("files.cdn.example")}")
      assert text(view, "#connections-summary") =~ "1 destination matches across 1 run"
      assert text(view, "#connections-view-all") == "All 1"
      assert text(view, "#connections-view-denied") == "Denied 1"
      assert has_element?(view, "#connections-view-all[aria-current=page]")

      view |> element("#connections-view-allowed") |> render_click()

      assert_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/network?#{%{"decision" => "allowed", "system" => "gitlab.example", "target" => "acme/shop"}}"
      )

      render_async(view, 2_000)
      assert has_element?(view, "#connections-view-allowed[aria-current=page]")
      refute has_element?(view, "#connections-token-decision")
      view |> element("#connections-token-target a") |> render_click()

      assert_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/network?decision=allowed"
      )

      render_async(view, 2_000)
      refute has_element?(view, "##{dst("files.cdn.example")}")

      view |> form("#filter-host-form") |> render_change(%{"host" => "registry.example"})

      assert_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/network?decision=allowed&host=registry.example"
      )

      view
      |> form("#filter-since-form")
      |> render_change(%{"since" => "1h", "_target" => ["since"]})

      assert_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/network?decision=allowed&host=registry.example&since=1h"
      )
    end

    test "a system with a colon filters and reads back", %{conn: conn, scope: scope} do
      started_run(scope, %{"forge" => "git.example:8443", "repository" => "acme/shop"},
        egress: [%{"host" => "colon.example"}]
      )

      view = open(conn, scope)
      value = Apiary.Runs.Filters.target_value({"git.example:8443", "acme/shop"})
      view |> form("#filter-target-form") |> render_change(%{"target" => value})

      assert_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/network?#{%{"system" => "git.example:8443", "target" => "acme/shop"}}"
      )

      render_async(view, 2_000)
      assert has_element?(view, "##{dst("colon.example")}")
      refute has_element?(view, "##{dst("registry.example")}")

      assert text(view, "#connections-target-note") == target_note("git.example:8443/acme/shop")
    end

    test "the range is bounded: the widest is 90 days, and removing one is the last seven", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)
      refute has_element?(view, "#connections-token-started")
      refute has_element?(view, "#filter-since-form input[value=all]")

      view
      |> form("#filter-since-form")
      |> render_change(%{"since" => "90d", "_target" => ["since"]})

      assert_patch(view, ~p"/#{scope.organisation}/#{scope.workspace}/network?since=90d")
      render_async(view, 2_000)
      assert text(view, "#connections-token-started") =~ "seen: 90d"
      assert text(view, "#connections-filter-value-since") == "last 90 days"

      view |> element("#connections-token-started a") |> render_click()
      assert_patch(view, ~p"/#{scope.organisation}/#{scope.workspace}/network")
    end

    test "the query, the rail and the order are the page's controls", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, scope)

      # Free text finds a host; a qualifier the page knows is a filter.
      view |> form("#connections-query", %{"q" => "decision:denied cdn"}) |> render_submit()

      assert_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/network?decision=denied&q=cdn"
      )

      render_async(view, 2_000)
      assert has_element?(view, "##{dst("files.cdn.example")}")
      refute has_element?(view, "##{dst("registry.example")}")

      # The rail counts the runs of each target that reached out, under the other filters.
      rail = "#connections-rail-t-#{RunComponents.dom_token({"gitlab.example", "acme/shop"})}"
      view = open(conn, scope)
      assert text(view, "#connections-rail-all") == "All repositories 2"
      assert text(view, rail) =~ "1"
      view |> element(rail) |> render_click()

      assert_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/network?#{%{"system" => "gitlab.example", "target" => "acme/shop"}}"
      )

      view |> element("#connections-sort-runs") |> render_click()

      assert_patch(
        view,
        ~p"/#{scope.organisation}/#{scope.workspace}/network?#{%{"sort" => "runs", "system" => "gitlab.example", "target" => "acme/shop"}}"
      )
    end

    test "a menu narrows on the server", %{conn: conn, scope: scope} do
      view = open(conn, scope)
      # The box shows once a menu is long; what it sends narrows on the server.
      refute has_element?(view, "#filter-host-narrow")
      render_change(view, "narrow", %{"_filter" => "host", "q" => "cdn"})
      render_async(view, 2_000)
      assert has_element?(view, "#filter-host-search[value=cdn]")
      assert text(view, "#filter-host-form") =~ "files.cdn.example 1"
      refute text(view, "#filter-host-form") =~ "registry.example"
    end

    test "unknown values are dropped and the URL is rewritten", %{conn: conn, scope: scope} do
      assert {:error, {:live_redirect, %{to: to}}} =
               live(
                 conn,
                 ~p"/#{scope.organisation}/#{scope.workspace}/network?decision=denied&state=failed&group=task&x=1"
               )

      assert to == ~p"/#{scope.organisation}/#{scope.workspace}/network?decision=denied"
    end

    test "while batches land nothing moves; the reader asks again, and what was open stays open",
         %{conn: conn, scope: scope} do
      view = open(conn, scope)
      id = dst("registry.example")
      view |> element("##{id}-toggle") |> render_click()
      refute has_element?(view, "#connections-refresh")

      started_run(scope, shop(), ago: 1, egress: [%{"host" => "new.example"}, @registry])
      assert has_element?(view, "#connections-refresh", "New activity")
      refute has_element?(view, "##{dst("new.example")}")

      view |> element("#connections-refresh") |> render_click()
      render_async(view, 2_000)
      assert has_element?(view, "##{dst("new.example")}")
      assert text(view, "##{id}-runs") =~ "3 runs reached this destination"
      refute has_element?(view, "#connections-refresh")
    end
  end
end
