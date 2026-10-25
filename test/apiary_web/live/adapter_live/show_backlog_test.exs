defmodule ApiaryWeb.AdapterLive.ShowBacklogTest do
  # The Backlog switches on an integration's page in Organisation settings › Integrations
  # (`ApiaryWeb.AdapterLive.Show`): a switch on each live collection assigned to a
  # workspace, for an adapter with items, named for its items; the hint under the lead;
  # turning one, with the flash, and none for a press that changed nothing; each refusal;
  # a member's disabled switches and the line that says who may; a dash for a collection
  # with no items; no column for an adapter with no items; and the switches as they change
  # elsewhere.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Edition, EditionStubs, Repo}
  alias Apiary.Accounts.Scope
  alias Apiary.Adapters.{Collection, Collections, Connection}

  @moduletag needs: :factory

  @hint "If the tickets of one of these collections only track bugs, turn its Backlog switch off. Work items already taken in stay."
  @read_only "Only owners and admins change the Backlog switches."

  setup :register_and_log_in_user

  setup do
    %{adapter: adapter, access_key: key} = connectable_adapter_fixture(%{name: "Acme tracker"})
    %{adapter: adapter, key: key}
  end

  defp page(scope, adapter),
    do: ~p"/#{scope.organisation}/settings/integrations/#{adapter.public_id}"

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

  defp rows(lv) do
    lv
    |> render()
    |> String.replace("><", "> <")
    |> LazyHTML.from_document()
    |> LazyHTML.query("#collections-table tr")
    |> Enum.map(fn row ->
      row
      |> LazyHTML.query("th, td")
      |> Enum.map_join(" ", &LazyHTML.text/1)
      |> String.split()
      |> Enum.join(" ")
    end)
  end

  # A complete listing of `connection`, as the adapter of `key` sends it: a collection per
  # title, with no target; `{title, :no_items}` for one with no items.
  defp list(key, connection, titles, id \\ "first") do
    {:ok, key} = AccessKeys.fetch_for_verification(key.key_id)

    {:ok, :accepted} =
      Collections.post_listing(Scope.for_access_key(key), %{
        time: DateTime.utc_now(:second),
        connection_id: connection.public_id,
        collections:
          Enum.map(titles, &Map.put(listed(&1), :grant_ref, listing_grant(connection))),
        listing: %{id: id, part: 1, started_at: ~U[2026-10-01 09:00:00Z], complete: true}
      })

    :ok
  end

  defp listed({title, :no_items}), do: Map.put(listed(title), :items, false)

  defp listed(title),
    do: %{ref: title, url: "https://forge.example.com/" <> title, title: title, target: nil}

  # The organisation with a second workspace, Platform, and a connection to `adapter`
  # whose complete listing names `titles`: those of `assigned` assigned to Platform, the
  # rest unassigned.
  defp several(scope, adapter, key, titles, assigned) do
    :ok = Edition.put_test_stub(EditionStubs.ManyWorkspaces)
    platform = workspace_fixture(scope.organisation, "Platform")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    list(key, connection, titles)
    ids = for title <- assigned, do: collection(connection, title).id
    {:ok, _changed} = Collections.assign_collections(scope, connection, ids, platform)
    {connection, platform}
  end

  defp collection(connection, title),
    do: Repo.get_by!(Collection, connection_id: connection.id, title: title)

  defp switch(connection, title),
    do: "#collection-#{collection(connection, title).public_id}-backlog"

  defp set_collection(connection, title, fields) do
    id = collection(connection, title).id
    {1, _} = Repo.update_all(from(c in Collection, where: c.id == ^id), set: fields)
    :ok
  end

  test "each assigned row has its switch, on, named for its items; the hint said once", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _platform} =
      several(scope, adapter, key, ["acme/api", "acme/shop", "acme/web"], [
        "acme/api",
        "acme/shop"
      ])

    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-lead") ==
             "These collections are each assigned to one workspace, and their tickets come into that workspace's Backlog while their Backlog switches are on."

    assert words(lv, "#collections-backlog-hint") == @hint
    refute has_element?(lv, "#collections-backlog-read-only")

    name = "Take the tickets of acme/shop into the Backlog"

    assert has_element?(
             lv,
             ~s{#{switch(connection, "acme/shop")}[role="switch"][aria-checked="true"][aria-label="#{name}"][title="#{name}"][phx-click="set_backlog"]:not([disabled])}
           )

    # Below 600 px of the table's width, the same switch on the name's second line, beside
    # the column's word, which screen readers skip.
    assert has_element?(
             lv,
             ~s{.q-to-sm #{switch(connection, "acme/shop")}-line[role="switch"][aria-label="#{name}"]}
           )

    assert has_element?(lv, ~s{.q-to-sm span[aria-hidden="true"]}, "Backlog")

    # An unassigned row has no switch, and no dash.
    refute has_element?(lv, switch(connection, "acme/web"))
    refute has_element?(lv, switch(connection, "acme/web") <> "-line")
    refute has_element?(lv, switch(connection, "acme/web") <> "-none")

    assert rows(lv) == [
             "Collection Workspace Backlog Open tickets Added",
             "acme/web Unassigned — Today",
             "acme/api Backlog Platform — Today",
             "acme/shop Backlog Platform — Today"
           ]

    lv |> element("#collections-view-unassigned") |> render_click()
    assert hd(rows(lv)) == "Collection Workspace Backlog Open tickets Added"
    refute has_element?(lv, ~s{#collections-table [role="switch"]})
    assert words(lv, "#collections-backlog-hint") == @hint
  end

  test "turned off, then on: a flash says what changed, and the row shows it", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _platform} =
      several(scope, adapter, key, ["acme/api", "acme/shop"], ["acme/shop"])

    {:ok, lv, _html} = live(conn, page(scope, adapter))

    lv |> element(switch(connection, "acme/shop")) |> render_click()

    assert words(lv, "#flash-info") =~
             "No longer taking tickets into the Backlog from collection acme/shop."

    assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}[aria-checked="false"]})
    assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}-line[aria-checked="false"]})
    assert %Collection{backlog: false} = collection(connection, "acme/shop")

    lv |> element(switch(connection, "acme/shop") <> "-line") |> render_click()

    assert words(lv, "#flash-info") =~
             "Now taking tickets into the Backlog from collection acme/shop."

    assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}[aria-checked="true"]})
    assert %Collection{backlog: true} = collection(connection, "acme/shop")
  end

  test "a press that changes nothing says nothing, and shows the switch as it is", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _platform} = several(scope, adapter, key, ["acme/shop"], ["acme/shop"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    # Turned off meanwhile with no broadcast: the page still shows it on.
    :ok = set_collection(connection, "acme/shop", backlog: false)
    assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}[aria-checked="true"]})

    lv |> element(switch(connection, "acme/shop")) |> render_click()

    refute has_element?(lv, "#flash-info")
    refute has_element?(lv, "#flash-error")
    assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}[aria-checked="false"]})
    assert %Collection{backlog: false} = collection(connection, "acme/shop")
  end

  test "refused for a person no longer an owner or an admin: who may, and the switches off",
       %{scope: scope, adapter: adapter, key: key} do
    {connection, _platform} = several(scope, adapter, key, ["acme/shop"], ["acme/shop"])
    %{user: user, membership: membership} = member_fixture(scope, :admin)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), page(scope, adapter))

    {:ok, _membership} = Apiary.Organisations.set_member_level(scope, membership.id, :member)
    lv |> element(switch(connection, "acme/shop")) |> render_click()

    assert words(lv, "#flash-error") =~ @read_only
    assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}[disabled][aria-checked="true"]})
    assert words(lv, "#collections-backlog-read-only") == @read_only
    assert %Collection{backlog: true} = collection(connection, "acme/shop")
  end

  test "a collection gone meanwhile: no flash, and the page shows them as they are", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _platform} =
      several(scope, adapter, key, ["acme/api", "acme/shop"], ["acme/api", "acme/shop"])

    {:ok, lv, _html} = live(conn, page(scope, adapter))
    shop = switch(connection, "acme/shop")

    :ok =
      set_collection(connection, "acme/shop",
        ended_at: DateTime.utc_now(),
        ended_reason: :not_listed
      )

    lv |> element(shop) |> render_click()

    refute has_element?(lv, "#flash-info")
    refute has_element?(lv, "#flash-error")
    refute has_element?(lv, shop)
    refute has_element?(lv, shop <> "-none")
    assert Enum.drop(rows(lv), 1) == ["acme/api Backlog Platform — Today"]
    assert %Collection{backlog: true} = collection(connection, "acme/shop")
  end

  test "an installation ended meanwhile: no flash, and the page says it ended", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _platform} = several(scope, adapter, key, ["acme/shop"], ["acme/shop"])
    {:ok, lv, _html} = live(conn, page(scope, adapter))
    shop = switch(connection, "acme/shop")

    {1, _} =
      Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
        set: [state: :ended, ended_at: DateTime.utc_now(), ended_reason: :adapter_reported]
      )

    lv |> element(shop) |> render_click()

    refute has_element?(lv, "#flash-info")
    refute has_element?(lv, "#flash-error")
    refute has_element?(lv, "#collections")
    assert words(lv, "#integration-status") =~ "Not installed. The installation ended on"
    assert %Collection{backlog: true} = collection(connection, "acme/shop")
  end

  test "a press naming another organisation's collection, or no collection, does nothing", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _platform} = several(scope, adapter, key, ["acme/shop"], ["acme/shop"])

    %{user: stranger} = sign_up_fixture()
    other = Apiary.Organisations.load_scope(Scope.for_user(stranger))
    {other_connection, _nonce} = connection_fixture(other, adapter, :connected)
    list(key, other_connection, ["beta/shop"], "theirs")
    theirs = collection(other_connection, "beta/shop")
    assert theirs.workspace_id

    {:ok, lv, _html} = live(conn, page(scope, adapter))

    for public_id <- [theirs.public_id, "sc_0000000000000000", "not-an-id"] do
      render_click(lv, "set_backlog", %{"collection" => public_id})

      refute has_element?(lv, "#flash-info")
      refute has_element?(lv, "#flash-error")
      assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}[aria-checked="true"]})
    end

    assert %Collection{backlog: true} = collection(other_connection, "beta/shop")
    assert %Collection{backlog: true} = collection(connection, "acme/shop")
  end

  test "a member sees the switches disabled, and who may turn them", %{
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _platform} = several(scope, adapter, key, ["acme/shop"], ["acme/shop"])
    %{user: user} = member_fixture(scope, :member)
    {:ok, lv, _html} = live(log_in_user(build_conn(), user), page(scope, adapter))

    assert words(lv, "#collections-backlog-hint") == @hint
    assert words(lv, "#collections-backlog-read-only") == @read_only

    assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}[disabled][aria-checked="true"]})
    refute has_element?(lv, ~s{#{switch(connection, "acme/shop")}[phx-click]})
    refute has_element?(lv, ~s{#{switch(connection, "acme/shop")}-line[phx-click]})

    # Forced, the press is refused, and changes nothing.
    render_click(lv, "set_backlog", %{
      "collection" => collection(connection, "acme/shop").public_id
    })

    assert words(lv, "#flash-error") =~ @read_only
    assert %Collection{backlog: true} = collection(connection, "acme/shop")
  end

  test "with one workspace, each row has its switch; a collection with no items, a dash", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    list(key, connection, ["acme/shop", {"acme/docs", :no_items}])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-lead") ==
             "#{scope.organisation.name} has one workspace, #{scope.workspace.name}, so every collection is assigned to it, and its tickets come into #{scope.workspace.name}'s Backlog while its Backlog switch is on."

    assert words(lv, "#collections-backlog-hint") == @hint
    assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}[aria-checked="true"]})

    docs = switch(connection, "acme/docs")
    refute has_element?(lv, docs)
    refute has_element?(lv, docs <> "-line")
    assert has_element?(lv, ~s{#{docs}-none.q-faint[title="No tickets to take in"]})
    assert has_element?(lv, ~s{#{docs}-none [aria-hidden="true"]}, "—")
    assert words(lv, "#{docs}-none .sr-only") == "No tickets to take in"

    assert rows(lv) == [
             "Collection Workspace Backlog Open tickets Added",
             "acme/docs #{scope.workspace.name} — No tickets to take in — Today",
             "acme/shop Backlog #{scope.workspace.name} — Today"
           ]
  end

  test "in the adapter's words: the switch's name and the hint", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    adapter = describe_source(adapter, "example-tracker.json")
    {connection, _nonce} = connection_fixture(scope, adapter, :connected)
    list(key, connection, ["Support", {"Sales", :no_items}])
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert words(lv, "#collections-backlog-hint") ==
             "If the issues of one of these projects only track bugs, turn its Backlog switch off. Work items already taken in stay."

    assert has_element?(
             lv,
             ~s{#{switch(connection, "Support")}[aria-label="Take the issues of Support into the Backlog"]}
           )

    assert has_element?(lv, ~s{#{switch(connection, "Sales")}-none[title="No issues to take in"]})
    assert hd(rows(lv)) == "Project Workspace Backlog Open issues Added"

    lv |> element(switch(connection, "Support")) |> render_click()

    assert words(lv, "#flash-info") =~
             "No longer taking issues into the Backlog from project Support."
  end

  test "an adapter with no items: no Backlog column, no switch, no hint, no read-only line", %{
    scope: scope,
    adapter: adapter,
    key: key
  } do
    adapter = describe_source(adapter, "example-projects.json")
    several(scope, adapter, key, ["Support", "Sales"], ["Support"])

    for level <- [:owner, :member] do
      %{user: user} = member_fixture(scope, level)
      {:ok, lv, _html} = live(log_in_user(build_conn(), user), page(scope, adapter))

      assert words(lv, "#collections-lead") ==
               "These projects are each assigned to one workspace."

      assert hd(rows(lv)) == "Project Workspace Added"
      assert Enum.drop(rows(lv), 1) == ["Sales Unassigned Today", "Support Platform Today"]
      refute has_element?(lv, ~s{#collections-table [role="switch"]})
      refute has_element?(lv, ~s{#collections-table [id$="-backlog-none"]})
      refute has_element?(lv, "#collections-backlog-hint")
      refute has_element?(lv, "#collections-backlog-read-only")
    end
  end

  test "the hint waits for the first listing, as the table does", %{
    conn: conn,
    scope: scope,
    adapter: adapter
  } do
    connection_fixture(scope, adapter, :connected)
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    assert has_element?(lv, "#collections-waiting")
    assert has_element?(lv, "#collections-lead")
    refute has_element?(lv, "#collections-backlog-hint")
  end

  test "the switches follow a switch turned elsewhere, and an assign", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, platform} =
      several(scope, adapter, key, ["acme/api", "acme/shop"], ["acme/shop"])

    {:ok, lv, _html} = live(conn, page(scope, adapter))

    shop = collection(connection, "acme/shop")
    assert {:ok, 1} = Collections.set_collection_backlog(scope, connection, shop.id, false)
    assert has_element?(lv, ~s{#{switch(connection, "acme/shop")}[aria-checked="false"]})
    refute has_element?(lv, "#flash-info")

    refute has_element?(lv, switch(connection, "acme/api"))
    api = collection(connection, "acme/api")
    {:ok, _changed} = Collections.assign_collections(scope, connection, [api.id], platform)
    assert has_element?(lv, ~s{#{switch(connection, "acme/api")}[aria-checked="true"]})
  end

  test "the flash names the collection as an external system's text is", %{
    conn: conn,
    scope: scope,
    adapter: adapter,
    key: key
  } do
    {connection, _platform} = several(scope, adapter, key, ["acme/shop"], ["acme/shop"])
    :ok = set_collection(connection, "acme/shop", title: "\u202Eacme/shop\u200B\a")
    {:ok, lv, _html} = live(conn, page(scope, adapter))

    lv |> element(switch(connection, "\u202Eacme/shop\u200B\a")) |> render_click()

    assert words(lv, "#flash-info") =~
             "No longer taking tickets into the Backlog from collection acme/shop\uFFFD."

    refute render(element(lv, "#flash-info")) =~ "\u202E"
  end
end
