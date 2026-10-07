defmodule ApiaryWeb.TargetLive.ShowTest do
  @moduledoc """
  A target's page (`ApiaryWeb.TargetLive.Show`): its address, the path alone or, where the
  path is shared, after its system (question 9, answer A); its header and pin, the crumb,
  the tabs, Overview and its links to the narrowed lists, the old addresses sent on, the
  page of a shared path given alone, and what is not found.
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
    # The tablist names the thing's kind, in the workspace's words.
    assert has_element?(view, "nav#target-tabs[aria-label=Repository]")
    assert has_element?(view, "#target-tabs-overview[aria-current=page]")

    # The lists live once, at the workspace: no Runs or Network access tab.
    refute has_element?(view, "#target-tabs-runs")
    refute has_element?(view, "#target-tabs-network")
    refute has_element?(view, "#target-tab-runs")
    refute has_element?(view, "#target-tab-connections")

    assert page_title(view) =~ "github.example/acme/shop"
    # Two systems have the path acme/shop: the address names the system.
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

    assert has_element?(
             view,
             "#target-all-runs[href='#{workspace_path(scope, "/runs?system=github.example&target=acme%2Fshop")}']",
             "All 2 runs"
           )

    assert has_element?(view, "#target-denied", "files.cdn.example")
    assert has_element?(view, "#target-denied", "1 attempt in 1 run")

    assert has_element?(
             view,
             "#target-denied-connections[href='#{workspace_path(scope, "/network?system=github.example&target=acme%2Fshop&decision=denied")}']"
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

  test "the pin: the header's toggle, and the sidebar marks the target", %{
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
    assert has_element?(view, "#nav-pin-#{shop.id}[aria-current=page]")
    refute has_element?(view, "#nav-targets[aria-current=page]")
  end

  test "a path no other target has: the address is the path alone, and the lists are narrowed to it",
       %{conn: conn, scope: scope} do
    started_run(scope, repo("github.example", "acme/billing"),
      egress: [%{"decision" => "denied", "outcome" => "refused", "host" => "files.cdn.example"}]
    )

    billing = Targets.get(scope, "github.example", "acme/billing")
    path = workspace_path(scope, "/targets/acme/billing")
    assert ApiaryWeb.TargetComponents.target_path(scope, billing.system, billing.path) == path

    view = open(conn, path)
    assert has_element?(view, "#target-header h1", "github.example/acme/billing")
    assert has_element?(view, "#target-tabs-overview[aria-current=page][href='#{path}']")

    assert has_element?(
             view,
             "#target-all-runs[href='#{workspace_path(scope, "/runs?target=acme%2Fbilling")}']",
             "All 1 run"
           )

    assert has_element?(
             view,
             "#target-denied-connections[href='#{workspace_path(scope, "/network?target=acme%2Fbilling&decision=denied")}']"
           )

    # The sidebar is the workspace's, plain: nothing on a target's page carries it.
    assert has_element?(view, "#nav-runs[href='#{workspace_path(scope, "/runs")}']")
    assert has_element?(view, "#nav-network[href='#{workspace_path(scope, "/network")}']")
  end

  test "an old address with the system of a path no other target has is sent on to the path alone",
       %{conn: conn, scope: scope} do
    started_run(scope, repo("github.example", "acme/billing"))
    old = workspace_path(scope, "/targets/github.example/acme/billing")
    new = workspace_path(scope, "/targets/acme/billing")

    assert redirected_to(get(conn, old)) == new

    assert redirected_to(get(conn, old <> "/-/policy?view=all")) ==
             new <> "/-/policy?view=all"

    assert {:error, {:redirect, %{to: ^new}}} = live(conn, old)
  end

  test "the old Runs and Network access tabs send on to the lists narrowed to the target, with the query",
       %{conn: conn, scope: scope, path: path} do
    shop = "system=github.example&target=acme%2Fshop"

    assert redirected_to(get(conn, path <> "/-/runs")) == workspace_path(scope, "/runs?#{shop}")

    assert redirected_to(get(conn, path <> "/-/network?decision=denied")) ==
             workspace_path(scope, "/network?#{shop}&decision=denied")

    assert redirected_to(get(conn, path <> "/-/connections?decision=denied&since=30d")) ==
             workspace_path(scope, "/network?#{shop}&decision=denied&since=30d")

    # A path no other target has: the path alone, from either of its addresses.
    started_run(scope, repo("github.example", "acme/billing"))

    for old <- ["/targets/acme/billing/-/runs", "/targets/github.example/acme/billing/-/runs"] do
      assert redirected_to(get(conn, workspace_path(scope, old))) ==
               workspace_path(scope, "/runs?target=acme%2Fbilling")
    end

    assert redirected_to(
             get(conn, workspace_path(scope, "/targets/acme/billing/-/network?target=x"))
           ) == workspace_path(scope, "/network?target=acme%2Fbilling")
  end

  test "a shared path given alone names the targets that share it, each a link to its page",
       %{conn: conn, scope: scope} do
    view = open(conn, workspace_path(scope, "/targets/acme/shop"))

    assert has_element?(view, "#target-choose-title", "acme/shop")

    assert has_element?(
             view,
             "#target-choices a[href='#{workspace_path(scope, "/targets/github.example/acme/shop")}']",
             "github.example/acme/shop"
           )

    assert has_element?(
             view,
             "#target-choices a[href='#{workspace_path(scope, "/targets/gitlab.example/acme/shop")}']",
             "gitlab.example/acme/shop"
           )

    # Its old Runs tab: the runs of the path on every system.
    assert redirected_to(get(conn, workspace_path(scope, "/targets/acme/shop/-/runs"))) ==
             workspace_path(scope, "/runs?target=acme%2Fshop")
  end

  @tag needs: :security
  test "Policy: the target's policy, a tab of its page", %{conn: conn, path: path} do
    view = open(conn, path <> "/-/policy")

    assert has_element?(view, "#target-tabs-policy[aria-current=page]")
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
          workspace_path(scope, "/targets/acme/nope"),
          path <> "/-/nope",
          path <> "/-/runs/more"
        ] do
      assert_raise Ecto.NoResultsError, fn -> live(conn, missing) end
    end
  end

  test "a path with a segment that would be misread is one segment of its own", %{
    conn: conn,
    scope: scope
  } do
    started_run(scope, repo("codeberg.org", "odd/-/name"))
    target = Targets.get(scope, "codeberg.org", "odd/-/name")

    path = ApiaryWeb.TargetComponents.target_path(scope, target.system, target.path)
    assert path == workspace_path(scope, "/targets/odd%2F-%2Fname")

    view = open(conn, path)
    assert has_element?(view, "#target-header h1", "odd/-/name")
    assert has_element?(view, "#target-external[href='https://codeberg.org/odd/-/name']")
  end

  test "an address that reads as two targets names both; a system kept where the path alone would not do",
       %{conn: conn, scope: scope} do
    # acme/shop is a path of github.example, and also, read as a system and a path, the
    # path shop of the system acme.
    started_run(scope, repo("acme", "shop"))
    acme = Targets.get(scope, "acme", "shop")
    github = Targets.get(scope, "github.example", "acme/shop")

    view = open(conn, workspace_path(scope, "/targets/acme/shop"))
    assert has_element?(view, "#target-choice-#{acme.id}", "acme/shop")
    assert has_element?(view, "#target-choice-#{github.id}", "github.example/acme/shop")

    # A path no other system has, whose path alone reads as another target: its address
    # keeps the system, and is not sent on.
    started_run(scope, repo("codeberg.org", "acme/billing"))
    started_run(scope, repo("acme", "billing"))
    view = open(conn, workspace_path(scope, "/targets/codeberg.org/acme/billing"))
    assert has_element?(view, "#target-header h1", "codeberg.org/acme/billing")
  end

  test "an address that is no label, such as bytes that are not UTF-8, is not found",
       %{conn: conn, scope: scope} do
    for missing <- ["/targets/%FF", "/targets/a%00b/c", "/targets/github.example/%FF"] do
      assert_raise Ecto.NoResultsError, fn -> live(conn, workspace_path(scope, missing)) end
    end
  end

  test "a run with no event does not stop the page", %{conn: conn, scope: scope, path: path} do
    _ = run_fixture(scope)
    view = open(conn, path)
    assert has_element?(view, "#target-overview")
  end
end
