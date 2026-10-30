defmodule ApiaryWeb.ConnectionLive.HarnessFetchTest do
  # The harness fetches on the workspace's Network access: a separate locked table below
  # the destinations, outside the page's counts, views and rule options. The rows of the
  # destinations are session rows only; no event of the page reaches a harness fetch.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.RunListFixtures

  alias Apiary.Policy

  setup :register_and_log_in_user
  setup {Apiary.DataCase, :without_registry}

  @fetch %{"host" => "git.example", "channel" => "stack", "rule" => nil}
  @session %{"host" => "registry.example", "rule" => "registry.example"}

  defp open(conn, scope, query \\ "") do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/network" <> query))
    render_async(view, 2_000)
    view
  end

  defp text(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, " ")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  test "lists the host of a harness fetch, labelled and locked, apart from the destinations",
       %{conn: conn, scope: scope} do
    started_run(scope, shop(), egress: [@fetch, @fetch, @session])
    view = open(conn, scope)

    assert has_element?(view, "#harness-fetches-h", "Harness fetch")

    assert [_one] =
             view
             |> render()
             |> LazyHTML.from_document()
             |> LazyHTML.query("#harness-fetch-rows tr")
             |> Enum.to_list()

    assert text(view, "#harness-fetch-rows") =~ "git.example"
    assert text(view, "#harness-fetch-rows") =~ "Harness fetch"
    assert text(view, "#harness-fetch-rows") =~ "Source not recorded"

    assert has_element?(
             view,
             "#harness-fetch-rows [aria-label='Host rules do not apply to a harness fetch.']"
           )

    refute has_element?(view, "#harness-fetches button")
    refute has_element?(view, "#harness-fetches a")

    # The destinations are the session's alone, and their view count does not take the fetch in.
    refute has_element?(view, "#destinations", "git.example")
    assert has_element?(view, "#destinations", "registry.example")
    assert text(view, "#connections-view-all") =~ "1"
  end

  test "is absent when no run fetched a harness", %{conn: conn, scope: scope} do
    started_run(scope, shop(), egress: [@session])
    refute has_element?(open(conn, scope), "#harness-fetches")
  end

  test "follows the page's host filter", %{conn: conn, scope: scope} do
    started_run(scope, shop(), egress: [@fetch, %{@fetch | "host" => "other.example"}])

    assert has_element?(
             open(conn, scope, "?host=other.example"),
             "#harness-fetch-rows",
             "other.example"
           )

    refute has_element?(
             open(conn, scope, "?host=other.example"),
             "#harness-fetch-rows",
             "git.example"
           )

    refute has_element?(open(conn, scope, "?host=nothing.example"), "#harness-fetches")
  end

  test "a host reached by a session and a fetch keeps Allow and Deny on its session row alone",
       %{conn: conn, scope: scope} do
    started_run(scope, shop(),
      egress: [@fetch, %{@fetch | "channel" => "session", "rule" => "git.example"}]
    )

    view = open(conn, scope)

    assert has_element?(view, "#destinations", "git.example")
    assert has_element?(view, "#harness-fetch-rows", "git.example")
    assert text(view, "#connections-view-all") =~ "1"
    refute has_element?(view, "#harness-fetches button")
  end

  describe "when the rows are cut" do
    defp rows(hosts),
      do:
        for(
          host <- hosts,
          do: %{
            host: host,
            runs: 1,
            attempts: 1,
            allowed: 1,
            denied: 0,
            last_seen_at: DateTime.utc_now(),
            sources: [:none]
          }
        )

    test "says how many of the hosts it shows" do
      html =
        render_component(&ApiaryWeb.HostComponents.harness_fetches/1,
          rows: rows(["a.example", "b.example"]),
          total: 1_234
        )

      assert html =~ "Showing 2 of 1,234 hosts."
    end

    test "says nothing when it shows every host" do
      html =
        render_component(&ApiaryWeb.HostComponents.harness_fetches/1,
          rows: rows(["a.example"]),
          total: 1
        )

      refute html =~ "Showing"
    end
  end

  describe "a crafted event with a harness fetch's host" do
    test "opens no rule panel, no runs and no rule", %{conn: conn, scope: scope} do
      started_run(scope, shop(), egress: [@fetch])
      view = open(conn, scope)
      row = %{"host" => "git.example", "port" => "443", "path" => ""}

      for action <- ~w(allow deny lock) do
        render_click(view, "rule_open", Map.put(row, "action", action))
      end

      render_click(view, "toggle_destination", row)
      render_click(view, "more_destination_runs", row)
      render_submit(view, "rule_submit", %{"for" => "workspace"})

      refute has_element?(view, "#rule-panel")
      refute has_element?(view, "tr.q-sub")
      assert Policy.list_rules(scope, nil) == []
    end
  end

  describe "with a harness record" do
    @describetag needs: [:factory]

    test "says the source of each host from the run's record", %{conn: conn, scope: scope} do
      import Apiary.SealedRunsFixtures
      import Apiary.RunEventsFixtures

      run = sealed_run_fixture(scope).run

      Apiary.Harnesses.RunHarness
      |> Apiary.Repo.get_by!(dispatch_run_id: run.dispatch_run_id)
      |> Ecto.Changeset.change(
        pins: [
          %{"git" => "https://git.example/acme/tools.git", "ref" => "main", "at" => "x"},
          %{
            "git" => Apiary.Lingo.Domain.Definition.qory_harness().git,
            "ref" => "main",
            "at" => "y"
          }
        ]
      )
      |> Apiary.Repo.update!()

      for {event, n} <- Enum.with_index([@fetch, %{@fetch | "host" => "github.com"}], 20) do
        event_fixture(run, n, "run.egress", egress_data(event), time: DateTime.utc_now())
      end

      {:ok, _run} = Apiary.Runs.Projector.project(run)
      view = open(conn, scope)

      assert text(view, "#harness-fetch-rows") =~ "The harness source acme/tools"
      assert text(view, "#harness-fetch-rows") =~ "The Qory harness"

      Apiary.Repo.update_all(Apiary.Harnesses.RunHarness, set: [harness_hidden: true])
      assert text(open(conn, scope), "#harness-fetch-rows") =~ "A hidden harness"
    end

    test "says a host no pin matches is not a source, not read yet, or not readable",
         %{conn: conn, scope: scope} do
      import Apiary.SealedRunsFixtures
      import Apiary.RunEventsFixtures

      run = sealed_run_fixture(scope).run
      event_fixture(run, 20, "run.egress", egress_data(@fetch), time: DateTime.utc_now())
      {:ok, _run} = Apiary.Runs.Projector.project(run)

      for {walk, words} <- [
            {[state: :resolved, origin: :none, failure: nil], "Not a harness source"},
            {[state: :pending, origin: nil, failure: nil], "The harness is not read yet"},
            {[state: :failed, origin: nil, failure: "invalid"], "The harness could not be read"}
          ] do
        Apiary.Repo.update_all(Apiary.Harnesses.RunHarness, set: [pins: []] ++ walk)
        assert text(open(conn, scope), "#harness-fetch-rows") =~ words
      end
    end
  end
end
