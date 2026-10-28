defmodule ApiaryWeb.CollectionsLiveTest do
  # Workspace settings › Work sources and › Destinations (`ApiaryWeb.CollectionsLive`):
  # where they are in the settings' list; the tick lists as the set-up's steps have them,
  # read by a member and ticked by an admin; a collection in another workspace, and one
  # moved there after the page read it; the empty state; and who finds no page.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Repo
  alias Apiary.Adapters.Collection
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  setup %{conn: conn} do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.ManyWorkspaces)
    %{user: user, organisation: organisation, scope: scope} = sign_up_fixture()
    second = workspace_fixture(organisation, "Second")

    %{
      conn: log_in_user(conn, user),
      organisation: organisation,
      scope: scope,
      second: second,
      sources: workspace_path(scope, "/settings/work-sources"),
      destinations: workspace_path(scope, "/settings/destinations")
    }
  end

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp href(lv, selector) do
    [href] =
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("href")

    href
  end

  defp signed_in(scope, level) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  defp targets!(collection) do
    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^collection.adapter_id),
        set: [targets: true]
      )

    collection
  end

  defp row(collection) do
    c = Repo.get!(Collection, collection.id)
    {c.workspace_id, c.backlog}
  end

  test "both pages are in the settings' list after Model, Work sources first, before Workflow",
       ctx do
    {:ok, lv, html} = live(ctx.conn, ctx.sources)

    assert has_element?(lv, "#settings-section-title", "Work sources")
    assert has_element?(lv, ~s(#settings-tab-work_sources[href="#{ctx.sources}"]), "Work sources")
    assert has_element?(lv, ~s(#settings-tab-work_sources[aria-current="page"]))

    assert has_element?(
             lv,
             ~s(#settings-tab-destinations[href="#{ctx.destinations}"]),
             "Destinations"
           )

    assert page_title(lv) =~ "Work sources · Workspace settings · Main"

    tabs = for [_, key] <- Regex.scan(~r/id="settings-tab-([a-z_]+)"/, html), do: key

    assert Enum.drop_while(tabs, &(&1 != "model")) |> Enum.take(4) ==
             ~w(model work_sources destinations workflow)

    {:ok, lv, _html} = live(ctx.conn, ctx.destinations)
    assert has_element?(lv, "#settings-section-title", "Destinations")
    assert has_element?(lv, ~s(#settings-tab-destinations[aria-current="page"]))
    assert page_title(lv) =~ "Destinations · Workspace settings · Main"
  end

  test "a member reads both lists, with the boxes disabled and who may; a tick changes nothing",
       ctx do
    collection = targets!(collection_fixture(ctx.scope, workspace_id: nil))
    conn = signed_in(ctx.scope, :member)

    {:ok, lv, _html} = live(conn, ctx.sources)
    assert has_element?(lv, ".q-settings-head-sub", "Which work sources does Main use?")
    assert has_element?(lv, "#work-sources-tick-#{collection.public_id} input[disabled]")

    assert words(lv, "#work-sources-who-may") ==
             "Only owners and admins of #{ctx.organisation.name} assign collections to " <>
               "workspaces."

    render_click(lv, "tick", %{"id" => collection.id})
    assert row(collection) == {nil, true}

    {:ok, lv, _html} = live(conn, ctx.destinations)
    assert has_element?(lv, ".q-settings-head-sub", "Which repositories may Main's runs change?")
    assert has_element?(lv, "#destinations-tick-#{collection.public_id} input[disabled]")
    assert has_element?(lv, "#destinations-who-may")

    render_click(lv, "tick", %{"id" => collection.id})
    assert row(collection) == {nil, true}
  end

  test "Work sources: an admin's tick assigns with Backlog on; an untick unassigns", ctx do
    collection = collection_fixture(ctx.scope, workspace_id: nil)
    {:ok, lv, _html} = live(signed_in(ctx.scope, :admin), ctx.sources)

    refute has_element?(lv, "#work-sources-who-may")
    assert has_element?(lv, "#work-sources-tick-#{collection.public_id} input:not([checked])")

    lv |> element("#work-sources-tick-#{collection.public_id} input") |> render_click()
    assert row(collection) == {ctx.scope.workspace.id, true}
    assert has_element?(lv, "#work-sources-tick-#{collection.public_id} input[checked]")

    lv |> element("#work-sources-tick-#{collection.public_id} input") |> render_click()
    assert row(collection) == {nil, false}
  end

  test "Destinations: an admin's tick assigns with Backlog off; tickets come in once Work sources ticks it",
       ctx do
    collection = targets!(collection_fixture(ctx.scope, workspace_id: nil))
    conn = signed_in(ctx.scope, :admin)
    {:ok, lv, _html} = live(conn, ctx.destinations)

    lv |> element("#destinations-tick-#{collection.public_id} input") |> render_click()
    assert row(collection) == {ctx.scope.workspace.id, false}
    refute has_element?(lv, "#destinations-tick-#{collection.public_id}-tickets")
    refute has_element?(lv, "#destinations-untick")

    {:ok, sources, _html} = live(conn, ctx.sources)
    sources |> element("#work-sources-tick-#{collection.public_id} input") |> render_click()
    assert row(collection) == {ctx.scope.workspace.id, true}

    {:ok, lv, _html} = live(conn, ctx.destinations)
    assert words(lv, "#destinations-tick-#{collection.public_id}-tickets") == "tickets come in"
    assert words(lv, "#destinations-untick") == "Unticking also stops its tickets coming in."

    lv |> element("#destinations-tick-#{collection.public_id} input") |> render_click()
    assert row(collection) == {nil, false}
  end

  test "a collection in another workspace shows it, with no checkbox, and a tick moves nothing",
       ctx do
    elsewhere = targets!(collection_fixture(ctx.scope, workspace_id: ctx.second.id))

    for {path, prefix} <- [{ctx.sources, "work-sources"}, {ctx.destinations, "destinations"}] do
      {:ok, lv, _html} = live(ctx.conn, path)

      refute has_element?(lv, "##{prefix}-tick-#{elsewhere.public_id} input")

      assert words(lv, "##{prefix}-tick-#{elsewhere.public_id}-elsewhere") ==
               "In Second (cannot be ticked)"

      render_click(lv, "tick", %{"id" => elsewhere.id})
      assert row(elsewhere) == {ctx.second.id, true}
    end
  end

  test "a tick on a collection moved to another workspace since the page read it moves nothing",
       ctx do
    collection = collection_fixture(ctx.scope, workspace_id: nil)
    {:ok, lv, _html} = live(ctx.conn, ctx.sources)

    # Another admin assigns it to Second: the page still shows its checkbox.
    {:ok, _moved} = set_collection_workspace(collection, ctx.second)
    assert has_element?(lv, "#work-sources-tick-#{collection.public_id} input")

    lv |> element("#work-sources-tick-#{collection.public_id} input") |> render_click()
    assert row(collection) == {ctx.second.id, true}

    assert words(lv, "#work-sources-tick-#{collection.public_id}-elsewhere") ==
             "In Second (cannot be ticked)"
  end

  test "a tick on a collection that ends after the tick read the list says nothing changed",
       ctx do
    collection = collection_fixture(ctx.scope, workspace_id: nil)
    {:ok, lv, _html} = live(ctx.conn, ctx.sources)

    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.EndsCollectionAtAssign)

    {1, _} =
      Repo.update_all(from(c in Collection, where: c.id == ^collection.id),
        set: [title: "ends-at-assign"]
      )

    lv |> element("#work-sources-tick-#{collection.public_id} input") |> render_click()

    assert has_element?(lv, "#flash-error", "Nothing was changed. Try again.")
    assert Repo.get!(Collection, collection.id).workspace_id == nil
  end

  test "a tick on a collection of another organisation changes nothing", ctx do
    %{scope: theirs} = sign_up_fixture()
    collection = collection_fixture(theirs, workspace_id: nil)
    {:ok, lv, _html} = live(ctx.conn, ctx.sources)

    render_click(lv, "tick", %{"id" => collection.id})
    assert row(collection) == {nil, true}
  end

  test "with nothing connected, says so, with the step that connects one, or who may", ctx do
    slug = ctx.scope.workspace.slug
    {:ok, lv, _html} = live(ctx.conn, ctx.sources)

    assert words(lv, "#work-sources-none") ==
             "#{ctx.organisation.name} has no work source connected yet. Work sources"

    assert href(lv, "#work-sources-none-connect") ==
             ~p"/#{ctx.organisation}/set-up?step=sources&workspace=#{slug}"

    {:ok, lv, _html} = live(ctx.conn, ctx.destinations)

    assert words(lv, "#destinations-none") ==
             "#{ctx.organisation.name} has no work destination connected yet. Work destinations"

    assert href(lv, "#destinations-none-connect") ==
             ~p"/#{ctx.organisation}/set-up?step=destinations&workspace=#{slug}"

    {:ok, lv, _html} = live(signed_in(ctx.scope, :member), ctx.sources)
    refute has_element?(lv, "#work-sources-none-connect")

    assert words(lv, "#work-sources-none-who") ==
             "Only owners and admins change the integrations of the organisation."
  end

  test "the link to the step that connects one opens that step", ctx do
    {:ok, lv, _html} = live(ctx.conn, ctx.sources)

    {:ok, step, _html} =
      lv |> element("#work-sources-none-connect") |> render_click() |> follow_redirect(ctx.conn)

    assert has_element?(step, "h1", "Where does #{ctx.organisation.name}'s work come from?")
  end

  test "a change of the organisation's collections shows at once", ctx do
    {:ok, lv, _html} = live(ctx.conn, ctx.sources)
    assert has_element?(lv, "#work-sources-none")

    collection = collection_fixture(ctx.scope, workspace_id: nil)
    send(lv.pid, {:collections_changed, %{}})

    assert has_element?(lv, "#work-sources-tick-#{collection.public_id} input")
  end

  test "another organisation's owner finds no such page", ctx do
    %{user: user} = sign_up_fixture()
    conn = log_in_user(build_conn(), user)

    for path <- [ctx.sources, ctx.destinations] do
      assert get(conn, path).status == 404
    end
  end
end

defmodule ApiaryWeb.CollectionsLiveFeaturesTest do
  # Workspace settings › Work sources and › Destinations need the `factory` feature:
  # without it, neither is in the settings' list, and their paths are not found. Not async:
  # the features are the whole node's.
  use ApiaryWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup :register_and_log_in_user

  # The status a path answers: the instance's gate answers before the router, and a
  # page's gate raises a 404 exception.
  defp status(conn, path) do
    get(conn, path).status
  rescue
    error -> Plug.Exception.status(error)
  end

  defp tabs(conn, scope) do
    {:ok, _lv, html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/settings")
    for [_, key] <- Regex.scan(~r/id="settings-tab-([a-z_]+)"/, html), do: key
  end

  @tag :feature_sets
  test "the list has both exactly where the instance has the feature", %{
    conn: conn,
    scope: scope
  } do
    listed = Enum.filter(tabs(conn, scope), &(&1 in ~w(work_sources destinations)))

    if Apiary.Features.on?(:factory),
      do: assert(listed == ~w(work_sources destinations)),
      else: assert(listed == [])
  end

  @tag with_features: [:observability, :security, :secrets, :factory]
  test "with the feature, both are listed, Work sources first", %{conn: conn, scope: scope} do
    assert Enum.filter(tabs(conn, scope), &(&1 in ~w(work_sources destinations))) ==
             ~w(work_sources destinations)

    for rest <- ~w(/settings/work-sources /settings/destinations) do
      assert status(conn, workspace_path(scope, rest)) == 200, rest
    end
  end

  @tag with_features: [:observability, :security, :secrets]
  test "without the feature, neither is listed and their paths are not found", %{
    conn: conn,
    scope: scope
  } do
    tabs = tabs(conn, scope)
    refute "work_sources" in tabs
    refute "destinations" in tabs

    for rest <- ~w(/settings/work-sources /settings/destinations) do
      assert status(conn, workspace_path(scope, rest)) == 404, rest
    end
  end
end
