defmodule ApiaryWeb.AdapterLive.IndexTest do
  # Organisation settings › Integrations (`ApiaryWeb.AdapterLive.Index`): the list
  # (`:index`), the instance's adapters by name, each installed in the organisation or
  # not, with how many collections it reaches and, with several workspaces, how many are
  # unassigned; Add for an owner or an admin, the chevron to an installed one's page, and
  # the foot notes, the members' by the organisation's workspaces; with no adapter, an
  # empty state in place of the table; behind the feature, for members.
  # Add an integration (`:new`), for an owner or an admin: a block for each adapter not
  # installed, Install, which posts to the Install path, or not ready yet; with every one
  # installed, a line that says so, in place of the lead.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures
  import Apiary.WorkItemsFixtures

  alias Apiary.{Edition, EditionStubs}

  @moduletag needs: :factory

  setup :register_and_log_in_user

  defp list_path(scope), do: ~p"/#{scope.organisation}/settings/integrations"

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp member_conn(scope, level \\ :member) do
    %{user: user} = member_fixture(scope, level)
    log_in_user(build_conn(), user)
  end

  test "lists the instance's adapters by name, none installed, with Add for an owner",
       %{conn: conn, scope: scope} do
    shop = adapter_fixture(%{name: unique_adapter_name("Shop tracker")})
    acme = adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    {:ok, lv, html} = live(conn, list_path(scope))

    assert has_element?(lv, "h1", "Integrations")
    assert page_title(lv) =~ "Integrations · Organisation settings · #{scope.organisation.name}"
    assert has_element?(lv, ~s{#settings-tab-integrations[aria-current="page"]})

    assert words(lv, ".q-settings-head-sub") ==
             "This instance's integrations, and whether each is installed for #{scope.organisation.name}."

    assert html =~ ~r{<th[^>]*>\s*Integration\s*</th>}
    assert html =~ ~r{<th[^>]*>\s*In #{Regex.escape(scope.organisation.name)}\s*</th>}

    rows = for [_whole, id] <- Regex.scan(~r/<tr id="(integration-na_[^"]+)"/, html), do: id
    assert rows == ["integration-#{acme.public_id}", "integration-#{shop.public_id}"]

    for adapter <- [acme, shop] do
      id = "#integration-#{adapter.public_id}"
      assert words(lv, "#{id}-name") == adapter.name
      refute has_element?(lv, "a#{id}-name")
      assert words(lv, "#{id}-state") == "Not installed"
      assert has_element?(lv, ~s{a#{id}-add[href="#{list_path(scope)}/new"]}, "Add")
      refute has_element?(lv, "#{id}-open")
    end

    assert words(lv, "#integrations-serve") ==
             "An integration installed here serves each workspace through the collections assigned to it."

    refute has_element?(lv, "#integrations-who")
  end

  test "an installed one leads to its page, by its name and its chevron; a pending one is not installed",
       %{conn: conn, scope: scope} do
    %{adapter: installed} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    %{adapter: pending} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Shop tracker")})

    connection_fixture(scope, installed, :connected)
    connection_fixture(scope, pending, :pending)

    {:ok, lv, _html} = live(conn, list_path(scope))

    show = "#{list_path(scope)}/#{installed.public_id}"
    id = "#integration-#{installed.public_id}"
    assert has_element?(lv, ~s{a#{id}-name[href="#{show}"]}, installed.name)
    assert has_element?(lv, ~s{a#{id}-open[href="#{show}"][aria-label="Open #{installed.name}"]})
    refute has_element?(lv, "#{id}-add")
    assert words(lv, "#{id}-state") == "Installed · 0 collections"

    id = "#integration-#{pending.public_id}"
    assert words(lv, "#{id}-state") == "Not installed"
    assert has_element?(lv, "#{id}-add")
    refute has_element?(lv, "#{id}-open")
  end

  test "an installed one says how many collections it reaches, in its words", %{
    conn: conn,
    scope: scope
  } do
    %{adapter: acme} = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
    %{adapter: shop} = connectable_adapter_fixture(%{name: unique_adapter_name("Shop tracker")})

    %{adapter: platform} =
      connectable_adapter_fixture(%{name: unique_adapter_name("Platform tracker")})

    shop = describe_source(shop, "example-tracker.json")
    {acme_connection, _nonce} = connection_fixture(scope, acme, :listed)
    {shop_connection, _nonce} = connection_fixture(scope, shop, :listed)
    connection_fixture(scope, platform, :connected)

    for _ <- 1..3, do: source_collection_fixture(scope, acme_connection)
    source_collection_fixture(scope, shop_connection)
    # One ended is counted nowhere.
    source_collection_fixture(scope, acme_connection, %{
      ended_at: DateTime.utc_now(),
      ended_reason: :not_listed
    })

    {:ok, lv, _html} = live(conn, list_path(scope))

    assert words(lv, "#integration-#{acme.public_id}-state") == "Installed · 3 collections"
    assert words(lv, "#integration-#{shop.public_id}-state") == "Installed · 1 project"
    assert words(lv, "#integration-#{platform.public_id}-state") == "Installed · 0 collections"
  end

  test "with several workspaces, how many are unassigned, when any is", %{
    conn: conn,
    scope: scope
  } do
    Edition.put_test_stub(EditionStubs.ManyWorkspaces)
    workspace_fixture(scope.organisation, "Platform")
    %{adapter: acme} = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
    {connection, _nonce} = connection_fixture(scope, acme, :listed)
    for _ <- 1..2, do: source_collection_fixture(scope, connection)

    {:ok, lv, _html} = live(conn, list_path(scope))
    assert words(lv, "#integration-#{acme.public_id}-state") == "Installed · 2 collections"

    source_collection_fixture(scope, connection, %{workspace_id: nil})
    {:ok, lv, _html} = live(conn, list_path(scope))

    assert words(lv, "#integration-#{acme.public_id}-state") ==
             "Installed · 3 collections, 1 unassigned"

    assert has_element?(lv, "#integration-#{acme.public_id}-state b", "1")
  end

  test "with one workspace, none is said unassigned", %{conn: conn, scope: scope} do
    %{adapter: acme} = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
    {connection, _nonce} = connection_fixture(scope, acme, :listed)
    source_collection_fixture(scope, connection, %{workspace_id: nil})

    {:ok, lv, _html} = live(conn, list_path(scope))
    assert words(lv, "#integration-#{acme.public_id}-state") == "Installed · 1 collection"
  end

  test "names the collections as each adapter does, joined by name where they differ", %{
    conn: conn,
    scope: scope
  } do
    adapter_fixture(%{name: unique_adapter_name("Beta")})
    |> describe_source("example-tracker.json")

    {:ok, lv, _html} = live(conn, list_path(scope))

    assert words(lv, "#integrations-serve") ==
             "An integration installed here serves each workspace through the projects assigned to it."

    adapter_fixture(%{name: unique_adapter_name("Gamma")}) |> describe_source("acme-tracker.json")
    {:ok, lv, _html} = live(conn, list_path(scope))

    assert words(lv, "#integrations-serve") ==
             "An integration installed here serves each workspace through the projects and collections assigned to it."

    alpha = adapter_fixture(%{name: unique_adapter_name("Alpha")})

    {1, _} =
      Apiary.Repo.update_all(from(n in Apiary.Nodes.Node, where: n.id == ^alpha.id),
        set: [collection_noun_one: "queue", collection_noun_other: "queues"]
      )

    {:ok, lv, _html} = live(conn, list_path(scope))

    assert words(lv, "#integrations-serve") ==
             "An integration installed here serves each workspace through the queues, projects and collections assigned to it."
  end

  test "a source that names no word for its collections: collection, for one and many", %{
    conn: conn,
    scope: scope
  } do
    %{adapter: acme} = connectable_adapter_fixture(%{name: "Acme tracker"})
    %{adapter: shop} = connectable_adapter_fixture(%{name: "Shop tracker"})
    assert Apiary.Adapters.collection_noun(acme) == nil
    {connection, _nonce} = connection_fixture(scope, acme, :listed)
    source_collection_fixture(scope, connection)

    {:ok, lv, _html} = live(conn, list_path(scope))
    assert words(lv, "#integration-#{acme.public_id}-state") == "Installed · 1 collection"

    assert words(lv, "#integrations-serve") ==
             "An integration installed here serves each workspace through the collections assigned to it."

    {:ok, lv, _html} = live(conn, list_path(scope) <> "/new")

    assert words(lv, "#add-#{shop.public_id}") =~
             "The collections it reaches are listed on this page."
  end

  test "an admin has Add too", %{scope: scope} do
    adapter = adapter_fixture()
    {:ok, lv, _html} = live(member_conn(scope, :admin), list_path(scope))
    assert has_element?(lv, "#integration-#{adapter.public_id}-add")
    refute has_element?(lv, "#integrations-who")
  end

  test "a member reads the list, with no Add, and who installs them", %{scope: scope} do
    adapter = adapter_fixture()
    {:ok, lv, _html} = live(member_conn(scope), list_path(scope))

    assert words(lv, "#integration-#{adapter.public_id}-state") == "Not installed"
    refute has_element?(lv, "#integration-#{adapter.public_id}-add")

    assert words(lv, "#integrations-who") ==
             "Owners and admins of #{scope.organisation.name} install integrations."
  end

  test "with several workspaces, a member reads that owners and admins assign their collections too",
       %{scope: scope} do
    Edition.put_test_stub(EditionStubs.ManyWorkspaces)
    workspace_fixture(scope.organisation, "Platform")
    adapter_fixture()

    {:ok, lv, _html} = live(member_conn(scope), list_path(scope))

    assert words(lv, "#integrations-who") ==
             "Owners and admins of #{scope.organisation.name} install integrations and assign their collections to workspaces."
  end

  test "with no adapter, an empty state in place of the table says who adds them", %{
    conn: conn,
    scope: scope
  } do
    {:ok, lv, _html} = live(conn, list_path(scope))
    refute has_element?(lv, "#integrations")
    assert has_element?(lv, "h2", "No integration yet")

    assert words(lv, "#integrations-none") ==
             "An instance admin adds integrations in Instance settings › Adapters. " <>
               "#{scope.organisation.name} can install them here once they are added."

    # The foot note about what an integration installed here does waits for one.
    refute has_element?(lv, "#integrations-serve")
  end

  test "with an adapter, the table and no empty state", %{conn: conn, scope: scope} do
    adapter = adapter_fixture(%{name: unique_adapter_name("Shop tracker")})
    {:ok, lv, _html} = live(conn, list_path(scope))
    assert has_element?(lv, "#integrations #integration-#{adapter.public_id}")
    refute has_element?(lv, "#integrations-none")
    refute has_element?(lv, "h2", "No integration yet")
  end

  test "is not found where the feature is hidden from the person", %{conn: conn, scope: scope} do
    :ok = Edition.put_test_stub(EditionStubs.HidesNamed)
    :ok = EditionStubs.HidesNamed.put([:factory])

    assert_raise ApiaryWeb.Features.NotFound, fn -> live(conn, list_path(scope)) end
  end

  test "is not found to someone outside the organisation", %{scope: scope} do
    %{user: other} = sign_up_fixture()

    assert log_in_user(build_conn(), other) |> get(list_path(scope)) |> response(404)
  end

  describe "Add an integration" do
    defp new_path(scope), do: ~p"/#{scope.organisation}/settings/integrations/new"

    test "a block for each integration not installed, with Install and Cancel", %{
      conn: conn,
      scope: scope
    } do
      %{adapter: acme} = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

      %{adapter: installed} =
        connectable_adapter_fixture(%{name: unique_adapter_name("Platform tracker")})

      connection_fixture(scope, installed, :listed)
      org = scope.organisation.name

      {:ok, lv, _html} = live(conn, new_path(scope))

      assert has_element?(lv, "h1", "Add an integration")

      assert page_title(lv) =~
               "Add an integration · Integrations · Organisation settings · #{org}"

      assert has_element?(lv, ~s{#settings-tab-integrations[aria-current="true"]})
      assert has_element?(lv, ~s{#breadcrumb-section[href="#{list_path(scope)}"]})

      assert words(lv, ".q-settings-head-sub") ==
               "Install one of this instance's integrations for #{org}."

      id = "#add-#{acme.public_id}"
      assert words(lv, "#{id}-name") == acme.name

      assert words(lv, id) ==
               "#{acme.name} #{acme.name} then brings you back here. The collections it reaches are listed on this page. #{org} can have one installation of #{acme.name}. Install Cancel"

      install = "#{list_path(scope)}/#{acme.public_id}/install"
      assert has_element?(lv, ~s{form#{id}-form[action="#{install}"][method="post"]})
      assert has_element?(lv, "#{id}-form-install:not([disabled])")
      assert has_element?(lv, ~s{a#{id}-cancel[href="#{list_path(scope)}"]})
      refute has_element?(lv, "#{id}-not-ready")
      refute has_element?(lv, "#add-#{installed.public_id}")
      refute has_element?(lv, "#add-none")
    end

    test "with every integration installed, says so, with no lead", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, new_path(scope))
      refute has_element?(lv, "#add-none")
      assert has_element?(lv, ".q-settings-head-sub")

      for base <- ["Acme tracker", "Platform tracker"] do
        %{adapter: adapter} = connectable_adapter_fixture(%{name: unique_adapter_name(base)})
        connection_fixture(scope, adapter, :listed)
      end

      {:ok, lv, _html} = live(conn, new_path(scope))
      assert words(lv, "#add-none") == "All integrations are installed."
      refute has_element?(lv, ".q-settings-head-sub")
      refute has_element?(lv, "[id^=add-na_]")
    end

    test "Install sends the person on to the integration, saying so meanwhile", %{
      conn: conn,
      scope: scope
    } do
      %{adapter: acme} = connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})
      {:ok, lv, _html} = live(conn, new_path(scope))

      form = form(lv, "#add-#{acme.public_id}-form")
      render_submit(form)

      assert words(lv, "#add-#{acme.public_id}-sending") == "Taking you to #{acme.name}…"
      refute has_element?(lv, "#add-#{acme.public_id}-cancel")

      conn = follow_trigger_action(form, conn)
      assert conn.method == "POST"

      assert conn.request_path ==
               "/#{scope.organisation.slug}/settings/integrations/#{acme.public_id}/install"

      assert conn.status == 200
      assert conn.resp_body =~ "https://tracker.example.com/connect?state="
    end

    test "an integration not set up yet: Install disabled, and why", %{conn: conn, scope: scope} do
      adapter = adapter_fixture(%{name: unique_adapter_name("Shop tracker")})
      {:ok, lv, _html} = live(conn, new_path(scope))

      id = "#add-#{adapter.public_id}"
      assert has_element?(lv, "#{id}-form-install[disabled]")

      assert words(lv, "#{id}-not-ready") ==
               "#{adapter.name} can't be installed yet: this instance's admins are still setting it up."

      render_submit(form(lv, "#{id}-form"))
      refute has_element?(lv, "#{id}-sending")
    end

    test "names the collections in each adapter's words", %{conn: conn, scope: scope} do
      %{adapter: adapter} =
        connectable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

      describe_source(adapter, "example-tracker.json")
      {:ok, lv, _html} = live(conn, new_path(scope))

      assert words(lv, "#add-#{adapter.public_id}") =~
               "The projects it reaches are listed on this page."
    end

    test "an admin has it too; a member does not", %{scope: scope} do
      connectable_adapter_fixture()
      {:ok, _lv, _html} = live(member_conn(scope, :admin), new_path(scope))

      assert_raise ApiaryWeb.NotFound, fn -> live(member_conn(scope), new_path(scope)) end
    end
  end
end
