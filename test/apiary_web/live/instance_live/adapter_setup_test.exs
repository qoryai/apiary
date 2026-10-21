defmodule ApiaryWeb.InstanceLive.AdapterSetupTest do
  # Set up on the pages of Instance settings › Adapters, for an instance admin: on an
  # adapter's Overview, its Set-up row, Not set up yet, while the adapter declares where
  # to be set up, with Set up and what it does while it holds a key in use; on the list,
  # Set up on the row of such an adapter alone. Each is a form that posts, with the
  # session's CSRF token, to the adapter's set-up (`ApiaryWeb.AdapterSetupController`).
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{AccessKeys, Repo}
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  @hint "Takes you to the adapter, to set it up where it reads from. Each use gives it a new one-time pass."

  setup do
    admin = instance_admin_scope()

    %{adapter: adapter, access_key: key} =
      settable_adapter_fixture(%{name: unique_adapter_name("Acme tracker")})

    %{admin: admin, adapter: adapter, key: key, conn: log_in_user(build_conn(), admin.user)}
  end

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> String.replace(~r/<(p|span|button|dt|dd)[\s>]/, " \\0")
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  defp overview(conn, adapter), do: live(conn, "/instance/adapters/#{adapter.public_id}")

  test "the Overview says it is not set up yet, with Set up and what it does",
       %{conn: conn, adapter: adapter} do
    {:ok, lv, _html} = overview(conn, adapter)

    assert words(lv, "#adapter-overview") =~
             "Set-up Not set up yet · Set up " <> @hint

    form = element(lv, "#adapter-setup")
    assert render(form) =~ ~s(action="/instance/adapters/#{adapter.public_id}/setup")
    assert render(form) =~ ~s(method="post")
    assert render(form) =~ ~s(name="_csrf_token")
    refute render(form) =~ ~s(name="back")
    assert words(lv, "#adapter-setup-button") == "Set up"
  end

  test "without a key in use, the Overview says it is not set up yet, with no Set up",
       %{conn: conn, adapter: adapter, key: key, admin: admin} do
    {:ok, _} = AccessKeys.revoke_access_key(admin, key)
    {:ok, lv, _html} = overview(conn, adapter)

    assert words(lv, "#adapter-overview-setup") == "Not set up yet"
    refute has_element?(lv, "#adapter-setup")
    refute has_element?(lv, "#adapter-setup-hint")
  end

  test "while the adapter declares no setup_url, the Overview has no Set-up row",
       %{conn: conn, adapter: adapter} do
    {1, _} = Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [setup_url: nil])
    {:ok, lv, html} = overview(conn, adapter)

    refute has_element?(lv, "#adapter-overview-setup")
    refute html =~ "Set-up"
    refute html =~ "Not set up yet"
    refute has_element?(lv, "#adapter-setup")
  end

  test "the list offers Set up on the row of an adapter that can be set up, and no other",
       %{conn: conn, adapter: adapter} do
    other = adapter_fixture(%{name: unique_adapter_name("Other tracker")})
    {:ok, lv, _html} = live(conn, ~p"/instance/adapters")

    id = "#adapter-#{adapter.public_id}-setup"
    assert has_element?(lv, id)
    assert words(lv, id <> "-button") == "Set up"
    assert render(element(lv, id)) =~ ~s(action="/instance/adapters/#{adapter.public_id}/setup")
    assert render(element(lv, id)) =~ ~r/<input[^>]* type="hidden" name="back" value="list"/

    refute has_element?(lv, "#adapter-#{other.public_id}-setup")
  end

  test "with no adapter to set up, the list has no Set up", %{conn: conn, adapter: adapter} do
    {1, _} = Repo.update_all(from(n in Node, where: n.id == ^adapter.id), set: [setup_url: nil])
    {:ok, lv, html} = live(conn, ~p"/instance/adapters")

    refute has_element?(lv, "#adapter-#{adapter.public_id}-setup")
    refute html =~ "Set up"
  end
end
