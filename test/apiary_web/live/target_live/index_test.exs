defmodule ApiaryWeb.TargetLive.IndexTest do
  @moduledoc """
  The workspace's targets (`ApiaryWeb.TargetLive.Index`): the rows, the views, the search
  and its qualifiers, the Filter and Sort menus, the pages and the reader's pins.
  """
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.RunListFixtures

  alias Apiary.{AccessKeys, Repo, Targets}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections}

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
             "#{row} a[href='#{workspace_path(scope, "/targets/#{shop.public_id}")}']"
           )

    # The last run went badly: its word shows, and so do the denied attempts.
    assert has_element?(view, "#{row} .q-tgt-lw", "Failed")
    assert has_element?(view, "#{row} .q-tgt-denied", "1")
    assert has_element?(view, "#{row} .q-spark")
    # Below 80 % the share is lifted to the text colour; red is for denials only.
    assert has_element?(view, "#{row} .q-hot", "0%")
    refute has_element?(view, "#{row} .text-error", "0%")
    assert has_element?(view, "#targets-pager", "1–3 of 3")
  end

  test "a last run that was cancelled is its dot and its word",
       %{conn: conn, scope: scope} do
    started_run(scope, repo("github.example", "acme/quiet"),
      ago: 30,
      exit: %{"state" => "cancelled", "reason" => "timeout"}
    )

    quiet = Targets.get(scope, "github.example", "acme/quiet")
    view = open(conn, scope)
    row = "#target-#{quiet.id}"

    assert has_element?(view, "#{row} .q-sdot-cancelled .sr-only", "Cancelled")
    assert has_element?(view, "#{row} .q-tgt-lw.q-sdot-cancelled", "Cancelled")
  end

  test "the breadcrumb ends with the section, in the workspace's words, the page itself", %{
    conn: conn,
    scope: scope
  } do
    view = open(conn, scope)
    assert crumbs(view) == [{"Repositories", nil}]
    assert has_element?(view, "#breadcrumb [aria-current=page]", "Repositories")

    assert crumbs(open(conn, scope, "?q=shop")) == [{"Repositories", nil}]
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

    # As the reader types, a qualifier is left out until they press Enter.
    view
    |> form("#targets-search")
    |> render_change(%{"q" => "forge:github.exa shop", "_target" => ["q"]})

    assert_patch(view, workspace_path(scope, "/targets?q=shop"))

    view |> form("#targets-search", %{"q" => "forge:github.example shop"}) |> render_submit()
    path = workspace_path(scope, "/targets?q=forge%3Agithub.example+shop")
    assert_patch(view, path)
    render_async(view, 2_000)

    assert rows(view) == ["github.example/acme/shop"]
    assert has_element?(view, "#targets-tokens .q-tok", "github.example")
    assert has_element?(view, "#targets-search-input[value=shop]")
    assert has_element?(view, "#targets-summary", "1 repository matches")
    assert has_element?(view, "#targets-status[role=status] #targets-summary")

    view |> element("#targets-tokens .q-tok a") |> render_click()
    assert_patch(view, workspace_path(scope, "/targets?q=shop"))
  end

  test "a system and a path Forager sent: cleaned in the Filter menu, a token and a row's title",
       %{conn: conn, scope: scope} do
    system = "zz\u202E.example"
    started_run(scope, repo(system, "acme/\u202Edocs\u200B"), ago: 30)

    view = open(conn, scope)
    menu = view |> element("#targets-filter") |> render()
    assert menu =~ ~r{<bdi[^>]*>zz.example</bdi>}
    # Only an item's id, which addresses it, keeps the system as sent.
    refute String.replace(menu, ~r/ id="[^"]*"/, "") =~ "\u202E"
    assert has_element?(view, ~s(#targets tr .q-tgt-name[title="zz.example/acme/docs"]))

    view = open(conn, scope, "?" <> URI.encode_query(%{"q" => "forge:#{system}"}))
    assert has_element?(view, "#targets-tokens .q-tok bdi", "zz.example")
    assert has_element?(view, ~s(#targets-tokens [aria-label="Remove forge:zz.example"]))
    refute view |> element("#targets-tokens") |> render() =~ "\u202E"
    assert rows(view) == ["acme/docs"]
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
    assert has_element?(view, "#targets-sort-button[aria-label='Sort: Name']")
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
    shop: shop,
    api: api
  } do
    view = open(conn, scope)
    refute has_element?(view, "#nav-group-pinned")

    # Its spoken name names the target by its path, with its system only where another
    # system shares the path.
    assert has_element?(view, "#target-pin-#{shop.id}[aria-label='Pin github.example/acme/shop']")
    assert has_element?(view, "#target-pin-#{api.id}[aria-label='Pin acme/api']")

    view |> element("#target-pin-#{shop.id}") |> render_click()
    assert has_element?(view, "#target-pin-#{shop.id}[aria-pressed=true]")

    assert has_element?(
             view,
             "#target-pin-#{shop.id}[aria-label='Unpin github.example/acme/shop']"
           )

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

  @tag needs: :factory
  test "a repository assigned with a collection, before any run, is listed in All and in Never",
       %{conn: conn, scope: scope} do
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    {connection, _nonce} =
      connection_fixture(scope, connectable.adapter, :connected)

    {:ok, verified} = AccessKeys.fetch_for_verification(connectable.access_key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(verified), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections: [
          %{
            ref: "NEW",
            url: "https://tracker.acme.example/NEW",
            title: "New",
            target: %{system: "code.example.com", path: "acme/new"}
          }
        ],
        listing: %{
          id: "listing-1",
          part: 1,
          started_at: DateTime.utc_now(:second),
          complete: false
        }
      })

    collection = Repo.get_by!(Collection, connection_id: connection.id)

    {:ok, _changed} =
      Collections.assign_collections(
        scope,
        connection,
        [collection.id],
        scope.workspace
      )

    view = open(conn, scope)
    assert has_element?(view, "#targets-view-all[aria-current=page]", "4")
    assert has_element?(view, "#targets-view-never", "1")
    assert "acme/new" in rows(view)

    view = open(conn, scope, "?view=never")
    assert rows(view) == ["acme/new"]
  end

  @tag needs: :factory
  test "a listing that changes an assigned collection's repository lists the new one, which takes the Backlog card",
       %{conn: conn, scope: scope} do
    connectable = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
    {connection, _nonce} = connection_fixture(scope, connectable.adapter, :connected)
    {:ok, verified} = AccessKeys.fetch_for_verification(connectable.access_key.key_id)

    post = fn path, listing, started_at ->
      {:ok, :accepted} =
        Collections.post_listing(Scope.for_access_key(verified), %{
          time: DateTime.utc_now(:second),
          connection_id: connection.public_id,
          collections: [
            %{
              ref: "NEW",
              url: "https://tracker.acme.example/NEW",
              title: "New",
              target: %{system: "code.example.com", path: path}
            }
          ],
          listing: %{id: listing, part: 1, started_at: started_at, complete: false}
        })
    end

    started_at = DateTime.utc_now(:second)
    post.("acme/new", "listing-1", started_at)
    collection = Repo.get_by!(Collection, connection_id: connection.id)

    {:ok, _changed} =
      Collections.assign_collections(scope, connection, [collection.id], scope.workspace)

    post.("acme/moved", "listing-2", DateTime.add(started_at, 60))

    view = open(conn, scope, "?view=never")
    assert Enum.sort(rows(view)) == ["acme/moved", "acme/new"]

    assert %{rows: never} = Targets.page(scope, %{view: :never})
    assert %{runs: 0} = Enum.find(never, &(&1.target.path == "acme/moved"))

    old = Targets.get(scope, "code.example.com", "acme/new")
    new = Targets.get(scope, "code.example.com", "acme/moved")

    {:ok, view, _html} = live(conn, workspace_path(scope, "/targets/#{new.public_id}"))
    render_async(view, 2_000)
    assert has_element?(view, "#target-backlog")

    {:ok, view, _html} = live(conn, workspace_path(scope, "/targets/#{old.public_id}"))
    render_async(view, 2_000)
    refute has_element?(view, "#target-backlog")
  end

  test "a workspace no run named a target of says what fills the page" do
    %{scope: scope, user: user} = sign_up_fixture()
    conn = log_in_user(build_conn(), user)

    view = open(conn, scope)
    assert has_element?(view, "#targets-empty", "No repository yet")
  end

  @tag needs: :security
  test "the Policy filters and column are left out where the policy is hidden from the reader",
       %{conn: conn, scope: scope} do
    view = open(conn, scope)
    assert has_element?(view, "#targets-filter-follows")

    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.HidesNamed)
    :ok = Apiary.EditionStubs.HidesNamed.put([:security])
    view = open(conn, scope)

    assert rows(view) != []
    refute has_element?(view, "#targets-filter-follows")
    refute has_element?(view, "#targets th", "Policy")
  end
end
