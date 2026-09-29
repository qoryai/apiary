defmodule ApiaryWeb.TargetLive.IndexTest do
  @moduledoc """
  The workspace's targets (`ApiaryWeb.TargetLive.Index`): the rows, the views, the search
  and its qualifiers, the Filter and Sort menus, the pages and the reader's pins.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.Targets

  setup :register_and_log_in_user

  @day 86_400

  defp repo(system, path), do: %{"forge" => system, "repository" => path}

  defp open(conn, scope, query \\ "") do
    {:ok, view, _html} = live(conn, workspace_path(scope, "/targets" <> query))
    render_async(view, 2_000)
    view
  end

  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#targets tr .q-tgt-name")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.replace(~r/\s+/, "")))
  end

  setup %{scope: scope} do
    started_run(scope, repo("github.example", "acme/shop"),
      ago: 60,
      exit: %{"state" => "failed", "exit_code" => 1},
      egress: [%{"decision" => "denied", "outcome" => "refused", "host" => "x.example"}]
    )

    started_run(scope, repo("gitlab.example", "acme/shop"), ago: 3 * @day)
    started_run(scope, repo("github.example", "acme/api"), ago: 40 * @day)

    %{
      shop: Targets.get(scope, "github.example", "acme/shop"),
      api: Targets.get(scope, "github.example", "acme/api")
    }
  end

  test "one row per target, by last run, the system written where the path is shared", %{
    conn: conn,
    scope: scope,
    shop: shop
  } do
    view = open(conn, scope)

    assert has_element?(view, "#nav-targets[aria-current=page]")
    assert has_element?(view, "h1", "Repositories")
    assert rows(view) == ["github.example/acme/shop", "gitlab.example/acme/shop", "acme/api"]

    row = "#target-#{shop.id}"

    assert has_element?(
             view,
             "#{row} a[href='#{workspace_path(scope, "/targets/github.example/acme/shop")}']"
           )

    # The last run went badly: its word shows, and so do the denied attempts.
    assert has_element?(view, "#{row} .q-tgt-lw", "Failed")
    assert has_element?(view, "#{row} .q-tgt-denied", "1")
    assert has_element?(view, "#{row} .q-tgt-spark")
    assert has_element?(view, "#{row} .text-error", "0%")
    assert has_element?(view, "#targets-pager", "1–3 of 3")
  end

  test "the views, with the workspace's counts", %{conn: conn, scope: scope} do
    view = open(conn, scope)
    assert has_element?(view, "#targets-view-all[aria-current=page]", "3")
    assert has_element?(view, "#targets-view-active", "2")
    assert has_element?(view, "#targets-view-never", "0")

    view |> element("#targets-view-active") |> render_click()
    assert_patch(view, workspace_path(scope, "/targets?view=active"))
    render_async(view, 2_000)
    assert rows(view) == ["github.example/acme/shop", "gitlab.example/acme/shop"]

    view = open(conn, scope, "?view=never")
    assert has_element?(view, "#targets-empty", "Every repository has run")
  end

  test "the search takes qualifiers, which become tokens the reader removes", %{
    conn: conn,
    scope: scope
  } do
    view = open(conn, scope)

    view |> form("#targets-search", %{"q" => "forge:github.example shop"}) |> render_submit()
    path = workspace_path(scope, "/targets?q=forge%3Agithub.example+shop")
    assert_patch(view, path)
    render_async(view, 2_000)

    assert rows(view) == ["github.example/acme/shop"]
    assert has_element?(view, ".q-tgt-qtok", "github.example")
    assert has_element?(view, "#targets-q[value=shop]")
    assert has_element?(view, "#targets-summary", "1 repository matches")

    view |> element(".q-tgt-qtok a") |> render_click()
    assert_patch(view, workspace_path(scope, "/targets?q=shop"))
  end

  test "the Filter menu writes the qualifiers, and Sort orders", %{
    conn: conn,
    scope: scope,
    api: api
  } do
    view = open(conn, scope)

    assert has_element?(view, "#targets-filter-system-gitlab\\.example", "gitlab.example")
    view |> element("#targets-filter-quiet-30") |> render_click()
    assert_patch(view, workspace_path(scope, "/targets?q=activity%3Aquiet-30d"))
    render_async(view, 2_000)
    assert rows(view) == ["acme/api"]
    assert has_element?(view, "#targets-filter-quiet-30[aria-checked=true]")

    view = open(conn, scope, "?sort=name")
    assert has_element?(view, "#targets-sort-button", "Name")
    assert rows(view) == ["acme/api", "github.example/acme/shop", "gitlab.example/acme/shop"]

    :ok = Targets.pin(scope, api)
    view = open(conn, scope, "?q=is%3Apinned")
    assert rows(view) == ["acme/api"]
  end

  test "what a link says that the page does not know is left out", %{conn: conn, scope: scope} do
    assert {:error, {:live_redirect, %{to: to}}} =
             live(conn, workspace_path(scope, "/targets?view=nope&sort=nope&page=0&x=1"))

    assert to == workspace_path(scope, "/targets")
  end

  test "the star pins a target for the reader, and the sidebar lists it", %{
    conn: conn,
    scope: scope,
    shop: shop
  } do
    view = open(conn, scope)
    refute has_element?(view, "#nav-group-pinned")

    view |> element("#target-pin-#{shop.id}") |> render_click()
    assert has_element?(view, "#target-pin-#{shop.id}[aria-pressed=true]")
    assert has_element?(view, "#nav-pin-#{shop.id}", "acme/shop")
    assert Targets.pinned?(scope, shop)

    view |> element("#target-pin-#{shop.id}") |> render_click()
    refute has_element?(view, "#nav-group-pinned")
    refute Targets.pinned?(scope, shop)
  end

  test "pages of 50", %{conn: conn, scope: scope} do
    for n <- 1..48, do: started_run(scope, repo("github.example", "bulk/#{n}"), ago: 600 + n)

    view = open(conn, scope)
    assert length(rows(view)) == 50
    assert has_element?(view, "#targets-pager", "1–50 of 51")
    view |> element("#targets-next") |> render_click()
    assert_patch(view, workspace_path(scope, "/targets?page=2"))
    render_async(view, 2_000)
    assert length(rows(view)) == 1
  end

  test "a workspace no run named a target of says what fills the page" do
    %{scope: scope, user: user} = sign_up_fixture()
    conn = log_in_user(build_conn(), user)

    view = open(conn, scope)
    assert has_element?(view, "#targets-empty", "No repository yet")
  end
end
