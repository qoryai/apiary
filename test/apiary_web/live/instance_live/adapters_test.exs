defmodule ApiaryWeb.InstanceLive.AdaptersTest do
  # Instance settings › Adapters (`ApiaryWeb.InstanceLive.Adapters`), for an instance
  # admin: the instance's adapters by name, each leading to its Overview, with its state,
  # No key yet, or when it was last seen, or Never seen;
  # with none, that there is no adapter yet; and a path that does not exist for anyone
  # else.
  use ApiaryWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.{Adapters, Repo}
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Nodes.Node

  @moduletag needs: :factory

  setup do
    admin = instance_admin_scope()
    %{admin: admin, conn: log_in_user(build_conn(), admin.user)}
  end

  defp words(lv, selector) do
    lv
    |> element(selector)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
    |> String.split()
    |> Enum.join(" ")
  end

  test "lists the adapters by name, each with its public id and its state",
       %{conn: conn, admin: admin} do
    shop = adapter_fixture(%{name: "Shop tracker"})
    platform = adapter_fixture(%{name: "Platform tracker"})
    acme = adapter_fixture(%{name: "Acme tracker"})
    %{access_key: key} = enrolled_key_fixture(admin, shop)
    enrolled_key_fixture(admin, acme)

    Repo.update_all(from(k in AccessKey, where: k.id == ^key.id),
      set: [last_used_at: DateTime.add(DateTime.utc_now(:second), -120)]
    )

    {:ok, lv, html} = live(conn, ~p"/instance/adapters")

    assert has_element?(lv, "h1", "Adapters")
    assert page_title(lv) =~ "Adapters · Instance settings"
    assert has_element?(lv, ~s{#instance-tab-adapters[aria-current="page"]})

    assert words(lv, ".q-settings-head-sub") ==
             "The adapters that bring work into Qory from other systems. Each organisation installs the ones it uses from its Integrations page; their keys and how often they pull are set here."

    assert html =~ ~r{<th[^>]*>\s*Adapter\s*</th>}
    assert html =~ ~s(<span class="sr-only">State</span>)

    rows = for [_whole, id] <- Regex.scan(~r/id="(adapter-na_[^"-]+)"/, html), do: id

    assert rows == [
             "adapter-#{acme.public_id}",
             "adapter-#{platform.public_id}",
             "adapter-#{shop.public_id}"
           ]

    assert has_element?(
             lv,
             ~s{#adapter-#{shop.public_id}-name[href="/instance/adapters/#{shop.public_id}"]},
             "Shop tracker"
           )

    assert words(lv, "#adapter-#{shop.public_id}") =~ shop.public_id
    assert words(lv, "#adapter-#{shop.public_id}-state") =~ ~r/^Last seen \S/
    assert has_element?(lv, "#adapter-#{shop.public_id}-state-seen")
    assert words(lv, "#adapter-#{acme.public_id}-state") == "Never seen"
    assert words(lv, "#adapter-#{platform.public_id}-state") == "No key yet"
    refute html =~ "Connected"
    assert has_element?(lv, "#adapter-#{platform.public_id}-state.q-stw-hot")
    refute has_element?(lv, "#adapters-empty")
  end

  test "each row says how often the adapter pulls, or that it has not declared it yet",
       %{conn: conn} do
    shop = adapter_fixture(%{name: "Shop tracker"})
    platform = adapter_fixture(%{name: "Platform tracker"})
    acme = adapter_fixture(%{name: "Acme tracker"})

    Repo.update_all(from(n in Node, where: n.id in ^[shop.id, platform.id]),
      set: [sync_default_interval: 3600, sync_minimum_interval: 900, sync_sends_changes: true]
    )

    Repo.update_all(from(n in Node, where: n.id == ^platform.id), set: [sync_interval: 900])

    {:ok, lv, html} = live(conn, ~p"/instance/adapters")

    assert html =~ ~r{<th[^>]*>\s*Pulls\s*</th>}
    assert words(lv, "#adapter-#{shop.public_id}-pulls") == "Every hour"
    assert words(lv, "#adapter-#{platform.public_id}-pulls") == "Every 15 minutes"
    assert words(lv, "#adapter-#{acme.public_id}-pulls") == "Not declared yet"
  end

  test "with no adapter, says there is none", %{conn: conn, admin: admin} do
    assert Adapters.list_adapters(admin) == []
    {:ok, lv, html} = live(conn, ~p"/instance/adapters")

    assert has_element?(lv, "h2", "No adapter yet")
    refute has_element?(lv, "#adapters")
    refute html =~ "Add one below"
  end

  test "a removed adapter is not listed", %{conn: conn, admin: admin} do
    adapter = adapter_fixture(%{name: "Shop tracker"})
    {:ok, _adapter} = Adapters.delete_adapter(admin, adapter)

    {:ok, lv, _html} = live(conn, ~p"/instance/adapters")
    refute has_element?(lv, "#adapter-#{adapter.public_id}")
    assert has_element?(lv, "h2", "No adapter yet")
  end

  test "anyone but an instance admin, an organisation's owner included, meets Not Found" do
    adapter_fixture(%{name: "Shop tracker"})
    %{user: owner} = sign_up_fixture()

    assert_raise ApiaryWeb.NotFound, fn ->
      live(log_in_user(build_conn(), owner), ~p"/instance/adapters")
    end
  end
end
