defmodule ApiaryWeb.RunLive.WithoutSecurityTest do
  @moduledoc """
  The runs, a run's four tabs and the connections on an instance launched with
  `QORY_FEATURES=observability`: the record is all there, and nothing of the policy is,
  not greyed out, not a link, not a word. A rule event sent all the same writes nothing.

  Only the page's own content is read (`#main`): the sidebar is the layout's.
  """
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures, only: [started_run: 3, shop: 1]

  alias Apiary.Policy
  alias Apiary.Repo
  alias Apiary.Runs.{Filters, Projector, Record}
  alias ApiaryWeb.RunComponents

  @moduletag with_features: [:observability]

  setup :register_and_log_in_user

  # What the policy made of a connection, and where it would lead: none of it on the page.
  @policy_words ~r/polic|\brules?\b|enforce|observe|digest|run configuration|in force/i

  defp main(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("#main")
  end

  defp refute_policy(html) do
    main = main(html)
    text = LazyHTML.text(main)

    refute text =~ @policy_words, "the page names the policy: " <> inspect(text)
    refute main |> LazyHTML.query("a[href*='/policy']") |> Enum.any?()
    refute main |> LazyHTML.query("[phx-click*='rule_open']") |> Enum.any?()
    refute main |> LazyHTML.query("#rule-popover") |> Enum.any?()
    refute main |> LazyHTML.query(".q-after, .q-kv-policy, #card-policy") |> Enum.any?()
  end

  defp nothing_written do
    assert Repo.aggregate(Policy.Rule, :count) == 0
    assert Repo.aggregate(Policy.Change, :count) == 0
  end

  # Nothing on the page's process follows the policy: not the page, not the sidebar.
  defp refute_follows_policy(view, scope) do
    refute Policy.topic(scope.workspace.id) in Registry.keys(Apiary.PubSub, view.pid)
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 2_000)
    view
  end

  defp dst(host, port \\ 443),
    do: RunComponents.destination_id(%{host: host, port: port, path: ""})

  defp projected(scope, events) do
    run = run_fixture(scope)
    events_fixture(run, events)
    {:ok, run} = Projector.project(run)
    run
  end

  describe "a run's pages" do
    setup %{scope: scope} do
      %{run: projected(scope, tool_record())}
    end

    test "the header and the timeline are the record, without the policy applied", %{
      conn: conn,
      run: run,
      scope: scope
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}")

      refute_policy(render(lv))

      assert has_element?(lv, "#run-facts", "dev-laptop")
      assert has_element?(lv, "#run-facts", "claude")
      assert has_element?(lv, "#timeline", "Run started")
      assert has_element?(lv, "#timeline", "Run exited")
      refute has_element?(lv, "#e-2")

      # the connections inline: the decision and the tool, never the rule
      assert has_element?(lv, "#timeline .q-cx .q-dest-tool .q-tool-name", "files")
      assert has_element?(lv, "#timeline .q-cx-denied .q-why", "Denied.")
      assert has_element?(lv, "#timeline .q-why", "Handed to files")

      # a link to the policy's item is no way to it: the sequence is dropped
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}?seq=2")

      refute has_element?(lv, "ol#timeline[data-target]")
      refute_policy(render(lv))
    end

    test "the connections tab is the record: no reason by rule, no Allow or Deny", %{
      conn: conn,
      scope: scope,
      run: run
    } do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/connections")

      html = render(lv)
      refute_policy(html)

      %{rows: rows} = Record.connections(scope, run)
      call = Enum.find(rows, &(&1.path == "/media/acme/shop/checkout.png"))
      refused = Enum.find(rows, &(&1.path == "/media/acme/other/checkout.png"))
      plain = Enum.find(rows, &(&1.host == "api.example.com"))

      assert has_element?(lv, "#cx-#{call.id} .q-dest-tool .q-tool-name", "files")
      assert has_element?(lv, "#cx-#{call.id} .q-outcome", "Answered 201")
      assert has_element?(lv, "#cx-#{refused.id}.q-denied[data-decision=denied]")
      assert has_element?(lv, "#cx-#{refused.id} .q-outcome", "Refused")
      assert has_element?(lv, "#cx-#{plain.id} .q-outcome", "Connected")
      assert has_element?(lv, "#decision", "Denied")

      refute has_element?(lv, "#run-connections .q-why")
      refute has_element?(lv, "th", "Reason")
      refute has_element?(lv, ".q-slot-cell")

      assert has_element?(
               lv,
               "#connections-footnote",
               "Counted per host, port and path from the run's egress events."
             )

      refute_follows_policy(lv, scope)
    end

    test "a crafted Allow or Deny writes nothing", %{conn: conn, scope: scope, run: run} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/connections")

      %{rows: rows} = Record.connections(scope, run)
      refused = Enum.find(rows, &(&1.path == "/media/acme/other/checkout.png"))

      for action <- ~w(allow deny) do
        render_click(lv, "rule_open", %{"id" => refused.id, "action" => action})
        render_change(lv, "rule_change", %{"for" => "workspace"})
        render_submit(lv, "rule_submit", %{"for" => "workspace"})
      end

      refute has_element?(lv, "#rule-popover")
      refute_policy(render(lv))
      nothing_written()
    end

    test "the terminal and the details are the record", %{conn: conn, run: run, scope: scope} do
      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/terminal")

      refute_policy(render(lv))

      {:ok, lv, _html} =
        live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs/#{run.run_id}/details")

      html = render(lv)
      refute_policy(html)

      assert has_element?(lv, "#card-command")
      assert has_element?(lv, "#card-record")
      assert has_element?(lv, "#run-id", run.run_id)
      refute html =~ "Policy in force"
    end
  end

  describe "the runs" do
    test "a target's group links to its connections, not to a policy", %{
      conn: conn,
      scope: scope
    } do
      started_run(scope, shop("github.example"),
        egress: [%{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""}]
      )

      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/runs")
      render_async(lv, 2_000)
      html = render(lv)
      refute_policy(html)

      refute has_element?(lv, ".q-g-policy")
      assert has_element?(lv, ".q-group a", "Connections")
      assert has_element?(lv, ".q-denials")
    end
  end

  describe "the connections" do
    setup %{scope: scope} do
      started_run(scope, shop("github.example"),
        egress: [
          %{
            "host" => "files.cdn.example",
            "decision" => "denied",
            "rule" => "",
            "outcome" => "refused"
          },
          %{"host" => "registry.example", "rule" => "registry.example"},
          %{
            "host" => "169.254.169.254",
            "port" => 80,
            "decision" => "denied",
            "rule" => "wall:own-address",
            "outcome" => "refused"
          }
        ]
      )

      :ok
    end

    test "the rows are the record: the decision, the outcome and the runs", %{
      conn: conn,
      scope: scope
    } do
      view = open(conn, ~p"/#{scope.organisation}/#{scope.workspace}/connections")
      refute_policy(render(view))

      cdn = dst("files.cdn.example")
      assert has_element?(view, "##{cdn}.q-denied[data-decision=denied]")
      assert has_element?(view, "##{cdn} .q-outcome", "Refused")
      assert has_element?(view, "##{dst("registry.example")} .q-outcome", "Connected")
      assert has_element?(view, "##{dst("169.254.169.254", 80)}.q-denied")
      refute has_element?(view, "#destinations .q-why")
      refute has_element?(view, "th", "Reason")
      assert has_element?(view, "#connections-footer", "Denied destinations come first")

      view |> element("##{cdn}-toggle") |> render_click()
      assert has_element?(view, "##{cdn}-runs", "1 run reached this destination")
      refute_policy(render(view))

      refute_follows_policy(view, scope)
    end

    test "per target, the page says which, and links to no policy", %{conn: conn, scope: scope} do
      view =
        open(
          conn,
          ~p"/#{scope.organisation}/#{scope.workspace}/connections?#{Filters.target_params("github.example", "acme/shop")}"
        )

      refute_policy(render(view))
      assert has_element?(view, "#connections-target-note", "github.example/acme/shop")
      refute has_element?(view, "#connections-target-policy")
    end

    test "a crafted Allow or Deny writes nothing", %{conn: conn, scope: scope} do
      view = open(conn, ~p"/#{scope.organisation}/#{scope.workspace}/connections")
      values = %{"host" => "files.cdn.example", "port" => "443", "path" => ""}

      for action <- ~w(allow deny) do
        render_click(view, "rule_open", Map.put(values, "action", action))
        render_change(view, "rule_change", %{"for" => "workspace"})
        render_submit(view, "rule_submit", %{"for" => "workspace"})
      end

      refute has_element?(view, "#rule-popover")
      refute_policy(render(view))
      nothing_written()
    end
  end
end
