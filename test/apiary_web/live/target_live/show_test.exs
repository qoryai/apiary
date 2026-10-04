defmodule ApiaryWeb.TargetLive.ShowTest do
  @moduledoc """
  A target's page (`ApiaryWeb.TargetLive.Show`): its header and pin, the crumb, the tabs
  by path (Overview and Security policy), Overview's ways to Runs and Network access
  filtered to the target, and what is not found.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Targets

  setup :register_and_log_in_user

  defp repo(system, path), do: %{"forge" => system, "repository" => path}

  defp open(conn, path) do
    {:ok, view, _html} = live(conn, path)
    render_async(view, 2_000)
    view
  end

  setup %{scope: scope} do
    old =
      started_run(scope, repo("github.example", "acme/shop"),
        ago: 3_600,
        host: "ci-01",
        exit: %{"state" => "succeeded", "exit_code" => 0}
      )

    last =
      started_run(scope, Map.put(repo("github.example", "acme/shop"), "task", "fix-totals"),
        ago: 60,
        host: "ci-02",
        exit: %{"state" => "failed", "exit_code" => 1},
        egress: [%{"decision" => "denied", "outcome" => "refused", "host" => "files.cdn.example"}]
      )

    started_run(scope, repo("gitlab.example", "acme/shop"), ago: 7_200)
    shop = Targets.get(scope, "github.example", "acme/shop")

    %{
      shop: shop,
      old: old,
      last: last,
      path: workspace_path(scope, "/targets/github.example/acme/shop")
    }
  end

  test "the header names the target in full, with its runs, its last run and the way to it",
       %{conn: conn, scope: scope, path: path} do
    view = open(conn, path)

    assert has_element?(view, "#target-header h1", "github.example/acme/shop")

    assert has_element?(view, "#target-meta", "2 runs since")

    assert has_element?(view, "#target-meta", "last run")
    refute has_element?(view, "#target-mode")
    assert has_element?(view, "#target-external[href='https://github.example/acme/shop']")

    # The breadcrumb's third segment is the target, the page itself on Overview.
    assert has_element?(view, "#breadcrumb [aria-current=page]", "github.example/acme/shop")
    assert has_element?(view, "#nav-targets[aria-current=page]")
    assert has_element?(view, "#target-tab-overview[aria-current=page]")

    # Its records are the sidebar's Runs and Network access, filtered to it, not tabs;
    # with nothing of its own to set, it has no Settings tab either.
    refute has_element?(view, "#target-tab-runs, #target-tab-connections")
    refute has_element?(view, "#target-tab-settings")

    assert has_element?(view, "#target-tab-policy[href='#{path}/-/policy']", "Security policy") ==
             Apiary.Features.on?(:security)

    assert page_title(view) =~ "github.example/acme/shop"
    assert workspace_path(scope) <> "/targets/github.example/acme/shop" == path
  end

  test "Overview: the last runs, the denied destinations and what the target is", %{
    conn: conn,
    scope: scope,
    path: path,
    last: last,
    old: old
  } do
    view = open(conn, path)

    assert has_element?(view, "#target-last-runs tr:first-child", "fix-totals")
    assert has_element?(view, "#target-last-runs-#{last.id} .q-sdot-failed", "Failed")
    assert has_element?(view, "#target-last-runs-#{old.id}")
    # See all: the sidebar's Runs, filtered to the target.
    assert has_element?(
             view,
             "#target-all-runs[href='#{workspace_path(scope, "/runs?system=github.example&target=acme%2Fshop")}'][title='All its 2 runs, on Runs']",
             "See all"
           )

    assert has_element?(view, "#target-denied", "files.cdn.example")
    assert has_element?(view, "#target-denied", "1 attempt in 1 run")

    # See all: the sidebar's Network access, filtered to the target, denied only.
    assert has_element?(
             view,
             "#target-denied-connections[href='#{workspace_path(scope, "/network?decision=denied&system=github.example&target=acme%2Fshop")}']",
             "See all"
           )

    assert has_element?(view, "#target-about", "github.example")
    assert has_element?(view, "#target-about", "The same path elsewhere")

    assert has_element?(
             view,
             "#target-about a[href$='/targets/gitlab.example/acme/shop']",
             "gitlab.example/acme/shop"
           )

    assert has_element?(view, "#target-about", "ci-02")
    assert has_element?(view, "#target-about", "claude 2.1.0")
  end

  test "a run of the target that changes shows in place; a new one is counted", %{
    conn: conn,
    scope: scope,
    path: path,
    last: last
  } do
    view = open(conn, path)

    send(view.pid, {:run_changed, %{last | task: "fix-totals-again"}})
    assert has_element?(view, "#target-last-runs-#{last.id}", "fix-totals-again")

    # The projector says so on the workspace's topic, which the page follows.
    new = started_run(scope, repo("github.example", "acme/shop"), ago: 5)
    refute has_element?(view, "#target-last-runs-#{new.id}")
    assert has_element?(view, "#target-new-runs", "1 new run")

    view |> element("#target-new-runs") |> render_click()
    render_async(view, 2_000)
    assert has_element?(view, "#target-last-runs-#{new.id}")
    refute has_element?(view, "#target-new-runs")
  end

  test "the pin: the header's toggle; the sidebar keeps Targets current and marks the pin", %{
    conn: conn,
    scope: scope,
    path: path,
    shop: shop
  } do
    view = open(conn, path)
    assert has_element?(view, "#target-pin[aria-pressed=false]", "Pin")

    view |> element("#target-pin") |> render_click()
    assert has_element?(view, "#target-pin[aria-pressed=true]", "Pinned")
    assert Targets.pinned?(scope, shop)

    view = open(conn, path)
    assert has_element?(view, "#nav-targets[aria-current=page]")
    assert has_element?(view, "#nav-pin-#{shop.id}[aria-current=location]")
    assert has_element?(view, "#sidebar [aria-current=page]", "Repositories")
  end

  test "See all leads to the sidebar's lists, filtered to the target, with their rail", %{
    conn: conn,
    scope: scope,
    last: last
  } do
    view = open(conn, workspace_path(scope, "/runs?system=github.example&target=acme%2Fshop"))
    assert has_element?(view, "#nav-runs[aria-current=page]")
    assert has_element?(view, "#runs #run-#{last.run_id}", "fix-totals")
    assert has_element?(view, "#runs-rail")
    assert has_element?(view, "#runs-token-target")

    view =
      open(
        conn,
        workspace_path(scope, "/network?decision=denied&system=github.example&target=acme%2Fshop")
      )

    assert has_element?(view, "#nav-network[aria-current=page]")
    assert has_element?(view, "#destinations", "files.cdn.example")
    assert has_element?(view, "#connections-rail")
    assert has_element?(view, "#connections-token-target")
  end

  @tag needs: :security
  test "Security policy: the target's policy, a tab of its page", %{conn: conn, path: path} do
    view = open(conn, path <> "/-/policy")

    assert has_element?(view, "#target-tab-policy[aria-current=page]", "Security policy")
    assert has_element?(view, "#nav-targets[aria-current=page]")
    assert has_element?(view, "#policy-tabs a[aria-current=page]", "Effective policy")
    assert has_element?(view, "#policy-rules")

    view = open(conn, path <> "/-/policy/history")
    assert has_element?(view, "#policy-tabs a[aria-current=page]", "History")
  end

  test "a target the workspace does not have, and a tab the page does not know, are not found",
       %{conn: conn, scope: scope, path: path} do
    other = scope_fixture()
    started_run(other, repo("github.example", "acme/theirs"))

    for missing <- [
          workspace_path(scope, "/targets/github.example/acme/theirs"),
          workspace_path(scope, "/targets/github.example/acme/nope"),
          path <> "/-/nope",
          # the records are the sidebar's lists, not tabs of the target's page
          path <> "/-/runs",
          path <> "/-/network",
          path <> "/-/connections"
        ] do
      assert_raise Ecto.NoResultsError, fn -> live(conn, missing) end
    end
  end

  test "a path with a segment that would be misread is one segment of its own", %{
    conn: conn,
    scope: scope
  } do
    started_run(scope, repo("git.example.com", "odd/-/name"))
    target = Targets.get(scope, "git.example.com", "odd/-/name")

    path = ApiaryWeb.TargetComponents.target_path(scope, target.system, target.path)
    assert path == workspace_path(scope, "/targets/git.example.com/odd%2F-%2Fname")

    view = open(conn, path)
    assert has_element?(view, "#target-header h1", "odd/-/name")
    assert has_element?(view, "#target-external[href='https://git.example.com/odd/-/name']")
  end

  test "a run with no event does not stop the page", %{conn: conn, scope: scope, path: path} do
    _ = run_fixture(scope)
    view = open(conn, path)
    assert has_element?(view, "#target-overview")
  end
end
