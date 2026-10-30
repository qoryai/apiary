defmodule ApiaryWeb.InstanceLive.NodesTest do
  # Instance settings › Nodes (`ApiaryWeb.InstanceLive.Nodes`, `ApiaryWeb.InstanceLive.Node`),
  # for an instance admin: the instance's pool and gateway, each with its Overview, its
  # Access key tab, which says a new code comes after a revoke only for a node of a kind
  # a setting declares, under any name, and where Revoke is the one act, refused for a person no longer an instance
  # admin and for a node deleted meanwhile, and its Settings, the pool's instance limit;
  # a path that does not exist for anyone else. Then a workspace's Nodes page, which
  # lists the instance's gateway, and the instance's pool while the workspace has no pool
  # in use, with links only for an instance admin, under a kind or a search; and a
  # workspace's node pages, where the default is the instance's gateway. Not async: the
  # instance has one pool and one gateway in use.
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

  # Declares the instance's nodes as the settings would, for this test alone.
  defp declare(declared) do
    previous = Application.fetch_env(:apiary, :installed_nodes)
    Application.put_env(:apiary, :installed_nodes, declared)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:apiary, :installed_nodes, value)
        :error -> Application.delete_env(:apiary, :installed_nodes)
      end
    end)
  end

  # The ids of the Nodes page's rows of nodes, in their order.
  defp row_ids(lv) do
    lv
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#nodes [id]")
    |> LazyHTML.attribute("id")
    |> Enum.filter(&Regex.match?(~r/\Anode-n[a-z]_[0-9a-z]+\z/, &1))
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

      assert html =~
               "The Qory Pool and the Qory Gateway that run with this instance. Qory Apiary " <>
                 "makes them and writes their one-time codes. The Qory Pool takes the runs of " <>
                 "every workspace that has no pool. The Qory Gateway serves every organisation."

      assert words(lv, "#instance-node-#{pool.public_id}-name") == "Qory Pool"
      assert words(lv, "#instance-node-#{gateway.public_id}-name") == "Qory Gateway"
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
      assert words(lv, "#settings-section-title") == "Qory Pool"
    end

    test "the gateway's Overview has its URL", %{conn: conn, gateway: gateway} do
      {:ok, lv, _html} = live(conn, ~p"/instance/nodes/#{gateway.public_id}")

      assert has_element?(lv, "#node-about-url", "https://gateway.example")
      refute has_element?(lv, "#node-instances")
      assert words(lv, "#settings-section-title") == "Qory Gateway"
    end

    test "another node is a path that does not exist", %{conn: conn, admin: admin} do
      theirs = pool_fixture(admin)

      assert_raise ApiaryWeb.NotFound, fn ->
        live(conn, ~p"/instance/nodes/#{theirs.public_id}")
      end
    end

    test "the Access key tab revokes a key, and the installer is nudged for a new code",
         %{conn: conn, pool: pool} do
      declare(%{pool: "shared-pool", gateway: nil, url: nil})
      %{access_key: key} = installed_key_fixture(pool)
      :ok = Phoenix.PubSub.subscribe(Apiary.PubSub, InstalledAdapters.topic())

      {:ok, lv, html} = live(conn, ~p"/instance/nodes/#{pool.public_id}/keys")

      assert html =~ "Qory Apiary writes this node&#39;s one-time code to its folder."
      assert html =~ "When you revoke the key, Qory Apiary writes a new code"
      refute html =~ "This instance has no setting for this node"
      assert words(lv, "#key-#{key.key_id}-secret") == "Stays on the Qory Pool; it is never shown"
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

    test "the Access key tab of a node no setting declares says no new code comes",
         %{conn: conn, pool: pool, gateway: gateway} do
      declare(%{pool: nil, gateway: nil, url: nil})

      for node <- [pool, gateway] do
        {:ok, lv, _html} = live(conn, ~p"/instance/nodes/#{node.public_id}/keys")

        assert words(lv, "#node-access-key-intro") ==
                 "This instance has no setting for this node, so Qory Apiary writes no new code after a revoke."
      end
    end

    test "the Access key tab of a node declared under another name says a new code comes",
         %{conn: conn, pool: pool, gateway: gateway} do
      # The installer renames each node to the declared name and writes it a new code.
      declare(%{pool: "other-pool", gateway: "edge", url: "https://gateway.example"})

      for node <- [pool, gateway] do
        {:ok, lv, _html} = live(conn, ~p"/instance/nodes/#{node.public_id}/keys")

        assert words(lv, "#node-access-key-intro") ==
                 "Qory Apiary writes this node's one-time code to its folder. When you revoke the key, Qory Apiary writes a new code to the node's code file, and the node enrols with it when it reads the file."
      end
    end

    test "the Settings tab sets the pool's limit, with an entry in the instance's trail",
         %{conn: conn, pool: pool, admin: admin} do
      {:ok, lv, _html} = live(conn, ~p"/instance/nodes/#{pool.public_id}/settings")

      assert lv |> form("#node-form", node: %{instance_limit: "0"}) |> render_submit() =~
               "must be greater than or equal to 1"

      assert Repo.reload!(pool).instance_limit == nil

      lv |> form("#node-form", node: %{instance_limit: "4"}) |> render_submit()
      assert Repo.reload!(pool).instance_limit == 4
      assert render(lv) =~ "The Qory Pool is saved."

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

      assert words(lv, "#node-#{pool.public_id}-level") ==
               "The instance provides the Qory Pool to every workspace that has no pool. " <>
                 "It belongs to no workspace or organisation."

      assert words(lv, "#node-#{gateway.public_id}-level") ==
               "The instance provides the Qory Gateway to every organisation. " <>
                 "It belongs to no workspace or organisation."

      assert words(lv, "#node-#{pool.public_id}-name") == "Qory Pool"
      assert words(lv, "#node-#{gateway.public_id}-name") == "Qory Gateway"

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

      assert words(lv, "#node-#{pool.public_id}-link") == "Qory Pool"
    end

    test "has no instance pool while the workspace has a pool in use",
         %{conn: conn, admin: admin, pool: pool, gateway: gateway} do
      _ours = pool_fixture(admin)

      {:ok, lv, _html} = live(conn, ~p"/#{admin.organisation}/#{admin.workspace}/nodes")

      refute has_element?(lv, "#node-#{pool.public_id}")
      assert has_element?(lv, "#node-#{gateway.public_id}")
    end

    test "narrowed by kind or by a search, lists the instance's nodes that match alone",
         %{pool: pool, gateway: gateway} do
      %{scope: scope, user: user} = sign_up_fixture()
      ours = node_fixture(scope, %{name: "edge-node"})
      conn = log_in_user(build_conn(), user)
      nodes = ~p"/#{scope.organisation}/#{scope.workspace}/nodes"

      {:ok, lv, _html} = live(conn, nodes <> "?kind=node")
      assert has_element?(lv, "#node-#{ours.public_id}")
      refute has_element?(lv, "#node-#{pool.public_id}")
      refute has_element?(lv, "#node-#{gateway.public_id}")

      {:ok, lv, _html} = live(conn, nodes <> "?kind=gateway")
      assert has_element?(lv, "#node-#{gateway.public_id}")
      refute has_element?(lv, "#node-#{pool.public_id}")

      {:ok, lv, _html} = live(conn, nodes <> "?q=zzzz")
      refute has_element?(lv, "#node-#{ours.public_id}")
      refute has_element?(lv, "#node-#{pool.public_id}")
      refute has_element?(lv, "#node-#{gateway.public_id}")

      {:ok, lv, _html} = live(conn, nodes <> "?q=shared-gate")
      assert has_element?(lv, "#node-#{gateway.public_id}")
      refute has_element?(lv, "#node-#{pool.public_id}")

      {:ok, lv, _html} = live(conn, nodes <> "?q=qory")
      assert has_element?(lv, "#node-#{gateway.public_id}")
      assert has_element?(lv, "#node-#{pool.public_id}")
      refute has_element?(lv, "#node-#{ours.public_id}")

      {:ok, lv, _html} = live(conn, nodes <> "?q=Qory+Pool")
      assert has_element?(lv, "#node-#{pool.public_id}")
      refute has_element?(lv, "#node-#{gateway.public_id}")
    end

    test "sorts the instance's nodes by the names it shows, Qory Gateway and Qory Pool",
         %{pool: pool, gateway: gateway} do
      %{scope: scope, user: user} = sign_up_fixture()
      ours = node_fixture(scope, %{name: "Quarry"})
      conn = log_in_user(build_conn(), user)
      nodes = ~p"/#{scope.organisation}/#{scope.workspace}/nodes"

      for path <- [nodes, nodes <> "?sort=seen"] do
        {:ok, lv, _html} = live(conn, path)

        assert row_ids(lv) == [
                 "node-#{gateway.public_id}",
                 "node-#{pool.public_id}",
                 "node-#{ours.public_id}"
               ]
      end
    end
  end

  describe "a workspace's node pages, where the default is the instance's gateway" do
    setup do
      %{scope: scope, user: user} = sign_up_fixture()
      node = node_fixture(scope, %{gateway_choice: :default})
      %{scope: scope, node: node, member: log_in_user(build_conn(), user)}
    end

    test "the forms for a node and a pool say the default is this instance's gateway",
         %{scope: scope, member: conn} do
      for path <- [
            ~p"/#{scope.organisation}/#{scope.workspace}/nodes/new",
            ~p"/#{scope.organisation}/#{scope.workspace}/nodes/new-pool"
          ] do
        {:ok, _lv, html} = live(conn, path)

        assert html =~
                 "On Default gateway, runs go through the Qory Gateway, the default for this instance."
      end
    end

    test "with a gateway of the workspace too, the form groups the instance's under This instance",
         %{scope: scope, member: conn, gateway: gateway} do
      ours = gateway_fixture(scope)
      {:ok, lv, _html} = live(conn, ~p"/#{scope.organisation}/#{scope.workspace}/nodes/new")

      assert has_element?(lv, ~s|optgroup[label="This workspace"] option[value="#{ours.id}"]|)
      assert has_element?(lv, ~s|optgroup[label="This instance"] option[value="#{gateway.id}"]|)

      assert words(lv, ~s|optgroup[label="This instance"] option[value="#{gateway.id}"]|) ==
               "Qory Gateway"
    end

    test "the command, its Forager file and Configure a machine say the Qory Gateway",
         %{scope: scope, member: conn, node: node} do
      base = ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node.public_id}"
      {:ok, lv, _html} = live(conn, base <> "/access-key")
      lv |> element("#code-new-button") |> render_click()

      assert words(lv, "#code-issued-header-description") ==
               "The command connects #{node.name} by itself, through the Qory Gateway: it " <>
                 "makes the machine's key there, saves it, and writes Qory Apiary's address " <>
                 "and public key and the gateway's address into the Forager file. The secret " <>
                 "never leaves the machine."

      assert words(lv, "#code-issued-via-ca") ==
               "If the Qory Gateway's certificate is signed by a private certificate " <>
                 "authority, add --via-ca-file and that authority's PEM file."

      %{access_key: key} = enrolled_key_fixture(scope, node, %{label: "current"})
      {:ok, lv, _html} = live(conn, base <> "/access-key/keys/#{key.key_id}/forager-file")
      assert render(lv) =~ "# the Qory Gateway"
      refute render(lv) =~ "# the gateway"

      {:ok, lv, _html} = live(conn, base <> "/access-key")

      assert words(lv, "#node-configure-steps-1") =~
               "Point the node at Qory Apiary, through the Qory Gateway."

      assert words(lv, "#node-configure-steps-1") =~
               "via sends every request to Qory Apiary through the Qory Gateway."
    end

    test "the node's Overview, Settings and Access key tabs name the Qory Gateway",
         %{scope: scope, member: conn, node: node} do
      base = ~p"/#{scope.organisation}/#{scope.workspace}/nodes/#{node.public_id}"

      {:ok, _lv, html} = live(conn, base)
      assert html =~ "Qory Gateway"
      refute html =~ "of this instance"

      {:ok, _lv, html} = live(conn, base <> "/settings")

      assert html =~
               "On Default gateway, runs go through the Qory Gateway, the default for this " <>
                 "instance. On Direct, they go through no gateway."

      {:ok, lv, _html} = live(conn, base <> "/access-key")

      assert words(lv, "#node-gateway") ==
               "Runs of #{node.name} go through the Qory Gateway, at https://gateway.example. " <>
                 "The Qory Gateway has no active access key, so it isn't connected."
    end
  end

  describe "Revoke on the Access key tab, refused" do
    setup %{pool: pool} do
      %{access_key: key} = installed_key_fixture(pool)
      %{key: key}
    end

    defp confirm(conn, pool, key) do
      {:ok, lv, _html} =
        live(conn, ~p"/instance/nodes/#{pool.public_id}/keys/#{key.key_id}/revoke")

      lv
    end

    test "for a person no longer an instance admin, leads to the list and revokes nothing",
         %{conn: conn, pool: pool, key: key, admin: admin} do
      lv = confirm(conn, pool, key)

      Repo.update_all(
        from(m in Apiary.Organisations.Membership,
          where: m.user_id == ^admin.user.id and m.organisation_id == ^admin.organisation.id
        ),
        set: [suspended_at: DateTime.utc_now()]
      )

      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert_redirect(lv, ~p"/instance/nodes")
      assert Repo.get!(AccessKey, key.id).revoked_at == nil
    end

    test "for a node deleted meanwhile, leads to the list and revokes nothing",
         %{conn: conn, pool: pool, key: key} do
      lv = confirm(conn, pool, key)

      Repo.update_all(from(n in Node, where: n.id == ^pool.id),
        set: [deleted_at: DateTime.utc_now()]
      )

      lv |> element("#key-#{key.key_id}-confirm-button") |> render_click()
      assert_redirect(lv, ~p"/instance/nodes")
      assert Repo.get!(AccessKey, key.id).revoked_at == nil
    end
  end
end
