defmodule ApiaryWeb.InstanceLive.NodesTest do
  # Instance settings › Nodes (`ApiaryWeb.InstanceLive.Nodes`, `ApiaryWeb.InstanceLive.Node`),
  # for an instance admin: the instance's pool and gateway, each with its Overview, its
  # Access key tab, where Revoke is the one act, and its Settings, the pool's instance
  # limit; a path that does not exist for anyone else. Then a workspace's Nodes page, which
  # lists the instance's gateway, and the instance's pool while the workspace has no pool
  # in use, with links only for an instance admin. Not async: the instance has one pool
  # and one gateway in use.
  use ApiaryWeb.ConnCase, async: false

  import Ecto.Query
  import Phoenix.LiveViewTest
  import Apiary.AccessKeysFixtures
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Adapters.Installed, as: InstalledAdapters
  alias Apiary.AccessKeys.AccessKey
  alias Apiary.Audit.Entry
  alias Apiary.Nodes.Node
  alias Apiary.Repo

  @moduletag needs: :factory

  setup do
    admin = instance_admin_scope()
    pool = instance_pool_fixture(%{name: "shared-pool", installed_as: "shared-pool"})
    gateway = instance_gateway_fixture(%{name: "shared-gateway", installed_as: "shared-gateway"})

    %{
      admin: admin,
      pool: pool,
      gateway: gateway,
      conn: log_in_user(build_conn(), admin.user)
    }
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

  # A run of the instance's pool in `scope`'s workspace, claimed by `instance_id`.
  defp pool_run!(pool, scope, instance_id) do
    node_run_fixture(pool, instance_id, %{
      organisation_id: scope.organisation.id,
      workspace_id: scope.workspace.id
    })
  end

  describe "the list" do
    test "has the pool and the gateway, each leading to its page",
         %{conn: conn, pool: pool, gateway: gateway} do
      {:ok, lv, html} = live(conn, ~p"/instance/nodes")

      assert html =~ "The node pool and the gateway that run with this instance."
      assert has_element?(lv, "#instance-node-#{pool.public_id}-kind", "Node pool")
      assert has_element?(lv, "#instance-node-#{gateway.public_id}-kind", "Gateway")
      assert has_element?(lv, "#instance-node-#{pool.public_id}-state", "Never seen")

      assert has_element?(
               lv,
               ~s|#instance-node-#{pool.public_id}-name[href="/instance/nodes/#{pool.public_id}"]|
             )

      assert has_element?(lv, ~s|a[href="/instance/nodes"]|, "Nodes")
    end

    test "is a path that does not exist for anyone but an instance admin" do
      %{user: user} = sign_up_fixture()
      conn = log_in_user(build_conn(), user)

      assert_raise ApiaryWeb.NotFound, fn -> live(conn, ~p"/instance/nodes") end
    end
  end

  describe "a node's page" do
    test "the pool's Overview has its running instances of every workspace and its limit",
         %{conn: conn, pool: pool} do
      Repo.update_all(from(n in Node, where: n.id == ^pool.id), set: [instance_limit: 10])
      %{scope: a} = sign_up_fixture()
      %{scope: b} = sign_up_fixture()
      pool_run!(pool, a, "i_a")
      pool_run!(pool, b, "i_b")

      {:ok, lv, _html} = live(conn, ~p"/instance/nodes/#{pool.public_id}")

      assert has_element?(lv, "#node-instances-count", "2 of 10 running")
      assert has_element?(lv, "#node-running", "i_a")
      assert has_element?(lv, "#node-running", "i_b")
      assert has_element?(lv, "#node-about-limit", "10")
      refute has_element?(lv, "#node-running a")
    end

    test "the gateway's Overview has its URL", %{conn: conn, gateway: gateway} do
      {:ok, lv, _html} = live(conn, ~p"/instance/nodes/#{gateway.public_id}")

      assert has_element?(lv, "#node-about-url", "https://gateway.example")
      refute has_element?(lv, "#node-instances")
    end

    test "another node is a path that does not exist", %{conn: conn, admin: admin} do
      theirs = pool_fixture(admin)

      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, ~p"/instance/nodes/#{theirs.public_id}")
      end
    end

    test "the Access key tab revokes a key, and the installer is nudged for a new code",
         %{conn: conn, pool: pool} do
      %{access_key: key} = installed_key_fixture(pool)
      :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, InstalledAdapters.topic())

      {:ok, lv, html} = live(conn, ~p"/instance/nodes/#{pool.public_id}/keys")

      assert html =~ "Qory Apiary writes this node&#39;s one-time code to its folder."
      assert words(lv, "#key-#{key.key_id}-secret") == "Stays on shared-pool; it is never shown"
      refute has_element?(lv, "#key-#{key.key_id}-forager-file")
      refute html =~ "command"

      lv |> element("#key-#{key.key_id}-revoke") |> render_click()
      assert_patch(lv, ~p"/instance/nodes/#{pool.public_id}/keys/#{key.key_id}/revoke")

      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert_patch(lv, ~p"/instance/nodes/#{pool.public_id}/keys")
      assert render(lv) =~ "#{key.label} is revoked."
      assert %AccessKey{revoked_at: %DateTime{}} = Repo.get!(AccessKey, key.id)
      assert_receive :nudge
    end

    test "the Settings tab sets the pool's limit, with an entry in the instance's trail",
         %{conn: conn, pool: pool, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/instance/nodes/#{pool.public_id}/settings")

      assert lv |> form("#node-form", node: %{instance_limit: "0"}) |> render_submit() =~
               "must be greater than or equal to 1"

      assert Repo.reload!(pool).instance_limit == nil

      lv |> form("#node-form", node: %{instance_limit: "4"}) |> render_submit()
      assert Repo.reload!(pool).instance_limit == 4
      assert render(lv) =~ "shared-pool is saved."

      assert [%Entry{actor_kind: :person, actor_id: actor_id} = entry] =
               Repo.all(
                 from e in Entry, where: e.action == "node.set_limit" and e.subject_id == ^pool.id
               )

      assert {actor_id, entry.organisation_id} == {admin.user.id, admin.organisation.id}
    end

    test "the gateway's Settings tab shows its URL and sets nothing",
         %{conn: conn, gateway: gateway} do
      {:ok, lv, _html} = live(conn, ~p"/instance/nodes/#{gateway.public_id}/settings")

      assert has_element?(lv, "#node-url-field", "https://gateway.example")
      refute has_element?(lv, "#node-form")
    end
  end

  describe "a workspace's Nodes page" do
    test "has the instance's pool and gateway, and links to neither for a member",
         %{pool: pool, gateway: gateway} do
      %{scope: scope, user: user} = sign_up_fixture()
      pool_run!(pool, scope, "i_ours")
      %{scope: other} = sign_up_fixture()
      pool_run!(pool, other, "i_theirs")

      {:ok, lv, _html} =
        live(log_in_user(build_conn(), user), ~p"/#{scope.organisation}/#{scope.workspace}/nodes")

      assert has_element?(
               lv,
               "#node-#{pool.public_id}-level",
               "Instance pool: takes this workspace's runs while it has no node pool."
             )

      assert has_element?(lv, "#node-#{pool.public_id}-state", "1 running")
      assert has_element?(lv, "#nodes", "i_ours")
      refute has_element?(lv, "#nodes", "i_theirs")
      assert has_element?(lv, "#node-#{gateway.public_id}-kind", "Gateway")
      assert has_element?(lv, "#node-#{pool.public_id}-name")
      refute has_element?(lv, "#node-#{pool.public_id}-link")
      refute has_element?(lv, "#node-#{gateway.public_id}-link")
    end

    test "links them for an instance admin", %{conn: conn, admin: admin, pool: pool} do
      {:ok, lv, _html} = live(conn, ~p"/#{admin.organisation}/#{admin.workspace}/nodes")

      assert has_element?(
               lv,
               ~s|#node-#{pool.public_id}-link[href="/instance/nodes/#{pool.public_id}"]|
             )
    end

    test "has no instance pool while the workspace has a pool in use",
         %{conn: conn, admin: admin, pool: pool, gateway: gateway} do
      _ours = pool_fixture(admin)

      {:ok, lv, _html} = live(conn, ~p"/#{admin.organisation}/#{admin.workspace}/nodes")

      refute has_element?(lv, "#node-#{pool.public_id}")
      assert has_element?(lv, "#node-#{gateway.public_id}")
    end
  end
end
