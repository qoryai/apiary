defmodule ApiaryWeb.CollectionsLiveTest do
  # Workspace settings › Work sources and › Destinations (`ApiaryWeb.CollectionsLive`):
  # where they are in the settings' list; a card per grant, as the set-up's steps have
  # them, with Choose, which opens the chooser in the settings
  # (`ApiaryWeb.ChooseCollectionsLive`, `:settings`), whose Save and Back return to the
  # page; Connect another; who may; a change shown at once; and who finds no page.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Grant, GrantRule}
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
      main: scope.workspace,
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

  defp targets!(adapter) do
    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [targets: true])

    Repo.get!(Node, adapter.id)
  end

  # A configured adapter connected for `scope`'s organisation, and a part of a listing of
  # `refs` under the connection's grant, for the account acme; with `targets: true`, an
  # adapter with targets, and each collection's target on code.example.com at its ref.
  defp listed!(scope, refs, opts \\ []) do
    %{adapter: adapter, access_key: key} = connectable_adapter_fixture()
    adapter = if opts[:targets], do: targets!(adapter), else: adapter
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    {:ok, verified} = AccessKeys.fetch_for_verification(key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(verified), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections:
          for ref <- refs do
            %{
              ref: ref,
              url: "https://forge.example.com/" <> ref,
              title: ref,
              grant_ref: listing_grant(connection),
              target: if(opts[:targets], do: %{system: "code.example.com", path: ref})
            }
          end,
        listing: %{
          id: "first",
          part: 1,
          started_at: DateTime.utc_now(:second),
          complete: false
        }
      })

    grant = Repo.get_by!(Grant, connection_id: connection.id)
    %{adapter: adapter, connection: connection, grant: grant}
  end

  # The live collection of `connection` with the ref `ref`.
  defp collection!(connection, ref) do
    Repo.one!(
      from c in Collection,
        where: c.connection_id == ^connection.id and c.external_ref == ^ref,
        where: is_nil(c.ended_at)
    )
  end

  defp row(collection) do
    c = Repo.get!(Collection, collection.id)
    {c.workspace_id, c.backlog}
  end

  # The chooser of `grant` in the settings of the scope's workspace.
  defp chooser(ctx, step, grant, query \\ []),
    do:
      ~p"/#{ctx.organisation}/#{ctx.main}/settings/choose?#{[step: step, grant: grant.public_id] ++ query}"

  defp pick(lv, collection),
    do: lv |> element("#collection-#{collection.public_id}-pick") |> render_click()

  defp save(lv), do: lv |> form("#choose-form") |> render_submit()

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

  test "a grant's card: the adapter and the account, how many are chosen, Choose to the settings' chooser",
       ctx do
    %{adapter: adapter, grant: grant, connection: connection} =
      listed!(ctx.scope, ["acme/api", "acme/shop"])

    %{adapter: other} = connectable_adapter_fixture()

    {:ok, lv, _html} = live(ctx.conn, ctx.sources)
    assert has_element?(lv, ".q-settings-head-sub", "Which work sources does Main use?")

    card = "#work-sources-grants #work-sources-grant-#{grant.public_id}"
    assert words(lv, "#{card}-title") == "#{Apiary.Adapters.title(adapter)} · acme"
    assert words(lv, "#{card}-summary") == "0 of 2 collections"
    assert href(lv, "#{card}-choose") == chooser(ctx, :sources, grant)

    # The connected adapter is not under Connect another source, which is closed; the
    # other adapter is, and its install leads to the set-up's step of Main.
    refute has_element?(lv, "#work-sources-adapter-#{adapter.public_id}")
    assert words(lv, "#work-sources-connect-another") == "Connect another source"

    assert has_element?(
             lv,
             "#work-sources-connect:not([open]) #work-sources-adapter-#{other.public_id}"
           )

    back = URI.encode_query(back: "set-up:sources:workspace=#{ctx.main.public_id}")

    assert has_element?(
             lv,
             ~s{#work-sources-adapter-#{other.public_id}-connect[action="/#{ctx.organisation.slug}/settings/integrations/#{other.public_id}/install?#{back}"]}
           )

    api = collection!(connection, "acme/api")
    {:ok, 1} = Collections.choose(ctx.scope, grant, ctx.main, :sources, {:only, [api.id]})
    send(lv.pid, {:collections_changed, %{}})
    assert words(lv, "#{card}-summary") == "1 of 2 collections"

    {:ok, 1} = Collections.choose(ctx.scope, grant, ctx.main, :sources, :all)
    send(lv.pid, {:collections_changed, %{}})
    assert words(lv, "#{card}-summary") == "All collections"
  end

  test "Choose opens the chooser in the settings; Save assigns with Backlog on and returns to Work sources",
       ctx do
    %{adapter: adapter, grant: grant, connection: connection} =
      listed!(ctx.scope, ["acme/api", "acme/shop", "acme/web"])

    [api, shop, web] =
      Enum.map(["acme/api", "acme/shop", "acme/web"], &collection!(connection, &1))

    {:ok, _moved} = set_collection_workspace(web, ctx.second)
    {:ok, page, _html} = live(ctx.conn, ctx.sources)

    {:ok, lv, html} =
      page
      |> element("#work-sources-grant-#{grant.public_id}-choose")
      |> render_click()
      |> follow_redirect(ctx.conn, chooser(ctx, :sources, grant))

    title = "Choose collections · #{Apiary.Adapters.title(adapter)} · acme"
    assert html =~ title
    assert words(lv, "#choose h1") == title
    assert page_title(lv) =~ "#{title} · Work sources · Workspace settings · Main"
    assert has_element?(lv, ~s(#settings-tab-work_sources[aria-current="true"]))
    refute has_element?(lv, "#set-up-step-list")
    assert has_element?(lv, "#choose-only[checked]")
    assert words(lv, "#choose-count") == "0 selected"

    refute has_element?(lv, "#collection-#{web.public_id}-pick")
    assert words(lv, "#collection-#{web.public_id}-elsewhere") == "In Second (cannot be ticked)"

    pick(lv, api)
    assert words(lv, "#choose-count") == "1 selected"
    assert href(lv, "#choose-back") == ctx.sources
    sources = ctx.sources
    assert {:error, {:live_redirect, %{to: ^sources}}} = save(lv)

    assert row(api) == {ctx.main.id, true}
    assert row(shop) == {nil, true}
    assert row(web) == {ctx.second.id, true}
    assert Repo.aggregate(GrantRule, :count) == 0
  end

  test "the settings' chooser pages and searches at its own path", ctx do
    refs = for n <- 1..60, do: "acme/repo-" <> String.pad_leading("#{n}", 2, "0")
    %{grant: grant} = listed!(ctx.scope, refs ++ ["acme/shop"])
    {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))

    assert words(lv, "#choose-pager-footer") == "1–50 of 61"
    lv |> element("#choose-pager-next") |> render_click()
    assert_patch(lv, chooser(ctx, :sources, grant, page: 2))
    assert words(lv, "#choose-pager-footer") == "51–61 of 61"

    lv |> form("#choose-search", %{q: "shop"}) |> render_change()
    assert_patch(lv, chooser(ctx, :sources, grant, q: "shop"))
  end

  test "Destinations: Choose opens its chooser, locked to All while Work sources is set to All; Save returns to Destinations",
       ctx do
    %{grant: grant, connection: connection} =
      listed!(ctx.scope, ["acme/api", "acme/shop"], targets: true)

    {:ok, page, _html} = live(ctx.conn, ctx.destinations)

    assert has_element?(
             page,
             ".q-settings-head-sub",
             "Which repositories may runs in Main change?"
           )

    assert words(page, "#destinations-grant-#{grant.public_id}-summary") ==
             "0 of 2 collections"

    {:ok, lv, _html} =
      page
      |> element("#destinations-grant-#{grant.public_id}-choose")
      |> render_click()
      |> follow_redirect(ctx.conn, chooser(ctx, :destinations, grant))

    assert has_element?(lv, ~s(#settings-tab-destinations[aria-current="true"]))
    api = collection!(connection, "acme/api")
    pick(lv, api)
    assert href(lv, "#choose-back") == ctx.destinations
    destinations = ctx.destinations
    assert {:error, {:live_redirect, %{to: ^destinations}}} = save(lv)
    assert row(api) == {ctx.main.id, false}

    {:ok, _count} = Collections.choose(ctx.scope, grant, ctx.main, :sources, :all)
    {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :destinations, grant))
    assert has_element?(lv, "#choose-all[checked]")
    refute has_element?(lv, "#choose-only")

    assert words(lv, "#choose-locked") ==
             "Work sources is set to All for acme. Change it there first."

    render_change(lv, "mode", %{"mode" => "only"})
    assert has_element?(lv, "#choose-all[checked]")
  end

  test "another workspace's All: Only selected alone, with the line", ctx do
    %{grant: grant} = listed!(ctx.scope, ["acme/api"])
    {:ok, 1} = Collections.choose(ctx.scope, grant, ctx.second, :sources, :all)

    {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))
    refute has_element?(lv, "#choose-all")
    assert has_element?(lv, "#choose-only[checked]")
    assert words(lv, "#choose-taken") == "All new collections of acme go to Second."

    render_change(lv, "mode", %{"mode" => "all"})
    assert has_element?(lv, "#choose-only[checked]")
  end

  test "an account with no name or one of whitespace: the card, the heading, the breadcrumb, the browser title and both lines leave it out",
       ctx do
    %{adapter: adapter, grant: grant} = listed!(ctx.scope, ["acme/api"], targets: true)
    {:ok, 1} = Collections.choose(ctx.scope, grant, ctx.main, :sources, :all)
    title = Apiary.Adapters.title(adapter)
    heading = "Choose collections · #{title}"

    # `adapter_grants_account_check` allows a ref with a name of 1 to 1024 characters, or
    # neither, so the empty name is tested on `account/1`.
    assert ApiaryWeb.IntegrationComponents.account(%{account_title: ""}) == nil

    for {ref, account} <- [{nil, nil}, {"acme", " \t\u00A0 "}] do
      {1, _} =
        Repo.update_all(from(g in Grant, where: g.id == ^grant.id),
          set: [account_ref: ref, account_title: account]
        )

      {:ok, page, _html} = live(ctx.conn, ctx.destinations)
      assert words(page, "#destinations-grant-#{grant.public_id}-title") == title

      {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :destinations, grant))
      assert words(lv, "#choose h1") == heading
      assert {^heading, nil} = List.last(crumbs(lv))
      assert page_title(lv) =~ "#{heading} · Destinations · Workspace settings · Main"

      assert words(lv, "#choose-locked") ==
               "Work sources is set to All for this account. Change it there first."

      # In Second's settings, Main's All of the grant.
      {:ok, lv, _html} =
        live(
          ctx.conn,
          ~p"/#{ctx.organisation}/#{ctx.second}/settings/choose?#{[step: :sources, grant: grant.public_id]}"
        )

      assert words(lv, "#choose h1") == heading
      assert words(lv, "#choose-taken") == "All new collections of this account go to Main."
    end
  end

  test "Not listed? shows the adapter's line on its access, with Change access to its Install",
       ctx do
    %{adapter: adapter, grant: grant} = listed!(ctx.scope, ["acme/api"])

    {1, _} =
      Repo.update_all(from(n in Node, where: n.id == ^adapter.id),
        set: [source_access: "Pick the repositories in the installation's settings."]
      )

    {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))

    assert words(lv, "#choose-access") =~
             "Not listed? Pick the repositories in the installation's settings."

    back = URI.encode_query(back: "set-up:sources:workspace=#{ctx.main.public_id}")

    assert has_element?(
             lv,
             ~s{#choose-change-access[action="/#{ctx.organisation.slug}/settings/integrations/#{adapter.public_id}/install?#{back}"]}
           )

    assert has_element?(lv, "#choose-change-access-install", "Change access")
  end

  test "a member reads the cards and who may; the chooser is disabled and a save sent changes nothing",
       ctx do
    %{grant: grant, connection: connection} = listed!(ctx.scope, ["acme/api"])
    %{adapter: other} = connectable_adapter_fixture()
    api = collection!(connection, "acme/api")
    conn = signed_in(ctx.scope, :member)

    {:ok, page, _html} = live(conn, ctx.sources)

    who_may =
      "Only owners and admins of #{ctx.organisation.name} assign collections to workspaces."

    assert words(page, "#work-sources-who-may") == who_may
    assert has_element?(page, "#work-sources-grant-#{grant.public_id}-choose")
    assert has_element?(page, "#work-sources-adapter-#{other.public_id}")
    refute has_element?(page, "#work-sources-adapter-#{other.public_id}-connect")

    assert words(page, "#work-sources-connect-who-may") ==
             "Only owners and admins change the integrations of the organisation."

    # An install sent anyway starts nothing.
    render_click(page, "install", %{"integration" => other.public_id})
    refute has_element?(page, "#work-sources-adapter-#{other.public_id}-connect")

    {:ok, lv, _html} = live(conn, chooser(ctx, :sources, grant))
    assert has_element?(lv, "#choose-only[disabled]")
    refute has_element?(lv, "#collection-#{api.public_id}-pick")
    refute has_element?(lv, "#choose-save")
    assert words(lv, "#choose-who-may") == who_may

    render_click(lv, "select", %{"collection" => api.public_id})
    render_change(lv, "mode", %{"mode" => "all"})
    render_submit(lv, "save", %{})
    assert row(api) == {nil, true}
    assert Repo.aggregate(GrantRule, :count) == 0
  end

  test "with no adapter for the type, says so; with one not connected, Connect another is open",
       ctx do
    {:ok, lv, _html} = live(ctx.conn, ctx.sources)

    assert words(lv, "#work-sources-no-adapter") ==
             "No work source for this type is set up on this instance. An instance admin " <>
               "sets one up in Instance settings › Adapters."

    refute has_element?(lv, "#work-sources-connect")

    {:ok, lv, _html} = live(ctx.conn, ctx.destinations)

    assert words(lv, "#destinations-no-adapter") ==
             "No work destination for this type is set up on this instance. An instance " <>
               "admin sets one up in Instance settings › Adapters."

    %{adapter: adapter} = connectable_adapter_fixture()
    {:ok, lv, _html} = live(ctx.conn, ctx.sources)
    refute has_element?(lv, "#work-sources-no-adapter")
    refute has_element?(lv, "#work-sources-grants")
    row = "#work-sources-connect[open] #work-sources-adapter-#{adapter.public_id}"
    assert has_element?(lv, row <> "-not-connected", "Not connected")

    assert has_element?(
             lv,
             "#work-sources-adapter-#{adapter.public_id}-connect-install",
             "Connect"
           )
  end

  test "a connected adapter with no grant yet shows Connected; a pending one Connecting…", ctx do
    %{adapter: connected} = connectable_adapter_fixture()
    {_connection, _nonce} = connection_fixture(ctx.scope, connected, :connected)
    %{adapter: pending} = connectable_adapter_fixture()
    {_connection, _nonce} = connection_fixture(ctx.scope, pending, :pending)

    {:ok, lv, _html} = live(ctx.conn, ctx.sources)

    assert has_element?(
             lv,
             "#work-sources-grants #work-sources-adapter-#{connected.public_id}-connected",
             "Connected"
           )

    assert has_element?(
             lv,
             "#work-sources-adapter-#{pending.public_id}-connecting",
             "Connecting…"
           )
  end

  test "a change of the organisation's collections shows at once", ctx do
    {:ok, lv, _html} = live(ctx.conn, ctx.sources)
    refute has_element?(lv, "#work-sources-grants")

    %{grant: grant} = listed!(ctx.scope, ["acme/api"])
    send(lv.pid, {:collections_changed, %{}})

    assert has_element?(lv, "#work-sources-grant-#{grant.public_id}-choose")
  end

  test "another organisation's grant, an unknown step or grant is no page; another organisation's collection is not picked",
       ctx do
    %{grant: grant} = listed!(ctx.scope, ["acme/api"])
    %{scope: theirs} = sign_up_fixture()
    %{grant: their_grant, connection: their_connection} = listed!(theirs, ["beta/api"])
    base = workspace_path(ctx.scope, "/settings/choose")

    for path <- [
          chooser(ctx, :sources, their_grant),
          chooser(ctx, :elsewhere, grant),
          base <> "?step=sources&grant=ag_0000000000000000",
          base <> "?step=sources&grant=not-a-grant",
          base
        ] do
      assert_raise ApiaryWeb.NotFound, fn -> live(ctx.conn, path) end
    end

    their = collection!(their_connection, "beta/api")
    {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant))
    render_click(lv, "select", %{"collection" => their.public_id})
    assert words(lv, "#choose-count") == "0 selected"
    {:error, {:live_redirect, _}} = save(lv)
    assert row(their) == {nil, true}
  end

  # In the core, `collection.assign` is the organisation's: a person who may assign in
  # one workspace may in every workspace of the organisation. A workspace where they may
  # not assign is one of another organisation.
  test "a workspace in ?workspace= is not the page's: Save under All assigns to the path's workspace, and nothing in another organisation's workspace",
       ctx do
    %{grant: grant, connection: connection} = listed!(ctx.scope, ["acme/api"])
    %{scope: theirs} = sign_up_fixture()
    billing = workspace_fixture(theirs.organisation, "Billing")
    %{grant: their_grant, connection: their_connection} = listed!(theirs, ["beta/api"])

    {:ok, lv, _html} = live(ctx.conn, chooser(ctx, :sources, grant, workspace: billing.slug))
    assert page_title(lv) =~ " · Work sources · Workspace settings · Main"
    lv |> form("#choose-form", %{mode: "all"}) |> render_change()
    sources = ctx.sources
    assert {:error, {:live_redirect, %{to: ^sources}}} = save(lv)

    assert Repo.get_by!(GrantRule, grant_id: grant.id).workspace_id == ctx.main.id
    assert row(collection!(connection, "acme/api")) == {ctx.main.id, true}

    assert Repo.aggregate(from(c in Collection, where: c.workspace_id == ^billing.id), :count) ==
             0

    assert Repo.aggregate(from(r in GrantRule, where: r.workspace_id == ^billing.id), :count) ==
             0

    assert Repo.get_by(GrantRule, grant_id: their_grant.id) == nil
    assert row(collection!(their_connection, "beta/api")) == {nil, true}
  end

  test "a workspace in the path the person does not reach, or of another organisation, is no page",
       ctx do
    :ok = Apiary.Edition.put_test_stub(Apiary.EditionStubs.MembersReachNamed)
    %{grant: grant} = listed!(ctx.scope, ["acme/api"])
    %{scope: theirs} = sign_up_fixture()
    billing = workspace_fixture(theirs.organisation, "Billing")
    params = [step: :sources, grant: grant.public_id]

    %{user: member} = member_fixture(ctx.scope, :member)
    Apiary.EditionStubs.MembersReachNamed.put([ctx.main.id])
    member_conn = log_in_user(build_conn(), member)
    second = ~p"/#{ctx.organisation}/#{ctx.second}/settings/choose?#{params}"

    assert {:ok, _lv, _html} = live(member_conn, chooser(ctx, :sources, grant))
    assert get(member_conn, second).status == 404

    elsewhere = ~p"/#{ctx.organisation}/#{billing.slug}/settings/choose?#{params}"
    assert get(ctx.conn, elsewhere).status == 404
  end

  test "another organisation's owner finds no such page", ctx do
    %{grant: grant} = listed!(ctx.scope, ["acme/api"])
    %{user: user} = sign_up_fixture()
    conn = log_in_user(build_conn(), user)

    for path <- [ctx.sources, ctx.destinations, chooser(ctx, :sources, grant)] do
      assert get(conn, path).status == 404
    end
  end
end

defmodule ApiaryWeb.CollectionsLiveFeaturesTest do
  # Workspace settings › Work sources and › Destinations need the `factory` feature:
  # without it, neither is in the settings' list, and their paths and the chooser's are
  # not found. Not async: the features are the whole node's.
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

    for rest <- ~w(/settings/work-sources /settings/destinations /settings/choose) do
      assert status(conn, workspace_path(scope, rest)) == 404, rest
    end
  end
end
