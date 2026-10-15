defmodule ApiaryWeb.AdapterLive.IndexTest do
  # Organisation settings › Integrations (`ApiaryWeb.AdapterLive.Index`): the list, its
  # columns and the words of a state, empty, and the lines under it; Add an integration on
  # a page of its own, its refusals, and the integration's page it opens on its Access key
  # tab; and what a member reads and is refused.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Adapters
  alias ApiaryWeb.AdapterRoutes

  @endpoint AdapterRoutes.Endpoint

  @moduletag needs: :factory

  setup :register_and_log_in_user

  setup do
    AdapterRoutes.start!()
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

  describe "the list" do
    test "says there is none yet, with the button and the line about accounts",
         %{conn: conn, scope: scope} do
      {:ok, lv, html} = live(conn, list_path(scope))

      assert page_title(lv) =~ "Integrations · Organisation settings"
      assert has_element?(lv, "h1", "Integrations")

      assert html =~
               "The systems this organisation works with: where tickets come from, and the node pools they serve. Each one reaches Qory through its adapter."

      assert has_element?(lv, "#new-adapter", "Add an integration")

      assert words(lv, "#adapters-empty") ==
               "No integration yet. Add one, enrol its adapter's access key, and connect it."

      refute has_element?(lv, "#adapters")

      assert words(lv, "#adapters-one-account") ==
               "One integration connects one account. To work with another account of the same system, use another organisation."

      refute has_element?(lv, "#adapters-readers")
    end

    test "lists each integration by name, with its state and a dash where it is not connected",
         %{conn: conn, scope: scope} do
      linear = adapter_fixture(scope, name: "Linear")
      github = adapter_fixture(scope, name: "GitHub")
      enrolled_key_fixture(scope, github)

      {:ok, lv, _html} = live(conn, list_path(scope))

      assert has_element?(lv, "thead th", "Integration")
      assert has_element?(lv, "thead th", "Repositories or projects")
      assert has_element?(lv, "thead th", "State")
      assert has_element?(lv, "thead th", "Last update")
      refute has_element?(lv, "#adapters-empty")

      # By name, each a link to its page.
      names =
        lv
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#adapters tr .q-title")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert names == ["GitHub", "Linear"]

      assert has_element?(
               lv,
               ~s{#adapter-#{github.public_id}-name[href="#{adapter_path(scope, github)}"]},
               "GitHub"
             )

      # One with a key that has not connected; one with no key yet.
      assert words(lv, "#adapter-#{github.public_id}-state") == "Not connected"
      assert words(lv, "#adapter-#{linear.public_id}-state") == "No access key yet"

      for adapter <- [github, linear] do
        assert words(lv, "#adapter-#{adapter.public_id}-collections") == "—"
        assert words(lv, "#adapter-#{adapter.public_id}-updated") == "—"
        refute has_element?(lv, "#adapter-#{adapter.public_id}-unassigned")
      end

      assert has_element?(lv, "#adapters-one-account")
    end

    test "is the organisation's: another organisation's integrations are not listed",
         %{conn: conn, scope: scope} do
      %{scope: other} = sign_up_fixture()
      adapter_fixture(other, name: "Elsewhere")

      {:ok, _lv, html} = live(conn, list_path(scope))
      refute html =~ "Elsewhere"
    end
  end

  describe "Add an integration" do
    test "is a page of its own: its name alone, then the integration's Access key tab",
         %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, list_path(scope))

      lv |> element("#new-adapter") |> render_click()
      assert_patch(lv, list_path(scope) <> "/new")

      assert has_element?(lv, "h1", "Add an integration")
      assert crumbs(lv, :organisation) |> List.last() |> elem(0) == "Add"
      assert has_element?(lv, "label", "Name")
      assert render(lv) =~ "What people here call it, such as GitHub or Linear."
      assert has_element?(lv, "#new-adapter-submit", "Add integration")

      assert has_element?(
               lv,
               ~s{#new-adapter-save a[href="#{list_path(scope)}"]},
               "Cancel"
             )

      {:error, {:live_redirect, %{to: to}}} =
        lv |> form("#new-adapter-form", adapter: %{name: "GitHub"}) |> render_submit()

      [adapter] = Adapters.list_adapters(scope)
      assert adapter.name == "GitHub"
      assert to == adapter_path(scope, adapter, "/access-key")
    end

    test "refuses an empty name and one the organisation has, in the page's words",
         %{conn: conn, scope: scope} do
      adapter_fixture(scope, name: "GitHub")
      {:ok, lv, _html} = live(conn, list_path(scope) <> "/new")

      html = lv |> form("#new-adapter-form", adapter: %{name: ""}) |> render_submit()
      assert html =~ "Give it a name."

      html = lv |> form("#new-adapter-form", adapter: %{name: "GitHub"}) |> render_submit()
      assert html =~ "This organisation already has an integration named GitHub."

      assert length(Adapters.list_adapters(scope)) == 1
    end

    test "Cancel goes back to the list", %{conn: conn, scope: scope} do
      {:ok, lv, _html} = live(conn, list_path(scope) <> "/new")

      lv |> element("#new-adapter-save a", "Cancel") |> render_click()
      assert_patch(lv, list_path(scope))
      assert has_element?(lv, "#adapters-empty")
    end
  end

  describe "a member" do
    test "reads the list without the button, and the line says who changes integrations",
         %{scope: scope} do
      adapter_fixture(scope, name: "GitHub")
      {:ok, lv, _html} = live(member_conn(scope), list_path(scope))

      assert has_element?(lv, "#adapters", "GitHub")
      refute has_element?(lv, "#new-adapter")

      assert words(lv, "#adapters-readers") ==
               "Only organisation owners and admins change integrations."
    end

    test "is refused the form's page and its event, and nothing is made", %{scope: scope} do
      conn = member_conn(scope)

      {:ok, lv, html} =
        live(conn, list_path(scope) <> "/new") |> follow_redirect(conn, list_path(scope))

      assert html =~ "Only organisation owners and admins change integrations."
      refute has_element?(lv, "#new-adapter-form")

      render_hook(lv, "create", %{"adapter" => %{"name" => "Pushed"}})
      assert_patch(lv, list_path(scope))
      assert Adapters.list_adapters(scope) == []
    end
  end
end
