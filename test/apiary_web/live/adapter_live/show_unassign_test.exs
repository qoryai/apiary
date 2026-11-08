defmodule ApiaryWeb.AdapterLive.ShowUnassignTest do
  # Unassign on an integration's page in Organisation settings › Integrations
  # (`ApiaryWeb.AdapterLive.Show`): Unassign on each assigned row, for whoever may assign;
  # the confirmation in the row's place, and Cancel; Yes, unassign, with the row, the
  # warning, the view's count, the flash and the audit entry; a row on a workspace marked
  # for deletion; the Backlog that no longer lists the collection's tickets; an adapter
  # with no items; the refusal for a person who may no longer assign, and a member's page;
  # a collection unassigned or moved by someone else while the confirmation is open, the
  # notice first or the click first; the work items taken in from it; the confirmation's
  # span in a table of six columns; where the focus moves, once; and the place of each row
  # unassigned, kept until a load or an assignment from the menu sorts the unassigned
  # ones first, with the pages, counts and pager of the list as it stands.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Deletion, Edition, EditionStubs, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections}
  alias Apiary.Audit.Entry
  alias Apiary.Sources.Backlog
  alias Apiary.WorkItems.WorkItem

  @moduletag needs: :factory

  @sub "Its tickets leave the Backlog of Platform. Work items taken in from it stay where they are. You can assign it to a workspace later."

  setup :register_and_log_in_user

  setup do
    %{adapter: adapter, access_key: key} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    %{adapter: adapter, key: key}
  end

  defp page(scope, adapter),
    do: ~p"/#{scope.organisation}/settings/integrations/#{adapter.public_id}"

  # The element's words, a space between its parts, as the screen shows them apart.
  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> String.replace("><", "> <")
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  # The names of the rows, top to bottom.
  defp names(lv) do
    lv
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(~s{#collections-table tbody [id$="-name"]})
    |> Enum.map(&String.trim(LazyHTML.text(&1)))
  end

  # A complete listing of `connection`, as the adapter of `key` sends it: a collection per
  # title, with no target; `listing`, a later listing, ends the collections it leaves out.
  defp list(key, connection, titles, listing \\ {"first", ~U[2026-10-01 09:00:00Z]}) do
    {listing_id, started_at} = listing
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(key), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections:
          for title <- titles do
            %{
              ref: title,
              url: "https://forge.example.com/" <> title,
              title: title,
              grant_ref: listing_grant(connection),
              target: nil
            }
          end,
        listing: %{id: listing_id, part: 1, started_at: started_at, complete: true}
      })

    :ok
  end

  # The organisation with a second workspace, Platform, and a connection to `adapter`
  # whose complete listing names acme/api, unassigned, and acme/shop and acme/web,
  # assigned to Platform.
  defp several(scope, adapter, key) do
    :ok = Edition.put_test_stub(EditionStubs.ManyWorkspaces)
    platform = workspace_fixture(scope.organisation, "Platform")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    list(key, connection, ["acme/api", "acme/shop", "acme/web"])
    ids = for title <- ["acme/shop", "acme/web"], do: collection(connection, title).id
    {:ok, 2} = Collections.assign_collections(scope, connection, ids, platform)
    {connection, platform}
  end

  defp collection(connection, title),
    do: Repo.get_by!(Collection, connection_id: connection.id, title: title)

  defp row(connection, title), do: "#collection-#{collection(connection, title).public_id}"

  defp unassign(lv, connection, title),
    do: lv |> element("#{row(connection, title)}-unassign") |> render_click()

  defp assign_entries do
    Repo.all(
      from e in Entry,
        where: e.action == "collection.assign",
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  test "each assigned row has Unassign, which turns the row into its confirmation; Cancel keeps it",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, platform} = several(scope, adapter, key)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-table thead .q-int-act") == "Actions"

    for title <- ["acme/shop", "acme/web"] do
      assert has_element?(
               lv,
               ~s{#{row(connection, title)}-unassign[aria-label="Unassign #{title}"][phx-click="ask_unassign"]},
               "Unassign"
             )
    end

    refute has_element?(lv, "#{row(connection, "acme/api")}-unassign")
    assert has_element?(lv, "#{row(connection, "acme/api")} td.q-int-act")

    unassign(lv, connection, "acme/shop")
    confirm = "#{row(connection, "acme/shop")}-confirm"

    assert has_element?(lv, "#{row(connection, "acme/shop")}.q-confirming td.q-confirm-cell")
    assert words(lv, "#{confirm}-question") == "Unassign acme/shop from Platform?"
    assert words(lv, "#{confirm}-sub") == @sub
    assert words(lv, "#{confirm}-button") == "Yes, unassign"
    assert words(lv, "#{confirm}-cancel") == "Cancel"
    refute has_element?(lv, "#{row(connection, "acme/shop")}-unassign")
    assert has_element?(lv, "#{row(connection, "acme/web")}-unassign")

    lv |> element("#{confirm}-cancel") |> render_click()

    refute has_element?(lv, confirm)
    assert has_element?(lv, "#{row(connection, "acme/shop")}-unassign")
    refute has_element?(lv, "#flash-info")
    assert collection(connection, "acme/shop").workspace_id == platform.id
    assert length(assign_entries()) == 1
  end

  test "Yes, unassign: the row is Unassigned, the warning and the view count it, a flash and an entry",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, _platform} = several(scope, adapter, key)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-view-unassigned") == "Unassigned 1"
    unassign(lv, connection, "acme/shop")
    lv |> element("#{row(connection, "acme/shop")}-confirm-button") |> render_click()

    assert words(lv, "#flash-info") ==
             "Unassigned acme/shop from Platform. Its tickets reach no backlog until you assign it to a workspace."

    refute has_element?(lv, "#{row(connection, "acme/shop")}-confirm")
    refute has_element?(lv, "#{row(connection, "acme/shop")}-unassign")
    assert words(lv, "#{row(connection, "acme/shop")} td:nth-child(3)") == "Unassigned"
    assert words(lv, "#collections-view-unassigned") == "Unassigned 2"

    assert words(lv, "#collections-unassigned") =~
             "2 collections are unassigned. Their tickets reach no backlog until you assign each to a workspace."

    assert collection(connection, "acme/shop").workspace_id == nil

    assert [_assigned, %Entry{} = unassigned] = assign_entries()

    assert {unassigned.subject_kind, unassigned.subject_id} ==
             {"organisation", scope.organisation.id}

    assert unassigned.actor_id == scope.user.id

    assert unassigned.details == %{
             "count" => 1,
             "connection_id" => connection.public_id,
             "workspace_id" => nil
           }
  end

  test "a row on a workspace marked for deletion says so and when it is purged, and unassigns",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, platform} = several(scope, adapter, key)
    {:ok, marked} = Deletion.delete_workspace(scope, platform.id, platform.slug)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#{row(connection, "acme/shop")}-deleted") ==
             "Deleted, purged on #{ApiaryWeb.Format.date(marked.purge_after)}"

    assert words(lv, "#{row(connection, "acme/shop")} td:nth-child(2)") ==
             "Platform Deleted, purged on #{ApiaryWeb.Format.date(marked.purge_after)}"

    refute has_element?(lv, "#{row(connection, "acme/api")}-deleted")

    unassign(lv, connection, "acme/shop")

    assert words(lv, "#{row(connection, "acme/shop")}-confirm-question") ==
             "Unassign acme/shop from Platform?"

    lv |> element("#{row(connection, "acme/shop")}-confirm-button") |> render_click()

    assert words(lv, "#flash-info") =~ "Unassigned acme/shop from Platform."
    assert collection(connection, "acme/shop").workspace_id == nil
    assert collection(connection, "acme/web").workspace_id == platform.id
    refute has_element?(lv, "#{row(connection, "acme/shop")}-deleted")
    assert has_element?(lv, "#{row(connection, "acme/web")}-deleted")
  end

  test "once unassigned, the workspace's Backlog no longer lists the collection's tickets", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    grant_rule_fixture(connection, scope.workspace)
    list(key, connection, ["acme/shop"])
    shop = collection(connection, "acme/shop")

    ticket =
      Apiary.WorkItemsFixtures.source_item_fixture(scope,
        collection: shop,
        external_ref: "acme/shop#1",
        key: "#1"
      )

    assert Enum.map(Backlog.list_tickets(scope, %{}).rows, & &1.id) == [ticket.public_id]

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    unassign(lv, connection, "acme/shop")
    lv |> element("#{row(connection, "acme/shop")}-confirm-button") |> render_click()

    assert words(lv, "#flash-info") =~ "Unassigned acme/shop from #{scope.workspace.name}."
    assert Backlog.list_tickets(scope, %{}).rows == []
  end

  test "an adapter with no items: the confirmation and the flash leave out the Backlog", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    adapter = describe_source(adapter, "example-projects.json")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    grant_rule_fixture(connection, scope.workspace)
    list(key, connection, ["Support"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    unassign(lv, connection, "Support")

    assert words(lv, "#{row(connection, "Support")}-confirm-question") ==
             "Unassign Support from #{scope.workspace.name}?"

    assert words(lv, "#{row(connection, "Support")}-confirm-sub") ==
             "You can assign it to a workspace later."

    lv |> element("#{row(connection, "Support")}-confirm-button") |> render_click()

    assert words(lv, "#flash-info") == "Unassigned Support from #{scope.workspace.name}."
    assert collection(connection, "Support").workspace_id == nil
  end

  test "an unassign refused for a person no longer an owner or an admin says who assigns", %{
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key)
    %{user: user, membership: membership} = member_fixture(scope, :admin)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), page(scope, adapter))

    unassign(lv, connection, "acme/shop")
    {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)
    lv |> element("#{row(connection, "acme/shop")}-confirm-button") |> render_click()

    assert words(lv, "#flash-error") ==
             "Only owners and admins of #{scope.organisation.name} assign collections."

    refute has_element?(lv, "#flash-info")
    refute has_element?(lv, "#{row(connection, "acme/shop")}-confirm")
    refute has_element?(lv, "#collections-table .q-int-act")
    assert collection(connection, "acme/shop").workspace_id == platform.id
    assert length(assign_entries()) == 1
  end

  test "a member has no Unassign, and one forced unassigns nothing", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key)
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    assert has_element?(lv, "#{row(connection, "acme/shop")}-unassign")

    %{user: user} = member_fixture(scope, :member)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), page(scope, adapter))

    refute has_element?(lv, "#collections-table .q-int-act")

    render_click(lv, "ask_unassign", %{
      "collection" => collection(connection, "acme/shop").public_id
    })

    refute has_element?(lv, "#{row(connection, "acme/shop")}-confirm")
    render_click(lv, "unassign", %{})

    refute has_element?(lv, "#flash-info")
    assert collection(connection, "acme/shop").workspace_id == platform.id
    assert length(assign_entries()) == 1
  end

  # The confirmation of acme/shop, open on the page `lv`.
  defp confirm_shop(lv, connection) do
    unassign(lv, connection, "acme/shop")
    assert has_element?(lv, "#{row(connection, "acme/shop")}-confirm")
  end

  defp set_workspace(connection, title, workspace_id) do
    id = collection(connection, title).id

    {1, _} =
      Repo.update_all(from(c in Collection, where: c.id == ^id),
        set: [workspace_id: workspace_id]
      )

    :ok
  end

  describe "a collection changed by someone else while the confirmation is open" do
    setup %{scope: scope, adapter: adapter, key: key} do
      {connection, platform} = several(scope, adapter, key)
      mobile = workspace_fixture(scope.organisation, "Mobile")
      %{connection: connection, platform: platform, mobile: mobile}
    end

    test "the notice first, unassigned: the confirmation closes, and Yes changes nothing", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      platform: platform
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)

      {:ok, 1} =
        Collections.assign_collections(
          scope,
          connection,
          [collection(connection, "acme/shop").id],
          nil
        )

      refute has_element?(lv, "#{row(connection, "acme/shop")}-confirm")
      assert words(lv, "#{row(connection, "acme/shop")} td:nth-child(3)") == "Unassigned"

      render_click(lv, "unassign", %{"workspace" => platform.id})

      refute has_element?(lv, "#flash-info")
      refute has_element?(lv, "#flash-error")
      assert collection(connection, "acme/shop").workspace_id == nil
      assert length(assign_entries()) == 2
    end

    test "the notice first, moved: the confirmation closes, and the other workspace keeps it",
         %{
           conn: conn,
           scope: scope,
           adapter: adapter,
           connection: connection,
           platform: platform,
           mobile: mobile
         } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)

      {:ok, 1} =
        Collections.assign_collections(
          scope,
          connection,
          [collection(connection, "acme/shop").id],
          mobile
        )

      refute has_element?(lv, "#{row(connection, "acme/shop")}-confirm")
      assert words(lv, "#{row(connection, "acme/shop")} td:nth-child(3)") == "Mobile"

      render_click(lv, "unassign", %{"workspace" => platform.id})

      refute has_element?(lv, "#flash-info")
      assert collection(connection, "acme/shop").workspace_id == mobile.id
      assert length(assign_entries()) == 2
    end

    test "the click first, unassigned: nothing changes, the confirmation closes, no flash", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)
      :ok = set_workspace(connection, "acme/shop", nil)

      lv |> element("#{row(connection, "acme/shop")}-confirm-button") |> render_click()

      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "#{String.trim_leading(row(connection, "acme/shop"), "#")}-name"
      refute has_element?(lv, "#flash-info")
      refute has_element?(lv, "#flash-error")
      refute has_element?(lv, "#{row(connection, "acme/shop")}-confirm")
      assert words(lv, "#{row(connection, "acme/shop")} td:nth-child(3)") == "Unassigned"
      assert collection(connection, "acme/shop").workspace_id == nil
      assert length(assign_entries()) == 1
    end

    test "the click first, moved: the other workspace keeps it, and the row shows it there", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      mobile: mobile
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)
      :ok = set_workspace(connection, "acme/shop", mobile.id)

      lv |> element("#{row(connection, "acme/shop")}-confirm-button") |> render_click()

      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "#{String.trim_leading(row(connection, "acme/shop"), "#")}-name"
      refute has_element?(lv, "#flash-info")
      refute has_element?(lv, "#{row(connection, "acme/shop")}-confirm")
      assert words(lv, "#{row(connection, "acme/shop")} td:nth-child(3)") == "Mobile"
      assert collection(connection, "acme/shop").workspace_id == mobile.id
      assert length(assign_entries()) == 1
    end
  end

  test "the work items taken in from the collection stay where they are", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    grant_rule_fixture(connection, scope.workspace)
    list(key, connection, ["acme/shop"])

    ticket =
      Apiary.WorkItemsFixtures.source_item_fixture(scope,
        collection: collection(connection, "acme/shop"),
        external_ref: "acme/shop#1",
        key: "#1"
      )

    work_item =
      Apiary.WorkItemsFixtures.work_item_fixture(scope,
        connection_id: connection.id,
        item_id: ticket.id,
        external_ref: "acme/shop#1"
      )

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    unassign(lv, connection, "acme/shop")
    lv |> element("#{row(connection, "acme/shop")}-confirm-button") |> render_click()

    assert collection(connection, "acme/shop").workspace_id == nil
    kept = Repo.get!(WorkItem, work_item.id)
    assert {kept.workspace_id, kept.state} == {scope.workspace.id, :exploring}
  end

  test "in a table of six columns, the confirmation spans six", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} = several(scope, adapter, key)
    {:ok, _marked} = Deletion.delete_workspace(scope, platform.id, platform.slug)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    refute has_element?(lv, "#collections-table-every")

    assert lv
           |> render()
           |> LazyHTML.from_document()
           |> LazyHTML.query("#collections-table thead th")
           |> Enum.count() == 6

    unassign(lv, connection, "acme/shop")
    assert has_element?(lv, ~s{#{row(connection, "acme/shop")} td.q-confirm-cell[colspan="6"]})

    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?q=billing")
    assert has_element?(lv, ~s{#collections-table-none td[colspan="6"]})
  end

  describe "the focus" do
    setup %{scope: scope, adapter: adapter, key: key} do
      {connection, platform} = several(scope, adapter, key)
      mobile = workspace_fixture(scope.organisation, "Mobile")
      shop = collection(connection, "acme/shop")
      %{connection: connection, platform: platform, mobile: mobile, shop: shop}
    end

    test "moves once: Cancel to the row's Unassign, and later notices move it nowhere", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      platform: platform,
      shop: shop
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)
      lv |> element("#collection-#{shop.public_id}-confirm-cancel") |> render_click()

      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "collection-#{shop.public_id}-unassign"

      {:ok, 1} = Collections.assign_collections(scope, connection, [shop.id], nil)
      {:ok, 1} = Collections.assign_collections(scope, connection, [shop.id], platform)
      assert has_element?(lv, "#collection-#{shop.public_id}-unassign")

      refute_push_event(lv, "run:focus", %{}, 200)
      refute has_element?(lv, "#collections-table [phx-mounted]")
    end

    test "Yes, unassign moves it to the row's name", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      shop: shop
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)
      lv |> element("#collection-#{shop.public_id}-confirm-button") |> render_click()

      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "collection-#{shop.public_id}-name"
      assert has_element?(lv, ~s{##{id}[tabindex="-1"][phx-hook="FocusOn"]})
    end

    test "a notice that closes the confirmation moves it to the row's name", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      mobile: mobile,
      shop: shop
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)
      {:ok, 1} = Collections.assign_collections(scope, connection, [shop.id], mobile)

      refute has_element?(lv, "#collection-#{shop.public_id}-confirm")
      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "collection-#{shop.public_id}-name"
    end

    test "a notice that leaves the confirmation open moves it nowhere", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      shop: shop
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)
      web = collection(connection, "acme/web")
      {:ok, 1} = Collections.set_collection_backlog(scope, connection, web.id, false)

      assert has_element?(lv, ~s{#collection-#{web.public_id}-backlog[aria-checked="false"]})
      assert has_element?(lv, "#collection-#{shop.public_id}-confirm")
      refute_push_event(lv, "run:focus", %{}, 200)
    end

    test "a notice about the connection that closes the confirmation moves it to the name", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      mobile: mobile,
      shop: shop
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)
      :ok = set_workspace(connection, "acme/shop", mobile.id)
      send(lv.pid, {:connection_changed, %{adapter_id: adapter.id}})

      refute has_element?(lv, "#collection-#{shop.public_id}-confirm")
      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "collection-#{shop.public_id}-name"
    end

    test "an installation that ends while the confirmation is open moves it nowhere", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      key: key,
      connection: connection,
      shop: shop
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      confirm_shop(lv, connection)

      {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

      {:ok, _ended} =
        Apiary.Adapters.Connections.end_connection(
          Scope.for_access_key(key),
          connection.public_id
        )

      send(lv.pid, {:connection_changed, %{adapter_id: adapter.id}})

      refute has_element?(lv, "#collection-#{shop.public_id}-confirm")
      refute has_element?(lv, "#collections-table")
      refute_push_event(lv, "run:focus", %{}, 200)
    end

    test "a notice that takes the row out of a filtered list moves it to the heading", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      platform: platform,
      mobile: mobile,
      shop: shop
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?workspace_id=#{platform.id}")
      confirm_shop(lv, connection)
      {:ok, 1} = Collections.assign_collections(scope, connection, [shop.id], mobile)

      refute has_element?(lv, "#collection-#{shop.public_id}")
      assert_push_event(lv, "run:focus", %{id: "collections-heading"})
      assert has_element?(lv, ~s{#collections-heading[tabindex="-1"][phx-hook="FocusOn"]})
    end

    test "Yes, unassign in a filtered list the row leaves moves it to the heading", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      platform: platform,
      shop: shop
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?workspace_id=#{platform.id}")
      confirm_shop(lv, connection)
      lv |> element("#collection-#{shop.public_id}-confirm-button") |> render_click()

      refute has_element?(lv, "#collection-#{shop.public_id}")
      assert collection(connection, "acme/shop").workspace_id == nil
      assert_push_event(lv, "run:focus", %{id: "collections-heading"})
    end
  end

  describe "the order" do
    setup %{scope: scope, adapter: adapter, key: key} do
      {connection, platform} = several(scope, adapter, key)
      %{connection: connection, platform: platform, web: collection(connection, "acme/web")}
    end

    defp unassign_web(lv, connection) do
      unassign(lv, connection, "acme/web")
      lv |> element("#{row(connection, "acme/web")}-confirm-button") |> render_click()
    end

    test "after Yes, unassign, the row stays where it was, through change notices too", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      platform: platform,
      web: web
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]

      unassign_web(lv, connection)

      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]
      assert words(lv, "#{row(connection, "acme/web")} td:nth-child(3)") == "Unassigned"
      assert_push_event(lv, "run:focus", %{id: id})
      assert id == "collection-#{web.public_id}-name"

      api = collection(connection, "acme/api")
      {:ok, 1} = Collections.assign_collections(scope, connection, [api.id], platform)

      assert words(lv, "#{row(connection, "acme/api")} td:nth-child(3)") == "Platform"
      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]
      refute_push_event(lv, "run:focus", %{}, 200)
    end

    test "a row that another person ends leaves the list; the unassigned row keeps its place",
         %{conn: conn, scope: scope, adapter: adapter, key: key, connection: connection} do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      unassign_web(lv, connection)
      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]

      list(key, connection, ["acme/shop", "acme/web"], {"second", ~U[2026-10-02 09:00:00Z]})

      assert names(lv) == ["acme/shop", "acme/web"]
      assert words(lv, "#collections-view-all") == "All 2"
      assert words(lv, "#collections-view-unassigned") == "Unassigned 1"
      refute has_element?(lv, "#collections-pager")
    end

    test "a collection another person adds takes its place in the order, with the counts",
         %{conn: conn, scope: scope, adapter: adapter, key: key, connection: connection} do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      unassign_web(lv, connection)

      list(
        key,
        connection,
        ["acme/api", "acme/new", "acme/shop", "acme/web"],
        {"second", ~U[2026-10-02 09:00:00Z]}
      )

      assert names(lv) == ["acme/api", "acme/new", "acme/shop", "acme/web"]
      assert words(lv, "#collections-view-all") == "All 4"
      assert words(lv, "#collections-view-unassigned") == "Unassigned 3"
      refute has_element?(lv, "#collections-pager")
    end

    test "each of several Unassigns keeps its row in place", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      platform: platform
    } do
      api = collection(connection, "acme/api")
      {:ok, 1} = Collections.assign_collections(scope, connection, [api.id], platform)
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]

      unassign_web(lv, connection)
      unassign(lv, connection, "acme/shop")
      lv |> element("#{row(connection, "acme/shop")}-confirm-button") |> render_click()

      assert collection(connection, "acme/shop").workspace_id == nil
      assert collection(connection, "acme/web").workspace_id == nil
      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]
      assert words(lv, "#collections-view-unassigned") == "Unassigned 2"

      render_patch(lv, page(scope, adapter))
      assert names(lv) == ["acme/shop", "acme/web", "acme/api"]
    end

    test "a refused assignment from the menu keeps the rows in place", %{
      scope: scope,
      adapter: adapter,
      connection: connection
    } do
      %{user: user, membership: membership} = member_fixture(scope, :admin)
      {:ok, lv, _html} = live(log_in_user(build_conn(), user), page(scope, adapter))
      unassign_web(lv, connection)
      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]

      lv |> element("#{row(connection, "acme/api")}-pick") |> render_click()
      {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)
      lv |> element("#collections-assign-#{scope.workspace.id}") |> render_click()

      assert has_element?(lv, "#flash-error")
      assert collection(connection, "acme/api").workspace_id == nil
      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]
    end

    test "an assignment from the menu sorts the rows again", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection,
      platform: platform
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      unassign_web(lv, connection)
      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]

      lv |> element("#{row(connection, "acme/api")}-pick") |> render_click()
      lv |> element("#collections-assign-#{platform.id}") |> render_click()

      assert collection(connection, "acme/api").workspace_id == platform.id
      assert names(lv) == ["acme/web", "acme/api", "acme/shop"]
    end

    test "a load, or a patch of the address, sorts the unassigned rows first again", %{
      conn: conn,
      scope: scope,
      adapter: adapter,
      connection: connection
    } do
      {:ok, lv, _html} = live(conn, page(scope, adapter))
      unassign_web(lv, connection)
      assert names(lv) == ["acme/api", "acme/shop", "acme/web"]

      render_patch(lv, page(scope, adapter))
      assert names(lv) == ["acme/api", "acme/web", "acme/shop"]

      {:ok, again, _html} = live(conn, page(scope, adapter))
      assert names(again) == ["acme/api", "acme/web", "acme/shop"]
    end
  end

  # The organisation with a second workspace, Platform, and a connection to `adapter`
  # whose complete listing names two pages of collections, all assigned to Platform:
  # `{connection, their titles}`.
  defp two_pages(scope, adapter, key) do
    :ok = Edition.put_test_stub(EditionStubs.ManyWorkspaces)
    platform = workspace_fixture(scope.organisation, "Platform")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    titles = for n <- 1..(Collections.page_size() + 2), do: "acme/repo-#{pad(n)}"
    list(key, connection, titles)
    ids = for title <- titles, do: collection(connection, title).id
    {:ok, _count} = Collections.assign_collections(scope, connection, ids, platform)
    {connection, titles}
  end

  test "after Yes, unassign on the second page, the page and its row stay; an added one counts",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, titles} = two_pages(scope, adapter, key)
    [before, first, second] = Enum.take(titles, -3)

    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?page=2")
    assert names(lv) == [first, second]

    unassign(lv, connection, first)
    lv |> element("#{row(connection, first)}-confirm-button") |> render_click()

    assert names(lv) == [first, second]
    assert words(lv, "#{row(connection, first)} td:nth-child(3)") == "Unassigned"
    assert collection(connection, first).workspace_id == nil

    list(key, connection, titles ++ ["acme/added"], {"second", ~U[2026-10-02 09:00:00Z]})

    assert names(lv) == [before, first, second]
    assert words(lv, "#collections-pager-footer") == "51–53 of 53"
    assert has_element?(lv, "#collections-pager-next[disabled]")
    assert words(lv, "#collections-view-all") == "All 53"
    assert words(lv, "#collections-view-unassigned") == "Unassigned 2"
  end

  test "on the first of two pages, with a collection added, Next shows each row once", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, titles} = two_pages(scope, adapter, key)
    unassigned = Enum.at(titles, 9)

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    unassign(lv, connection, unassigned)
    lv |> element("#{row(connection, unassigned)}-confirm-button") |> render_click()
    assert names(lv) == Enum.take(titles, 50)

    list(key, connection, titles ++ ["acme/added"], {"second", ~U[2026-10-02 09:00:00Z]})

    first = names(lv)
    assert first == ["acme/added" | Enum.take(titles, 49)]
    assert Enum.find_index(first, &(&1 == unassigned)) == 10
    assert words(lv, "#collections-pager-footer") == "1–50 of 53"

    lv |> element("#collections-pager-next") |> render_click()
    second = names(lv)

    assert length(second) == 3
    assert Enum.sort(first ++ second) == Enum.sort(["acme/added" | titles])
  end

  test "on the second page, its first row unassigned, then a row of the first page ended: the rest",
       %{conn: conn, scope: scope, adapter: adapter, key: key} do
    {connection, titles} = two_pages(scope, adapter, key)
    [first, last] = Enum.take(titles, -2)

    {:ok, lv, _html} = live(conn, page(scope, adapter) <> "?page=2")
    unassign(lv, connection, first)
    lv |> element("#{row(connection, first)}-confirm-button") |> render_click()
    assert names(lv) == [first, last]

    list(key, connection, tl(titles), {"second", ~U[2026-10-02 09:00:00Z]})

    assert names(lv) == [last]
    assert words(lv, "#collections-pager-footer") == "51–51 of 51"
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")
end
