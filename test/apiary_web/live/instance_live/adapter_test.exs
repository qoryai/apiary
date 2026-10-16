defmodule ApiaryWeb.InstanceLive.AdapterTest do
  # An adapter's page in Instance settings › Adapters (`ApiaryWeb.InstanceLive.Adapter`),
  # for an instance admin: its Overview, the state, when it was last seen, read again as a
  # key arrives, and the install
  # address; its Settings tab, with its name and the danger zone; the Rename page, with its
  # errors; the Remove page, which revokes its keys and ends every connection to it; and a
  # path that does not exist for anyone else.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Adapters.Connection

  @moduletag needs: :factory

  setup do
    admin = instance_admin_scope()

    %{
      admin: admin,
      conn: log_in_user(build_conn(), admin.user),
      adapter: adapter_fixture(%{name: "Shop tracker"})
    }
  end

  defp page_path(adapter, rest \\ ""), do: "/instance/adapters/#{adapter.public_id}" <> rest

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> String.replace(~r/<(p|div|h[1-6]|li|dt|dd|span)[\s>]/, " \\0")
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  describe "the Overview" do
    test "with no key yet, says so, with the way to connect it, and that nothing is declared",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter))

      assert has_element?(lv, "h1", "Shop tracker")
      assert page_title(lv) =~ "Shop tracker · Adapters · Instance settings"
      assert words(lv, "#adapter-meta") =~ ~r/^Added by .+, .+ · #{adapter.public_id}$/
      assert has_element?(lv, ~s{#adapter-tabs-overview[aria-current="page"]}, "Overview")
      assert has_element?(lv, ~s{#adapter-tabs-keys[href="#{page_path(adapter, "/keys")}"]})

      assert has_element?(
               lv,
               ~s{#adapter-tabs-settings[href="#{page_path(adapter, "/settings")}"]}
             )

      assert words(lv, "#adapter-overview") ==
               "State No key yet · organisations can install it once it is connected and running Connect it Install address Not declared yet"

      assert has_element?(lv, ~s{#adapter-connect-it[href="#{page_path(adapter, "/keys")}"]})
    end

    test "with a key, says when it was last seen, or Never seen, and shows the install address it declared",
         %{conn: conn, admin: admin} do
      %{adapter: adapter, access_key: key} =
        connectable_adapter_fixture(%{name: "Platform tracker"})

      {:ok, lv, html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-state") == "Never seen"
      refute has_element?(lv, "#adapter-connect-it")
      refute html =~ "Connected"

      assert words(lv, "#adapter-overview-install") ==
               "#{adapter.connect_url} · where organisations are sent to install it, as it declares"

      Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
        set: [last_used_at: DateTime.add(DateTime.utc_now(:second), -120)]
      )

      {:ok, lv, _html} = live(conn, page_path(adapter))
      assert words(lv, "#adapter-overview-state") =~ ~r/^Last seen \S/
      assert has_element?(lv, "#adapter-state-seen")

      other = adapter_fixture(%{name: "Shop tracker 2"})
      {:ok, lv, _html} = live(conn, page_path(other))
      assert words(lv, "#adapter-overview-state") =~ "No key yet"

      %{access_key: key} = enrolled_key_fixture(admin, other)
      send(lv.pid, {:key_enrolled, %{key_id: key.key_id, node_id: other.id}})
      assert words(lv, "#adapter-overview-state") == "Never seen"
      refute has_element?(lv, "#adapter-connect-it")
    end
  end

  describe "the Settings tab" do
    test "holds the name with Rename…, and the danger zone with Remove adapter…",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))

      assert has_element?(lv, ~s{#adapter-tabs-settings[aria-current="page"]})
      assert page_title(lv) =~ "Settings · Shop tracker · Adapters"
      assert words(lv, "#adapter-name") == "Name Shop tracker Rename…"

      assert words(lv, "#adapter-danger") ==
               "Danger zone Remove this adapter Its keys are revoked, and every organisation's installation of it ends. This cannot be undone. Remove adapter…"

      lv |> element("#adapter-rename-link") |> render_click()
      assert_patch(lv, page_path(adapter, "/settings/rename"))

      lv |> render_patch(page_path(adapter, "/settings"))
      lv |> element("#adapter-remove-link") |> render_click()
      assert_patch(lv, page_path(adapter, "/settings/remove"))
    end
  end

  describe "Rename" do
    test "renames the adapter, and Settings shows the new name", %{
      conn: conn,
      admin: admin,
      adapter: adapter
    } do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings/rename"))

      assert has_element?(lv, "h1", "Rename Shop tracker")
      assert page_title(lv) =~ "Rename Shop tracker · Adapters"

      assert words(lv, ".q-settings-head-sub") ==
               "Organisations see the new name on their Integrations page and when they install it."

      assert has_element?(lv, "#adapter-rename-form label", "Name")
      assert render(lv) =~ "At most 64 characters, and not the name of another adapter here."

      assert has_element?(
               lv,
               ~s{#adapter-rename-save-cancel[href="#{page_path(adapter, "/settings")}"]}
             )

      lv |> form("#adapter-rename-form", adapter: %{name: "Platform tracker"}) |> render_submit()
      assert_patch(lv, page_path(adapter, "/settings"))
      assert words(lv, "#adapter-name-value") == "Platform tracker"
      assert has_element?(lv, "h1", "Platform tracker")
      assert Adapters.get_adapter(admin, adapter.public_id).name == "Platform tracker"
    end

    test "a name taken by another adapter, or too long, is said under the field",
         %{conn: conn, admin: admin, adapter: adapter} do
      adapter_fixture(%{name: "Platform tracker"})
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings/rename"))

      html =
        lv
        |> form("#adapter-rename-form", adapter: %{name: "Platform tracker"})
        |> render_submit()

      assert html =~ "has already been taken"

      html =
        lv
        |> form("#adapter-rename-form", adapter: %{name: String.duplicate("a", 65)})
        |> render_change()

      assert html =~ "should be at most 64 character(s)"
      assert Adapters.get_adapter(admin, adapter.public_id).name == "Shop tracker"
    end
  end

  describe "Remove" do
    test "says what happens, then revokes its keys, cancels its codes and ends its connections",
         %{conn: conn, admin: admin} do
      %{scope: scope} = sign_up_fixture()

      %{adapter: adapter, access_key: key} =
        connectable_adapter_fixture(%{name: "Platform tracker"})

      {:ok, code, _code} = Adapters.create_code(admin, adapter)
      {connection, _nonce} = connection_fixture(scope, adapter, :listed)

      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings/remove"))

      assert has_element?(lv, "h1", "Remove Platform tracker?")
      assert page_title(lv) =~ "Remove Platform tracker · Adapters"
      assert words(lv, ".q-settings-head-sub") == "This happens at once:"

      assert words(lv, "#adapter-remove-follows") ==
               "Its keys are revoked, so the adapter can no longer reach Qory. A command still waiting is cancelled. Qory tells the adapter nothing. Its name is free again. This cannot be undone."

      assert has_element?(lv, "#adapter-remove-button", "Remove Platform tracker")

      assert has_element?(
               lv,
               ~s{#adapter-remove-save-cancel[href="#{page_path(adapter, "/settings")}"]}
             )

      assert {:error, {:live_redirect, %{to: "/instance/adapters"}}} =
               lv |> element("#adapter-remove-button") |> render_click()

      assert Adapters.get_adapter(admin, adapter.public_id) == nil
      assert Repo.get!(AccessKey, key.id).revoked_at
      assert Repo.get!(EnrolmentCode, code.id).cancelled_at
      assert Repo.get!(Connection, connection.id).ended_at

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, page_path(adapter)) end
    end

    test "an adapter removed meanwhile leaves for the list", %{
      conn: conn,
      admin: admin,
      adapter: adapter
    } do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings/remove"))
      {:ok, _removed} = Adapters.delete_adapter(admin, adapter)

      assert {:error, {:live_redirect, %{to: "/instance/adapters"}}} =
               lv |> element("#adapter-remove-button") |> render_click()
    end
  end

  test "an act without its page open does nothing", %{conn: conn, admin: admin, adapter: adapter} do
    {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))
    render_click(lv, "remove", %{})
    render_submit(lv, "rename", %{"adapter" => %{"name" => "Platform tracker"}})
    assert Adapters.get_adapter(admin, adapter.public_id).name == "Shop tracker"
  end

  test "anyone but an instance admin, an organisation's owner included, meets Not Found",
       %{conn: conn, adapter: adapter} do
    %{user: owner} = sign_up_fixture()
    owner_conn = log_in_user(build_conn(), owner)

    for rest <- ["", "/settings", "/settings/rename", "/settings/remove"] do
      assert_raise ApiaryWeb.NotFound, fn -> live(owner_conn, page_path(adapter, rest)) end
    end

    assert_raise ApiaryWeb.NotFound, fn -> live(conn, "/instance/adapters/na_none") end
  end
end
