defmodule ApiaryWeb.InstanceLive.AdapterTest do
  # An adapter's page in Instance settings › Adapters (`ApiaryWeb.InstanceLive.Adapter`),
  # for an instance admin: its Overview, the state, when it was last seen, read again as a
  # key arrives, the install address and how often it pulls; its Settings tab, with the
  # pull interval, its name and the danger zone; the Rename page, with its errors; the
  # Remove page, which revokes its keys and ends every connection to it; and a path that
  # does not exist for anyone else.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, Repo}
  alias Apiary.AccessKeys.{AccessKey, EnrolmentCode}
  alias Apiary.Adapters.Connection
  alias Apiary.Nodes.Node

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

  # As the adapter's declaration would: its default, its minimum and whether it sends
  # changes.
  defp declare(adapter, set) do
    {1, _} = Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: set)
    adapter
  end

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
               "State No key yet · organisations can install it once it is connected and running · Connect it Install address Not declared yet Pulls Not declared yet"

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

  describe "the Overview's Pulls row" do
    test "says how often it pulls, that changes are sent, and leads to Settings",
         %{conn: conn, adapter: adapter} do
      declare(adapter,
        sync_default_interval: 3600,
        sync_minimum_interval: 900,
        sync_sends_changes: true
      )

      {:ok, lv, _html} = live(conn, page_path(adapter))

      assert words(lv, "#adapter-overview-pulls") ==
               "Every hour, and changes are sent as they happen · Change"

      lv |> element("#adapter-change-pulls") |> render_click()
      assert_patch(lv, page_path(adapter, "/settings"))
    end

    test "says the chosen interval alone when the adapter sends no changes",
         %{conn: conn, adapter: adapter} do
      declare(adapter,
        sync_interval: 7200,
        sync_default_interval: 3600,
        sync_minimum_interval: 900,
        sync_sends_changes: false
      )

      {:ok, lv, _html} = live(conn, page_path(adapter))
      assert words(lv, "#adapter-overview-pulls") == "Every 2 hours · Change"
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

  describe "the Settings tab's pull interval" do
    setup %{adapter: adapter} do
      declare(adapter,
        sync_default_interval: 3600,
        sync_minimum_interval: 900,
        sync_sends_changes: true
      )

      :ok
    end

    defp choices(lv) do
      html = lv |> element("#adapter-interval-form select") |> render()

      for [_whole, value, label] <-
            Regex.scan(~r{<option[^>]*value="(\d+)"[^>]*>([^<]*)</option>}, html),
          do: {label, value}
    end

    test "offers the declared choices, its default marked, with the hint and Save",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))

      assert has_element?(lv, "#adapter-interval h2, #adapter-interval h3", "Pull interval")

      assert has_element?(
               lv,
               "#adapter-interval-form label",
               "How often the adapter pulls what changed"
             )

      assert choices(lv) == [
               {"Every 15 minutes", "900"},
               {"Every 30 minutes", "1800"},
               {"Every hour (its default)", "3600"},
               {"Every 2 hours", "7200"},
               {"Every 6 hours", "21600"},
               {"Every 12 hours", "43200"},
               {"Every 24 hours", "86400"}
             ]

      assert has_element?(lv, ~s{#adapter-interval-form option[value="3600"][selected]})

      assert words(lv, "#adapter-interval-form .fieldset") =~
               "Changes are also sent to Qory as they happen; the pull catches what they missed. The adapter declares every hour as its default, and every 15 minutes as the most often. Organisations don't see this setting."

      assert has_element?(lv, "#adapter-interval-save button[type=submit]", "Save")
    end

    test "saves the chosen interval, says so, and the Overview reads it",
         %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))

      html =
        lv
        |> form("#adapter-interval-form", sync: %{sync_interval: "7200"})
        |> render_submit()

      assert html =~ "Shop tracker is saved."
      assert has_element?(lv, ~s{#adapter-interval-form option[value="7200"][selected]})
      assert Adapters.get_adapter(admin, adapter.public_id).sync_interval == 7200

      lv |> element("#adapter-tabs-overview") |> render_click()

      assert words(lv, "#adapter-overview-pulls") ==
               "Every 2 hours, and changes are sent as they happen · Change"
    end

    test "a value not among the choices is said under the field, and nothing is saved",
         %{conn: conn, admin: admin, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))

      html = render_submit(lv, "save_interval", %{"sync" => %{"sync_interval" => "300"}})

      assert html =~ "is invalid"
      refute html =~ "is saved."
      assert Adapters.get_adapter(admin, adapter.public_id).sync_interval == nil
    end

    test "without changes sent, the hint leaves out its first sentence; an off-ladder default is marked",
         %{conn: conn, adapter: adapter} do
      declare(adapter, sync_default_interval: 2700, sync_sends_changes: false)
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))

      assert {"Every 45 minutes (its default)", "2700"} in choices(lv)

      hint = words(lv, "#adapter-interval-form .fieldset")

      assert hint =~
               "The adapter declares every 45 minutes as its default, and every 15 minutes as the most often. Organisations don't see this setting."

      refute hint =~ "Changes are also sent"
    end

    test "an adapter no longer declared when saved shows the choice disabled",
         %{conn: conn, adapter: adapter} do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))

      declare(adapter,
        sync_default_interval: nil,
        sync_minimum_interval: nil,
        sync_sends_changes: nil
      )

      html = render_submit(lv, "save_interval", %{"sync" => %{"sync_interval" => "7200"}})

      refute html =~ "is saved."
      refute has_element?(lv, "#adapter-interval-form")
      assert has_element?(lv, "#adapter-interval-undeclared select[disabled]")
    end

    test "an adapter removed meanwhile leaves for the list", %{
      conn: conn,
      admin: admin,
      adapter: adapter
    } do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))
      {:ok, _removed} = Adapters.delete_adapter(admin, adapter)

      assert {:error, {:live_redirect, %{to: "/instance/adapters"}}} =
               render_submit(lv, "save_interval", %{"sync" => %{"sync_interval" => "7200"}})
    end
  end

  test "before the adapter declares, the pull interval is disabled, with why",
       %{conn: conn, adapter: adapter} do
    {:ok, lv, _html} = live(conn, page_path(adapter, "/settings"))

    refute has_element?(lv, "#adapter-interval-form")
    assert has_element?(lv, "#adapter-interval-undeclared select[disabled]")
    refute has_element?(lv, "#adapter-interval button")

    assert words(lv, "#adapter-interval-undeclared") ==
             "How often the adapter pulls what changed Not declared yet The adapter declares its default, and the most often it may pull, once it is connected and running. Until then this can't be set."
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
      assert render(lv) =~ "Platform tracker is renamed."
      assert words(lv, "#adapter-name-value") == "Platform tracker"
      assert has_element?(lv, "h1", "Platform tracker")
      assert Adapters.get_adapter(admin, adapter.public_id).name == "Platform tracker"
    end

    test "the name saved unchanged closes the form and says nothing", %{
      conn: conn,
      admin: admin,
      adapter: adapter
    } do
      {:ok, lv, _html} = live(conn, page_path(adapter, "/settings/rename"))

      lv |> form("#adapter-rename-form", adapter: %{name: "Shop tracker"}) |> render_submit()
      assert_patch(lv, page_path(adapter, "/settings"))
      refute render(lv) =~ "is renamed."
      assert words(lv, "#adapter-name-value") == "Shop tracker"
      assert Adapters.get_adapter(admin, adapter.public_id).name == "Shop tracker"
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

      removed = lv |> element("#adapter-remove-button") |> render_click()
      assert {:error, {:live_redirect, %{to: "/instance/adapters"}}} = removed
      {:ok, _list, html} = follow_redirect(removed, conn)
      assert html =~ "Platform tracker is removed."
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

    declare(adapter, sync_default_interval: 3600, sync_minimum_interval: 900)
    {:ok, lv, _html} = live(conn, page_path(adapter))
    render_submit(lv, "save_interval", %{"sync" => %{"sync_interval" => "7200"}})
    assert Adapters.get_adapter(admin, adapter.public_id).sync_interval == nil
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
