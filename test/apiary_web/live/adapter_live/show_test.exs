defmodule ApiaryWeb.AdapterLive.ShowTest do
  # An integration's page (`ApiaryWeb.AdapterLive.Show`): its title, state line and tabs;
  # Node pools, the pools it serves with their workspaces; Settings, with Rename on a page
  # of its own and Remove this integration asked in place; and what a member reads and is
  # refused, and another organisation's integration, which is not found.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, Nodes}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Repo
  alias ApiaryWeb.AdapterRoutes

  @endpoint AdapterRoutes.Endpoint

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup %{scope: scope} do
    AdapterRoutes.start!()
    %{adapter: adapter_fixture(scope, name: "GitHub")}
  end

  defp list_path(scope), do: "/#{scope.organisation.slug}/settings/integrations"

  defp adapter_path(scope, adapter, rest \\ ""),
    do: list_path(scope) <> "/#{adapter.public_id}" <> rest

  defp member_conn(scope) do
    %{user: user} = member_fixture(scope)
    log_in_user(build_conn(), user)
  end

  # The text of an element as rendered, its spaces made one.
  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  describe "the page" do
    test "is titled by the name, with its state and its four tabs",
         %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, lv, _html} = live(conn, adapter_path(scope, adapter))

      assert has_element?(lv, "h1", "GitHub")
      assert words(lv, "#adapter-state") == "No access key yet"

      for {key, words, rest} <- [
            {:collections, "Repositories and projects", ""},
            {:pools, "Node pools", "/node-pools"},
            {:access_key, "Access key", "/access-key"},
            {:settings, "Settings", "/settings"}
          ] do
        assert has_element?(
                 lv,
                 ~s{#adapter-tabs-#{key}[href="#{adapter_path(scope, adapter, rest)}"]},
                 words
               )
      end

      assert has_element?(lv, ~s{#adapter-tabs-collections[aria-current="page"]})
    end

    test "says not connected once the integration holds a key",
         %{conn: conn, scope: scope, adapter: adapter} do
      enrolled_key_fixture(scope, adapter)
      {:ok, lv, _html} = live(conn, adapter_path(scope, adapter))

      assert words(lv, "#adapter-state") == "Not connected"
    end

    test "of another organisation, or of none, is not found", %{conn: conn, scope: scope} do
      %{scope: other} = sign_up_fixture()
      elsewhere = adapter_fixture(other)

      assert_error_sent :not_found, fn ->
        get(conn, list_path(scope) <> "/#{elsewhere.public_id}")
      end

      assert_error_sent :not_found, fn -> get(conn, list_path(scope) <> "/na_none") end
    end
  end

  describe "Node pools" do
    test "says it serves none", %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, lv, _html} = live(conn, adapter_path(scope, adapter, "/node-pools"))

      assert has_element?(lv, ~s{#adapter-tabs-pools[aria-current="page"]})

      assert render(lv) =~
               "Node pools whose runs this integration starts. Set on each pool&#39;s settings page, under Served by."

      assert words(lv, "#adapter-pools-empty") == "It serves no node pool."
      refute has_element?(lv, "#adapter-pools-table")
    end

    test "lists the pools it serves, each with its workspace and a link to the pool",
         %{conn: conn, scope: scope, user: user, adapter: adapter} do
      pool = pool_fixture(scope, name: "build")
      {:ok, _pool} = Nodes.update_node(scope, pool, %{served_by_id: adapter.id})

      platform = workspace_fixture(scope.organisation, "Platform")
      platform_scope = workspace_scope(user, platform)
      other = pool_fixture(platform_scope, name: "deploy")
      {:ok, _other} = Nodes.update_node(platform_scope, other, %{served_by_id: adapter.id})
      pool_fixture(scope, name: "unserved")

      {:ok, lv, html} = live(conn, adapter_path(scope, adapter, "/node-pools"))

      refute has_element?(lv, "#adapter-pools-empty")
      assert has_element?(lv, "thead th", "Workspace")
      assert has_element?(lv, "thead th", "Node pool")
      refute html =~ "unserved"

      assert has_element?(lv, "#pool-#{pool.public_id}", scope.workspace.name)

      assert has_element?(
               lv,
               ~s{#pool-#{pool.public_id} a[href="/#{scope.organisation.slug}/#{scope.workspace.slug}/nodes/#{pool.public_id}"]},
               "build"
             )

      assert has_element?(lv, "#pool-#{other.public_id}", "Platform")

      assert has_element?(
               lv,
               ~s{#pool-#{other.public_id} a[href="/#{scope.organisation.slug}/#{platform.slug}/nodes/#{other.public_id}"]},
               "deploy"
             )
    end
  end

  describe "Settings" do
    test "shows the name with Rename, and Remove this integration",
         %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, lv, _html} = live(conn, adapter_path(scope, adapter, "/settings"))

      assert has_element?(lv, ~s{#adapter-tabs-settings[aria-current="page"]})
      assert has_element?(lv, "#adapter-name", "Name")
      assert words(lv, "#adapter-name-value") == "GitHub"

      assert has_element?(
               lv,
               ~s{#adapter-rename[href="#{adapter_path(scope, adapter, "/settings/rename")}"]},
               "Rename"
             )

      assert has_element?(lv, "#adapter-remove", "Remove this integration")
      refute has_element?(lv, "#adapter-remove-confirm")
      refute has_element?(lv, "#adapter-readers")
    end

    test "Rename is a page: the name, Save, and back on Settings with the new name",
         %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, lv, _html} = live(conn, adapter_path(scope, adapter, "/settings"))

      lv |> element("#adapter-rename") |> render_click()
      assert_patch(lv, adapter_path(scope, adapter, "/settings/rename"))

      assert has_element?(lv, "h1", "Rename GitHub")
      assert has_element?(lv, "label", "Name")
      assert has_element?(lv, "#rename-adapter-submit", "Save")

      assert has_element?(
               lv,
               ~s{#rename-adapter-save a[href="#{adapter_path(scope, adapter, "/settings")}"]},
               "Cancel"
             )

      html = lv |> form("#rename-adapter-form", adapter: %{name: ""}) |> render_submit()
      assert html =~ "Give it a name."

      adapter_fixture(scope, name: "Linear")
      html = lv |> form("#rename-adapter-form", adapter: %{name: "Linear"}) |> render_submit()
      assert html =~ "This organisation already has an integration named Linear."

      lv |> form("#rename-adapter-form", adapter: %{name: "GitHub Shop"}) |> render_submit()
      assert_patch(lv, adapter_path(scope, adapter, "/settings"))

      assert words(lv, "#adapter-name-value") == "GitHub Shop"
      assert has_element?(lv, "h1", "GitHub Shop")
      assert Adapters.get_adapter(scope, adapter.public_id).name == "GitHub Shop"
    end

    test "Remove this integration is asked in place; Keep it leaves it be",
         %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, lv, _html} = live(conn, adapter_path(scope, adapter, "/settings"))

      lv |> element("#adapter-remove") |> render_click()
      assert_patch(lv, adapter_path(scope, adapter, "/settings/remove"))

      assert words(lv, "#adapter-remove-confirm") =~
               "Remove GitHub? Its access keys are revoked, and its repositories and projects leave every backlog. Work items already taken in keep their links."

      assert has_element?(lv, "#adapter-remove-confirm-button", "Remove it")
      assert has_element?(lv, "#adapter-remove-confirm-cancel", "Keep it")

      lv |> element("#adapter-remove-confirm-cancel") |> render_click()
      assert_patch(lv, adapter_path(scope, adapter, "/settings"))
      refute has_element?(lv, "#adapter-remove-confirm")
      assert Adapters.get_adapter(scope, adapter.public_id)
    end

    test "Remove it removes it, revokes its keys, and leads to the list",
         %{conn: conn, scope: scope, adapter: adapter} do
      %{access_key: key} = enrolled_key_fixture(scope, adapter)
      pool = pool_fixture(scope)
      {:ok, _pool} = Nodes.update_node(scope, pool, %{served_by_id: adapter.id})

      {:ok, lv, _html} = live(conn, adapter_path(scope, adapter, "/settings/remove"))

      {:error, {:live_redirect, %{to: to}}} =
        lv |> element("#adapter-remove-confirm-button") |> render_click()

      assert to == list_path(scope)
      refute Adapters.get_adapter(scope, adapter.public_id)
      assert Repo.get!(AccessKey, key.id).revoked_at
      assert Repo.reload!(pool).served_by_id == nil
    end
  end

  describe "a member" do
    test "reads Settings without Rename or Remove, and the line says who changes them",
         %{scope: scope, adapter: adapter} do
      {:ok, lv, _html} = live(member_conn(scope), adapter_path(scope, adapter, "/settings"))

      assert words(lv, "#adapter-name-value") == "GitHub"
      refute has_element?(lv, "#adapter-rename")
      refute has_element?(lv, "#adapter-remove")

      assert words(lv, "#adapter-readers") ==
               "Only organisation owners and admins change integrations."
    end

    test "is refused Rename's and Remove's paths and events, and nothing changes",
         %{scope: scope, adapter: adapter} do
      conn = member_conn(scope)
      settings = adapter_path(scope, adapter, "/settings")

      for rest <- ["/settings/rename", "/settings/remove"] do
        {:ok, lv, html} =
          live(conn, adapter_path(scope, adapter, rest)) |> follow_redirect(conn, settings)

        assert html =~ "Only organisation owners and admins change integrations."
        refute has_element?(lv, "#rename-adapter-form")
        refute has_element?(lv, "#adapter-remove-confirm")
      end

      {:ok, lv, _html} = live(conn, settings)
      render_hook(lv, "rename", %{"adapter" => %{"name" => "Pushed"}})
      assert_patch(lv, settings)
      render_hook(lv, "remove", %{})
      assert_patch(lv, settings)

      assert Adapters.get_adapter(scope, adapter.public_id).name == "GitHub"
    end
  end
end
