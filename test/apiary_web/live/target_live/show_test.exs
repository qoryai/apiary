defmodule ApiaryWeb.TargetLive.ShowTest do
  @moduledoc """
  A target's page (`ApiaryWeb.TargetLive.Show`): its address, the target's public id
  (`tg_…`); its header and pin, the crumb, the tabs, Overview and its links to the
  narrowed lists, and what is not found, the old addresses by system and path among it.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunEventsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Targets
  alias ApiaryWeb.TargetComponents

  setup :register_and_log_in_user

  defp repo(system, path), do: %{"forge" => system, "repository" => path}

  # A name as it reads: its parts joined, as `<.target_name>` writes them.
  defp name(view, selector) do
    view
    |> element(selector)
    |> render()
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  # The status a request is answered with, whether the endpoint sends it or raises it.
  defp status(conn, path) do
    get(conn, path).status
  rescue
    error -> Plug.Exception.status(error)
  end

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
      started_run(scope, repo("github.example", "acme/shop"),
        about: %{"title" => "fix-totals"},
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
      path: workspace_path(scope, "/targets/#{shop.public_id}")
    }
  end

  test "the header names a shared path with its system, with its runs, its last run and the way to it",
       %{conn: conn, scope: scope, path: path, shop: shop} do
    view = open(conn, path)

    assert name(view, "#target-header h1") == "github.example/acme/shop"

    assert has_element?(view, "#target-meta", "2 runs since")

    assert has_element?(view, "#target-meta", "last run")
    refute has_element?(view, "#target-mode")
    assert has_element?(view, "#target-external[href='https://github.example/acme/shop']")

    # The breadcrumb ends with the section, a link to its list, and the target, the page
    # itself on Overview.
    assert crumbs(view) == [
             {"Repositories", workspace_path(scope, "/targets")},
             {"github.example/acme/shop", nil}
           ]

    assert has_element?(view, "#breadcrumb [aria-current=page]", "github.example/acme/shop")
    assert has_element?(view, "#nav-targets[aria-current=page]")
    # The tablist names the thing's kind, in the workspace's words.
    assert has_element?(view, "nav#target-tabs[aria-label=Repository]")
    assert has_element?(view, "#target-tabs-overview[aria-current=page]")

    # The lists live once, at the workspace: no Runs or Network access tab.
    refute has_element?(view, "#target-tabs-runs")
    refute has_element?(view, "#target-tabs-network")

    assert page_title(view) =~ "github.example/acme/shop"
    # Two systems have the path acme/shop: the name has the system, the address neither.
    assert TargetComponents.target_path(scope, shop) == path
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
    # The heading says "Denied"; each row's mark is a faint grey bullet, never red.
    assert has_element?(view, "#target-denied li .hero-no-symbol-micro.size-3\\.5.text-faint")
    refute has_element?(view, "#target-denied .text-error")

    assert has_element?(
             view,
             "#target-denied-connections[href='#{workspace_path(scope, "/network?system=github.example&target=acme%2Fshop&decision=denied")}']"
           )

    assert has_element?(view, "#target-about", "github.example")
    assert has_element?(view, "#target-about", "The same path elsewhere")

    gitlab = Targets.get(scope, "gitlab.example", "acme/shop")

    assert has_element?(
             view,
             "#target-about a[href='#{workspace_path(scope, "/targets/#{gitlab.public_id}")}']",
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

    send(view.pid, {:run_changed, %{last | about_title: "fix-totals-again"}})
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

  test "a denied host is isolated, so a bidi override reorders nothing",
       %{conn: conn, scope: scope} do
    host = "evil\u202Elpmaxe.<script>"

    started_run(scope, repo("github.example", "acme/billing"),
      egress: [%{"decision" => "denied", "outcome" => "refused", "host" => host}]
    )

    billing = Targets.get(scope, "github.example", "acme/billing")
    view = open(conn, TargetComponents.target_path(scope, billing))

    assert has_element?(view, "#target-denied .q-tgt-dn-dest > bdi", host)

    assert render(view) =~
             "<bdi>evil\u202Elpmaxe.&lt;script&gt;</bdi><span class=\"text-faint\">:443"

    refute render(view) =~ "elpmaxe.<script>"
  end

  test "a path no other target has: named by the path alone, and the lists are narrowed to it",
       %{conn: conn, scope: scope} do
    started_run(scope, repo("github.example", "acme/billing"),
      egress: [%{"decision" => "denied", "outcome" => "refused", "host" => "files.cdn.example"}]
    )

    billing = Targets.get(scope, "github.example", "acme/billing")
    path = workspace_path(scope, "/targets/#{billing.public_id}")
    assert TargetComponents.target_path(scope, billing) == path
    assert TargetComponents.target_path(scope, billing.public_id) == path

    view = open(conn, path)

    # It is named in its notation: its path alone, its system the name's tooltip.
    assert has_element?(view, "#target-header h1 [title='github.example/acme/billing']")
    assert name(view, "#target-header h1") == "acme/billing"
    assert name(view, "#breadcrumb [aria-current=page]") == "acme/billing"
    assert page_title(view) =~ "acme/billing"
    refute page_title(view) =~ "github.example"
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

  @tag needs: :security
  test "the Policy tab names the target in its notation, in its title and its crumb",
       %{conn: conn, scope: scope, path: shop} do
    started_run(scope, repo("github.example", "acme/billing"))
    billing = Targets.get(scope, "github.example", "acme/billing")
    path = workspace_path(scope, "/targets/#{billing.public_id}")

    view = open(conn, path <> "/policy")
    assert page_title(view) =~ "Policy · acme/billing"
    refute page_title(view) =~ "github.example"
    assert name(view, "#breadcrumb a[href='#{path}']") == "acme/billing"

    assert crumbs(view) == [
             {"Repositories", workspace_path(scope, "/targets")},
             {"acme/billing", path}
           ]

    view = open(conn, shop <> "/policy")
    assert page_title(view) =~ "Policy · github.example/acme/shop"
  end

  @tag needs: :security
  test "the Policy tab is not there where the policy is hidden from the reader",
       %{conn: conn, scope: scope} do
    started_run(scope, repo("github.example", "acme/billing"))
    billing = Targets.get(scope, "github.example", "acme/billing")
    path = TargetComponents.target_path(scope, billing)
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
    :ok = Apiary.EditionStubs.HidesNamed.put([:security])

    view = open(conn, path)
    refute has_element?(view, "a[href='#{path}/policy']")
    assert_raise Ecto.NoResultsError, fn -> live(conn, path <> "/policy") end
  end

  @tag needs: :security
  test "Policy: the target's policy, a tab of its page", %{conn: conn, path: path} do
    view = open(conn, path <> "/policy")

    assert has_element?(view, "#target-tabs-policy[aria-current=page]")
    assert has_element?(view, "#policy-tabs a[aria-current=page]", "Effective policy")
    assert has_element?(view, "#policy-rules")

    view = open(conn, path <> "/policy/history")
    assert has_element?(view, "#policy-tabs a[aria-current=page]", "History")
  end

  test "a target the workspace does not have, and a tab the page does not know, are not found",
       %{conn: conn, scope: scope, path: path} do
    other = scope_fixture()
    started_run(other, repo("github.example", "acme/theirs"))
    theirs = Targets.get(other, "github.example", "acme/theirs")

    # Another workspace's target, by its id: not this workspace's, so not found.
    assert Targets.get_by_public_id(scope, theirs.public_id) == nil
    assert Targets.get_by_public_id(other, theirs.public_id).id == theirs.id

    for missing <- [
          workspace_path(scope, "/targets/#{theirs.public_id}"),
          workspace_path(scope, "/targets/tg_0000000000000000"),
          workspace_path(scope, "/targets/nd_0000000000000000")
        ] do
      assert_raise Ecto.NoResultsError, fn -> live(conn, missing) end
    end

    for missing <- [path <> "/nope", path <> "/policy/nope"] do
      assert status(conn, missing) == 404, missing
    end
  end

  test "an address by system and path, the old form and its tabs, is not found", %{
    conn: conn,
    scope: scope,
    path: path
  } do
    started_run(scope, repo("github.example", "acme/billing"))

    for old <- [
          "/targets/github.example/acme/shop",
          "/targets/acme/shop",
          "/targets/acme/billing",
          "/targets/github.example/acme/billing",
          "/targets/acme/billing/-/policy",
          "/targets/acme/billing/-/runs",
          "/targets/github.example/acme/shop/-/network",
          "/targets/-/acme/x",
          "/targets/%FF"
        ] do
      assert status(conn, workspace_path(scope, old)) == 404, old
    end

    # The tabs no longer follow a `-` segment.
    assert status(conn, path <> "/-/policy") == 404
  end

  test "a path with a segment that would read as a step is named whole; the address is its id",
       %{conn: conn, scope: scope} do
    started_run(scope, repo("codeberg.org", "odd/-/name"))
    target = Targets.get(scope, "codeberg.org", "odd/-/name")

    path = TargetComponents.target_path(scope, target)
    assert path == workspace_path(scope, "/targets/#{target.public_id}")

    view = open(conn, path)
    assert has_element?(view, "#target-header h1", "odd/-/name")
    assert has_element?(view, "#target-external[href='https://codeberg.org/odd/-/name']")
  end

  test "a system named - is named with its path where the path is shared", %{
    conn: conn,
    scope: scope
  } do
    started_run(scope, repo("-", "acme/x"))
    started_run(scope, repo("codeberg.org", "acme/x"))
    target = Targets.get(scope, "-", "acme/x")

    view = open(conn, TargetComponents.target_path(scope, target))
    assert has_element?(view, "#target-header h1", "-/acme/x")
    assert has_element?(view, "#target-tabs-overview[aria-current=page]")

    assert has_element?(
             view,
             "#target-all-runs[href='#{workspace_path(scope, "/runs?system=-&target=acme%2Fx")}']"
           )
  end

  test "a run with no event does not stop the page", %{conn: conn, scope: scope, path: path} do
    _ = run_fixture(scope)
    view = open(conn, path)
    assert has_element?(view, "#target-overview")
  end
end
