defmodule ApiaryWeb.AdapterLive.IndexTest do
  # Organisation settings › Integrations (`ApiaryWeb.AdapterLive.Index`, `:index`): the
  # instance's adapters by name, each installed in the organisation or not, Add for an
  # owner or an admin, the chevron to an installed one's page, and the foot notes, the
  # members' by the organisation's workspaces; behind the feature, for members.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

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
    shop = adapter_fixture(%{name: "Shop tracker"})
    acme = adapter_fixture(%{name: "Acme tracker"})

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
             "An integration installed here serves each workspace through the repositories assigned to it."

    refute has_element?(lv, "#integrations-who")
  end

  test "an installed one leads to its page, by its name and its chevron; a pending one is not installed",
       %{conn: conn, scope: scope} do
    %{adapter: installed} = connectable_adapter_fixture(%{name: "Acme tracker"})
    %{adapter: pending} = connectable_adapter_fixture(%{name: "Shop tracker"})
    connection_fixture(scope, installed, :connected)
    connection_fixture(scope, pending, :pending)

    {:ok, lv, _html} = live(conn, list_path(scope))

    show = "#{list_path(scope)}/#{installed.public_id}"
    id = "#integration-#{installed.public_id}"
    assert has_element?(lv, ~s{a#{id}-name[href="#{show}"]}, "Acme tracker")
    assert has_element?(lv, ~s{a#{id}-open[href="#{show}"][aria-label="Open Acme tracker"]})
    refute has_element?(lv, "#{id}-add")
    refute has_element?(lv, "#{id}-state")

    id = "#integration-#{pending.public_id}"
    assert words(lv, "#{id}-state") == "Not installed"
    assert has_element?(lv, "#{id}-add")
    refute has_element?(lv, "#{id}-open")
  end

  test "names the collections as the adapters do, when they all name the same", %{
    conn: conn,
    scope: scope
  } do
    adapter_fixture() |> describe_source("example-tracker.json")

    {:ok, lv, _html} = live(conn, list_path(scope))

    assert words(lv, "#integrations-serve") ==
             "An integration installed here serves each workspace through the projects assigned to it."

    adapter_fixture() |> describe_source("acme-tracker.json")
    {:ok, lv, _html} = live(conn, list_path(scope))

    assert words(lv, "#integrations-serve") ==
             "An integration installed here serves each workspace through the repositories assigned to it."
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
             "Owners and admins of #{scope.organisation.name} install integrations and assign their repositories to workspaces."
  end

  test "with no adapter, the table has no row", %{conn: conn, scope: scope} do
    {:ok, lv, _html} = live(conn, list_path(scope))
    refute has_element?(lv, "#integrations tr")
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
end
