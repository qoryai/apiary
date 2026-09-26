defmodule ApiaryWeb.WorkspaceLive.OverviewWithoutSecurityTest do
  # Not async: `@tag with_features:` switches the features of the whole node.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Policy
  alias ApiaryWeb.UserAuth

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.WorkspaceLive.Overview,
      coalesce: 0,
      announce: 0,
      quiet_tick: 3_600_000,
      refresh: 3_600_000
    )

    :ok
  end

  # A workspace with something of everything the policy has an opinion on: a denied
  # destination (an allow to offer), runs under the machines' own policies (the unmanaged
  # item), a lost run (an item that is the record's, not the policy's).
  defp record(scope) do
    started_run(scope, shop(),
      egress: [%{"host" => "files.cdn.example", "decision" => "denied", "rule" => ""}]
    )

    now = DateTime.utc_now()

    run_fixture(scope, %{
      state: "lost",
      task: "nightly-mirror",
      started_at: DateTime.add(now, -7200, :second),
      last_heartbeat_at: DateTime.add(now, -3600, :second),
      lost_at: DateTime.add(now, -3000, :second),
      heartbeat_interval_seconds: 30
    })
  end

  defp open(conn, scope) do
    {:ok, view, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}")
    render_async(view, 5_000)
    view
  end

  defp subscribed_to_policy?(view, scope) do
    Policy.topic(scope.workspace.id) in Registry.keys(Apiary.PubSub, view.pid)
  end

  # The tables the policy keeps, its history in the audit trail's. Every query made by
  # this test, the page it opens and the page's tasks is heard (they carry the test in
  # `$callers`); nothing else is.
  @policy_tables ~w(policy_rules audit_entries run_configurations)

  defp policy_reads(fun) do
    handler = {__MODULE__, make_ref()}
    test = self()
    agent = start_supervised!({Agent, fn -> [] end})

    :telemetry.attach(
      handler,
      [:apiary, :repo, :query],
      fn _event, _measurements, metadata, _config ->
        ours? = test in [self() | Process.get(:"$callers", [])]

        if ours? and metadata[:source] in @policy_tables,
          do: Agent.update(agent, &[metadata.source | &1])
      end,
      nil
    )

    try do
      result = fun.()
      {result, Agent.get(agent, & &1)}
    after
      :telemetry.detach(handler)
    end
  end

  describe "with security off" do
    @describetag with_features: [:observability]

    test "the sidebar has no Policy entry and no mode word, on every page", %{
      conn: conn,
      scope: scope
    } do
      for path <- [workspace_path(scope), workspace_path(scope, "/keys")] do
        {:ok, view, _html} = live(conn, path)

        for key <- ~w(overview runs connections keys members settings),
            do: assert(has_element?(view, "#nav-#{key}"))

        refute has_element?(view, "#nav-policy")
        refute has_element?(view, "#nav-policy-mode")
        refute has_element?(view, "#sidebar a[href^='#{workspace_path(scope, "/policy")}']")
      end
    end

    test "the sidebar's counts carry no mode, and no page follows the policy", %{
      conn: conn,
      scope: scope
    } do
      counts = UserAuth.nav_counts(scope)
      assert Map.has_key?(counts, :keys)
      refute Map.has_key?(counts, :mode)
      refute Map.has_key?(counts, :own_modes)

      record(scope)
      view = open(conn, scope)
      refute subscribed_to_policy?(view, scope)

      {:ok, keys, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/keys")
      refute subscribed_to_policy?(keys, scope)
    end

    test "the overview reads nothing of the policy", %{conn: conn, scope: scope} do
      record(scope)
      {view, reads} = policy_reads(fn -> open(conn, scope) end)

      assert reads == []
      assert has_element?(view, "#overview-strip")
    end

    test "the overview is a page that never had a policy", %{conn: conn, scope: scope} do
      lost = record(scope)
      view = open(conn, scope)
      html = render(view)

      # No card, no item, no act, no link, no word.
      refute has_element?(view, "#overview-policy")
      refute has_element?(view, "#policy-error")
      refute has_element?(view, "a[href^='#{workspace_path(scope, "/policy")}']")
      refute has_element?(view, "#attention li[data-kind=denied]")
      refute has_element?(view, "#attention li[data-kind=enforce]")
      refute has_element?(view, "#attention li[data-kind=unmanaged]")
      refute has_element?(view, "#attention li[data-kind=behind]")
      refute has_element?(view, "[phx-click*=rule_open]")
      refute html =~ ~r/polic/i
      refute html =~ ~r/\b(enforce|observe)\b/i
      refute html =~ ~r/Workspace default|Not served/

      # What the record says stays: the lost run is still an act, the denials are counted.
      assert has_element?(view, "#att-run-#{lost.run_id}")
      assert has_element?(view, "#overview-strip-denied", "1")
      assert has_element?(view, "#overview-strip", "to 1 destination")
      assert has_element?(view, "#overview-retention")
    end

    test "an allow asked for anyway opens nothing", %{conn: conn, scope: scope} do
      record(scope)
      view = open(conn, scope)

      id = "att-denied-#{:erlang.phash2({"files.cdn.example", 443, ""}, 4_294_967_296)}"

      for level <- ~w(target workspace choose),
          do: render_hook(view, "rule_open", %{"id" => id, "level" => level})

      render_hook(view, "rule_submit", %{})
      refute has_element?(view, "#rule-popover")
      assert Policy.list_rules(scope, nil) == []
    end
  end

  describe "with security on" do
    @describetag with_features: [:observability, :security]
    @describetag needs: :security

    test "the same workspace has the Policy entry, the card, the items and the allow", %{
      conn: conn,
      scope: scope
    } do
      record(scope)
      {view, reads} = policy_reads(fn -> open(conn, scope) end)

      # The probe the page without security passes hears the policy's reads here.
      assert reads != []
      assert render(view) =~ ~r/polic/i
      assert has_element?(view, "#nav-policy[href='#{workspace_path(scope, "/policy")}']")

      assert has_element?(
               view,
               "#overview-policy-open[href='#{workspace_path(scope, "/policy")}']"
             )

      assert has_element?(
               view,
               "#att-policy-unmanaged-act[href='#{workspace_path(scope, "/policy")}']"
             )

      assert has_element?(view, "#attention li[data-kind=denied] [phx-click*=rule_open]")
      assert subscribed_to_policy?(view, scope)
      assert Map.has_key?(UserAuth.nav_counts(scope), :mode)
    end
  end
end
