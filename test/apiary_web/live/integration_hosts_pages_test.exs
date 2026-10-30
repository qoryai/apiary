defmodule ApiaryWeb.IntegrationHostsPagesTest do
  @moduledoc """
  The pages' rule lists show no integration's host (`Apiary.Policy.effective/2`): the
  policy page's rule list, the rule form's reading, Network access and a run's
  connections tab show a workspace with an integration host as they showed it before the
  integration was added. Only the version that the change rendered differs, which the
  sections compared here do not show. The Policy page's "Allowed for every run" list is
  where those hosts appear, apart from the rules
  (`ApiaryWeb.PolicyLive.RequiredHostsTest`).
  """
  use ApiaryWeb.ConnCase, async: true

  @moduletag needs: :secrets

  import Phoenix.LiveViewTest
  import Apiary.ConnectionsFixtures, only: [ready_release!: 3]
  import Apiary.DescriptionFixtures
  import Apiary.RunListFixtures
  import ApiaryWeb.TargetComponents, only: [target_path: 3]

  alias Apiary.{Connections, Policy}

  setup :register_and_log_in_user

  setup do
    Application.put_env(:apiary, ApiaryWeb.PolicyLive, reload_window: 0, nav_window: 0)
    :ok
  end

  setup %{scope: scope} do
    started_run(scope, shop(),
      egress: [
        %{"host" => "api.example.com", "decision" => "denied", "rule" => "api.example.com"},
        %{"host" => "files.example.org", "decision" => "denied", "rule" => "*.example.org"},
        %{"host" => "docs.example.com", "rule" => "docs.example.com"}
      ]
    )

    [%{target: target}] = Policy.list_targets(scope)
    {:ok, rule} = Policy.deny(scope, nil, %{host: "api.example.com"})
    {:ok, _rule} = Policy.lock(scope, rule)
    {:ok, _rule} = Policy.deny(scope, nil, %{host: "*.example.org"})
    {:ok, _rule} = Policy.allow(scope, nil, %{host: "docs.example.com"})
    {:ok, _rule} = Policy.allow(scope, target, %{host: "cdn.example.org"})

    release =
      ready_release!(
        scope,
        tracker_description(%{"egress_hosts" => ["api.example.com", "files.example.org"]}),
        "codeberg.org/acme/tracker"
      )

    %{target: target, release: release}
  end

  defp add_integration(%{scope: scope, release: release}) do
    {:ok, _connection} = Connections.create_integration(scope, release.id, %{})
    assert [_api, _files] = Connections.egress_hosts(scope.workspace)
  end

  defp page(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 5_000)
    view
  end

  defp html(view, selector), do: view |> element(selector) |> render()

  # A time on a page is said relative to the moment it is drawn.
  defp untimed(html), do: String.replace(html, ~r{<time[^>]*>[^<]*</time>}, "<time/>")

  defp same(before, after_) do
    assert untimed(after_) == untimed(before)
    refute after_ =~ "acme-tracker"
  end

  test "the policy page's rule list, of the workspace and of a target", ctx do
    %{conn: conn, scope: scope, target: target} = ctx
    workspace = workspace_path(scope, "/policy")
    targeted = target_path(scope, target, ["policy"])

    before =
      {html(page(conn, workspace), "#policy-rules"), html(page(conn, targeted), "#policy-rules")}

    add_integration(ctx)

    after_ =
      {html(page(conn, workspace), "#policy-rules"), html(page(conn, targeted), "#policy-rules")}

    same(elem(before, 0), elem(after_, 0))
    same(elem(before, 1), elem(after_, 1))
  end

  test "the rule form's reading of an integration's host", ctx do
    %{conn: conn, scope: scope} = ctx

    read = fn ->
      view = page(conn, workspace_path(scope, "/policy/rules/new"))

      view
      |> form("#policy-rule-form", rule: %{"action" => "deny", "host" => "api.example.com"})
      |> render_change()

      html(view, "#policy-rule-form")
    end

    before = read.()
    add_integration(ctx)
    same(before, read.())
  end

  test "Network access", ctx do
    %{conn: conn, scope: scope} = ctx
    path = workspace_path(scope, "/network")

    before = html(page(conn, path), "#destinations")
    add_integration(ctx)
    same(before, html(page(conn, path), "#destinations"))
  end

  test "a run's connections tab", ctx do
    %{conn: conn, scope: scope} = ctx
    [run | _] = Apiary.Repo.all(Apiary.Runs.Run)
    path = workspace_path(scope, "/runs/#{run.public_id}/network")

    before = html(page(conn, path), "#run-connections")
    add_integration(ctx)
    same(before, html(page(conn, path), "#run-connections"))
  end
end
