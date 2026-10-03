defmodule Apiary.NodesTest do
  use Apiary.DataCase, async: true

  import Ecto.Query
  import Apiary.NodesFixtures
  import Apiary.OrganisationsFixtures

  alias Apiary.Audit.Entry
  alias Apiary.Nodes
  alias Apiary.Nodes.Node

  @public_id ~r/\A(nd|np)_[0-9a-hjkmnp-tv-z]{16}\z/

  setup do
    %{scope: scope} = sign_up_fixture()
    %{scope: scope}
  end

  defp entries(node) do
    Repo.all(
      from e in Entry,
        where: e.subject_kind == "node" and e.subject_id == ^node.id,
        order_by: [asc: e.inserted_at, asc: e.id]
    )
  end

  defp errors(changeset), do: errors_on(changeset)

  describe "making a node" do
    test "a node runs one instance at a time, by a public id of its kind", %{scope: scope} do
      assert {:ok, node} = Nodes.create_node(scope, %{kind: "node", name: "build-01"})

      assert %Node{kind: :node, name: "build-01", instance_limit: 1} = node
      assert node.public_id =~ @public_id
      assert "nd_" <> _ = node.public_id
      assert node.created_by_id == scope.user.id

      assert {node.organisation_id, node.workspace_id} ==
               {scope.organisation.id, scope.workspace.id}
    end

    test "a node's limit is 1, whatever is asked", %{scope: scope} do
      assert {:ok, node} =
               Nodes.create_node(scope, %{kind: "node", name: "build-01", instance_limit: 5})

      assert node.instance_limit == 1
    end

    test "a node pool has no limit unless it is given one", %{scope: scope} do
      assert {:ok, pool} = Nodes.create_node(scope, %{kind: "pool", name: "spot-runners"})
      assert %Node{kind: :pool, instance_limit: nil} = pool
      assert "np_" <> _ = pool.public_id
      assert pool.public_id =~ @public_id

      assert {:ok, limited} =
               Nodes.create_node(scope, %{
                 "kind" => "pool",
                 "name" => "ci",
                 "instance_limit" => "10"
               })

      assert limited.instance_limit == 10

      assert {:ok, empty} =
               Nodes.create_node(scope, %{
                 "kind" => "pool",
                 "name" => "ci-2",
                 "instance_limit" => ""
               })

      assert empty.instance_limit == nil
    end

    test "a pool's limit is 1 to 10000", %{scope: scope} do
      for limit <- [0, -1, 10_001] do
        assert {:error, changeset} =
                 Nodes.create_node(scope, %{kind: "pool", name: "ci", instance_limit: limit})

        assert %{instance_limit: [_]} = errors(changeset)
      end

      assert {:error, changeset} =
               Nodes.create_node(scope, %{kind: "pool", name: "ci", instance_limit: "ten"})

      assert %{instance_limit: ["is invalid"]} = errors(changeset)

      for limit <- [1, 10_000] do
        assert {:ok, %Node{instance_limit: ^limit}} =
                 Nodes.create_node(scope, %{
                   kind: "pool",
                   name: "ci-#{limit}",
                   instance_limit: limit
                 })
      end
    end

    test "the kind is one of node and pool, and must be given", %{scope: scope} do
      assert {:error, changeset} = Nodes.create_node(scope, %{kind: "machine", name: "x"})
      assert %{kind: ["is invalid"]} = errors(changeset)

      assert {:error, changeset} = Nodes.create_node(scope, %{name: "x"})
      assert %{kind: ["can't be blank"]} = errors(changeset)
    end

    test "a name is 1 to 80 characters, without control characters", %{scope: scope} do
      assert {:error, changeset} = Nodes.create_node(scope, %{kind: "node", name: ""})
      assert %{name: ["can't be blank"]} = errors(changeset)

      assert {:error, changeset} =
               Nodes.create_node(scope, %{kind: "node", name: String.duplicate("a", 81)})

      assert %{name: [_]} = errors(changeset)

      assert {:error, changeset} = Nodes.create_node(scope, %{kind: "node", name: "build\n01"})
      assert %{name: ["must not contain control characters"]} = errors(changeset)

      assert {:ok, _} = Nodes.create_node(scope, %{kind: "node", name: String.duplicate("a", 80)})
    end

    test "a name is the workspace's once among its nodes in use", %{scope: scope} do
      node = node_fixture(scope, name: "build-01")

      assert {:error, changeset} = Nodes.create_node(scope, %{kind: "pool", name: "build-01"})
      assert %{name: ["is already the name of a node in this workspace"]} = errors(changeset)

      # Another workspace of the organisation may have its own.
      other = %{scope | workspace: workspace_fixture(scope.organisation)}
      assert {:ok, _} = Nodes.create_node(other, %{kind: "node", name: "build-01"})

      # A deleted node's name is free again.
      {:ok, _} = Nodes.delete_node(scope, node)
      assert {:ok, _} = Nodes.create_node(scope, %{kind: "node", name: "build-01"})
    end

    test "every public id is new", %{scope: scope} do
      ids = for _ <- 1..20, do: node_fixture(scope).public_id
      assert length(Enum.uniq(ids)) == 20
      assert Enum.all?(ids, &(&1 =~ @public_id))
    end

    test "leaves its entry in the trail, with no person in it", %{scope: scope} do
      pool = pool_fixture(scope, name: "spot-runners", instance_limit: 10)

      assert [entry] = entries(pool)
      assert entry.action == "node.create"
      assert entry.actor_id == scope.user.id
      assert entry.workspace_id == scope.workspace.id

      assert entry.after == %{
               "name" => "spot-runners",
               "kind" => "pool",
               "public_id" => pool.public_id,
               "instance_limit" => 10
             }
    end
  end

  describe "changing a node" do
    test "renames it and changes a pool's limit; the kind stays", %{scope: scope} do
      pool = pool_fixture(scope, name: "spot-runners")

      assert {:ok, changed} =
               Nodes.update_node(scope, pool, %{
                 name: "ci-runners",
                 instance_limit: 3,
                 kind: "node"
               })

      assert %Node{name: "ci-runners", instance_limit: 3, kind: :pool} = changed
      assert "np_" <> _ = changed.public_id

      assert {:ok, %Node{instance_limit: nil}} =
               Nodes.update_node(scope, changed, %{instance_limit: ""})
    end

    test "a node keeps its limit of 1 and its kind", %{scope: scope} do
      node = node_fixture(scope)

      assert {:ok, changed} = Nodes.update_node(scope, node, %{instance_limit: 4, kind: "pool"})
      assert %Node{kind: :node, instance_limit: 1} = changed
    end

    test "refuses a limit out of range", %{scope: scope} do
      pool = pool_fixture(scope)
      assert {:error, changeset} = Nodes.update_node(scope, pool, %{instance_limit: 0})
      assert %{instance_limit: [_]} = errors(changeset)
    end

    test "records what changed, and nothing when nothing did", %{scope: scope} do
      pool = pool_fixture(scope, name: "spot-runners")

      {:ok, pool} = Nodes.update_node(scope, pool, %{name: "ci-runners", instance_limit: 5})
      {:ok, _same} = Nodes.update_node(scope, pool, %{name: "ci-runners"})

      assert [_created, edit] = entries(pool)
      assert edit.action == "node.edit"
      assert edit.before == %{"name" => "spot-runners", "instance_limit" => nil}
      assert edit.after == %{"name" => "ci-runners", "instance_limit" => 5}
    end
  end

  describe "deleting a node" do
    test "takes it out of the workspace's nodes, and keeps its row", %{scope: scope} do
      node = node_fixture(scope, name: "build-01")

      assert {:ok, deleted} = Nodes.delete_node(scope, node)
      assert %DateTime{} = deleted.deleted_at
      assert deleted.deleted_by_id == scope.user.id

      assert Nodes.list_nodes(scope) == []
      assert Nodes.get_node(scope, node.public_id) == nil
      assert Repo.get!(Node, node.id).deleted_at

      assert [_created, entry] = entries(node)
      assert entry.action == "node.delete"
      assert entry.before == %{"deleted_at" => nil}
      assert %{"name" => "build-01", "kind" => "node"} = entry.details
    end

    test "a deleted node is not found again", %{scope: scope} do
      node = node_fixture(scope)
      {:ok, _} = Nodes.delete_node(scope, node)

      assert Nodes.delete_node(scope, node) == {:error, :not_found}
      assert Nodes.update_node(scope, node, %{name: "again"}) == {:error, :not_found}
    end
  end

  describe "who may" do
    test "a member reads the nodes and changes none", %{scope: owner} do
      node = node_fixture(owner, name: "build-01")
      %{scope: member} = member_fixture(owner, :member)

      assert [%Node{id: id}] = Nodes.list_nodes(member)
      assert id == node.id
      assert %Node{} = Nodes.get_node(member, node.public_id)

      assert Nodes.create_node(member, %{kind: "node", name: "build-02"}) == {:error, :forbidden}
      assert Nodes.update_node(member, node, %{name: "renamed"}) == {:error, :forbidden}
      assert Nodes.delete_node(member, node) == {:error, :forbidden}

      assert Repo.get!(Node, node.id).name == "build-01"
      assert Nodes.list_nodes(owner) |> length() == 1
    end

    test "an admin and an owner make, change and delete nodes", %{scope: owner} do
      %{scope: admin} = member_fixture(owner, :admin)

      for scope <- [owner, admin] do
        assert {:ok, node} = Nodes.create_node(scope, %{kind: "pool", name: unique_node_name()})
        assert {:ok, node} = Nodes.update_node(scope, node, %{instance_limit: 2})
        assert {:ok, _} = Nodes.delete_node(scope, node)
      end
    end

    test "a member made a member after their page opened is refused", %{scope: owner} do
      %{scope: admin, membership: membership} = member_fixture(owner, :admin)
      {:ok, _} = Apiary.Organisations.set_member_level(owner, membership.id, :member)

      assert Nodes.create_node(admin, %{kind: "node", name: "build-01"}) == {:error, :forbidden}
    end
  end

  describe "the organisation and the workspace" do
    test "a node of another organisation is neither read nor changed", %{scope: scope} do
      %{scope: other} = sign_up_fixture()
      theirs = node_fixture(other, name: "build-01")

      assert Nodes.list_nodes(scope) == []
      assert Nodes.get_node(scope, theirs.public_id) == nil
      assert Nodes.update_node(scope, theirs, %{name: "mine"}) == {:error, :not_found}
      assert Nodes.delete_node(scope, theirs) == {:error, :not_found}
      assert Repo.get!(Node, theirs.id).name == "build-01"
    end

    test "a node of another workspace of the organisation is not this one's", %{scope: scope} do
      other = %{scope | workspace: workspace_fixture(scope.organisation)}
      theirs = node_fixture(other, name: "build-01")

      assert Nodes.list_nodes(scope) == []
      assert Nodes.get_node(scope, theirs.public_id) == nil
      assert Nodes.update_node(scope, theirs, %{name: "mine"}) == {:error, :not_found}
      assert Nodes.delete_node(scope, theirs) == {:error, :not_found}
      assert [_] = Nodes.list_nodes(other)
    end
  end

  describe "reading the nodes" do
    test "by name, narrowed by words of a name or an id, and by kind", %{scope: scope} do
      build = node_fixture(scope, name: "build-01")
      pool = pool_fixture(scope, name: "spot-runners")
      _mac = node_fixture(scope, name: "mac-mini")

      assert Enum.map(Nodes.list_nodes(scope), & &1.name) == [
               "build-01",
               "mac-mini",
               "spot-runners"
             ]

      assert [%{id: id}] = Nodes.list_nodes(scope, %{q: "BUILD"})
      assert id == build.id
      assert [%{id: ^id}] = Nodes.list_nodes(scope, %{q: String.upcase(build.public_id)})
      assert [%{id: pool_id}] = Nodes.list_nodes(scope, %{kind: :pool})
      assert pool_id == pool.id
      assert Nodes.list_nodes(scope, %{q: "%"}) == []
      assert Nodes.list_nodes(scope, %{q: "spot", kind: :node}) == []

      assert Nodes.count_nodes(scope) == %{node: 2, pool: 1}
    end
  end
end
