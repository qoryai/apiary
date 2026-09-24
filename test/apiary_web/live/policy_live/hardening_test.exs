defmodule ApiaryWeb.PolicyLive.HardeningTest do
  @moduledoc """
  What a client can send that the page never offered: events without their dialog, ids of
  another hive, payloads that are not what a form sends, parameters that are not what a
  link writes. Nothing changes that the sender may not change, and no page goes down.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Policy

  setup :register_and_log_in_user

  setup %{scope: scope} do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)

    started_run(scope, shop())
    [%{target: target}] = Policy.list_targets(scope)
    {:ok, locked} = Policy.deny(scope, nil, %{host: "*.paste.example", locked: true})
    {:ok, plain} = Policy.allow(scope, nil, %{host: "github.example"})
    {:ok, denied} = Policy.deny(scope, nil, %{host: "telemetry.example"})

    %{user: member} = member_fixture(scope, :member)

    %{
      target: target,
      path: "/hive/policy/repositories/#{target.id}",
      locked: locked,
      plain: plain,
      denied: denied,
      member_conn: log_in_user(build_conn(), member)
    }
  end

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  defp rules(scope, holder \\ nil), do: Policy.list_rules(scope, holder)
  defp rule(scope, host), do: Enum.find(rules(scope), &(&1.host == host))

  describe "a member's crafted events on the hive's page" do
    test "confirms with no dialog open do nothing", %{member_conn: conn, scope: scope} do
      view = open(conn, "/hive/policy")
      before = rules(scope)

      for event <- ~w(mode_confirm lock_confirm remove_confirm target_mode_confirm) do
        render_hook(view, event, %{})
      end

      assert rules(scope) == before
      assert Policy.get_mode(scope) == "observe"
      assert Process.alive?(view.pid)
    end

    test "unlock, remove of a locked rule and saving over a locked host are refused",
         %{member_conn: conn, scope: scope, locked: locked} do
      view = open(conn, "/hive/policy")

      render_hook(view, "lock_toggle", %{"id" => locked.id})
      assert rule(scope, "*.paste.example").locked

      render_hook(view, "remove", %{"id" => locked.id})
      render_hook(view, "remove_confirm", %{})
      assert rule(scope, "*.paste.example")

      view
      |> form("#policy-composer", rule: %{host: "*.paste.example", paths: ""})
      |> render_change()

      render_hook(view, "composer_save", %{})
      assert rule(scope, "*.paste.example").action == "deny"
    end
  end

  describe "a member's crafted events on a target's page" do
    test "a locked hive rule is not disabled, and allowing for the hive stays a member's right",
         %{member_conn: conn, scope: scope, target: target, path: path, locked: locked} do
      view = open(conn, path)

      render_hook(view, "row_act", %{"id" => locked.id, "act" => "allow_here"})
      assert rules(scope, target) == []
      assert render(view) =~ "is locked"

      render_hook(view, "target_mode_ask", %{"setting" => "enforce"})
      render_hook(view, "target_mode_confirm", %{})
      assert Policy.get_mode(scope, target).own == nil

      # Rules are a member's to edit, the hive's too: these are allowed, not refused.
      render_hook(view, "suggest_allow", %{"host" => "flags.example", "level" => "hive"})
      assert rule(scope, "flags.example")
      render_hook(view, "suggest_allow_all", %{})
      assert Process.alive?(view.pid)
    end
  end

  describe "another hive's ids" do
    setup do
      other = scope_fixture()
      started_run(other, shop())
      [%{target: theirs}] = Policy.list_targets(other)
      {:ok, rule} = Policy.allow(other, nil, %{host: "secret.example"})
      {:ok, own} = Policy.allow(other, theirs, %{host: "inner.example"})
      %{other: other, their_rule: rule, their_own: own}
    end

    test "change nothing there, from either page",
         %{conn: conn, path: path, other: other, their_rule: rule, their_own: own} do
      hive = open(conn, "/hive/policy")

      for event <- ~w(lock_toggle remove edit_paths), id <- [rule.id, own.id, "nope", nil, %{}] do
        render_hook(hive, event, %{"id" => id})
      end

      render_hook(hive, "remove_confirm", %{})
      refute render(hive) =~ "secret.example"

      target = open(conn, path)

      for act <- ~w(disable allow_here remove restore bogus), id <- [rule.id, own.id] do
        render_hook(target, "row_act", %{"id" => id, "act" => act})
      end

      render_hook(target, "remove", %{"id" => own.id})
      refute render(target) =~ "inner.example"

      assert [%{host: "secret.example", locked: false}] = Policy.list_rules(other, nil)
      assert length(Policy.list_changes(other, :all, 1).items) == 2
      assert Process.alive?(hive.pid) and Process.alive?(target.pid)
    end
  end

  describe "a rule that changed while a confirm was open" do
    test "a removed rule is not removed twice, and a lock is not put on what is gone",
         %{conn: conn, scope: scope, locked: locked, plain: plain, target: target} do
      {:ok, _} = Policy.deny(scope, target, %{host: "github.example"})
      view = open(conn, "/hive/policy")

      view |> element("#rule-#{plain.id}-lock") |> render_click()
      assert has_element?(view, "#lock-confirm")
      {:ok, _} = Policy.remove_rule(scope, plain)
      view |> element("#lock-confirm-button") |> render_click()
      assert render(view) =~ "was removed while you were deciding"

      view |> element("#rule-#{locked.id}-menu button", "Remove") |> render_click()
      {:ok, _} = Policy.remove_rule(scope, locked)
      {:ok, again} = Policy.allow(scope, nil, %{host: "*.paste.example"})
      view |> element("#remove-confirm-button") |> render_click()
      assert rule(scope, "*.paste.example").id == again.id
    end

    test "a row's act is matched against the rule as it is now",
         %{conn: conn, scope: scope, target: target, path: path, denied: denied} do
      view = open(conn, path)

      # The hive's deny became an allow held to paths: "Allow here" must not open them.
      {:ok, _} = Policy.allow(scope, nil, %{host: "telemetry.example", paths: ["/v1/*"]})
      render_hook(view, "row_act", %{"id" => denied.id, "act" => "allow_here"})

      assert rules(scope, target) == []
      assert render(view) =~ "changed while you were deciding"
    end
  end

  describe "payloads no form sends" do
    test "leave the composer as it was and the page up", %{conn: conn, scope: scope} do
      view = open(conn, "/hive/policy")

      for payload <- [
            %{"rule" => "text"},
            %{"rule" => ["a"]},
            %{"rule" => %{"host" => %{"a" => 1}, "paths" => 7}},
            %{"rule" => %{"host" => ["x"], "paths" => nil}},
            %{}
          ] do
        render_hook(view, "composer_change", payload)
      end

      for payload <- [
            %{"host" => %{"a" => 1}},
            %{"host" => 5, "paths" => [], "action" => "burn"},
            %{"action" => %{}}
          ] do
        render_hook(view, "composer_use", payload)
      end

      for payload <- [%{"credential" => "x"}, %{"credential" => %{"name" => %{}}}, %{}] do
        render_hook(view, "credential_change", payload)
      end

      render_hook(view, "composer_paste", %{"hosts" => [1, %{}, "ok.example"]})
      render_hook(view, "composer_paste", %{"hosts" => "nope"})
      render_hook(view, "would_allow", %{"key" => %{}})
      render_hook(view, "mode_ask", %{"mode" => ["enforce"]})
      render_hook(view, "show_rule", %{"host" => 1})
      render_hook(view, "compare", %{"compare" => %{}})

      render_hook(view, "composer_change", %{
        "rule" => %{"host" => "a\0b.example" <> String.duplicate("x", 10_000), "paths" => ""}
      })

      assert Process.alive?(view.pid)
      assert length(rules(scope)) == 3
      assert has_element?(view, "#policy-composer-add[disabled]")
    end
  end

  describe "parameters no link writes" do
    test "are read as their defaults", %{conn: conn, path: path} do
      for query <- [
            "/hive/policy?show=%00&rule=%00",
            "/hive/policy?show[]=allow&rule[a]=b",
            "/hive/policy/repositories?mode=",
            "/hive/policy/repositories?mode=own%00",
            "/hive/policy/repositories?mode[]=own",
            "/hive/policy/history?page=-1",
            "/hive/policy/history?page=99999999999999999999",
            "/hive/policy/history?page[]=2&change[]=x",
            "/hive/policy/history?change=%00",
            "/hive/policy/versions/1?compare=-3&view=%00",
            "/hive/policy/versions/1?compare[]=1&view[]=served",
            path <> "?show=%00&rule[]=x",
            path <> "/history?page=0&change=1"
          ] do
        view = open(conn, query)
        assert has_element?(view, "#policy-page"), query
      end

      for missing <- [
            "/hive/policy/versions/%00",
            "/hive/policy/versions/0",
            "/hive/policy/versions/99999999999"
          ] do
        view = open(conn, missing)
        assert has_element?(view, "h2", "There is no version"), missing
      end
    end
  end
end
