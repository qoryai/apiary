defmodule ApiaryWeb.AdapterLive.AccessKeyTest do
  # An integration's Access key tab (`ApiaryWeb.AdapterLive.AccessKey`): Enrol its key,
  # Make an enrolment code and the server and code it shows once, each with its Copy; a
  # code still waiting, with its cancelling confirmed in place; the keys, as a node's
  # tab lists them, without what only Forager's keys have, and Revoke at a node key's
  # path; and what a member reads and is refused.
  use ApiaryWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.AccessKeys
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

  defp tab_path(scope, adapter, rest \\ ""),
    do:
      "/#{scope.organisation.slug}/settings/integrations/#{adapter.public_id}/access-key" <> rest

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

  describe "Enrol its key" do
    test "is a tab of the integration's page, with one button and no key yet",
         %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, lv, _html} = live(conn, tab_path(scope, adapter))

      assert has_element?(lv, "h1", "GitHub")
      assert has_element?(lv, ~s{#adapter-tabs-access_key[aria-current="page"]}, "Access key")
      assert has_element?(lv, "#adapter-enrol h2", "Enrol its key")
      assert has_element?(lv, "#adapter-code-new", "Make an enrolment code")
      refute has_element?(lv, "#adapter-code")
      refute has_element?(lv, "#adapter-keys")
      refute has_element?(lv, "#adapter-readers")
    end

    test "Make an enrolment code shows the server and the code, each with its Copy, once",
         %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, lv, _html} = live(conn, tab_path(scope, adapter))

      lv |> element("#adapter-code-new") |> render_click()
      assert_patch(lv, tab_path(scope, adapter, "/new-code"))

      assert words(lv, "#adapter-code-text") ==
               "Run the adapter's enrol command with the server and this code on the adapter's host. The code works once, for 15 minutes."

      assert has_element?(lv, "#adapter-code dt", "Server")
      assert has_element?(lv, "#adapter-code dt", "Code")
      assert words(lv, "#adapter-code-server") == ApiaryWeb.Endpoint.url()
      assert has_element?(lv, "#adapter-code-server-copy", "Copy the server")
      assert has_element?(lv, "#adapter-code-code-copy", "Copy the code")

      code = words(lv, "#adapter-code-code")
      assert [_row] = AccessKeys.list_enrolment_codes(scope, adapter)
      assert code != ""
      refute page_title(lv) =~ code

      # Back on the tab the code is gone, and its page opened again has none to show.
      lv |> element("#adapter-tabs-access_key") |> render_click()
      assert_patch(lv, tab_path(scope, adapter))
      refute render(lv) =~ code

      {:ok, lv, html} =
        live(conn, tab_path(scope, adapter, "/new-code"))
        |> follow_redirect(conn, tab_path(scope, adapter))

      refute html =~ code
      assert has_element?(lv, "#adapter-code-new")
    end
  end

  describe "a code still waiting" do
    test "is listed with who got it and until when, and Cancel the command…",
         %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, adapter, %{})
      {:ok, lv, _html} = live(conn, tab_path(scope, adapter))

      assert has_element?(lv, "#adapter-enrol #code-#{row.id}")
      assert words(lv, "#code-#{row.id}") =~ ~r/got it at .+ It works once, until /
      refute render(lv) =~ "A command is waiting to be run on"
      assert has_element?(lv, "#adapter-code-new")

      assert has_element?(
               lv,
               ~s{#code-#{row.id}-revoke[href="#{tab_path(scope, adapter, "/codes/#{row.id}/revoke")}"]},
               "Cancel the command…"
             )
    end

    test "is cancelled once confirmed in place; Keep it leaves it waiting",
         %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, adapter, %{})
      {:ok, lv, _html} = live(conn, tab_path(scope, adapter))

      lv |> element("#code-#{row.id}-revoke") |> render_click()
      assert_patch(lv, tab_path(scope, adapter, "/codes/#{row.id}/revoke"))

      assert words(lv, "#code-#{row.id}-confirm") =~
               ~r/^Cancel the command from .+\? It stops working at once. A machine that runs it after this is refused./

      assert has_element?(lv, "#code-#{row.id}-confirm-button", "Yes, cancel it")

      lv |> element("#code-#{row.id}-confirm-cancel", "Keep it") |> render_click()
      assert_patch(lv, tab_path(scope, adapter))
      refute has_element?(lv, "#code-#{row.id}-confirm")

      lv |> element("#code-#{row.id}-revoke") |> render_click()
      lv |> element("#code-#{row.id}-confirm-button") |> render_click()
      assert_patch(lv, tab_path(scope, adapter))
      assert words(lv, "#flash-group") =~ ~r/The command is cancelled\.\s*It no longer works\./
      refute has_element?(lv, "#code-#{row.id}")
      assert AccessKeys.list_enrolment_codes(scope, adapter) == []
    end

    test "no longer waiting, its path says so", %{conn: conn, scope: scope, adapter: adapter} do
      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, adapter, %{})
      {:ok, _row} = AccessKeys.cancel_code(scope, row)

      {:ok, _lv, html} =
        live(conn, tab_path(scope, adapter, "/codes/#{row.id}/revoke"))
        |> follow_redirect(conn, tab_path(scope, adapter))

      assert html =~ "That command no longer works: it was run, cancelled or expired."
    end
  end

  describe "the keys" do
    test "are listed as a node's are, without what only Forager's keys have, with Revoke",
         %{conn: conn, scope: scope, adapter: adapter} do
      %{access_key: key} = enrolled_key_fixture(scope, adapter, label: "shop-adapter")

      key
      |> Ecto.Changeset.change(
        last_used_at: DateTime.utc_now(),
        last_forager_version: "0.7.0"
      )
      |> Repo.update!()

      {:ok, lv, _html} = live(conn, tab_path(scope, adapter))

      assert has_element?(lv, "#adapter-keys h2", "Keys")
      assert has_element?(lv, "#key-#{key.key_id}", "shop-adapter")
      assert words(lv, "#key-#{key.key_id}-added") =~ "Connected with a command by"
      refute has_element?(lv, "#key-#{key.key_id}-forager-file")
      refute has_element?(lv, "#key-#{key.key_id}-secret")
      refute has_element?(lv, "#key-#{key.key_id}-stored-secrets")
      # Its use is not recorded yet, so it has no Last used.
      refute has_element?(lv, "#key-#{key.key_id}-used")
      refute has_element?(lv, "#key-#{key.key_id} dt", "Last used")
      refute render(lv) =~ "Forager"

      assert has_element?(
               lv,
               ~s{#key-#{key.key_id}-revoke[href="#{tab_path(scope, adapter, "/keys/#{key.key_id}/revoke")}"]}
             )
    end

    test "Revoke is confirmed in place, as a node key's is, and revokes it",
         %{conn: conn, scope: scope, adapter: adapter} do
      %{access_key: key} = enrolled_key_fixture(scope, adapter, label: "shop-adapter")
      {:ok, lv, _html} = live(conn, tab_path(scope, adapter, "/keys/#{key.key_id}/revoke"))

      html = lv |> element("#key-#{key.key_id} button[phx-click=revoke]") |> render_click()
      assert_patch(lv, tab_path(scope, adapter))
      assert html =~ "shop-adapter is revoked."
      assert Repo.get!(AccessKey, key.id).revoked_at
    end

    test "at the key limit, no code is offered", %{conn: conn, scope: scope, adapter: adapter} do
      for _ <- 1..AccessKeys.key_limit(), do: enrolled_key_fixture(scope, adapter)
      {:ok, lv, _html} = live(conn, tab_path(scope, adapter))

      refute has_element?(lv, "#adapter-code-new")
      render_hook(lv, "create_code", %{})
      assert AccessKeys.list_enrolment_codes(scope, adapter) == []
    end
  end

  describe "a member" do
    test "sees the keys, no button, and the line that says who changes integrations",
         %{scope: scope, adapter: adapter} do
      %{access_key: key} = enrolled_key_fixture(scope, adapter, label: "shop-adapter")
      {:ok, lv, _html} = live(member_conn(scope), tab_path(scope, adapter))

      assert has_element?(lv, "#key-#{key.key_id}", "shop-adapter")
      refute has_element?(lv, "#key-#{key.key_id}-revoke")
      refute has_element?(lv, "#adapter-enrol")

      assert words(lv, "#adapter-readers") ==
               "Only organisation owners and admins change integrations."
    end

    test "is refused the code's and the revocation's paths and events",
         %{scope: scope, adapter: adapter} do
      %{access_key: key} = enrolled_key_fixture(scope, adapter)
      conn = member_conn(scope)

      {:ok, row, _code} = AccessKeys.create_enrolment_code(scope, adapter, %{})

      for rest <- ["/new-code", "/keys/#{key.key_id}/revoke", "/codes/#{row.id}/revoke"] do
        {:ok, _lv, html} =
          live(conn, tab_path(scope, adapter, rest))
          |> follow_redirect(conn, tab_path(scope, adapter))

        assert html =~ "Only organisation owners and admins change integrations."
      end

      {:ok, lv, _html} = live(conn, tab_path(scope, adapter))
      refute has_element?(lv, "#code-#{row.id}")
      render_hook(lv, "create_code", %{})
      assert_patch(lv, tab_path(scope, adapter))
      render_hook(lv, "revoke_code", %{})
      assert_patch(lv, tab_path(scope, adapter))
      assert [%{id: id}] = AccessKeys.list_enrolment_codes(scope, adapter)
      assert id == row.id
      refute Repo.get!(AccessKey, key.id).revoked_at
    end
  end
end
